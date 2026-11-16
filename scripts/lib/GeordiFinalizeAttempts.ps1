function Test-GeordiM19ManifestCompleted {
    param([System.Collections.IDictionary] $Manifest)
    return (($Manifest.Contains('completedUtc') -and ![string]::IsNullOrWhiteSpace([string]$Manifest.completedUtc)) -or
        ($Manifest.Contains('acceptedAttemptId') -and ![string]::IsNullOrWhiteSpace([string]$Manifest.acceptedAttemptId)))
}

function Get-GeordiFinalizeTimingDetails {
    param([Diagnostics.Stopwatch] $TotalClock,[Diagnostics.Stopwatch] $PhaseClock,[long] $DeadlineMilliseconds,
        [switch] $KeepRunning)
    if (!$KeepRunning) { $PhaseClock.Stop() }
    return [ordered]@{
        phaseElapsedMs = [long]$PhaseClock.ElapsedMilliseconds
        cumulativeElapsedMs = [long]$TotalClock.ElapsedMilliseconds
        remainingDeadlineMs = [long][Math]::Floor($DeadlineMilliseconds-$TotalClock.Elapsed.TotalMilliseconds)
    }
}

function Assert-GeordiFinalizeDeadline {
    param([Diagnostics.Stopwatch] $TotalClock,[long] $DeadlineMilliseconds)
    if ($TotalClock.Elapsed.TotalMilliseconds -ge $DeadlineMilliseconds) {
        throw 'Finalize exceeded its configured monotonic deadline.'
    }
}

function Get-GeordiFinalizeRequestTimeoutMilliseconds {
    param([Diagnostics.Stopwatch] $TotalClock,[long] $DeadlineMilliseconds,[int] $RequestedMilliseconds)
    $remaining=[long][Math]::Floor($DeadlineMilliseconds-$TotalClock.Elapsed.TotalMilliseconds)
    if($remaining -le 0){throw 'Finalize exceeded its configured monotonic deadline.'}
    return [int][Math]::Max(1,[Math]::Min($RequestedMilliseconds,$remaining))
}

function Write-GeordiM19ManifestAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [switch] $AllowCompletion,
        [switch] $LockAlreadyHeld,
        [scriptblock] $BeforePublish
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (!$LockAlreadyHeld) {
        $lock = Open-GeordiM19ManifestUpdateLock -ManifestPath $fullPath
        try {
            Write-GeordiM19ManifestAtomic -Path $fullPath -Manifest $Manifest -AllowCompletion:$AllowCompletion `
                -LockAlreadyHeld -BeforePublish $BeforePublish
            return
        } finally { $lock.Dispose() }
    }
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (!(Test-Path -LiteralPath $parent -PathType Container)) { throw 'M19 manifest parent is unavailable.' }
    $existing = $null
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        try { $existing = [IO.File]::ReadAllText($fullPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { throw 'Existing M19 manifest is malformed.' }
        if (Test-GeordiM19ManifestCompleted $existing) { throw 'Completed M19 manifest is immutable.' }
    }

    $serialized = ConvertTo-Json -InputObject $Manifest -Depth 32
    if ([Text.Encoding]::UTF8.GetByteCount($serialized) -gt 1048576) {
        throw 'M19 manifest exceeded its configured 1 MiB size bound.'
    }
    try { $candidate = $serialized | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'M19 manifest candidate failed JSON validation.' }
    if ($candidate.version -ne 2 -or [IO.Path]::GetFullPath([string]$candidate.root) -cne $parent -or
            [string]::IsNullOrWhiteSpace([string]$candidate.runId)) {
        throw 'M19 manifest candidate identity is invalid.'
    }
    if ($existing) {
        foreach ($field in @('version','root','runId','startedUtc')) {
            if ([string]$candidate[$field] -cne [string]$existing[$field]) {
                throw 'M19 manifest candidate changed stable run identity.'
            }
        }
        if ($existing.Contains('captureStartedUtc') -and
                [string]$candidate.captureStartedUtc -cne [string]$existing.captureStartedUtc) {
            throw 'M19 manifest candidate changed capture start identity.'
        }
    }

    $candidateCompleted = Test-GeordiM19ManifestCompleted $candidate
    if ($candidateCompleted) {
        if (!$AllowCompletion -or
                ($candidate.Contains('diagnosticOnly') -and $candidate.diagnosticOnly -eq $true) -or
                !$candidate.Contains('completedUtc') -or
                !$candidate.Contains('acceptedAttemptId') -or
                !$candidate.Contains('attempts') -or
                !$candidate.attempts.Contains([string]$candidate.acceptedAttemptId)) {
            throw 'M19 manifest completion candidate is invalid.'
        }
        $accepted = $candidate.attempts[[string]$candidate.acceptedAttemptId]
        if ([string]$accepted.status -cne 'completed' -or
                ($accepted.Contains('diagnosticOnly') -and $accepted.diagnosticOnly -eq $true) -or
                @($candidate.attempts.Values | Where-Object { [string]$_.status -ceq 'completed' }).Count -ne 1) {
            throw 'M19 manifest must accept exactly one completed attempt.'
        }
    } elseif ($AllowCompletion) {
        throw 'M19 completion publication requires a completed candidate.'
    }

    $temporary = "$fullPath.$([guid]::NewGuid().ToString('N')).tmp"
    $stream = $null
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($serialized)
        $stream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null

        try { $validated = [IO.File]::ReadAllText($temporary) | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { throw 'M19 manifest temporary candidate failed validation.' }
        if ([string]$validated.root -cne [string]$candidate.root -or
                [string]$validated.runId -cne [string]$candidate.runId -or
                [bool](Test-GeordiM19ManifestCompleted $validated) -ne [bool]$candidateCompleted) {
            throw 'M19 manifest temporary candidate changed identity or completion state.'
        }
        if ($BeforePublish) { & $BeforePublish }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [IO.File]::Move($temporary,$fullPath,$true)
        } else {
            [IO.File]::Move($temporary,$fullPath)
        }
    } finally {
        if ($stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Open-GeordiM19ManifestUpdateLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ManifestPath)
    $fullPath=[IO.Path]::GetFullPath($ManifestPath)
    $parent=[IO.Path]::GetDirectoryName($fullPath)
    if ([IO.Path]::GetFileName($fullPath) -cne 'manifest.json' -or !(Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'M19 manifest update lock target is invalid.'
    }
    $lockPath=Join-Path $parent 'manifest.update.lock'
    try { return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'M19 manifest is being updated by another owner.' }
}

function Update-GeordiM19ManifestAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ManifestPath,[Parameter(Mandatory)][string] $ExpectedRunId,
        [Parameter(Mandatory)][scriptblock] $Mutation)
    $fullPath=[IO.Path]::GetFullPath($ManifestPath)
    $lock=Open-GeordiM19ManifestUpdateLock -ManifestPath $fullPath
    try {
        $latest=[IO.File]::ReadAllText($fullPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($latest.version -ne 2 -or [IO.Path]::GetFullPath([string]$latest.root) -cne [IO.Path]::GetDirectoryName($fullPath) -or
                [string]$latest.runId -cne $ExpectedRunId -or (Test-GeordiM19ManifestCompleted $latest)) {
            throw 'M19 manifest identity or lifecycle changed during update.'
        }
        $mutationResult=& $Mutation $latest
        if ($mutationResult -is [bool] -and !$mutationResult) { return $latest }
        Write-GeordiM19ManifestAtomic -Path $fullPath -Manifest $latest -LockAlreadyHeld
        return $latest
    } finally { $lock.Dispose() }
}

function Open-GeordiM19FinalizeLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot)
    $path = Join-Path $CaptureRoot 'finalize.lock'
    try { return [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'Another M19 Finalize attempt owns the recovery lock.' }
}

function New-GeordiM19FinalizeAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CaptureRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $ManifestPath,
        [switch] $DiagnosticOnly
    )
    if (Test-GeordiM19ManifestCompleted $Manifest) { throw 'Completed M19 manifest is immutable.' }
    if ($Manifest.Contains('diagnosticOnly') -and $Manifest.diagnosticOnly -eq $true -and !$DiagnosticOnly) {
        throw 'Diagnostic-only M19 evidence roots cannot start production attempts.'
    }
    $attemptsRoot = Join-Path $CaptureRoot 'finalize-attempts'
    if (!(Test-Path -LiteralPath $attemptsRoot)) { [void][IO.Directory]::CreateDirectory($attemptsRoot) }
    $attemptsRootItem = Get-Item -LiteralPath $attemptsRoot -Force
    if ($attemptsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'M19 attempt root must not be redirected.' }

    $attemptId = [guid]::NewGuid().ToString('N')
    $attemptRoot = Join-Path $attemptsRoot $attemptId
    if (Test-Path -LiteralPath $attemptRoot) { throw 'M19 attempt identity collision.' }
    [void][IO.Directory]::CreateDirectory($attemptRoot)
    $attempt = [ordered]@{
        attemptId = $attemptId
        root = $attemptRoot
        status = 'running'
        diagnosticOnly = [bool]$DiagnosticOnly
        currentPhase = 'initialized'
        startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        phases = @{}
        channels = @{}
        additionalSources = @()
        failureCategory = $null
        failedPhase = $null
    }
    if (!$Manifest.Contains('attempts')) { $Manifest.attempts = @{} }
    $null = Get-GeordiM19FinalizeAttemptDirectories -CaptureRoot $CaptureRoot
    foreach ($priorId in @($Manifest.attempts.Keys)) {
        $prior = $Manifest.attempts[$priorId]
        if ([string]$prior.status -in @('running','cleanup-pending')) {
            $prior.status = 'interrupted'
            $prior.interruptedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    $Manifest.attempts[$attemptId] = $attempt
    if ($DiagnosticOnly) { $Manifest.diagnosticOnly = $true }
    Write-GeordiM19ManifestAtomic -Path $ManifestPath -Manifest $Manifest
    return [pscustomobject]@{ AttemptId=$attemptId; Root=$attemptRoot; Manifest=$Manifest }
}

function Complete-GeordiM19DiagnosticAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $AttemptId,
        [Parameter(Mandatory)][hashtable] $ChannelState,
        [Parameter(Mandatory)][object[]] $AdditionalSources,
        [hashtable] $Timing = @{},
        [scriptblock] $BeforePublish
    )
    if (Test-GeordiM19ManifestCompleted $Manifest) { throw 'Completed M19 manifest is immutable.' }
    if (!$Manifest.Contains('attempts') -or !$Manifest.attempts.Contains([string]$AttemptId)) {
        throw 'M19 Finalize attempt record is missing.'
    }
    $candidateManifest = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Manifest -Depth 32 -Compress) -AsHashtable
    $attempt = $candidateManifest.attempts[[string]$AttemptId]
    if ([string]$attempt.status -cne 'running' -or $attempt.diagnosticOnly -ne $true) {
        throw 'Only a running diagnostic-only M19 attempt may be diagnostically completed.'
    }
    $attempt.channels = $ChannelState
    $attempt.additionalSources = @($AdditionalSources)
    $attempt.status = 'diagnostic-completed'
    $attempt.finishedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $attempt.currentPhase = 'diagnostic-manifest'
    $attempt.phases['diagnostic-manifest'] = [ordered]@{
        status='PASS'; recordedUtc=[DateTimeOffset]::UtcNow.ToString('o'); details=@{ timing=$Timing }
    }
    $candidateManifest.diagnosticOnly = $true
    $candidateManifest.latestDiagnosticAttemptId = $AttemptId
    Write-GeordiM19ManifestAtomic -Path $ManifestPath -Manifest $candidateManifest -BeforePublish $BeforePublish
    return $candidateManifest
}

function Set-GeordiM19FinalizeAttemptState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $AttemptId,
        [Parameter(Mandatory)][string] $Phase,
        [ValidateSet('PASS','FAIL','CLEANUP_PENDING')][string] $Status = 'PASS',
        [hashtable] $Details = @{},
        [hashtable] $ChannelState,
        [object[]] $AdditionalSources,
        [string] $FailureCategory
    )
    if (Test-GeordiM19ManifestCompleted $Manifest) { throw 'Completed M19 manifest is immutable.' }
    if (!$Manifest.Contains('attempts') -or !$Manifest.attempts.Contains([string]$AttemptId)) {
        throw 'M19 Finalize attempt record is missing.'
    }
    $attempt = $Manifest.attempts[[string]$AttemptId]
    $attempt.currentPhase = $Phase
    $attempt.phases[$Phase] = [ordered]@{
        status = if ($Status -eq 'PASS') { 'PASS' } else { 'FAIL' }
        recordedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        details = $Details
    }
    if ($ChannelState) { $attempt.channels = $ChannelState }
    if ($PSBoundParameters.ContainsKey('AdditionalSources')) { $attempt.additionalSources = @($AdditionalSources) }
    if ($Status -ne 'PASS') {
        $attempt.status = if ($Status -eq 'CLEANUP_PENDING') { 'cleanup-pending' } else { 'failed' }
        $attempt.failedPhase = $Phase
        $attempt.failureCategory = if ($FailureCategory) { $FailureCategory } else { 'validation' }
        $attempt.finishedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-GeordiM19ManifestAtomic -Path $ManifestPath -Manifest $Manifest
    return $Manifest
}

function Complete-GeordiM19FinalizeAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $AttemptId,
        [Parameter(Mandatory)][hashtable] $ChannelState,
        [Parameter(Mandatory)][object[]] $AdditionalSources,
        [long] $PersistedMetricEvidenceBytes = -1,
        [hashtable] $Timing = @{},
        [scriptblock] $BeforePublish
    )
    if (Test-GeordiM19ManifestCompleted $Manifest) { throw 'Completed M19 manifest is immutable.' }
    if ($Manifest.Contains('diagnosticOnly') -and $Manifest.diagnosticOnly -eq $true) {
        throw 'Diagnostic-only M19 evidence cannot become a production candidate.'
    }
    if (!$Manifest.Contains('attempts') -or !$Manifest.attempts.Contains([string]$AttemptId)) {
        throw 'M19 Finalize attempt record is missing.'
    }
    $candidateManifest = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Manifest -Depth 32 -Compress) -AsHashtable
    $attempt = $candidateManifest.attempts[[string]$AttemptId]
    if ($attempt.diagnosticOnly -eq $true) { throw 'Diagnostic-only M19 evidence cannot be accepted as a production candidate.' }
    if ([string]$attempt.status -cne 'running') { throw 'Only a running M19 attempt can be accepted.' }
    $attempt.channels = $ChannelState
    $attempt.additionalSources = @($AdditionalSources)
    $attempt.status = 'completed'
    $attempt.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $attempt.currentPhase = 'manifest'
    $attempt.phases['manifest'] = [ordered]@{ status='PASS'; recordedUtc=[DateTimeOffset]::UtcNow.ToString('o'); details=@{ timing=$Timing } }
    $candidateManifest.acceptedAttemptId = $AttemptId
    $candidateManifest.completedUtc = [string]$attempt.completedUtc
    $candidateManifest.controls = $ChannelState.controls
    $candidateManifest.captures = $ChannelState.captures
    $candidateManifest.captureMetadata = $ChannelState.captureMetadata
    $candidateManifest.additionalSources = @($AdditionalSources)
    if ($PersistedMetricEvidenceBytes -ge 0) { $candidateManifest.persistedMetricEvidenceBytes = $PersistedMetricEvidenceBytes }
    Write-GeordiM19ManifestAtomic -Path $ManifestPath -Manifest $candidateManifest -AllowCompletion -BeforePublish $BeforePublish
    return $candidateManifest
}

function Write-GeordiM19AttemptFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][string] $Content)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Stop-GeordiM19TrackedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Diagnostics.Process] $Process)
    $Process.Refresh()
    if ($Process.HasExited) { return }
    $processId = [int]$Process.Id
    $processName = [string]$Process.ProcessName
    $startTicks = $Process.StartTime.ToUniversalTime().Ticks
    $current = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (!$current -or $current.ProcessName -cne $processName -or
            $current.StartTime.ToUniversalTime().Ticks -ne $startTicks) {
        throw 'Tracked Finalize process identity changed.'
    }
    $taskkillPath = Join-Path $env:SystemRoot 'System32/taskkill.exe'
    & $taskkillPath /PID $processId /T /F *> $null
    if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
        throw 'Tracked Finalize process tree could not be stopped.'
    }
    Wait-Process -Id $processId -Timeout 5 -ErrorAction SilentlyContinue
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { throw 'Tracked Finalize process remains.' }
}

function Get-GeordiM19FinalizeAttemptDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot)
    $attemptsRoot = Join-Path $CaptureRoot 'finalize-attempts'
    if (!(Test-Path -LiteralPath $attemptsRoot)) { return @() }
    $rootItem = Get-Item -LiteralPath $attemptsRoot -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'M19 attempt root is redirected.' }
    $entries = @(Get-ChildItem -LiteralPath $attemptsRoot -Force)
    $attempts = [Collections.Generic.List[IO.DirectoryInfo]]::new()
    foreach ($entry in $entries) {
        if (!$entry.PSIsContainer -or $entry.Name -notmatch '^[0-9a-f]{32}$' -or
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'M19 attempt inventory contains an unrecognized path.'
        }
        foreach ($child in Get-ChildItem -LiteralPath $entry.FullName -Force -Recurse) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'M19 attempt contains a redirected path.' }
        }
        $attempts.Add([IO.DirectoryInfo]$entry)
    }
    return @($attempts.ToArray() | Sort-Object Name)
}

function Assert-GeordiM19FinalizeLaunchRecordsRecoverable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $AttemptRoot)
    if (!(Test-Path -LiteralPath $AttemptRoot -PathType Container)) { throw 'M19 attempt directory is unavailable.' }
    foreach ($launchRecord in Get-ChildItem -LiteralPath $AttemptRoot -File -Filter '*.launch.json' -Recurse) {
        if ($launchRecord.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'M19 launch record is redirected.' }
        $processRecord = $launchRecord.FullName -replace '\.launch\.json$','.process.json'
        $stoppedMarker = $launchRecord.FullName -replace '\.launch\.json$','.stopped.json'
        if (!(Test-Path -LiteralPath $processRecord -PathType Leaf) -and
                !(Test-Path -LiteralPath $stoppedMarker -PathType Leaf)) {
            throw 'M19 process launch has no durable process identity.'
        }
    }
}

function Remove-GeordiM19FinalizeAttempts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot)
    $attempts = @(Get-GeordiM19FinalizeAttemptDirectories -CaptureRoot $CaptureRoot)
    foreach ($attempt in $attempts) {
        Remove-Item -LiteralPath $attempt.FullName -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $attempt.FullName) { throw 'M19 attempt directory remains after cleanup.' }
    }
    $attemptsRoot = Join-Path $CaptureRoot 'finalize-attempts'
    if (Test-Path -LiteralPath $attemptsRoot) {
        if (@(Get-ChildItem -LiteralPath $attemptsRoot -Force).Count -ne 0) { throw 'M19 attempt root contains unowned files.' }
        Remove-Item -LiteralPath $attemptsRoot -Force -ErrorAction Stop
    }
}
