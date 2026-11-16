Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'GeordiCaptureGenerations.ps1')

function Get-GeordiDiagnosticEvidenceIdentity {
    param([Parameter(Mandatory)][string] $CaptureRoot)
    $fullRoot = [IO.Path]::GetFullPath($CaptureRoot)
    $item = Get-Item -LiteralPath $fullRoot -Force -ErrorAction Stop
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            [IO.Path]::GetDirectoryName($fullRoot) -cne $temp -or
            (Split-Path -Leaf $fullRoot) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
        throw 'Diagnostic evidence root failed private ownership validation.'
    }
    $manifestPath = Join-Path $fullRoot 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($manifest.version -ne 2 -or [IO.Path]::GetFullPath([string]$manifest.root) -cne $fullRoot -or
            [string]::IsNullOrWhiteSpace([string]$manifest.runId)) {
        throw 'Diagnostic evidence manifest identity is invalid.'
    }
    return [pscustomobject]@{ Root=$fullRoot; ManifestPath=$manifestPath; Manifest=$manifest; RunId=[string]$manifest.runId }
}

function New-GeordiDiagnosticSentinelSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot, [string] $DiagnosticInvocationId = [guid]::NewGuid().ToString('N'))
    if ($DiagnosticInvocationId -notmatch '^[0-9a-f]{32}$') { throw 'Diagnostic invocation identity is invalid.' }
    $identity = Get-GeordiDiagnosticEvidenceIdentity $CaptureRoot
    $directory = Join-Path $identity.Root 'diagnostic-evidence/sentinels'
    [void][IO.Directory]::CreateDirectory($directory)
    $dirItem = Get-Item -LiteralPath $directory -Force
    if ($dirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Diagnostic sentinel destination was redirected.' }
    $path = Join-Path $directory "$DiagnosticInvocationId.jsonl"
    $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $source = [ordered]@{
        candidateId=$identity.RunId; runId=$identity.RunId; diagnosticInvocationId=$DiagnosticInvocationId
        phase='m14-diagnostic'; state='open'; path=$path; sourceIdentity=[IO.Path]::GetFileName($path)
        createdUtc=[DateTimeOffset]::UtcNow.ToString('o'); sentinelCount=0; byteCount=0L; sha256=$null
    }
    . (Join-Path $PSScriptRoot 'GeordiFinalizeAttempts.ps1')
    try {
        $identity.Manifest=Update-GeordiM19ManifestAtomic -ManifestPath $identity.ManifestPath -ExpectedRunId $identity.RunId -Mutation {
            param($latest)
            if (!$latest.ContainsKey('diagnosticSentinelSources')) { $latest.diagnosticSentinelSources=@{} }
            if ($latest.diagnosticSentinelSources.ContainsKey($DiagnosticInvocationId)) { throw 'Diagnostic invocation identity already exists.' }
            $latest.diagnosticSentinelSources[$DiagnosticInvocationId]=$source
        }
    } catch {
        $stream.Dispose()
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        throw 'Diagnostic sentinel allocation failed; private evidence withheld.'
    }
    return [pscustomobject]@{ Identity=$identity; Source=$source; Stream=$stream; Path=$path; Sealed=$false }
}

function Add-GeordiDiagnosticSentinel {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Source, [Parameter(Mandatory)][ValidateSet('browser-state','browser-nonce','browser-pkce','browser-code','browser-csrf','browser-cookie','webhook-token','runtime-bearer')][string] $Class,
        [Parameter(Mandatory)][string] $Value)
    if ($Source.Sealed -or $Source.Source.state -cne 'open' -or !$Source.Stream -or
            [string]$Source.Identity.Manifest.diagnosticSentinelSources[$Source.Source.diagnosticInvocationId].state -cne 'open') {
        throw 'Diagnostic sentinel source is not open.'
    }
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 16384 -or $Value.Length -lt 8 -or $Source.Source.sentinelCount -ge 256) {
        throw 'Diagnostic sentinel value exceeded its bounded evidence contract.'
    }
    $record = ConvertTo-Json -InputObject ([ordered]@{ class=$Class; value=$Value }) -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($record + "`n")
    if ($Source.Source.byteCount + $bytes.Length -gt 1048576) { throw 'Diagnostic sentinel source exceeded its 1 MiB bound.' }
    $Source.Stream.Write($bytes,0,$bytes.Length)
    $Source.Source.sentinelCount++
    $Source.Source.byteCount += $bytes.Length
    $Source.Identity.Manifest.diagnosticSentinelSources[$Source.Source.diagnosticInvocationId]=$Source.Source
}

function Seal-GeordiDiagnosticSentinelSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Source, [switch] $Failed)
    $targetState=if($Failed){'failed-sealed'}else{'sealed'}
    if ($Source.Source.state -in @('sealed','failed-sealed')) {
        if ([string]$Source.Source.state -cne $targetState) { throw 'Invalid diagnostic sentinel terminal-state transition.' }
        $current=[IO.File]::ReadAllText($Source.Identity.ManifestPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $record=$current.diagnosticSentinelSources[[string]$Source.Source.diagnosticInvocationId]
        if (!$record -or [string]$record.state -cne $targetState -or [string]$record.path -cne [string]$Source.Path -or
                [string]$record.sourceIdentity -cne [string]$Source.Source.sourceIdentity -or
                [string]$record.runId -cne [string]$Source.Identity.RunId -or [string]$record.candidateId -cne [string]$Source.Identity.RunId -or
                [string]$record.diagnosticInvocationId -cne [string]$Source.Source.diagnosticInvocationId -or
                (Get-FileHash -LiteralPath $Source.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$record.sha256 -or
                (Get-Item -LiteralPath $Source.Path -Force).Length -ne [long]$record.byteCount) {
            throw 'Repeated diagnostic sentinel seal failed integrity validation.'
        }
        $Source.Sealed=$true
        return $record
    }
    if ($Source.Source.state -cne 'open' -or !$Source.Stream) { throw 'Invalid diagnostic sentinel lifecycle transition.' }
    $Source.Stream.Flush($true); $Source.Stream.Dispose(); $Source.Stream=$null
    $bytes = [IO.File]::ReadAllBytes($Source.Path)
    if ($bytes.Length -ne [long]$Source.Source.byteCount -or $bytes.Length -gt 1048576) { throw 'Diagnostic sentinel source size changed before sealing.' }
    $records = @([Text.UTF8Encoding]::new($false,$true).GetString($bytes).Split("`n",[StringSplitOptions]::RemoveEmptyEntries))
    if ($records.Count -ne [int]$Source.Source.sentinelCount) { throw 'Diagnostic sentinel source record count is invalid.' }
    foreach ($record in $records) {
        $parsed = $record | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($parsed.Keys.Count -ne 2 -or !$parsed.ContainsKey('class') -or !$parsed.ContainsKey('value') -or
                $parsed.class -notin @('browser-state','browser-nonce','browser-pkce','browser-code','browser-csrf','browser-cookie','webhook-token','runtime-bearer') -or
                [string]$parsed.value -match '[\r\n]' -or [string]$parsed.value -notmatch '.{8,}') { throw 'Diagnostic sentinel source contains a malformed record.' }
    }
    $Source.Source.state = $targetState
    $Source.Source.sealedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $Source.Source.byteCount = [long]$bytes.Length
    $Source.Source.sha256 = (Get-FileHash -LiteralPath $Source.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    . (Join-Path $PSScriptRoot 'GeordiFinalizeAttempts.ps1')
    $item = Get-Item -LiteralPath $Source.Path -Force
    $item.IsReadOnly=$true
    try {
        $updated=Update-GeordiM19ManifestAtomic -ManifestPath $Source.Identity.ManifestPath -ExpectedRunId $Source.Identity.RunId -Mutation {
            param($latest)
            if (!$latest.ContainsKey('diagnosticSentinelSources')) { throw 'Diagnostic source registry disappeared.' }
            $registered=$latest.diagnosticSentinelSources[[string]$Source.Source.diagnosticInvocationId]
            if (!$registered -or [string]$registered.state -cne 'open' -or [string]$registered.path -cne [string]$Source.Path -or
                    [string]$registered.sourceIdentity -cne [string]$Source.Source.sourceIdentity -or
                    [string]$registered.runId -cne [string]$Source.Identity.RunId -or
                    [string]$registered.candidateId -cne [string]$Source.Identity.RunId -or
                    [string]$registered.diagnosticInvocationId -cne [string]$Source.Source.diagnosticInvocationId) {
                throw 'Conflicting diagnostic source update rejected.'
            }
            $latest.diagnosticSentinelSources[[string]$Source.Source.diagnosticInvocationId]=$Source.Source
        }
    } catch {
        $item.IsReadOnly=$false
        throw 'Diagnostic sentinel sealing failed; private evidence withheld.'
    }
    $Source.Identity.Manifest=$updated
    $Source.Source=$updated.diagnosticSentinelSources[[string]$Source.Source.diagnosticInvocationId]
    $Source.Sealed=$true
    return $Source.Source
}

function Invoke-GeordiDiagnosticEvidenceLifecycle {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock] $Action,[scriptblock] $SourceProvider,[AllowNull()] $Source)
    $primaryFailure=$null
    $actionSucceeded=$false
    try {
        & $Action
        $actionSucceeded=$true
    } catch {
        $primaryFailure=$_
        throw
    } finally {
        try {
            $ownedSource=$Source
            if ($SourceProvider) { $ownedSource=& $SourceProvider }
            if ($ownedSource) {
                try { $null=Seal-GeordiDiagnosticSentinelSource -Source $ownedSource -Failed:(!$actionSucceeded) }
                catch {
                    if ($primaryFailure) { Write-Warning 'Diagnostic evidence finalization also failed; original failure is preserved.' -ErrorAction Continue }
                    else { throw 'Diagnostic evidence finalization failed; private details withheld.' }
                }
            }
        } catch {
            if ($primaryFailure) { Write-Warning 'Diagnostic evidence finalization also failed; original failure is preserved.' -ErrorAction Continue }
            else { throw 'Diagnostic evidence finalization failed; private details withheld.' }
        } finally {
            $script:GeordiPrivateTokenSentinelOverride=$null
        }
    }
}

function Get-GeordiDiagnosticSentinelValues {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest)
    $values = [Collections.Generic.List[string]]::new()
    if (!$Manifest.Contains('diagnosticSentinelSources')) { return @() }
    foreach ($key in @($Manifest.diagnosticSentinelSources.Keys)) {
        $source = $Manifest.diagnosticSentinelSources[$key]
        if ([string]$source.state -cne 'sealed' -or [string]$source.candidateId -cne [string]$Manifest.runId -or
                [string]$source.runId -cne [string]$Manifest.runId -or [string]$source.diagnosticInvocationId -cne [string]$key) {
            throw 'Incomplete diagnostic sentinel evidence cannot be scanned.'
        }
        $root = [IO.Path]::GetFullPath([string]$Manifest.root)
        $path = [IO.Path]::GetFullPath([string]$source.path)
        if (![string]$path.StartsWith($root.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($path) -cne [string]$source.sourceIdentity -or !(Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Diagnostic sentinel source path identity is invalid.'
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Length -ne [long]$source.byteCount -or $item.Length -gt 1048576 -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$source.sha256) {
            throw 'Diagnostic sentinel source integrity validation failed.'
        }
        $records = [IO.File]::ReadAllLines($path,[Text.UTF8Encoding]::new($false,$true))
        if ($records.Count -ne [int]$source.sentinelCount -or $records.Count -gt 256) { throw 'Diagnostic sentinel source is truncated or over-count.' }
        foreach ($line in $records) {
            $record = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($record.Keys.Count -ne 2 -or !$record.ContainsKey('value') -or !$record.ContainsKey('class')) { throw 'Diagnostic sentinel record is malformed.' }
            [void]$values.Add([string]$record.value)
        }
    }
    return @($values.ToArray() | Select-Object -Unique)
}

function Assert-GeordiM14GenerationEvents {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,[switch] $RequireSealedGenerations)
    if ($RequireSealedGenerations -and $Manifest.Contains('captureGenerations')) { Assert-GeordiCaptureHandoffCoverage -Manifest $Manifest }
    if (!$Manifest.Contains('generationCaptureEvents')) { return }
    foreach ($eventId in @($Manifest.generationCaptureEvents.Keys)) {
        $event = $Manifest.generationCaptureEvents[$eventId]
        if ([string]$event.status -cne 'complete' -or [string]$event.candidateId -cne [string]$Manifest.runId -or
                [string]$event.runId -cne [string]$Manifest.runId -or [string]$event.occurrenceId -cne [string]$eventId -or
                [string]$event.diagnosticInvocationId -notmatch '^[0-9a-f]{32}$' -or
                [string]$event.phase -notin @('m14-reset','m14-final') -or @($event.files).Count -eq 0) {
            throw 'Incomplete M14 generation event cannot be accepted.'
        }
        $containerIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $serviceIds=@{}
        foreach ($generation in @($event.containerGenerations)) {
            if ([string]$generation.service -notin @($event.services) -or [string]$generation.containerId -notmatch '^[a-f0-9]{12,64}$' -or
                    [string]$generation.composeProject -cne 'geordi' -or
                    [IO.Path]::GetFullPath([string]$generation.workingDirectory) -cne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))) {
                throw 'M14 container generation identity is missing or outside the candidate checkout.'
            }
            if (!$containerIds.Add([string]$generation.containerId) -or $serviceIds.ContainsKey([string]$generation.service)) {
                throw 'M14 event contains duplicate or ambiguous container generation identities.'
            }
            $serviceIds[[string]$generation.service]=[string]$generation.containerId
        }
        foreach ($requiredService in @('backend','victoriametrics','otel-collector')) {
            if ($requiredService -in @($event.services) -and !$serviceIds.ContainsKey($requiredService)) {
                throw 'M14 replacement service generation is not represented in its capture event.'
            }
        }
        foreach ($file in @($event.files)) {
            $path = [IO.Path]::GetFullPath([string]$file.path)
            $root = [IO.Path]::GetFullPath([string]$Manifest.root)
            if (!$path.StartsWith($root.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase) -or
                    [IO.Path]::GetFileName($path) -cne [string]$file.identity -or !(Test-Path -LiteralPath $path -PathType Leaf)) {
                throw 'M14 generation event file identity is invalid.'
            }
            if (!$serviceIds.ContainsKey([string]$file.service) -or [string]$serviceIds[[string]$file.service] -cne [string]$file.containerId -or
                    [string]$file.source -notin @('docker-container-logs','victoriametrics-export')) {
                throw 'M14 event file is not bound to its exact service container generation.'
            }
            $item = Get-Item -LiteralPath $path -Force
            if ($item.Length -ne [long]$file.byteCount -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.sha256) {
                throw 'M14 generation event file integrity validation failed.'
            }
        }
    }
}

function Assert-GeordiMinimumBrowserSentinels {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Sentinels)
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($sentinel in $Sentinels) {
        if (![string]::IsNullOrWhiteSpace($sentinel) -and $sentinel.Length -ge 8 -and $sentinel.Length -le 16384) { [void]$unique.Add($sentinel) }
    }
    if ($unique.Count -lt 4) { throw 'Real browser credential sentinel classes were not captured.' }
    return $unique.Count
}

function New-GeordiM14GenerationPaths {
    param([Parameter(Mandatory)][string] $CaptureRoot, [Parameter(Mandatory)][ValidateSet('m14-reset','m14-final')][string] $Phase,
        [Parameter(Mandatory)][string] $OccurrenceId)
    if ($OccurrenceId -notmatch '^[0-9a-f]{32}$') { throw 'M14 capture occurrence identity is invalid.' }
    $directory = Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'victoriametrics-generations'
    $base = "$Phase-$OccurrenceId"
    $snapshot = Join-Path $directory "$base.jsonl"
    $ledger = Join-Path $directory "$base.snapshot.json"
    if ((Test-Path -LiteralPath $snapshot) -or (Test-Path -LiteralPath $ledger)) { throw 'M14 generation capture identity collision.' }
    return [pscustomobject]@{ Key=$base; SnapshotPath=$snapshot; LedgerPath=$ledger }
}
