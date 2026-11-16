. (Join-Path $PSScriptRoot 'GeordiUtcTimestamp.ps1')

function ConvertTo-GeordiPersistedMetricSampleUtcInstant {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object] $Value)
    if ($null -eq $Value -or
            ($Value -isnot [byte] -and $Value -isnot [sbyte] -and $Value -isnot [int16] -and $Value -isnot [uint16] -and
             $Value -isnot [int] -and $Value -isnot [uint32] -and $Value -isnot [long] -and $Value -isnot [uint64])) {
        throw 'VictoriaMetrics persisted-source sample timestamp is missing or unsupported.'
    }
    try {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Value)
    } catch {
        throw 'VictoriaMetrics persisted-source sample timestamp is outside the supported Unix-millisecond range.'
    }
}

function Get-GeordiPersistedMetricLedgerInterval {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Ledger)
    if (!$Ledger.ContainsKey('intervalStartUtc') -or !$Ledger.ContainsKey('intervalEndUtc')) {
        throw 'VictoriaMetrics persisted ledger interval is missing or malformed.'
    }
    $start = ConvertTo-GeordiCaptureUtcInstant -Value $Ledger.intervalStartUtc -Field 'ledger.intervalStartUtc'
    $end = ConvertTo-GeordiCaptureUtcInstant -Value $Ledger.intervalEndUtc -Field 'ledger.intervalEndUtc'
    if ($end.UtcTicks -lt $start.UtcTicks) {
        throw 'VictoriaMetrics persisted ledger interval is reversed.'
    }
    return [pscustomobject]@{ StartUtc=$start; EndUtc=$end }
}

function Test-GeordiPersistedMetricExportFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path,[Parameter(Mandatory)][DateTimeOffset] $StartUtc,
        [Parameter(Mandatory)][DateTimeOffset] $EndUtc,[switch] $AllowEmpty)
    $sampleSets=0; $sampleCount=0L; $positiveControl=$false; $positiveMetricName=$null
    $stream=[IO.File]::OpenRead($Path)
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,65536)
    try {
        while (($line=$reader.ReadLine()) -ne $null) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.Length -gt 4194304) { throw 'VictoriaMetrics persisted-source sample line exceeded its bound.' }
            try { $set=ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop }
            catch { throw 'VictoriaMetrics persisted-source export was malformed.' }
            if ($null -eq $set.metric -or $null -eq $set.timestamps -or $null -eq $set.values) {
                throw 'VictoriaMetrics persisted-source export had incomplete or out-of-scope samples.'
            }
            $serviceName = if ($set.metric.Contains('service.name')) { [string]$set.metric['service.name'] } elseif ($set.metric.Contains('service_name')) { [string]$set.metric.service_name } else { '' }
            $telemetryOrigin = if ($set.metric.Contains('geordi.telemetry.origin')) { [string]$set.metric['geordi.telemetry.origin'] } elseif ($set.metric.Contains('geordi_telemetry_origin')) { [string]$set.metric.geordi_telemetry_origin } else { '' }
            if ($null -eq $set.timestamps -or $null -eq $set.values -or
                    @($set.timestamps).Count -eq 0 -or @($set.values).Count -eq 0 -or
                    @($set.timestamps).Count -ne @($set.values).Count -or
                    $serviceName -cne 'geordi-backend' -or $telemetryOrigin -cne 'platform') {
                throw 'VictoriaMetrics persisted-source export had incomplete or out-of-scope samples.'
            }
            $sampleSets++
            $sampleCount+=@($set.values).Count
            $metricName=[string]$set.metric.'__name__'
            $normalizedMetricName=$metricName.Replace('.','_') -replace '_total$',''
            if ($normalizedMetricName -ceq 'geordi_security_authentication_attempts' -and @($set.values).Count -gt 0) {
                $positiveControl=$true; $positiveMetricName=$metricName
            }
            foreach ($stamp in @($set.timestamps)) {
                $sampleUtc=ConvertTo-GeordiPersistedMetricSampleUtcInstant -Value $stamp
                if ($sampleUtc -lt $StartUtc -or $sampleUtc -gt $EndUtc) {
                    throw 'VictoriaMetrics persisted-source export escaped its requested time interval.'
                }
            }
        }
    } finally { $reader.Dispose() }
    if ($sampleSets -eq 0 -and !$AllowEmpty) { throw 'VictoriaMetrics persisted-source export contained no current-run samples.' }
    return [pscustomobject]@{ Series=$sampleSets; Samples=$sampleCount; PositiveControl=$positiveControl; PositiveMetricName=$positiveMetricName }
}

function Export-GeordiPersistedMetricSamples {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTimeOffset] $StartUtc,
        [Parameter(Mandatory)][DateTimeOffset] $EndUtc,
        [Parameter(Mandatory)][string] $Path,
        [switch] $AllowEmpty,
        [switch] $PreservePartialOnFailure,
        [ValidateRange(1,30)][int] $TimeoutSeconds = 12,
        [ValidateRange(1,30000)][int] $TimeoutMilliseconds = 0,
        [ValidateRange(1,67108864)][long] $MaximumBytes = 67108864
    )
    if ($EndUtc -lt $StartUtc) { throw 'Persisted metric interval is invalid.' }
    $selector = '{"service.name"="geordi-backend","geordi.telemetry.origin"="platform"}'
    $uri = 'http://127.0.0.1:8428/api/v1/export?match%5B%5D=' + [Uri]::EscapeDataString($selector) +
        '&start=' + [Uri]::EscapeDataString($StartUtc.ToString('o')) +
        '&end=' + [Uri]::EscapeDataString($EndUtc.ToString('o')) + '&max_rows_per_line=10000&reduce_mem_usage=1'
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $requestTimeout = if ($TimeoutMilliseconds -gt 0) { [TimeSpan]::FromMilliseconds($TimeoutMilliseconds) } else { [TimeSpan]::FromSeconds($TimeoutSeconds) }
    $cancellation = [Threading.CancellationTokenSource]::new($requestTimeout)
    $response = $null
    $request = $null
    $output = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$uri)
        $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancellation.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200) { throw 'VictoriaMetrics persisted-source export was not successful.' }
        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $buffer = [byte[]]::new(65536)
        [long]$total = 0
        while (($read = $input.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
            $total += $read
            if ($total -gt $MaximumBytes) { throw 'VictoriaMetrics persisted-source capture exceeded its size bound.' }
            $output.Write($buffer,0,$read)
        }
        $output.Flush()
        $output.Dispose(); $output = $null
        $validated=Test-GeordiPersistedMetricExportFile -Path $Path -StartUtc $StartUtc -EndUtc $EndUtc -AllowEmpty:$AllowEmpty
        return [pscustomobject]@{ Path=$Path; Bytes=$total; Series=$validated.Series; Samples=$validated.Samples;
            PositiveControl=$validated.PositiveControl; PositiveMetricName=$validated.PositiveMetricName }
    } catch {
        if ($output) { $output.Dispose(); $output = $null }
        if (!$PreservePartialOnFailure -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        if ($_.Exception.Message -match '^VictoriaMetrics persisted-source') { throw }
        throw 'VictoriaMetrics persisted-source export failed within its bounded request.'
    } finally {
        if ($output) { $output.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        $cancellation.Dispose()
        $client.Dispose()
    }
}

function Complete-GeordiPersistedMetricSnapshotFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $TemporaryPath,[Parameter(Mandatory)][string] $SnapshotPath,
        [Parameter(Mandatory)][long] $Bytes,[switch] $CreateNew)
    if ($Bytes -gt 0) {
        if ($CreateNew) { [IO.File]::Move($TemporaryPath,$SnapshotPath) }
        else { [IO.File]::Move($TemporaryPath,$SnapshotPath,$true) }
        return $SnapshotPath
    }
    if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $TemporaryPath -Force
    }
    return $null
}

function Assert-GeordiPersistedMetricPhaseAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][string] $SnapshotPath,
        [Parameter(Mandatory)][string] $LedgerPath,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest
    )
    if ($Phase -notin @('m11-final','m12-reset','m12-fixture-start','m12-recovery-start')) { return }
    $evidenceLabel=switch($Phase){'m11-final'{'Authoritative M11 final'};'m12-reset'{'Authoritative M12 reset'};'m12-fixture-start'{'Authoritative M12 fixture-start'};default{'Authoritative M12 recovery-start'}}

    $reservedPaths = @(
        [IO.Path]::GetFullPath($SnapshotPath),
        [IO.Path]::GetFullPath($LedgerPath)
    )
    foreach ($path in $reservedPaths) {
        if (Test-Path -LiteralPath $path) {
            throw "$evidenceLabel metric evidence path is already occupied."
        }
    }

    foreach ($source in @($Manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })) {
        foreach ($capture in @($source.captures)) {
            if ([string]::IsNullOrWhiteSpace([string]$capture)) { continue }
            $referencedPath = [IO.Path]::GetFullPath([string]$capture)
            foreach ($path in $reservedPaths) {
                if ([string]::Equals($referencedPath, $path, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$evidenceLabel metric evidence path is already referenced by the manifest."
                }
            }
        }
    }
}

function Get-GeordiPersistedMetricPhasePublicationMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $LedgerPath)
    $identity=[IO.Path]::GetFullPath($LedgerPath).ToUpperInvariant()
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $token=[Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))) }
    finally { $sha.Dispose() }
    return "Local\GeordiM19MetricPhase-$token"
}

function Enter-GeordiPersistedMetricPhasePublication {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SnapshotPath,[Parameter(Mandatory)][string] $LedgerPath)
    $mutex=[Threading.Mutex]::new($false,(Get-GeordiPersistedMetricPhasePublicationMutexName -LedgerPath $LedgerPath))
    try {
        try { $acquired=$mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] {
            $mutex.ReleaseMutex()
            throw 'A persisted metric phase publication ended unexpectedly; recovery is required.'
        }
        if (!$acquired) { throw 'A persisted metric phase publication is already in progress.' }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-GeordiPersistedMetricPhasePublication {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Threading.Mutex] $Mutex)
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Get-GeordiPersistedMetricSourceIdentity {
    [CmdletBinding()]
    param(
            [Parameter(Mandatory)][ValidateSet('m10-reset','m11-reset','m11-final','m12-reset','m12-fixture-start','m12-recovery-start','m12-overlap-reset','m12-overlap-recreate','m13-reset','m14-reset','m14-final','m19-burn-isolate','m19-burn-restore')][string] $Phase,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [object[]] $ResolvedM14ContainerGenerations = @(),
        [scriptblock] $ResolveIdentity
    )
    $identity = $null
    if ($Phase -in @('m14-reset','m14-final')) {
        $matches = @($ResolvedM14ContainerGenerations | Where-Object { [string]$_.service -ceq 'victoriametrics' })
        if ($matches.Count -ne 1) { throw 'Persisted VictoriaMetrics source identity is missing or ambiguous.' }
        $identity = [pscustomobject]@{
            Id = [string]$matches[0].containerId
            Project = [string]$matches[0].composeProject
            Service = [string]$matches[0].service
            WorkingDirectory = [string]$matches[0].workingDirectory
            CreatedUtc = [string]$matches[0].createdUtc
            Running = $true
        }
    } else {
        try {
            if ($ResolveIdentity) {
                $identities = @(& $ResolveIdentity 'victoriametrics')
                if ($identities.Count -ne 1) { throw 'Persisted VictoriaMetrics source identity is missing or ambiguous.' }
                $identity = $identities[0]
            } else {
                $identity = Get-GeordiCurrentCaptureContainerIdentity -Service 'victoriametrics' -RepositoryRoot $RepositoryRoot
            }
        } catch {
            if ($_.Exception.Message -like 'Persisted VictoriaMetrics source identity*') { throw }
            throw 'Persisted VictoriaMetrics live source identity could not be resolved.'
        }
    }
    Assert-GeordiCaptureContainerIdentity -Identity $identity -Service 'victoriametrics'
    if ([string]$identity.Id -cnotmatch '^[a-f0-9]{64}$' -or
            [IO.Path]::GetFullPath([string]$identity.WorkingDirectory) -cne [IO.Path]::GetFullPath($RepositoryRoot) -or
            !$identity.Running) {
        throw 'Persisted VictoriaMetrics source identity is not the exact running container owned by this checkout.'
    }
    return [ordered]@{ sourceService='victoriametrics'; sourceContainerId=[string]$identity.Id }
}

function Add-GeordiPersistedMetricArtifactBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Ledger,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][AllowNull()][System.Collections.IDictionary] $SourceIdentity,
        [Parameter(Mandatory)][string] $SnapshotTemporaryPath,
        [Parameter(Mandatory)][long] $Bytes
    )
    if ($Bytes -lt 0) { throw 'Persisted metric snapshot byte count is invalid.' }
    $Ledger.bytes = $Bytes
    if ($Source -ceq 'victoriametrics-export') {
        if (!$SourceIdentity -or [string]$SourceIdentity.sourceService -cne 'victoriametrics' -or
                [string]$SourceIdentity.sourceContainerId -cnotmatch '^[a-f0-9]{64}$') {
            throw 'Persisted metric export has no exact validated VictoriaMetrics source identity.'
        }
        $Ledger.sourceService = [string]$SourceIdentity.sourceService
        $Ledger.sourceContainerId = [string]$SourceIdentity.sourceContainerId
        if ($Bytes -gt 0) {
            if (!(Test-Path -LiteralPath $SnapshotTemporaryPath -PathType Leaf) -or
                    [long](Get-Item -LiteralPath $SnapshotTemporaryPath).Length -ne $Bytes) {
                throw 'Persisted metric snapshot bytes changed before ledger publication.'
            }
            $Ledger.snapshotSha256 = (Get-FileHash -LiteralPath $SnapshotTemporaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        } else {
            if ((Test-Path -LiteralPath $SnapshotTemporaryPath -PathType Leaf) -and
                    [long](Get-Item -LiteralPath $SnapshotTemporaryPath).Length -ne 0) {
                throw 'Zero-byte persisted metric snapshot has nonempty temporary artifact.'
            }
            $Ledger.Remove('snapshotSha256')
        }
    } elseif ($Source -ceq 'verified-prior-generation-removal') {
        if ($Bytes -ne 0) { throw 'Removed-generation evidence cannot claim snapshot bytes.' }
        $Ledger.Remove('snapshotSha256')
        $Ledger.Remove('sourceService')
        $Ledger.Remove('sourceContainerId')
    } else {
        throw 'Persisted metric ledger source is unsupported.'
    }
}

function Assert-GeordiPersistedMetricLedgerArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Ledger,
        [Parameter(Mandatory)][string] $LedgerPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Captures
    )
    if ($Ledger.source -cne 'victoriametrics-export' -or [string]$Ledger.sourceService -cne 'victoriametrics' -or
            [string]$Ledger.sourceContainerId -cnotmatch '^[a-f0-9]{64}$' -or !$Ledger.ContainsKey('bytes') -or
            ($Ledger.bytes -isnot [byte] -and $Ledger.bytes -isnot [int16] -and $Ledger.bytes -isnot [int] -and $Ledger.bytes -isnot [long] -and
             $Ledger.bytes -isnot [uint16] -and $Ledger.bytes -isnot [uint32] -and $Ledger.bytes -isnot [uint64]) -or [long]$Ledger.bytes -lt 0) {
        throw 'VictoriaMetrics persisted ledger source identity or byte count is invalid.'
    }
    $interval = Get-GeordiPersistedMetricLedgerInterval -Ledger $Ledger
    $fullLedgerPath = [IO.Path]::GetFullPath($LedgerPath)
    if (![IO.Path]::GetFileName($fullLedgerPath).EndsWith('.snapshot.json',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'VictoriaMetrics persisted ledger path has no canonical snapshot suffix.'
    }
    $ledgerName = [IO.Path]::GetFileName($fullLedgerPath)
    $snapshotName = $ledgerName.Substring(0,$ledgerName.Length-'.snapshot.json'.Length)+'.jsonl'
    $snapshotPath = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($fullLedgerPath)) $snapshotName))
    $references = @($Captures | Where-Object { [string]::Equals([IO.Path]::GetFullPath([string]$_),$snapshotPath,[StringComparison]::OrdinalIgnoreCase) }).Count
    if ([long]$Ledger.bytes -gt 0) {
        if ($references -ne 1 -or !(Test-Path -LiteralPath $snapshotPath -PathType Leaf) -or
                [long](Get-Item -LiteralPath $snapshotPath).Length -ne [long]$Ledger.bytes -or
                [string]$Ledger.snapshotSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Ledger.snapshotSha256) {
            throw 'VictoriaMetrics persisted ledger artifact binding is invalid.'
        }
        [void](Test-GeordiPersistedMetricExportFile -Path $snapshotPath -StartUtc $interval.StartUtc -EndUtc $interval.EndUtc)
    } else {
        if ($references -ne 0 -or (Test-Path -LiteralPath $snapshotPath) -or
                ($Ledger.ContainsKey('snapshotSha256') -and $null -ne $Ledger.snapshotSha256 -and [string]$Ledger.snapshotSha256 -cne '')) {
            throw 'Zero-byte VictoriaMetrics persisted ledger has a contradictory artifact binding.'
        }
    }
    return $snapshotPath
}

function Assert-GeordiM11FinalSourceTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $SnapshotDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary] $FinalSourceIdentity,
        [Parameter(Mandatory)][DateTimeOffset] $CaptureStartedUtc
    )
    $sources = @($Manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
    if ($sources.Count -ne 1) { throw 'M11 reset persisted VictoriaMetrics source is missing or ambiguous.' }
    $resetLedgerPath = [IO.Path]::GetFullPath((Join-Path $SnapshotDirectory 'm11-reset.snapshot.json'))
    $ledgerReferences = @($sources[0].captures | Where-Object {
        [string]::Equals([IO.Path]::GetFullPath([string]$_),$resetLedgerPath,[StringComparison]::OrdinalIgnoreCase)
    }).Count
    if ($ledgerReferences -ne 1 -or !(Test-Path -LiteralPath $resetLedgerPath -PathType Leaf)) {
        throw 'M11 reset VictoriaMetrics ledger is missing from the authoritative manifest.'
    }
    $resetLedger = Get-Content -LiteralPath $resetLedgerPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $resetInterval = Get-GeordiPersistedMetricLedgerInterval -Ledger $resetLedger
    if ($resetLedger.complete -isnot [bool] -or !$resetLedger.complete -or $resetLedger.runStartBound -isnot [bool] -or !$resetLedger.runStartBound -or
            $resetInterval.StartUtc.UtcTicks -ne $CaptureStartedUtc.ToUniversalTime().UtcTicks) {
        throw 'M11 reset VictoriaMetrics ledger is incomplete or outside the current run.'
    }
    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $resetLedger -LedgerPath $resetLedgerPath -Captures ([string[]]$sources[0].captures))
    Assert-GeordiM11PersistedMetricIdentityBoundary -ResetContainerId ([string]$resetLedger.sourceContainerId) `
        -FinalContainerId ([string]$FinalSourceIdentity.sourceContainerId)
    return [string]$resetLedger.sourceContainerId
}

function Assert-GeordiM11PersistedMetricIdentityBoundary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ResetContainerId,[Parameter(Mandatory)][string] $FinalContainerId)
    if ($ResetContainerId -cnotmatch '^[a-f0-9]{64}$' -or $FinalContainerId -cnotmatch '^[a-f0-9]{64}$' -or
            $ResetContainerId -ceq $FinalContainerId) {
        throw 'M11 VictoriaMetrics reset/final evidence does not bind distinct exact container identities.'
    }
}
