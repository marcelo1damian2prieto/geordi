. (Join-Path $PSScriptRoot 'GeordiCaptureGenerations.ps1')
. (Join-Path $PSScriptRoot 'GeordiPersistedMetricEvidence.ps1')

function Get-GeordiM11ControlledReplacementComposeArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('--project-directory')
    $arguments.Add($root)
    foreach ($file in @('compose.yaml', 'compose.m19.yaml', 'compose.m11.yaml', 'compose.m11-victoriametrics-isolation.yaml')) {
        $arguments.Add('--file')
        $arguments.Add((Join-Path $root $file))
    }
    return $arguments.ToArray()
}

function Assert-GeordiM11ResetVictoriaMetricsSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string] $SnapshotDirectory,[Parameter(Mandatory)][string] $ExpectedContainerId)
    $sources = @($Manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
    if ($sources.Count -ne 1) { throw 'M11 reset has no unique persisted VictoriaMetrics evidence source.' }
    $ledgerPath = [IO.Path]::GetFullPath((Join-Path $SnapshotDirectory 'm11-reset.snapshot.json'))
    if (@($sources[0].captures | Where-Object { [IO.Path]::GetFullPath([string]$_) -ceq $ledgerPath }).Count -ne 1 -or
            !(Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        throw 'M11 reset VictoriaMetrics ledger is missing or not uniquely registered.'
    }
    $ledger = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if (!$ledger.complete -or !$ledger.runStartBound -or [string]$ledger.source -cne 'victoriametrics-export' -or
            [string]$ledger.sourceService -cne 'victoriametrics' -or [string]$ledger.sourceContainerId -cne $ExpectedContainerId) {
        throw 'M11 reset VictoriaMetrics ledger does not bind the live old container.'
    }
    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath -Captures ([string[]]$sources[0].captures))
    return [string]$ledger.sourceContainerId
}

function Get-GeordiM11DockerVolumeInspection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name,[Parameter(Mandatory)][scriptblock] $DockerCommand)
    $inventory = & $DockerCommand @('volume','ls','--format','{{.Name}}')
    if ($null -eq $inventory -or [int]$inventory.ExitCode -ne 0) { throw 'Unable to inventory Docker volumes for the M11 fixture.' }
    $volumeNames = @($inventory.Output | ForEach-Object { [string]$_ } | Where-Object { $_.Length -gt 0 })
    if ($volumeNames -cnotcontains $Name) { return }
    $inspection = & $DockerCommand @('volume','inspect',$Name)
    if ($null -eq $inspection -or [int]$inspection.ExitCode -ne 0) { throw 'Unable to inspect an inventoried M11 fixture volume.' }
    $volumes = @($inspection.Output | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    if ($volumes.Count -ne 1) { throw 'Docker returned an ambiguous M11 fixture volume inspection.' }
    return $volumes[0]
}

function Remove-GeordiM11DedicatedFixtureVolumes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $ExpectedVolumes,
        [Parameter(Mandatory)][scriptblock] $InspectVolume,[Parameter(Mandatory)][scriptblock] $RemoveVolume,
        [switch] $RequirePresent)
    $expected = [ordered]@{
        'm11-alert-lifecycle-data' = 'geordi_m11-alert-lifecycle-data'
        'm11-victoriametrics-data' = 'geordi_m11-victoriametrics-data'
    }
    if ($ExpectedVolumes.Count -ne $expected.Count) { throw 'M11 fixture volume allowlist is incomplete or contains extra entries.' }
    foreach ($logicalName in $expected.Keys) {
        if (!$ExpectedVolumes.Contains($logicalName) -or [string]$ExpectedVolumes[$logicalName] -cne [string]$expected[$logicalName]) {
            throw 'M11 fixture volume allowlist does not match the dedicated M11 volumes.'
        }
    }
    foreach ($logicalName in $expected.Keys) {
        $candidate = [string]$expected[$logicalName]
        $matches = @(& $InspectVolume $candidate)
        if ($matches.Count -eq 0) {
            if ($RequirePresent) { throw 'Expected owned M11 fixture volume disappeared before transfer cleanup.' }
            continue
        }
        if ($matches.Count -ne 1) { throw 'M11 fixture volume inventory is ambiguous.' }
        $volume = $matches[0]
        if ([string]$volume.Name -cne $candidate -or
                [string]$volume.Labels.'com.docker.compose.project' -cne 'geordi' -or
                [string]$volume.Labels.'com.docker.compose.volume' -cne $logicalName) {
            throw 'Refusing M11 removal for a volume without exact M11 Compose ownership.'
        }
        $null = & $RemoveVolume $candidate
    }
}

function Invoke-GeordiM11BackendGenerationReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CaptureRoot,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $Replace,
        [Parameter(Mandatory)][scriptblock] $ResolveContainerIdentity,
        [Parameter(Mandatory)][scriptblock] $WaitReadiness,
        [Parameter(Mandatory)][string] $Reason,
        [switch] $RequireVictoriaMetricsReplacement,
        [scriptblock] $StartFollower,
        [scriptblock] $TestProcessIdentity,
        [scriptblock] $StopProcess,
        [string] $DockerPath=(Get-Command docker.exe -ErrorAction Stop).Source,
        [string] $PowerShellPath=(Get-Process -Id $PID).Path,
        [string] $WorkerPath=(Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1')
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $oldIdentity = & $ResolveContainerIdentity 'backend'
    Assert-GeordiCaptureContainerIdentity -Identity $oldIdentity -Service backend
    if ([IO.Path]::GetFullPath([string]$oldIdentity.WorkingDirectory) -cne $root -or
            ($oldIdentity.PSObject.Properties.Name -contains 'Running' -and !$oldIdentity.Running)) {
        throw 'M11 backend identity is outside the active candidate checkout.'
    }

    $manifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $records = if ($manifest.captureGenerations.ContainsKey('backend')) { @($manifest.captureGenerations.backend) } else { @() }
    $active = @($records | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
    if ($active.Count -ne 1 -or [string]$active[0].containerId -cne [string]$oldIdentity.Id -or !$active[0].followerProcess) {
        throw 'M11 backend has no unique active generation bound to its current container.'
    }

    $oldVictoriaMetricsIdentity = $null
    if ($RequireVictoriaMetricsReplacement) {
        $oldVictoriaMetricsIdentity = & $ResolveContainerIdentity 'victoriametrics'
        Assert-GeordiCaptureContainerIdentity -Identity $oldVictoriaMetricsIdentity -Service victoriametrics
        $snapshotDirectory = Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'victoriametrics-generations'
        if ([IO.Path]::GetFullPath([string]$oldVictoriaMetricsIdentity.WorkingDirectory) -cne $root -or
                ($oldVictoriaMetricsIdentity.PSObject.Properties.Name -contains 'Running' -and !$oldVictoriaMetricsIdentity.Running)) {
            throw 'M11 VictoriaMetrics identity does not match the captured pre-reset source.'
        }
        [void](Assert-GeordiM11ResetVictoriaMetricsSource -Manifest $manifest -SnapshotDirectory $snapshotDirectory `
            -ExpectedContainerId ([string]$oldVictoriaMetricsIdentity.Id))
    }

    $handoffId = Begin-GeordiCaptureHandoff -CaptureRoot $CaptureRoot -Service backend -Reason $Reason `
        -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess
    $replacementState = @{ NewVictoriaMetricsIdentity=$null }
    $replaceWithVmBoundary = {
        $null = & $Replace
        if ($RequireVictoriaMetricsReplacement) {
            $newVictoriaMetricsIdentity = & $ResolveContainerIdentity 'victoriametrics'
            Assert-GeordiCaptureContainerIdentity -Identity $newVictoriaMetricsIdentity -Service victoriametrics
            if ([IO.Path]::GetFullPath([string]$newVictoriaMetricsIdentity.WorkingDirectory) -cne $root -or
                    ($newVictoriaMetricsIdentity.PSObject.Properties.Name -contains 'Running' -and !$newVictoriaMetricsIdentity.Running) -or
                    [string]$newVictoriaMetricsIdentity.Id -ceq [string]$oldVictoriaMetricsIdentity.Id) {
                throw 'M11 VictoriaMetrics reset did not produce a distinct owned running container.'
            }
            $replacementState.NewVictoriaMetricsIdentity = $newVictoriaMetricsIdentity
        }
    }.GetNewClosure()
    $resolveNewBackend = {
        param([string] $service)
        if ($service -cne 'backend') { throw 'M11 replacement requested an unexpected logical service.' }
        $identity = & $ResolveContainerIdentity $service
        Assert-GeordiCaptureContainerIdentity -Identity $identity -Service backend
        if ([IO.Path]::GetFullPath([string]$identity.WorkingDirectory) -cne $root -or
                ($identity.PSObject.Properties.Name -contains 'Running' -and !$identity.Running) -or
                [string]$identity.Id -ceq [string]$oldIdentity.Id) {
            throw 'M11 replacement backend is not a distinct owned running container.'
        }
        return $identity
    }.GetNewClosure()
    $startFollowerOnly = {
        param($stdout,$stderr,$processRecord,$arguments,$target)
        if ($StartFollower) {
            $started = @(& $StartFollower $stdout $stderr $processRecord $arguments $target)
        } else {
            $started = @(Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath `
                -DockerPath $DockerPath -DockerArguments $arguments -WorkingDirectory $root -StandardOutputPath $stdout `
                -StandardErrorPath $stderr -ProcessRecordPath $processRecord -TargetMetadata $target)
        }
        if ($started.Count -ne 1 -or !$started[0]) { throw 'M11 follower startup returned an invalid process identity.' }
        return $started[0]
    }.GetNewClosure()
    $afterFollowerValidated={param($target,$process,$generationId) $null=& $WaitReadiness $target}.GetNewClosure()
    $generationId = Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $CaptureRoot -Service backend -HandoffId $handoffId `
        -RepositoryRoot $root -Replace $replaceWithVmBoundary -GetContainerIdentity $resolveNewBackend -StartFollower $startFollowerOnly `
        -AfterFollowerValidated $afterFollowerValidated -StopProcess $StopProcess `
        -Reason $Reason -DockerPath $DockerPath -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath

    $completed = Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $handoff = $completed.captureHandoffs[$handoffId]
    $newRecord = Get-GeordiCaptureGenerationRecord -Manifest $completed -Service backend -GenerationId ([string]$generationId)
    if (!$newRecord -or [string]$newRecord.terminalStatus -cne 'capturing' -or [string]$newRecord.handoffId -cne $handoffId -or
            [string]$handoff.status -cne 'complete' -or [string]$handoff.newContainerId -cne [string]$newRecord.containerId -or
            [string]$newRecord.containerId -ceq [string]$oldIdentity.Id) {
        throw 'M11 backend generation handoff did not publish one distinct active replacement.'
    }
    $newVictoriaMetricsId = if ($replacementState.NewVictoriaMetricsIdentity) { [string]$replacementState.NewVictoriaMetricsIdentity.Id } else { $null }
    return [pscustomobject]@{ HandoffId=$handoffId;OldGenerationId=[string]$active[0].generationId;NewGenerationId=[string]$generationId
        OldContainerId=[string]$oldIdentity.Id;NewContainerId=[string]$newRecord.containerId
        OldVictoriaMetricsContainerId=$(if ($oldVictoriaMetricsIdentity) { [string]$oldVictoriaMetricsIdentity.Id } else { $null })
        NewVictoriaMetricsContainerId=$newVictoriaMetricsId }
}
