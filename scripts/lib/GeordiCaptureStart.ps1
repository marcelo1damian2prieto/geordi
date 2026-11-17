function Read-GeordiCaptureStartFile {
    param([Parameter(Mandatory)][string] $Path, [ValidateRange(1,67108864)][int] $MaximumBytes = 4096)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -gt $MaximumBytes) { throw 'Capture-start metadata exceeded its bound.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -le 0) { throw 'Capture-start metadata changed while being read.' }
            $offset += $read
        }
        return [Text.Encoding]::UTF8.GetString($bytes)
    } finally { $stream.Dispose() }
}

function Write-GeordiCaptureStartupDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $FailureStage,
        [Parameter(Mandatory)][string] $FailureCode,
        [AllowNull()][object] $WorkerExitCode,
        [AllowNull()][string] $ExceptionType,
        [Parameter(Mandatory)][ValidateSet('confirmed','unconfirmed','not-required')][string] $CleanupStatus
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryPath = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $diagnostic = [ordered]@{
        version = 1
        failureStage = $FailureStage
        failureCode = $FailureCode
        workerExitCode = $WorkerExitCode
        exceptionType = $ExceptionType
        cleanupStatus = $CleanupStatus
        observedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        [IO.File]::WriteAllText($temporaryPath,(ConvertTo-Json -InputObject $diagnostic -Compress),[Text.UTF8Encoding]::new($false))
        try {
            [IO.File]::Move($temporaryPath,$fullPath)
        } catch {
            if (-not [IO.File]::Exists($fullPath)) { throw }
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Stop-GeordiCaptureProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int] $ProcessId,
        [ValidateRange(1,30)][int] $TimeoutSeconds = 5,
        [string] $ExpectedStartUtc,
        [scriptblock] $KillAction
    )

    # Open a process handle first. Killing through this handle avoids sending a
    # later PID-only taskkill command to an unrelated process after PID reuse.
    $rootProcess = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $rootProcess) { return }
    try {
        if ($ExpectedStartUtc) {
            $expectedStart = [DateTimeOffset]::Parse(
                $ExpectedStartUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
            if ($rootProcess.StartTime.ToUniversalTime().Ticks -ne $expectedStart.UtcTicks) {
                throw 'Capture-start PID now belongs to a different process identity.'
            }
        }

        # A successful empty snapshot is not evidence of termination. Require
        # the root itself to be present before constructing the tracked tree.
        $processSnapshot = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,CreationDate -ErrorAction Stop)
        $rootSnapshot = @($processSnapshot | Where-Object { [int]$_.ProcessId -eq $ProcessId })
        if ($rootSnapshot.Count -ne 1) {
            throw 'Capture-start root process could not be confirmed in the process snapshot.'
        }

        $treeIds = @($ProcessId)
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($candidate in $processSnapshot) {
                $candidateId = [int]$candidate.ProcessId
                if (($treeIds -contains [int]$candidate.ParentProcessId) -and ($treeIds -notcontains $candidateId)) {
                    $treeIds += $candidateId
                    $changed = $true
                }
            }
        }
        $trackedProcesses = @($processSnapshot | Where-Object { $treeIds -contains [int]$_.ProcessId } |
            ForEach-Object { [pscustomobject]@{ Id=[int]$_.ProcessId; CreationDate=[string]$_.CreationDate } })

        if ($KillAction) {
            & $KillAction $rootProcess
        } elseif (-not $rootProcess.HasExited) {
            $rootProcess.Kill($true)
        }
        [void]$rootProcess.WaitForExit($TimeoutSeconds * 1000)

        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            do {
                $currentProcesses = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,CreationDate -ErrorAction Stop)
                $remaining = @(
                    foreach ($tracked in $trackedProcesses) {
                        $isAlive = $false
                        foreach ($current in $currentProcesses) {
                            if (([int]$current.ProcessId -eq $tracked.Id) -and
                                    ([string]$current.CreationDate -ceq $tracked.CreationDate)) {
                                $isAlive = $true
                                break
                            }
                        }
                        if ($isAlive) { $tracked }
                    }
                )
                if ($remaining.Count -eq 0) { return }
                if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
                Start-Sleep -Milliseconds 25
            } while ($true)
        } finally {
            $clock.Stop()
        }

        $remainingIds = @($remaining | ForEach-Object { $_.Id }) -join ','
        throw "Capture-start process tree could not be confirmed stopped within $TimeoutSeconds seconds (remaining PIDs: $remainingIds)."
    } finally {
        $rootProcess.Dispose()
    }
}

function Wait-GeordiCaptureFilesReleased {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Path,
        [ValidateRange(1,30)][int] $TimeoutSeconds = 5
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $lockedPaths = [Collections.Generic.List[string]]::new()
            foreach ($filePath in $Path) {
                if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { continue }
                try {
                    $stream = [IO.File]::Open($filePath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                    $stream.Dispose()
                } catch [IO.IOException] {
                    $lockedPaths.Add($filePath)
                } catch [UnauthorizedAccessException] {
                    $lockedPaths.Add($filePath)
                }
            }
            if ($lockedPaths.Count -eq 0) { return }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            Start-Sleep -Milliseconds 25
        } while ($true)
    } finally {
        $clock.Stop()
    }
    throw "Capture log files remained locked beyond $TimeoutSeconds seconds: $($lockedPaths -join ', ')"
}

function Invoke-GeordiBoundedLogFollowerStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PowerShellPath,
        [Parameter(Mandatory)][string] $WorkerPath,
        [Parameter(Mandatory)][string] $DockerPath,
        [Parameter(Mandatory)][string[]] $DockerArguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $StandardOutputPath,
        [Parameter(Mandatory)][string] $StandardErrorPath,
        [Parameter(Mandatory)][string] $ProcessRecordPath,
        [AllowNull()] $TargetMetadata,
        [ValidateRange(1,20)][int] $TimeoutSeconds = 8
    )
    $startupDiagnosticPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($ProcessRecordPath))) 'startup-diagnostic.json'
    $payload = @{ dockerPath=$DockerPath;dockerArguments=$DockerArguments;workingDirectory=$WorkingDirectory
        standardOutputPath=$StandardOutputPath;standardErrorPath=$StandardErrorPath;processRecordPath=$ProcessRecordPath
        startupDiagnosticPath=$startupDiagnosticPath;targetMetadata=$TargetMetadata }
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        (ConvertTo-Json -InputObject $payload -Compress -Depth 4)))
    $quotedWorker = '"' + $WorkerPath + '"'
    $launcher = $null
    $cleanupVerified = $true
    $cleanupFailure = $null
    $failureStage = 'launcher-startup'
    $failureCode = 'launcher-start-failed'
    $workerExitCode = $null
    $exceptionType = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $launcher = Start-Process -FilePath $PowerShellPath `
            -ArgumentList @('-NoLogo','-NoProfile','-File',$quotedWorker,'-PayloadBase64',$encodedPayload) `
            -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
        if (!$launcher.WaitForExit($TimeoutSeconds * 1000)) {
            $failureStage = 'launcher-readiness'
            $failureCode = 'launcher-timeout'
            Stop-GeordiCaptureProcessTree -ProcessId $launcher.Id
            throw 'Capture follower process launch/readiness exceeded its bound.'
        }
        if ($launcher.ExitCode -ne 0) {
            $workerExitCode = [int]$launcher.ExitCode
            $failureStage = 'worker-result'
            $failureCode = switch ($workerExitCode) {
                21 { 'worker-exited-early' }
                22 { 'worker-startup-failed' }
                23 { 'worker-cleanup-unconfirmed' }
                default { 'worker-failed-with-unknown-exit-code' }
            }
            throw 'Capture follower process failed its bounded startup check.'
        }
        if (!(Test-Path -LiteralPath $ProcessRecordPath -PathType Leaf)) {
            $failureStage = 'launcher-protocol'
            $failureCode = 'process-record-missing'
            throw 'Capture follower process failed its bounded startup check.'
        }
        $failureStage = 'launcher-record-validation'
        $failureCode = 'process-record-invalid'
        $recordText = Read-GeordiCaptureStartFile -Path $ProcessRecordPath
        $record = $recordText | ConvertFrom-Json -DateKind String -ErrorAction Stop
        if ([int]$record.id -le 0 -or [string]::IsNullOrWhiteSpace([string]$record.name) -or
                [string]::IsNullOrWhiteSpace([string]$record.startUtc)) {
            throw 'Capture follower process identity record is malformed.'
        }
        $failureStage = 'launcher-readiness'
        $failureCode = 'follower-readiness-failed'
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        if (!$process -or $process.ProcessName -cne [string]$record.name -or
                $process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$record.startUtc).UtcTicks -or
                !(Test-Path -LiteralPath $StandardOutputPath -PathType Leaf) -or
                !(Test-Path -LiteralPath $StandardErrorPath -PathType Leaf)) {
            throw 'Capture log follower did not remain ready after launch.'
        }
        return $record
    } catch {
        $exceptionType = $_.Exception.GetType().FullName
        if (Test-Path -LiteralPath $ProcessRecordPath) {
            try {
                $record = (Read-GeordiCaptureStartFile -Path $ProcessRecordPath) | ConvertFrom-Json
                Stop-GeordiCaptureProcessTree -ProcessId ([int]$record.id)
            } catch { $cleanupVerified = $false }
        }
        if ($launcher -and (Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue)) {
            try { Stop-GeordiCaptureProcessTree -ProcessId $launcher.Id } catch { $cleanupVerified = $false }
        }
        if ($cleanupVerified) {
            try {
                Wait-GeordiCaptureFilesReleased -Path @($StandardOutputPath,$StandardErrorPath) -TimeoutSeconds 5
                foreach ($path in @($ProcessRecordPath,$StandardOutputPath,$StandardErrorPath)) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
                }
            } catch {
                $cleanupVerified = $false
                $cleanupFailure = $_.Exception.Message
            }
        }
        if (-not [IO.File]::Exists($startupDiagnosticPath)) {
            try {
                $diagnosticCleanupStatus = if ($cleanupVerified) { 'confirmed' } else { 'unconfirmed' }
                Write-GeordiCaptureStartupDiagnostic -Path $startupDiagnosticPath -FailureStage $failureStage -FailureCode $failureCode -WorkerExitCode $workerExitCode -ExceptionType $exceptionType -CleanupStatus $diagnosticCleanupStatus
            } catch { }
        }
        if (-not $cleanupVerified) {
            throw "Capture follower startup failed; process/file cleanup could not be confirmed. $cleanupFailure"
        }
        throw
    } finally {
        $clock.Stop()
        if ($launcher) {
            $launcher.Dispose()
        }
    }
}
