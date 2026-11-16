. (Join-Path $PSScriptRoot 'GeordiCaptureGenerations.ps1')
. (Join-Path $PSScriptRoot 'GeordiPersistedMetricEvidence.ps1')
. (Join-Path $PSScriptRoot 'GeordiM11BackendReplacement.ps1')

function Get-GeordiM11TransferVolumeAllowlist {
    [CmdletBinding()]
    param()
    return [ordered]@{
        'm11-alert-lifecycle-data' = 'geordi_m11-alert-lifecycle-data'
        'm11-victoriametrics-data' = 'geordi_m11-victoriametrics-data'
    }
}

function Test-GeordiM11TransferFollowerProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $FollowerRecord)
    try {
        $process = Get-Process -Id ([int]$FollowerRecord.id) -ErrorAction Stop
        return $process.ProcessName -ceq [string]$FollowerRecord.name -and
            $process.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$FollowerRecord.startUtc).UtcTicks
    } catch { return $false }
}

function Assert-GeordiM11TransferActiveGeneration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $Service,[Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)][scriptblock] $TestFollowerProcess,[Parameter(Mandatory)][string] $RepositoryRoot)
    Assert-GeordiCaptureContainerIdentity -Identity $Identity -Service $Service
    if ([string]$Identity.Id -notmatch '^[a-f0-9]{64}$' -or !$Identity.Running -or
            [IO.Path]::GetFullPath([string]$Identity.WorkingDirectory) -cne [IO.Path]::GetFullPath($RepositoryRoot)) {
        throw 'M11 transfer service identity is not the exact running container owned by this checkout.'
    }
    $records = if ($Manifest.captureGenerations.ContainsKey($Service)) { @($Manifest.captureGenerations[$Service]) } else { @() }
    $activeRecords = [Collections.Generic.List[System.Collections.IDictionary]]::new()
    $incompleteCount = 0
    foreach ($record in $records) {
        if ($record -isnot [System.Collections.IDictionary]) { throw 'M11 transfer generation record is malformed.' }
        if ([string]$record['terminalStatus'] -ceq 'capturing') { $activeRecords.Add($record) }
        if ([string]$record['terminalStatus'] -in @('incomplete-start','sealing-failed')) { $incompleteCount++ }
    }
    if ($activeRecords.Count -ne 1) { throw 'M11 transfer has no unique active exact-container capture generation.' }
    $activeRecord=$activeRecords[0]
    if ([string]$activeRecord['logicalService'] -cne $Service -or
            [string]$activeRecord['containerId'] -cne [string]$Identity.Id -or [string]$activeRecord['composeProject'] -cne 'geordi' -or
            !$activeRecord['followerProcess'] -or [string]$activeRecord['generationId'] -notmatch '^[0-9a-f]{32}$') {
        throw 'M11 transfer has no unique active exact-container capture generation.'
    }
    if ($records.Count -eq 0) { throw 'M11 transfer active generation ordering is invalid.' }
    $activeGenerationId=[string]$activeRecord['generationId']
    $lastRecord = $records | Select-Object -Last 1
    if ([string]$lastRecord['generationId'] -cne $activeGenerationId -or
            [string]$lastRecord['terminalStatus'] -cne 'capturing' -or $incompleteCount -gt 0) {
        throw 'M11 transfer active generation ordering is invalid.'
    }
    $root = [IO.Path]::GetFullPath([string]$Manifest.root).TrimEnd('\') + '\'
    foreach ($pathProperty in @('processRecordPath','capturePath','stderrCapturePath')) {
        $path = [IO.Path]::GetFullPath([string]$activeRecord[$pathProperty])
        if (!$path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'M11 transfer active generation evidence path is missing or outside its capture root.'
        }
    }
    $follower = $activeRecord['followerProcess']
    $disk = [IO.File]::ReadAllText([string]$activeRecord['processRecordPath']) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ([int]$disk.id -ne [int]$follower.id -or
            [string]$disk.name -cne [string]$follower.name -or
            [string]$disk.startUtc -cne [string]$follower.startUtc -or
            [string]$disk.containerId -cne [string]$Identity.Id -or [string]$disk.service -cne $Service -or
            [string]$disk.project -cne 'geordi' -or -not (& $TestFollowerProcess $disk)) {
        throw 'M11 transfer follower process is not active and bound to the exact service container.'
    }
    return $activeRecord
}

function Assert-GeordiM11TransferVolumes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $ExpectedVolumes,
        [Parameter(Mandatory)][scriptblock] $InspectVolume)
    $allowlist = Get-GeordiM11TransferVolumeAllowlist
    if ($ExpectedVolumes.Count -ne $allowlist.Count) { throw 'M11 transfer volume set is incomplete or contains unexpected resources.' }
    foreach ($logical in $allowlist.Keys) {
        if (!$ExpectedVolumes.Contains($logical) -or [string]$ExpectedVolumes[$logical] -cne [string]$allowlist[$logical]) {
            throw 'M11 transfer volume set does not match the exact dedicated M11 resources.'
        }
        $name = [string]$allowlist[$logical]
        $matches = @(& $InspectVolume $name)
        if ($matches.Count -ne 1 -or [string]$matches[0].Name -cne $name -or
                [string]$matches[0].Labels.'com.docker.compose.project' -cne 'geordi' -or
                [string]$matches[0].Labels.'com.docker.compose.volume' -cne $logical) {
            throw 'M11 transfer volume is missing or does not have exact Compose ownership.'
        }
    }
    return $true
}

function Assert-GeordiM11FinalTransferEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $VictoriaMetricsContainerId)
    $sources = @($Manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
    if ($sources.Count -ne 1) { throw 'M11 transfer has no unique VictoriaMetrics evidence source.' }
    $directory = Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'victoriametrics-generations'
    $ledgerPath = [IO.Path]::GetFullPath((Join-Path $directory 'm11-final.snapshot.json'))
    $snapshotPath = [IO.Path]::GetFullPath((Join-Path $directory 'm11-final.jsonl'))
    if (@($sources[0].captures | Where-Object { [IO.Path]::GetFullPath([string]$_) -ceq $ledgerPath }).Count -ne 1) {
        throw 'M11 final ledger is not uniquely registered in the capture manifest.'
    }
    $ledger = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $interval = Get-GeordiPersistedMetricLedgerInterval -Ledger $ledger
    $captureStarted = ConvertTo-GeordiCaptureUtcInstant -Value $Manifest.captureStartedUtc -Field 'manifest.captureStartedUtc'
    if ($ledger.source -cne 'victoriametrics-export' -or $ledger.complete -isnot [bool] -or !$ledger.complete -or
            $ledger.runStartBound -isnot [bool] -or !$ledger.runStartBound -or
            [string]$ledger.sourceService -cne 'victoriametrics' -or [string]$ledger.sourceContainerId -cne $VictoriaMetricsContainerId -or
            $interval.StartUtc.UtcTicks -ne $captureStarted.UtcTicks) {
        throw 'M11 final evidence does not authenticate the current run and live VictoriaMetrics container.'
    }
    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath -Captures ([string[]]$sources[0].captures))
    [void](Assert-GeordiM11FinalSourceTransition -Manifest $Manifest -SnapshotDirectory $directory `
        -FinalSourceIdentity ([ordered]@{sourceService='victoriametrics';sourceContainerId=$VictoriaMetricsContainerId}) `
        -CaptureStartedUtc $captureStarted)
    $publicationStillReserved = $false
    try { Assert-GeordiPersistedMetricPhaseAvailable -Phase 'm11-final' -SnapshotPath $snapshotPath -LedgerPath $ledgerPath -Manifest $Manifest }
    catch { $publicationStillReserved = $true }
    if (!$publicationStillReserved) { throw 'M11 final publication path is not immutable against republishing.' }
    return $ledger
}

function Assert-GeordiM11M12FixtureTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,[Parameter(Mandatory)][scriptblock] $InspectVolume,
        [Parameter(Mandatory)][scriptblock] $TestFollowerProcess,[Parameter(Mandatory)][System.Collections.IDictionary] $ExpectedVolumes,
        [string] $ExpectedCollectorContainerId)
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $captureRootPath = [IO.Path]::GetFullPath($CaptureRoot)
    $manifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $captureRootPath
    if ([IO.Path]::GetDirectoryName($captureRootPath) -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
            (Split-Path $captureRootPath -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
        throw 'M11 transfer capture root is not the private current-run root.'
    }
    $backend = & $ResolveIdentity 'backend'
    $victoriaMetrics = & $ResolveIdentity 'victoriametrics'
    $collector = & $ResolveIdentity 'otel-collector'
    foreach ($binding in @(@{Service='backend';Identity=$backend},@{Service='victoriametrics';Identity=$victoriaMetrics},@{Service='otel-collector';Identity=$collector})) {
        $identity=$binding.Identity
        Assert-GeordiCaptureContainerIdentity -Identity $identity -Service $binding.Service
        if ([string]$identity.Id -notmatch '^[a-f0-9]{64}$' -or !$identity.Running -or
                [IO.Path]::GetFullPath([string]$identity.WorkingDirectory) -cne $root) {
            throw 'M11 transfer container belongs to another checkout.'
        }
    }
    $backendGeneration = Assert-GeordiM11TransferActiveGeneration -Manifest $manifest -Service backend -Identity $backend `
        -TestFollowerProcess $TestFollowerProcess -RepositoryRoot $root
    $collectorGeneration = Assert-GeordiM11TransferActiveGeneration -Manifest $manifest -Service 'otel-collector' -Identity $collector `
        -TestFollowerProcess $TestFollowerProcess -RepositoryRoot $root
    if (![string]::IsNullOrEmpty($ExpectedCollectorContainerId) -and [string]$collector.Id -cne $ExpectedCollectorContainerId) {
        throw 'M11 Collector identity changed during notification delivery.'
    }
    [void](Assert-GeordiM11FinalTransferEvidence -Manifest $manifest -CaptureRoot $captureRootPath `
        -VictoriaMetricsContainerId ([string]$victoriaMetrics.Id))
    [void](Assert-GeordiM11TransferVolumes -ExpectedVolumes $ExpectedVolumes -InspectVolume $InspectVolume)
    return [pscustomobject]@{ RunId=[string]$manifest.runId;BackendContainerId=[string]$backend.Id
        BackendGenerationId=[string]$backendGeneration['generationId'];VictoriaMetricsContainerId=[string]$victoriaMetrics.Id
        CollectorContainerId=[string]$collector.Id;CollectorGenerationId=[string]$collectorGeneration['generationId'] }
}

function Assert-GeordiM12ResetTransferEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $ExpectedVictoriaMetricsContainerId)
    $manifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $sources = @($manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
    if ($sources.Count -ne 1) { throw 'M12 transfer reset evidence has no unique VictoriaMetrics source.' }
    $ledgerPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $CaptureRoot 'victoriametrics-generations') 'm12-reset.snapshot.json'))
    if (@($sources[0].captures | Where-Object { [IO.Path]::GetFullPath([string]$_) -ceq $ledgerPath }).Count -ne 1) {
        throw 'M12 transfer reset ledger is not uniquely registered.'
    }
    $ledger = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $interval = Get-GeordiPersistedMetricLedgerInterval -Ledger $ledger
    $captureStarted = ConvertTo-GeordiCaptureUtcInstant -Value $manifest.captureStartedUtc -Field 'manifest.captureStartedUtc'
    if ($ledger.source -cne 'victoriametrics-export' -or $ledger.complete -isnot [bool] -or !$ledger.complete -or
            $ledger.runStartBound -isnot [bool] -or !$ledger.runStartBound -or
            [string]$ledger.sourceService -cne 'victoriametrics' -or
            [string]$ledger.sourceContainerId -cne $ExpectedVictoriaMetricsContainerId -or
            $interval.StartUtc.UtcTicks -ne $captureStarted.UtcTicks) {
        throw 'M12 transfer reset did not capture the exact inherited VictoriaMetrics container.'
    }
    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath -Captures ([string[]]$sources[0].captures))
    return $ledger
}

function Invoke-GeordiM11M12FixtureTransferConsumer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,[Parameter(Mandatory)][scriptblock] $InspectVolume,
        [Parameter(Mandatory)][scriptblock] $TestFollowerProcess,[Parameter(Mandatory)][System.Collections.IDictionary] $ExpectedVolumes,
        [Parameter(Mandatory)][scriptblock] $CaptureM12Reset)
    $transfer = Assert-GeordiM11M12FixtureTransfer -CaptureRoot $CaptureRoot -RepositoryRoot $RepositoryRoot `
        -ResolveIdentity $ResolveIdentity -InspectVolume $InspectVolume -TestFollowerProcess $TestFollowerProcess `
        -ExpectedVolumes $ExpectedVolumes
    & $CaptureM12Reset $transfer
    $revalidated = Assert-GeordiM11M12FixtureTransfer -CaptureRoot $CaptureRoot -RepositoryRoot $RepositoryRoot `
        -ResolveIdentity $ResolveIdentity -InspectVolume $InspectVolume -TestFollowerProcess $TestFollowerProcess `
        -ExpectedVolumes $ExpectedVolumes
    foreach ($property in @('RunId','BackendContainerId','BackendGenerationId','VictoriaMetricsContainerId','CollectorContainerId','CollectorGenerationId')) {
        if ([string]$transfer.$property -cne [string]$revalidated.$property) { throw 'M11 transfer identities changed during m12-reset evidence capture.' }
    }
    $resetLedger = Assert-GeordiM12ResetTransferEvidence -CaptureRoot $CaptureRoot `
        -ExpectedVictoriaMetricsContainerId $revalidated.VictoriaMetricsContainerId
    return [pscustomobject]@{ Status='TRANSFER_VALIDATED';RunId=$revalidated.RunId
        BackendContainerId=$revalidated.BackendContainerId;BackendGenerationId=$revalidated.BackendGenerationId
        VictoriaMetricsContainerId=$revalidated.VictoriaMetricsContainerId;CollectorContainerId=$revalidated.CollectorContainerId
        M12ResetSourceContainerId=[string]$resetLedger.sourceContainerId }
}

function Test-GeordiM11FixtureCleanupRequired {
    [CmdletBinding()]
    param([bool] $FixtureOwned,[bool] $MutationStarted,[bool] $TransferCommitted)
    return ($FixtureOwned -or $MutationStarted) -and !$TransferCommitted
}
