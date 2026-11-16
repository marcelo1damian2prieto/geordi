. (Join-Path $PSScriptRoot 'GeordiCaptureGenerations.ps1')
. (Join-Path $PSScriptRoot 'GeordiM11M12FixtureTransfer.ps1')

function Get-GeordiM12DedicatedFixtureVolumeAllowlist {
    [CmdletBinding()]
    param()
    return [ordered]@{
        'm12-alert-lifecycle-data' = 'geordi_m12-alert-lifecycle-data'
        'm12-victoriametrics-data' = 'geordi_m12-victoriametrics-data'
    }
}

function Get-GeordiM12BackendRecreationArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('initial-fixture','scheduler-enablement','provider-recovery')][string] $Boundary)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    return @('--project-directory',$root,'up','-d','--no-deps','--force-recreate','backend')
}

function Remove-GeordiM12DedicatedFixtureVolumes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $ExpectedVolumes,
        [Parameter(Mandatory)][scriptblock] $InspectVolume,[Parameter(Mandatory)][scriptblock] $RemoveVolume)
    $allowlist=Get-GeordiM12DedicatedFixtureVolumeAllowlist
    if ($ExpectedVolumes.Count -ne $allowlist.Count) { throw 'M12 fixture volume map is incomplete or contains unexpected resources.' }
    foreach ($logicalName in $allowlist.Keys) {
        if (!$ExpectedVolumes.Contains($logicalName) -or [string]$ExpectedVolumes[$logicalName] -cne [string]$allowlist[$logicalName]) {
            throw 'M12 fixture volume map does not match the exact dedicated M12 resources.'
        }
    }
    foreach ($logicalName in $allowlist.Keys) {
        $name=[string]$allowlist[$logicalName]
        $matches=@(& $InspectVolume $name)
        if ($matches.Count -eq 0) { continue }
        if ($matches.Count -ne 1 -or [string]$matches[0].Name -cne $name -or
                [string]$matches[0].Labels.'com.docker.compose.project' -cne 'geordi' -or
                [string]$matches[0].Labels.'com.docker.compose.volume' -cne $logicalName) {
            throw 'Refusing M12 removal for a volume without exact M12 Compose ownership.'
        }
        $null=& $RemoveVolume $name
    }
}

function Assert-GeordiM12BackendBoundaryMetricSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,
        [Parameter(Mandatory)][ValidateSet('m12-reset','m12-fixture-start','m12-recovery-start')][string] $Phase,
        [Parameter(Mandatory)][string] $ExpectedVictoriaMetricsContainerId)
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $sources=@($manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
    if ($sources.Count -ne 1) { throw 'M12 backend boundary has no unique persisted VictoriaMetrics source.' }
    $ledgerPath=[IO.Path]::GetFullPath((Join-Path (Join-Path $CaptureRoot 'victoriametrics-generations') "$Phase.snapshot.json"))
    if (@($sources[0].captures | Where-Object { [IO.Path]::GetFullPath([string]$_) -ceq $ledgerPath }).Count -ne 1 -or
            !(Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        throw 'M12 backend boundary metric ledger is missing or not uniquely registered.'
    }
    $ledger=[IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $interval=Get-GeordiPersistedMetricLedgerInterval -Ledger $ledger
    $captureStarted=ConvertTo-GeordiCaptureUtcInstant -Value $manifest.captureStartedUtc -Field 'manifest.captureStartedUtc'
    if ($ledger.source -cne 'victoriametrics-export' -or $ledger.complete -isnot [bool] -or !$ledger.complete -or
            $ledger.runStartBound -isnot [bool] -or !$ledger.runStartBound -or
            [string]$ledger.sourceService -cne 'victoriametrics' -or
            [string]$ledger.sourceContainerId -cne $ExpectedVictoriaMetricsContainerId -or
            $interval.StartUtc.UtcTicks -ne $captureStarted.UtcTicks) {
        throw 'M12 backend boundary metrics do not bind the current run and live VictoriaMetrics identity.'
    }
    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath -Captures ([string[]]$sources[0].captures))
    return $ledger
}

function Ensure-GeordiM12ResetTransferEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,
        [Parameter(Mandatory)][string] $ExpectedVictoriaMetricsContainerId,
        [Parameter(Mandatory)][scriptblock] $Capture)
    $root=[IO.Path]::GetFullPath($CaptureRoot)
    $snapshotPath=[IO.Path]::GetFullPath((Join-Path (Join-Path $root 'victoriametrics-generations') 'm12-reset.jsonl'))
    $ledgerPath=[IO.Path]::GetFullPath((Join-Path (Join-Path $root 'victoriametrics-generations') 'm12-reset.snapshot.json'))
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $root
    $references=@($manifest.additionalSources | ForEach-Object { $_.captures } | Where-Object {
        [string]::Equals([IO.Path]::GetFullPath([string]$_),$snapshotPath,[StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals([IO.Path]::GetFullPath([string]$_),$ledgerPath,[StringComparison]::OrdinalIgnoreCase)
    })
    $occupied=(Test-Path -LiteralPath $snapshotPath) -or (Test-Path -LiteralPath $ledgerPath) -or ($references.Count -gt 0)
    if (!$occupied) { $null=& $Capture }
    return Assert-GeordiM12ResetTransferEvidence -CaptureRoot $root `
        -ExpectedVictoriaMetricsContainerId $ExpectedVictoriaMetricsContainerId
}

function Invoke-GeordiM12BackendGenerationReplacement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('m12-reset','m12-fixture-start','m12-recovery-start')][string] $EvidencePhase,
        [Parameter(Mandatory)][string] $Reason,[Parameter(Mandatory)][scriptblock] $Replace,
        [Parameter(Mandatory)][scriptblock] $ResolveContainerIdentity,
        [Parameter(Mandatory)][scriptblock] $WaitForReadiness,[scriptblock] $BeforeHandoff,
        [scriptblock] $StartFollower,[scriptblock] $TestFollowerProcess,
        [scriptblock] $TestProcessIdentity,[scriptblock] $StopProcess,
        [string] $DockerPath=(Get-Command docker.exe -ErrorAction Stop).Source,
        [string] $PowerShellPath=(Get-Process -Id $PID).Path,
        [string] $WorkerPath=(Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1'))
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $oldIdentity=& $ResolveContainerIdentity 'backend'
    Assert-GeordiCaptureContainerIdentity -Identity $oldIdentity -Service 'backend'
    if ([string]$oldIdentity.Id -cnotmatch '^[a-f0-9]{64}$' -or
            [IO.Path]::GetFullPath([string]$oldIdentity.WorkingDirectory) -cne $root -or
            ($oldIdentity.PSObject.Properties.Name -contains 'Running' -and !$oldIdentity.Running)) {
        throw 'M12 backend identity is not the exact running container owned by this checkout.'
    }
    $vmIdentity=& $ResolveContainerIdentity 'victoriametrics'
    Assert-GeordiCaptureContainerIdentity -Identity $vmIdentity -Service 'victoriametrics'
    if ([string]$vmIdentity.Id -cnotmatch '^[a-f0-9]{64}$' -or
            [IO.Path]::GetFullPath([string]$vmIdentity.WorkingDirectory) -cne $root -or
            ($vmIdentity.PSObject.Properties.Name -contains 'Running' -and !$vmIdentity.Running)) {
        throw 'M12 VictoriaMetrics identity is not the exact running container owned by this checkout.'
    }
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $followerCheck=$TestFollowerProcess
    if (!$followerCheck) { $followerCheck={param($record) Test-GeordiM11TransferFollowerProcess -FollowerRecord $record} }
    $null=Assert-GeordiM11TransferActiveGeneration -Manifest $manifest -Service backend -Identity $oldIdentity `
        -TestFollowerProcess $followerCheck -RepositoryRoot $root
    [void](Assert-GeordiM12BackendBoundaryMetricSource -CaptureRoot $CaptureRoot -Phase $EvidencePhase `
        -ExpectedVictoriaMetricsContainerId ([string]$vmIdentity.Id))
    if ($BeforeHandoff) { $null=& $BeforeHandoff $oldIdentity $vmIdentity }
    $handoffId=Begin-GeordiCaptureHandoff -CaptureRoot $CaptureRoot -Service backend -Reason $Reason `
        -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess
    $getNewIdentity={
        param([string] $service)
        if ($service -cne 'backend') { throw 'M12 replacement requested an unexpected logical service.' }
        $identity=& $ResolveContainerIdentity 'backend'
        Assert-GeordiCaptureContainerIdentity -Identity $identity -Service backend
        if ([string]$identity.Id -cnotmatch '^[a-f0-9]{64}$' -or
                [IO.Path]::GetFullPath([string]$identity.WorkingDirectory) -cne $root -or
                ($identity.PSObject.Properties.Name -contains 'Running' -and !$identity.Running) -or
                [string]$identity.Id -ceq [string]$oldIdentity.Id) {
            throw 'M12 replacement backend is not a distinct owned running container.'
        }
        return $identity
    }.GetNewClosure()
    $startFollowerOnly={
        param($stdout,$stderr,$processRecord,$arguments,$target)
        if ($StartFollower) {
            $started=@(& $StartFollower $stdout $stderr $processRecord $arguments $target)
        } else {
            $started=@(Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath `
                -DockerPath $DockerPath -DockerArguments $arguments -WorkingDirectory $root -StandardOutputPath $stdout `
                -StandardErrorPath $stderr -ProcessRecordPath $processRecord -TargetMetadata $target)
        }
        if ($started.Count -ne 1 -or !$started[0]) { throw 'M12 backend follower startup returned an invalid process identity.' }
        return $started[0]
    }.GetNewClosure()
    $afterFollowerValidated={param($target,$process,$generationId) $null=& $WaitForReadiness $target}.GetNewClosure()
    $generationId=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $CaptureRoot -Service backend -HandoffId $handoffId `
        -RepositoryRoot $root -Replace $Replace -GetContainerIdentity $getNewIdentity -StartFollower $startFollowerOnly `
        -AfterFollowerValidated $afterFollowerValidated -StopProcess $StopProcess `
        -Reason $Reason -DockerPath $DockerPath -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath
    $completed=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $handoff=$completed.captureHandoffs[$handoffId]
    $newRecord=Get-GeordiCaptureGenerationRecord -Manifest $completed -Service backend -GenerationId ([string]$generationId)
    if (!$newRecord -or [string]$newRecord.terminalStatus -cne 'capturing' -or [string]$newRecord.handoffId -cne $handoffId -or
            [string]$handoff.status -cne 'complete' -or [string]$handoff.oldContainerId -cne [string]$oldIdentity.Id -or
            [string]$handoff.newContainerId -cne [string]$newRecord.containerId -or
            [string]$newRecord.containerId -ceq [string]$oldIdentity.Id) {
        throw 'M12 backend generation handoff did not publish one distinct active replacement.'
    }
    return [pscustomobject]@{HandoffId=$handoffId;OldGenerationId=[string]$handoff.oldGenerationId
        NewGenerationId=[string]$generationId;OldContainerId=[string]$oldIdentity.Id;NewContainerId=[string]$newRecord.containerId
        Status=[string]$handoff.status}
}
