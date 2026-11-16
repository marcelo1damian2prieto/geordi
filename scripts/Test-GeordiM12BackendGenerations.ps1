[CmdletBinding()]
param([ValidateSet('SelfTest','FirstPublication','Reuse','DirectOverwrite','ReuseIntegrity','PartialMatrix','WrongInheritedVm',
    'PublicationRace','FixtureStartImmutability','RecoveryStartImmutability','RecoveryPositive','RecoveryNegativeSealOrder',
    'RecoveryNegativeBackendQuery','RecoveryNegativeProviderOrder')][string] $Case='SelfTest')

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM12BackendReplacement.ps1')

function Assert-M12Backend([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "M12 backend-generation regression failed: $Message" }
}

function Remove-M12BackendSyntheticRoot([string] $Root) {
    if (!(Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { $_.IsReadOnly=$false }
    Remove-Item -LiteralPath $Root -Recurse -Force
}

function New-M12BackendIdentity($State,[string] $Service) {
    $id=[string]$State.Ids[$Service]
    return [pscustomobject]@{Id=$id;Project='geordi';Service=$Service;WorkingDirectory=$State.RepositoryRoot
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}
}

function Add-M12BackendMetricLedger($State,[string] $Phase,[string] $ContainerId) {
    $directory=Join-Path $State.Root 'victoriametrics-generations'
    [void][IO.Directory]::CreateDirectory($directory)
    $snapshotPath=Join-Path $directory "$Phase.jsonl"
    $ledgerPath=Join-Path $directory "$Phase.snapshot.json"
    $now=[DateTimeOffset]::UtcNow
    $sample=@{metric=@{'__name__'='geordi_security_authentication_attempts_total';'service.name'='geordi-backend';'geordi.telemetry.origin'='platform'}
        timestamps=@($now.ToUnixTimeMilliseconds());values=@('1')} | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($snapshotPath,$sample+"`n",[Text.UTF8Encoding]::new($false))
    $bytes=[long](Get-Item -LiteralPath $snapshotPath).Length
    $ledger=[ordered]@{intervalStartUtc=$State.RunStart;intervalEndUtc=$now.AddSeconds(1).ToString('o');source='victoriametrics-export'
        complete=$true;runStartBound=$true;series=1;samples=1;bytes=$bytes;sourceService='victoriametrics';sourceContainerId=$ContainerId
        snapshotSha256=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    [IO.File]::WriteAllText($ledgerPath,(ConvertTo-Json -InputObject $ledger -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $State.Root
    $manifest.additionalSources[0].captures=@(@($manifest.additionalSources[0].captures)+@($snapshotPath,$ledgerPath))
    $manifest.persistedMetricEvidenceBytes=[long](@($manifest.additionalSources[0].captures | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum)
    Write-GeordiM19ManifestAtomic -Path $State.ManifestPath -Manifest $manifest
}

function New-M12BackendSyntheticState {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m12-backend-generation-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $runStart=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o')
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-m12-backend';startedUtc=$runStart;captureStartedUtc=$runStart
        captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};additionalSources=@(@{channel='victoriametrics';control='geordi_security_authentication_attempts_total';captures=@()})
        captures=@();persistedMetricEvidenceBytes=0}
    $manifestPath=Join-Path $root 'manifest.json'
    [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
    $state=[pscustomobject]@{Root=$root;ManifestPath=$manifestPath;RepositoryRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
        RunStart=$runStart;Ids=@{backend=('a'*64);victoriametrics=('d'*64)};Pid=71000;Alive=@{};ReplaceCalls=0;ReadinessCalls=0
        BackendGenerationId=$null;Events=[Collections.Generic.List[string]]::new();TrackRecoveryEvents=$false;ExpectedNewBackendId=$null
        WrongFollower=$false;BindingChecks=0}
    try {
        $state.BackendGenerationId=Start-M12BackendSyntheticGeneration $state
        Add-M12BackendMetricLedger $state 'm12-reset' $state.Ids.victoriametrics
        return $state
    } catch { Remove-M12BackendSyntheticRoot $root; throw }
}

function Start-M12BackendSyntheticGeneration($State) {
    $identity=New-M12BackendIdentity $State 'backend'
    $startFollower={
        param($stdout,$stderr,$processRecord,$arguments,$target)
        $State.Pid++
        $started=[DateTimeOffset]::UtcNow.ToString('o')
        $recordContainer=if($State.WrongFollower -and [string]$target.containerId -cne ('a'*64)){'f'*64}else{[string]$target.containerId}
        $record=[ordered]@{id=$State.Pid;name='synthetic-log-follower';startUtc=$started;containerId=$recordContainer
            service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc}
        [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stdout,"backend-generation-$($target.containerId)`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
        $State.Alive[[string]$State.Pid]=$true
        return [pscustomobject]@{id=$State.Pid;name='synthetic-log-follower';startUtc=$started}
    }.GetNewClosure()
    return [string](Start-GeordiCaptureGeneration -CaptureRoot $State.Root -Service backend -ContainerIdentity $identity `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' `
        -WorkingDirectory $State.RepositoryRoot -StartFollower $startFollower)
}

function New-M12BackendAdapters($State) {
    $resolve={param([string]$Service)
        if ($State.TrackRecoveryEvents -and $Service -ceq 'backend' -and [string]$State.Ids.backend -ceq [string]$State.ExpectedNewBackendId) {
            $State.Events.Add('new-identity')
        }
        New-M12BackendIdentity $State $Service
    }.GetNewClosure()
    $testFollower={param($Record) [bool]$State.Alive[[string]$Record.id]}.GetNewClosure()
    $testProcess={param($Record) [bool]$State.Alive[[string]$Record.id]}.GetNewClosure()
    $stopProcess={param($Record) $State.Alive[[string]$Record.id]=$false}.GetNewClosure()
    $startFollower={
        param($stdout,$stderr,$processRecord,$arguments,$target)
        $State.Pid++
        $started=[DateTimeOffset]::UtcNow.ToString('o')
        $recordContainer=if($State.WrongFollower -and [string]$target.containerId -cne ('a'*64)){'f'*64}else{[string]$target.containerId}
        $record=[ordered]@{id=$State.Pid;name='synthetic-log-follower';startUtc=$started;containerId=$recordContainer
            service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc}
        [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stdout,"backend-generation-$($target.containerId)`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
        $State.Alive[[string]$State.Pid]=$true
        if ($State.TrackRecoveryEvents) { $State.Events.Add('new-follower') }
        return [pscustomobject]@{id=$State.Pid;name='synthetic-log-follower';startUtc=$started}
    }.GetNewClosure()
    $readiness={param($Target)
        $manifest=Get-GeordiCaptureGenerationManifest $State.Root
        $active=@($manifest.captureGenerations.backend|Where-Object{$_.terminalStatus -ceq 'capturing' -and $_.containerId -ceq [string]$Target.containerId})
        if($active.Count -ne 1 -or [int]$active[0].followerProcess.id -ne [int]$State.Pid){throw 'M12 readiness preceded exact shared follower validation.'}
        $State.BindingChecks++
        if ($State.TrackRecoveryEvents) { $State.Events.Add('follower-binding-validated') }
        $State.ReadinessCalls++
        if ($State.TrackRecoveryEvents) { $State.Events.Add('readiness') }
        if ([string]$Target.containerId -cne [string]$State.Ids.backend) { throw 'Synthetic backend readiness identity mismatch.' }
    }.GetNewClosure()
    return [pscustomobject]@{Resolve=$resolve;TestFollower=$testFollower;TestProcess=$testProcess;StopProcess=$stopProcess
        StartFollower=$startFollower;Readiness=$readiness}
}

function Assert-M12RecoveryEventTrace([string[]] $Events) {
    $required=@('capture-recovery-metric','vm-stop','backend-outage-observed','lifecycle-state-verified','handoff-begin',
        'old-follower-sealed','backend-stop','vm-start','provider-firing','backend-recreate','new-identity','new-follower',
        'follower-binding-validated','readiness','handoff-complete')
    $positions=@{}
    foreach($event in $required) {
        $indices=@(for($i=0;$i -lt $Events.Count;$i++){if($Events[$i] -ceq $event){$i}})
        if($indices.Count -ne 1){throw "M12 recovery trace is missing or duplicates required event '$event'."}
        $positions[$event]=[int]$indices[0]
    }
    for($i=0;$i -lt $required.Count-1;$i++) {
        if($positions[$required[$i]] -ge $positions[$required[$i+1]]){throw "M12 recovery event order is invalid between '$($required[$i])' and '$($required[$i+1])'."}
    }
    $sealed=$positions['old-follower-sealed'];$follower=$positions['new-follower']
    if ($positions['backend-stop'] -ne ($sealed+1)) { throw 'M12 backend stop did not immediately follow old-generation sealing.' }
    if ($follower -gt ($sealed+1) -and @($Events[($sealed+1)..($follower-1)] | Where-Object { $_ -ceq 'backend-api-query' -or $_ -ceq 'backend-state-query' }).Count -gt 0) {
        throw 'M12 recovery performed a backend request after sealing and before the new follower.'
    }
}

function Invoke-M12BackendSyntheticRecoveryBoundary($State,[string] $NewBackendId) {
    $adapters=New-M12BackendAdapters $State
    $State.TrackRecoveryEvents=$true
    $State.ExpectedNewBackendId=$NewBackendId
    $State.Events.Clear()
    $State.Events.Add('capture-recovery-metric')
    $beforeHandoff={
        param($OldIdentity,$VmIdentity)
        $manifest=Get-GeordiCaptureGenerationManifest $State.Root
        $active=@($manifest.captureGenerations.backend | Where-Object terminalStatus -ceq 'capturing')
        if ($active.Count -ne 1 -or [string]$active[0].containerId -cne [string]$OldIdentity.Id -or
                !$State.Alive[[string]$active[0].followerProcess.id] -or [string]$VmIdentity.Id -cne [string]$State.Ids.victoriametrics) {
            throw 'M12 outage assertions did not run under the exact active backend follower and VM identity.'
        }
        $State.Events.Add('vm-stop')
        $State.Events.Add('backend-outage-observed')
        $State.Events.Add('lifecycle-state-verified')
    }.GetNewClosure()
    $replace={
        $manifest=Get-GeordiCaptureGenerationManifest $State.Root
        $pending=@($manifest.captureHandoffs.Values | Where-Object { [string]$_.logicalService -ceq 'backend' -and [string]$_.status -ceq 'old-sealed' })
        if($pending.Count -ne 1){throw 'Synthetic M12 recovery did not have one sealed handoff.'}
        $old=Get-GeordiCaptureGenerationRecord $manifest backend ([string]$pending[0].oldGenerationId)
        if (!$old -or [string]$old.terminalStatus -cne 'sealed' -or $State.Alive[[string]$old.followerProcess.id]) {
            throw 'M12 recovery replacement began before the old follower was sealed.'
        }
        $State.Events.Add('old-follower-sealed')
        $State.Events.Add('backend-stop')
        $State.Events.Add('vm-start')
        $State.Events.Add('provider-firing')
        $State.ReplaceCalls++
        $State.Events.Add('backend-recreate')
        $State.Ids.backend=$NewBackendId
    }.GetNewClosure()
    $testProcess={param($Record) $State.Events.Add('handoff-begin');return $true}.GetNewClosure()
    $resolve=$adapters.Resolve
    $ready=$adapters.Readiness
    $result=Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $State.Root -RepositoryRoot $State.RepositoryRoot `
        -EvidencePhase m12-recovery-start -Reason 'synthetic-m12-provider-recovery' -Replace $replace `
        -ResolveContainerIdentity $resolve -WaitForReadiness $ready -BeforeHandoff $beforeHandoff `
        -StartFollower $adapters.StartFollower -TestFollowerProcess $adapters.TestFollower `
        -TestProcessIdentity $testProcess -StopProcess $adapters.StopProcess `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
    $State.Events.Add('handoff-complete')
    return [pscustomobject]@{Result=$result;Events=@($State.Events.ToArray())}
}

function Invoke-M12BackendSyntheticBoundary($State,[string] $NewBackendId,[string] $EvidencePhase,[switch] $FailReplace,
    [switch] $ReuseBackendId,[switch] $FailFollower,[switch] $FailReadiness,[switch] $WrongOldIdentity) {
    $adapters=New-M12BackendAdapters $State
    if ($WrongOldIdentity) { $State.Ids.backend='f'*64 }
    $replace={
        $State.ReplaceCalls++
        if ($FailReplace) { throw 'Synthetic M12 replacement command failed.' }
        if (!$ReuseBackendId) { $State.Ids.backend=$NewBackendId }
    }.GetNewClosure()
    if ($FailFollower) { $adapters.StartFollower={throw 'Synthetic follower start failure.'}.GetNewClosure() }
    if ($FailReadiness) { $adapters.Readiness={throw 'Synthetic backend readiness failure.'}.GetNewClosure() }
    return Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $State.Root -RepositoryRoot $State.RepositoryRoot `
        -EvidencePhase $EvidencePhase -Reason 'synthetic-m12-backend-boundary' -Replace $replace `
        -ResolveContainerIdentity $adapters.Resolve -WaitForReadiness $adapters.Readiness -StartFollower $adapters.StartFollower `
        -TestFollowerProcess $adapters.TestFollower -TestProcessIdentity $adapters.TestProcess -StopProcess $adapters.StopProcess `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
}

function Test-M12BackendPositiveChain {
    $state=New-M12BackendSyntheticState
    try {
        $oldPaths=@((Get-GeordiCaptureGenerationRecord (Get-GeordiCaptureGenerationManifest $state.Root) backend $state.BackendGenerationId).capturePath)
        $first=Invoke-M12BackendSyntheticBoundary $state ('b'*64) 'm12-reset'
        Assert-M12Backend ($first.Status -ceq 'complete' -and $first.OldContainerId -ceq ('a'*64) -and $first.NewContainerId -ceq ('b'*64)) `
            'transferred M11 backend did not hand off to a distinct M12 generation'
        $state.Ids.victoriametrics='e'*64
        Add-M12BackendMetricLedger $state 'm12-fixture-start' $state.Ids.victoriametrics
        $second=Invoke-M12BackendSyntheticBoundary $state ('c'*64) 'm12-fixture-start'
        Add-M12BackendMetricLedger $state 'm12-recovery-start' $state.Ids.victoriametrics
        $third=Invoke-M12BackendSyntheticRecoveryBoundary $state ('9'*64)
        Assert-M12RecoveryEventTrace $third.Events
        $manifest=Get-GeordiCaptureGenerationManifest $state.Root
        $backendGenerations=@($manifest.captureGenerations.backend)
        $handoffs=@($manifest.captureHandoffs.Values | Where-Object { $_.logicalService -ceq 'backend' })
        Assert-M12Backend ($backendGenerations.Count -eq 4 -and $handoffs.Count -eq 3 -and
            @($handoffs | Where-Object status -cne 'complete').Count -eq 0) 'M12 ordered backend generation chain is incomplete'
        Assert-M12Backend ($backendGenerations[0].terminalStatus -ceq 'sealed' -and $backendGenerations[-1].terminalStatus -ceq 'capturing' -and
            $backendGenerations[0].containerId -cne $backendGenerations[1].containerId -and
            $backendGenerations[1].containerId -cne $backendGenerations[2].containerId -and
            $backendGenerations[2].containerId -cne $backendGenerations[3].containerId) 'M12 backend physical generations are not distinct/ordered'
        Assert-M12Backend ((Get-FileHash -LiteralPath $oldPaths[0] -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $backendGenerations[0].sha256) `
            'historical M11 backend generation bytes changed'
        Assert-M12Backend ($second.OldContainerId -ceq $first.NewContainerId -and $third.Result.OldContainerId -ceq $second.NewContainerId -and
            $state.ReadinessCalls -eq 3 -and $state.ReplaceCalls -eq 3) 'M12 scheduler/recovery replacements did not use the generation lifecycle'
        foreach($record in @($backendGenerations | Where-Object { $_.terminalStatus -ceq 'sealed' })) {
            Assert-M12Backend ((Get-FileHash -LiteralPath $record.capturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $record.sha256 -and
                (Get-FileHash -LiteralPath $record.stderrCapturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $record.stderrSha256) `
                'a sealed historical backend stream failed its recorded integrity check'
        }
        foreach($handoff in $handoffs) {
            Assert-M12Backend ($handoff.status -ceq 'complete' -and $handoff.oldContainerId -cne $handoff.newContainerId -and
                $handoff.oldCaptureEndedUtc -and $handoff.newCaptureStartedUtc) 'completed M12 handoff does not bind a distinct, ordered container boundary'
        }
        Write-Output 'm12_backend_positive_chain=PASS M11_to_M12_scheduler_enablement_provider_recovery=true generations=4 handoffs=3 evidence_immutable=true'
    } finally { Remove-M12BackendSyntheticRoot $state.Root }
}

function Test-M12BackendFailureCases {
    foreach($case in @('wrong-old-identity','wrong-evidence','replacement-failure','same-container','follower-failure','wrong-follower','readiness-failure','missing-evidence')) {
        $state=New-M12BackendSyntheticState
        try {
            $phase='m12-reset'
            if ($case -eq 'wrong-evidence') {
                $ledgerPath=Join-Path $state.Root 'victoriametrics-generations/m12-reset.snapshot.json'
                $ledger=Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
                $ledger.sourceContainerId='f'*64
                [IO.File]::WriteAllText($ledgerPath,(ConvertTo-Json -InputObject $ledger -Compress),[Text.UTF8Encoding]::new($false))
            }
            if ($case -eq 'missing-evidence') { Remove-Item -LiteralPath (Join-Path $state.Root 'victoriametrics-generations/m12-reset.snapshot.json') -Force }
            if ($case -eq 'wrong-follower') { $state.WrongFollower=$true }
            $before=Get-GeordiCaptureGenerationManifest $state.Root
            $old=Get-GeordiCaptureGenerationRecord $before backend $state.BackendGenerationId
            $oldHash=(Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash
            $failed=$false
            try {
                switch($case) {
                    'wrong-old-identity' { $null=Invoke-M12BackendSyntheticBoundary $state ('b'*64) $phase -WrongOldIdentity }
                    'wrong-evidence' { $null=Invoke-M12BackendSyntheticBoundary $state ('b'*64) $phase }
                    'replacement-failure' { $null=Invoke-M12BackendSyntheticBoundary $state ('b'*64) $phase -FailReplace }
                    'same-container' { $null=Invoke-M12BackendSyntheticBoundary $state ('a'*64) $phase -ReuseBackendId }
                    'follower-failure' { $null=Invoke-M12BackendSyntheticBoundary $state ('b'*64) $phase -FailFollower }
                    'wrong-follower' { $null=Invoke-M12BackendSyntheticBoundary $state ('b'*64) $phase }
                    'readiness-failure' { $null=Invoke-M12BackendSyntheticBoundary $state ('b'*64) $phase -FailReadiness }
                    'missing-evidence' { $null=Invoke-M12BackendSyntheticBoundary $state ('b'*64) $phase }
                }
            } catch { $failed=$true }
            $after=Get-GeordiCaptureGenerationManifest $state.Root
            $handoffs=@($after.captureHandoffs.Values | Where-Object { $_.logicalService -ceq 'backend' })
            Assert-M12Backend ($failed -and $handoffs.Count -eq 0 -or
                ($failed -and $handoffs.Count -eq 1 -and [string]$handoffs[0].status -like 'incomplete-*')) "$case did not fail closed"
            if ($case -in @('wrong-old-identity','wrong-evidence','missing-evidence')) {
                Assert-M12Backend ($state.ReplaceCalls -eq 0 -and $old.terminalStatus -ceq 'capturing') "$case mutated before boundary authorization"
            }
            Assert-M12Backend ((Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash -ceq $oldHash) "$case modified sealed/historical evidence"
            if($case -eq 'wrong-follower'){
                Assert-M12Backend ($state.ReadinessCalls -eq 0 -and $state.BindingChecks -eq 0 -and
                    @($after.captureGenerations.backend|Where-Object terminalStatus -ceq 'incomplete-start').Count -eq 1 -and
                    @($after.captureGenerations.backend|Where-Object{[string]$_.containerId -ceq ('b'*64) -and $_.terminalStatus -ceq 'capturing'}).Count -eq 0) `
                    'wrong M12 follower reached readiness or was accepted as the new generation'
            }
        } finally { Remove-M12BackendSyntheticRoot $state.Root }
        Write-Output "m12_backend_failure=PASS case=$case incomplete_handoff_or_preflight_rejection=true"
    }
}

function Test-M12FixtureVolumeOwnership {
    $expected=Get-GeordiM12DedicatedFixtureVolumeAllowlist
    $inventory=@{}
    foreach($logical in $expected.Keys) { $name=$expected[$logical];$inventory[$name]=[pscustomobject]@{Name=$name;Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'=$logical}} }
    $removed=[Collections.Generic.List[string]]::new()
    $inspect={param($Name) $inventory[$Name]}.GetNewClosure()
    $remove={param($Name) $removed.Add([string]$Name)}.GetNewClosure()
    Remove-GeordiM12DedicatedFixtureVolumes -ExpectedVolumes $expected -InspectVolume $inspect -RemoveVolume $remove
    Assert-M12Backend ($removed.Count -eq 2 -and @($removed | Where-Object { $_ -match 'm19-' }).Count -eq 0) 'M12 cleanup escaped its exact volume allowlist'
    $protected=$false
    try { Remove-GeordiM12DedicatedFixtureVolumes -ExpectedVolumes ([ordered]@{'m12-alert-lifecycle-data'='geordi_m19-alert-lifecycle-data';'m12-victoriametrics-data'='geordi_m12-victoriametrics-data'}) -InspectVolume $inspect -RemoveVolume $remove }
    catch { $protected=$true }
    Assert-M12Backend $protected 'protected M19 volume substitution was accepted'
    Write-Output 'm12_backend_volumes=PASS exact_m12_labels=true protected_substitution_rejected=true'
}

function Test-M12BackendCommandScope {
    $root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    foreach($boundary in @('initial-fixture','scheduler-enablement','provider-recovery')) {
        $arguments=@(Get-GeordiM12BackendRecreationArguments -RepositoryRoot $root -Boundary $boundary)
        Assert-M12Backend ($arguments[-1] -ceq 'backend' -and $arguments -contains '--no-deps' -and
            $arguments -contains '--force-recreate' -and $arguments -contains 'up' -and
            @($arguments | Where-Object { $_ -in @('backend','frontend','otel-collector','victoriametrics','burn-demo','m12-burn-demo','webhook-receiver-a','webhook-receiver-b','down','rm','-v') }).Count -eq 1) `
            "$boundary command is not isolated to backend recreation"
    }
    Write-Output 'm12_backend_command_scope=PASS backend_only=true dependencies_disabled=true destructive_project_flags=false'
}

function Test-M12BackendMetricPhases {
    $root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $identity={param([string]$Service) [pscustomobject]@{Id=('d'*64);Project='geordi';Service=$Service;WorkingDirectory=$root
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}}.GetNewClosure()
    foreach($phase in @('m12-fixture-start','m12-recovery-start')) {
        $resolved=Get-GeordiPersistedMetricSourceIdentity -Phase $phase -RepositoryRoot $root -ResolveIdentity $identity
        Assert-M12Backend ($resolved.sourceService -ceq 'victoriametrics' -and $resolved.sourceContainerId -ceq ('d'*64)) `
            "$phase did not resolve exact VictoriaMetrics source identity"
        $directory=Join-Path ([IO.Path]::GetTempPath()) ('m12-phase-contract-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($directory)
        try {
            $snapshot=Join-Path $directory "$phase.jsonl";$ledger=Join-Path $directory "$phase.snapshot.json"
            $manifest=@{additionalSources=@(@{channel='victoriametrics';captures=@()})}
            Assert-GeordiPersistedMetricPhaseAvailable -Phase $phase -SnapshotPath $snapshot -LedgerPath $ledger -Manifest $manifest
            $manifest.additionalSources[0].captures=@($ledger)
            $referenced=$false
            try { Assert-GeordiPersistedMetricPhaseAvailable -Phase $phase -SnapshotPath $snapshot -LedgerPath $ledger -Manifest $manifest }
            catch { $referenced=$true }
            Assert-M12Backend $referenced "$phase allowed a previously referenced ledger path"
            [IO.File]::WriteAllText($snapshot,'',[Text.UTF8Encoding]::new($false))
            $occupied=$false
            try { Assert-GeordiPersistedMetricPhaseAvailable -Phase $phase -SnapshotPath $snapshot -LedgerPath $ledger -Manifest @{additionalSources=@()} }
            catch { $occupied=$true }
            Assert-M12Backend $occupied "$phase allowed an occupied immutable snapshot path"
        } finally { Remove-M12BackendSyntheticRoot $directory }
    }
    Write-Output 'm12_backend_metric_phases=PASS unique_immutable_paths=true exact_vm_identity=true'
}

function Remove-M12BackendResetEvidence($State) {
    $directory=Join-Path $State.Root 'victoriametrics-generations'
    foreach($path in @((Join-Path $directory 'm12-reset.jsonl'),(Join-Path $directory 'm12-reset.snapshot.json'))) {
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
    }
    $manifest=Get-GeordiCaptureGenerationManifest $State.Root
    $manifest.additionalSources[0].captures=@($manifest.additionalSources[0].captures | Where-Object { [IO.Path]::GetFileName([string]$_) -notin @('m12-reset.jsonl','m12-reset.snapshot.json') })
    $manifest.persistedMetricEvidenceBytes=[long](@($manifest.additionalSources[0].captures | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum)
    Write-GeordiM19ManifestAtomic -Path $State.ManifestPath -Manifest $manifest
}

function Invoke-M12BackendResetEnsure($State,[scriptblock] $Capture,[string] $ExpectedVmId) {
    return Ensure-GeordiM12ResetTransferEvidence -CaptureRoot $State.Root `
        -ExpectedVictoriaMetricsContainerId $ExpectedVmId -Capture $Capture
}

function Test-M12ResetFirstPublication {
    $state=New-M12BackendSyntheticState
    try {
        Remove-M12BackendResetEvidence $state
        $manifest=Get-GeordiCaptureGenerationManifest $state.Root
        $dir=Join-Path $state.Root 'victoriametrics-generations'
        Assert-GeordiPersistedMetricPhaseAvailable -Phase m12-reset -SnapshotPath (Join-Path $dir 'm12-reset.jsonl') `
            -LedgerPath (Join-Path $dir 'm12-reset.snapshot.json') -Manifest $manifest
        $counter=[pscustomobject]@{Calls=0}
        $capture={ $counter.Calls++;Add-M12BackendMetricLedger $state 'm12-reset' $state.Ids.victoriametrics }.GetNewClosure()
        $ledger=Invoke-M12BackendResetEnsure $state $capture $state.Ids.victoriametrics
        Assert-M12Backend ($counter.Calls -eq 1) 'first m12-reset publication did not invoke its capture exactly once'
        Assert-M12Backend ($ledger.source -ceq 'victoriametrics-export') 'first m12-reset publication did not require a live VictoriaMetrics export'
        Assert-M12Backend ($ledger.sourceContainerId -ceq $state.Ids.victoriametrics) 'first m12-reset publication did not bind the inherited live VM identity'
        Write-Output 'm12_reset_first_publication=PASS canonical_phase=true live_inherited_vm=true'
    } finally { Remove-M12BackendSyntheticRoot $state.Root }
}

function Test-M12ResetConsumerApplyReuse {
    $state=New-M12BackendSyntheticState
    try {
        Remove-M12BackendResetEvidence $state
        $counter=[pscustomobject]@{Calls=0}
        $capture={ $counter.Calls++;Add-M12BackendMetricLedger $state 'm12-reset' $state.Ids.victoriametrics }.GetNewClosure()
        $first=Invoke-M12BackendResetEnsure $state $capture $state.Ids.victoriametrics
        $snapshotPath=Join-Path $state.Root 'victoriametrics-generations/m12-reset.jsonl'
        $ledgerPath=Join-Path $state.Root 'victoriametrics-generations/m12-reset.snapshot.json'
        $snapshotHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
        $ledgerHash=(Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash
        $firstLedger=[IO.File]::ReadAllText($ledgerPath)
        $before=Get-GeordiCaptureGenerationManifest $state.Root
        $beforeRefs=@($before.additionalSources[0].captures)
        $secondCapture={ $counter.Calls++;throw 'm12-reset was recaptured instead of reused.' }.GetNewClosure()
        $second=Invoke-M12BackendResetEnsure $state $secondCapture $state.Ids.victoriametrics
        $after=Get-GeordiCaptureGenerationManifest $state.Root
        Assert-M12Backend ($counter.Calls -eq 1 -and $second.sourceContainerId -ceq $first.sourceContainerId) 'consumer-only -> apply did not reuse the authenticated reset evidence'
        Assert-M12Backend ((Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash -ceq $snapshotHash -and
            (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash -ceq $ledgerHash) 'm12-reset evidence bytes changed during reuse'
        Assert-M12Backend ([IO.File]::ReadAllText($ledgerPath) -ceq $firstLedger) 'm12-reset interval/ledger changed during reuse'
        Assert-M12Backend ((@($after.additionalSources[0].captures) -join "`n") -ceq (@($beforeRefs) -join "`n")) 'manifest references changed during reuse'
        Write-Output 'm12_reset_consumer_apply_reuse=PASS snapshot_ledger_interval_references_unchanged=true'
    } finally { Remove-M12BackendSyntheticRoot $state.Root }
}

function Test-M12ResetDirectOverwriteRejected {
    $state=New-M12BackendSyntheticState
    try {
        $dir=Join-Path $state.Root 'victoriametrics-generations'
        $manifest=Get-GeordiCaptureGenerationManifest $state.Root
        $snapshotPath=Join-Path $dir 'm12-reset.jsonl';$ledgerPath=Join-Path $dir 'm12-reset.snapshot.json'
        $blocked=$false
        try { Assert-GeordiPersistedMetricPhaseAvailable -Phase m12-reset -SnapshotPath $snapshotPath -LedgerPath $ledgerPath -Manifest $manifest }
        catch { $blocked=$true }
        Assert-M12Backend $blocked 'occupied m12-reset phase availability check permitted republishing'
        $snapshotHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
        $ledgerHash=(Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash
        $tempSnapshot=Join-Path $dir 'second-attempt.jsonl';[IO.File]::WriteAllText($tempSnapshot,'replacement')
        $moveBlocked=$false
        try { [void](Complete-GeordiPersistedMetricSnapshotFile -TemporaryPath $tempSnapshot -SnapshotPath $snapshotPath -Bytes 11 -CreateNew) }
        catch { $moveBlocked=$true }
        Assert-M12Backend ($moveBlocked -and (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash -ceq $snapshotHash) `
            'physical snapshot publication replaced the first m12-reset file'
        $tempLedger=Join-Path $dir 'second-attempt.snapshot.tmp';[IO.File]::WriteAllText($tempLedger,'replacement')
        $ledgerMoveBlocked=$false
        try { [IO.File]::Move($tempLedger,$ledgerPath) }
        catch { $ledgerMoveBlocked=$true }
        Assert-M12Backend ($ledgerMoveBlocked -and (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash -ceq $ledgerHash) `
            'physical ledger publication replaced the first m12-reset ledger'
        $captureSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Raw
        Assert-M12Backend ($captureSource -match 'CreateNew:\(\$isM14Event\s+-or\s+\$isM11Final\s+-or\s+\$isM12Reset' -and
            $captureSource.Contains('if ($isM14Event -or $isM11Final -or $isM12Reset -or')) 'capture entry point lacks m12-reset occupied-path and create-new enforcement'
        Write-Output 'm12_reset_direct_overwrite=PASS preflight_and_physical_create_new=true'
    } finally { Remove-M12BackendSyntheticRoot $state.Root }
}

function Test-M12ResetZeroNonemptyPublicationRace {
    if (!('GeordiM19MetricPhaseMutexProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class GeordiM19MetricPhaseMutexProbe {
    public static int TryAcquireFromNewThread(string name) {
        int result = -1;
        using (ManualResetEvent ready = new ManualResetEvent(false)) {
            Thread worker = new Thread(delegate() {
                using (Mutex mutex = new Mutex(false, name)) {
                    try {
                        if (mutex.WaitOne(0)) { result = 1; mutex.ReleaseMutex(); }
                        else { result = 0; }
                    } catch (AbandonedMutexException) { result = 2; }
                    finally { ready.Set(); }
                }
            });
            worker.IsBackground = true;
            worker.Start();
            ready.WaitOne();
            worker.Join();
        }
        return result;
    }
}
'@ -ErrorAction Stop
    }
    $state=New-M12BackendSyntheticState
    $mutex=$null
    try {
        $capturePath=Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1'
        $tokens=$null;$errors=$null
        $captureAst=[Management.Automation.Language.Parser]::ParseFile($capturePath,[ref]$tokens,[ref]$errors)
        Assert-M12Backend ($errors.Count -eq 0) 'capture script failed parsing during publication-lock wiring check'
        $publicationTry=@($captureAst.FindAll({param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
            $node.Body.Extent.Text.Contains('Assert-GeordiPersistedMetricPhaseAvailable') -and
            $node.Body.Extent.Text.Contains('Complete-GeordiPersistedMetricSnapshotFile') -and
            $node.Body.Extent.Text.Contains('Write-GeordiM19ManifestAtomic') -and
            $node.Finally.Extent.Text.Contains('Exit-GeordiPersistedMetricPhasePublication')
        },$true))
        $lockAssignment=@($captureAst.FindAll({param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$phasePublicationMutex' -and
            $node.Right.Extent.Text.Contains('Enter-GeordiPersistedMetricPhasePublication')
        },$true))
        Assert-M12Backend ($publicationTry.Count -eq 1 -and $lockAssignment.Count -eq 1 -and
            $lockAssignment[0].Extent.StartOffset -lt $publicationTry[0].Extent.StartOffset) `
            'm12-reset fixed-phase lock does not cover preflight, artifact publication, and manifest publication'
        Remove-M12BackendResetEvidence $state
        $directory=Join-Path $state.Root 'victoriametrics-generations'
        $snapshotPath=Join-Path $directory 'm12-reset.jsonl'
        $ledgerPath=Join-Path $directory 'm12-reset.snapshot.json'
        $mutex=$null=Enter-GeordiPersistedMetricPhasePublication -SnapshotPath $snapshotPath -LedgerPath $ledgerPath
        $mutexName=Get-GeordiPersistedMetricPhasePublicationMutexName -LedgerPath $ledgerPath
        $competingAcquire=[GeordiM19MetricPhaseMutexProbe]::TryAcquireFromNewThread($mutexName)
        Assert-M12Backend ($competingAcquire -eq 0 -and !(Test-Path -LiteralPath $snapshotPath) -and !(Test-Path -LiteralPath $ledgerPath)) `
            'concurrent nonempty publisher entered or wrote canonical evidence during the zero-byte publication'

        $now=[DateTimeOffset]::UtcNow
        $ledger=[ordered]@{intervalStartUtc=$state.RunStart;intervalEndUtc=$now.ToString('o');source='victoriametrics-export';
            complete=$true;runStartBound=$true;series=0;samples=0L;bytes=0L}
        Add-GeordiPersistedMetricArtifactBinding -Ledger $ledger -Source 'victoriametrics-export' `
            -SourceIdentity ([ordered]@{sourceService='victoriametrics';sourceContainerId=$state.Ids.victoriametrics}) `
            -SnapshotTemporaryPath (Join-Path $directory 'empty-publication.tmp') -Bytes 0
        $ledgerTemporary=Join-Path $directory 'm12-reset.snapshot.pending'
        [IO.File]::WriteAllText($ledgerTemporary,(ConvertTo-Json -InputObject $ledger -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($ledgerTemporary,$ledgerPath)
        $manifest=Get-GeordiCaptureGenerationManifest $state.Root
        $manifest.additionalSources[0].captures=@($ledgerPath)
        $manifest.persistedMetricEvidenceBytes=[long](Get-Item -LiteralPath $ledgerPath).Length
        Write-GeordiM19ManifestAtomic -Path $state.ManifestPath -Manifest $manifest
        $ledgerHash=(Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash
        $references=@((Get-GeordiCaptureGenerationManifest $state.Root).additionalSources[0].captures)
        Exit-GeordiPersistedMetricPhasePublication -Mutex $mutex
        $mutex=$null

        $mutex=Enter-GeordiPersistedMetricPhasePublication -SnapshotPath $snapshotPath -LedgerPath $ledgerPath
        $rejected=$false
        try { Assert-GeordiPersistedMetricPhaseAvailable -Phase 'm12-reset' -SnapshotPath $snapshotPath -LedgerPath $ledgerPath `
                -Manifest (Get-GeordiCaptureGenerationManifest $state.Root) }
        catch { $rejected=$true }
        $after=Get-GeordiCaptureGenerationManifest $state.Root
        Assert-M12Backend ($rejected -and !(Test-Path -LiteralPath $snapshotPath) -and
            (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash -ceq $ledgerHash -and
            ((@($after.additionalSources[0].captures)) -join "`n") -ceq ($references -join "`n")) `
            'a later nonempty publication altered the accepted zero-byte evidence or its manifest binding'
        Write-Output 'm12_reset_zero_nonempty_race=PASS loser_blocked_before_publish=true accepted_zero_byte_evidence_immutable=true'
    } finally {
        if ($mutex) { Exit-GeordiPersistedMetricPhasePublication -Mutex $mutex }
        Remove-M12BackendSyntheticRoot $state.Root
    }
}

function Set-M12ResetLedger($State,[scriptblock] $Mutation) {
    $path=Join-Path $State.Root 'victoriametrics-generations/m12-reset.snapshot.json'
    $ledger=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    & $Mutation $ledger
    [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $ledger -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
}

function Assert-M12ResetReuseFails($State,[string] $ExpectedVmId) {
    $counter=[pscustomobject]@{Calls=0}
    $capture={ $counter.Calls++;throw 'Invalid occupied m12-reset evidence was recaptured.' }.GetNewClosure()
    $failed=$false
    try { $null=Invoke-M12BackendResetEnsure $State $capture $ExpectedVmId } catch { $failed=$true }
    Assert-M12Backend ($failed -and $counter.Calls -eq 0) 'invalid existing m12-reset evidence was accepted or overwritten'
}

function Test-M12ResetReuseIntegrity {
    foreach($case in @('hash','bytes','sample-interval','wrong-source')) {
        $state=New-M12BackendSyntheticState
        try {
            switch($case) {
                'hash' { Set-M12ResetLedger $state {param($ledger)$ledger.snapshotSha256='0'*64} }
                'bytes' { Set-M12ResetLedger $state {param($ledger)$ledger.bytes=[long]$ledger.bytes+1} }
                'sample-interval' { Set-M12ResetLedger $state {param($ledger)$ledger.intervalEndUtc=$state.RunStart} }
                'wrong-source' {
                    $snapshotPath=Join-Path $state.Root 'victoriametrics-generations/m12-reset.jsonl'
                    Remove-Item -LiteralPath $snapshotPath -Force
                    Set-M12ResetLedger $state {param($ledger)
                        $ledger.source='verified-prior-generation-removal';$ledger.bytes=0;$ledger.Remove('sourceService');$ledger.Remove('sourceContainerId');$ledger.Remove('snapshotSha256');$ledger.priorSnapshot='m11-final'
                    }
                    $manifest=Get-GeordiCaptureGenerationManifest $state.Root
                    $manifest.additionalSources[0].captures=@($manifest.additionalSources[0].captures | Where-Object { [IO.Path]::GetFileName([string]$_) -cne 'm12-reset.jsonl' })
                    Write-GeordiM19ManifestAtomic -Path $state.ManifestPath -Manifest $manifest
                }
            }
            Assert-M12ResetReuseFails $state $state.Ids.victoriametrics
        } finally { Remove-M12BackendSyntheticRoot $state.Root }
        Write-Output "m12_reset_reuse_integrity=PASS case=$case rejected=true"
    }
}

function Test-M12ResetPartialMatrix {
    foreach($case in @('snapshot-without-ledger','ledger-without-snapshot','manifest-reference-incomplete','physical-unreferenced')) {
        $state=New-M12BackendSyntheticState
        try {
            $snapshotPath=Join-Path $state.Root 'victoriametrics-generations/m12-reset.jsonl'
            $ledgerPath=Join-Path $state.Root 'victoriametrics-generations/m12-reset.snapshot.json'
            switch($case) {
                'snapshot-without-ledger' { Remove-Item -LiteralPath $ledgerPath -Force }
                'ledger-without-snapshot' { Remove-Item -LiteralPath $snapshotPath -Force }
                'manifest-reference-incomplete' { Remove-Item -LiteralPath $ledgerPath -Force }
                'physical-unreferenced' {
                    $manifest=Get-GeordiCaptureGenerationManifest $state.Root
                    $manifest.additionalSources[0].captures=@()
                    Write-GeordiM19ManifestAtomic -Path $state.ManifestPath -Manifest $manifest
                }
            }
            Assert-M12ResetReuseFails $state $state.Ids.victoriametrics
        } finally { Remove-M12BackendSyntheticRoot $state.Root }
        Write-Output "m12_reset_partial_phase=PASS case=$case rejected=true"
    }
}

function Test-M12ResetWrongInheritedVm {
    $state=New-M12BackendSyntheticState
    try {
        $capture={throw 'Wrong inherited VM caused a recapture.'}.GetNewClosure()
        $failed=$false
        try { $null=Invoke-M12BackendResetEnsure $state $capture ('f'*64) } catch { $failed=$true }
        Assert-M12Backend $failed 'm12-reset from a different inherited VictoriaMetrics container was reused'
        Write-Output 'm12_reset_wrong_inherited_vm=PASS rejected=true'
    } finally { Remove-M12BackendSyntheticRoot $state.Root }
}

function Test-M12OtherMetricPhaseImmutability([string] $Phase) {
    $state=New-M12BackendSyntheticState
    try {
        $dir=Join-Path $state.Root 'victoriametrics-generations'
        $manifest=Get-GeordiCaptureGenerationManifest $state.Root
        $snapshot=Join-Path $dir "$Phase.jsonl";$ledger=Join-Path $dir "$Phase.snapshot.json"
        Assert-GeordiPersistedMetricPhaseAvailable -Phase $Phase -SnapshotPath $snapshot -LedgerPath $ledger -Manifest $manifest
        [IO.File]::WriteAllText($snapshot,'')
        $blocked=$false
        try { Assert-GeordiPersistedMetricPhaseAvailable -Phase $Phase -SnapshotPath $snapshot -LedgerPath $ledger -Manifest $manifest }
        catch { $blocked=$true }
        Assert-M12Backend $blocked "$Phase lost its existing occupied-phase immutability guard"
        Write-Output "m12_other_metric_phase_immutability=PASS phase=$Phase"
    } finally { Remove-M12BackendSyntheticRoot $state.Root }
}

function Get-M12RecoveryPositiveTrace {
    $state=New-M12BackendSyntheticState
    try {
        $first=Invoke-M12BackendSyntheticBoundary $state ('b'*64) 'm12-reset'
        $state.Ids.victoriametrics='e'*64
        Add-M12BackendMetricLedger $state 'm12-fixture-start' $state.Ids.victoriametrics
        $second=Invoke-M12BackendSyntheticBoundary $state ('c'*64) 'm12-fixture-start'
        Add-M12BackendMetricLedger $state 'm12-recovery-start' $state.Ids.victoriametrics
        $recovery=Invoke-M12BackendSyntheticRecoveryBoundary $state ('9'*64)
        $manifest=Get-GeordiCaptureGenerationManifest $state.Root
        $generations=@($manifest.captureGenerations.backend)
        $handoffs=@($manifest.captureHandoffs.Values | Where-Object { [string]$_.logicalService -ceq 'backend' })
        Assert-M12Backend ($generations.Count -eq 4 -and $handoffs.Count -eq 3 -and @($handoffs | Where-Object status -cne 'complete').Count -eq 0 -and
            $recovery.Result.OldContainerId -ceq $second.NewContainerId -and $recovery.Result.NewContainerId -ceq ('9'*64)) `
            'recovery event trace was not produced by the complete four-generation production-helper chain'
        return ,$recovery.Events
    } finally { Remove-M12BackendSyntheticRoot $state.Root }
}

function Assert-M12RecoveryRejected([string[]] $Events,[string] $Case) {
    $rejected=$false
    try { Assert-M12RecoveryEventTrace $Events } catch { $rejected=$true }
    Assert-M12Backend $rejected "invalid M12 recovery event trace was accepted: $Case"
}

function Test-M12RecoveryNegativeSealOrder {
    $base=Get-M12RecoveryPositiveTrace
    foreach($target in @('vm-stop','backend-outage-observed','lifecycle-state-verified')) {
        $events=[Collections.Generic.List[string]]::new();$events.AddRange([string[]]$base)
        $sealIndex=$events.IndexOf('old-follower-sealed');$targetIndex=$events.IndexOf($target)
        $events.RemoveAt($sealIndex);$events.Insert($targetIndex,'old-follower-sealed')
        Assert-M12RecoveryRejected $events.ToArray() "seal-before-$target"
    }
    Write-Output 'm12_recovery_negative=PASS cases=seal-before-vm-stop,outage-observed,lifecycle-verified'
}

function Test-M12RecoveryNegativeBackendQuery {
    $events=[Collections.Generic.List[string]]::new();$events.AddRange([string[]](Get-M12RecoveryPositiveTrace))
    $events.Insert(($events.IndexOf('old-follower-sealed')+1),'backend-api-query')
    Assert-M12RecoveryRejected $events.ToArray() 'backend-query-after-seal'
    Write-Output 'm12_recovery_negative=PASS case=backend-query-after-seal'
}

function Test-M12RecoveryNegativeProviderOrder {
    $base=Get-M12RecoveryPositiveTrace
    $events=[Collections.Generic.List[string]]::new();$events.AddRange([string[]]$base)
    $providerIndex=$events.IndexOf('provider-firing');$recreateIndex=$events.IndexOf('backend-recreate')
    $events.RemoveAt($recreateIndex);$events.Insert($providerIndex,'backend-recreate')
    Assert-M12RecoveryRejected $events.ToArray() 'backend-recreate-before-provider-firing'
    $base=Get-M12RecoveryPositiveTrace
    $events=[Collections.Generic.List[string]]::new();$events.AddRange([string[]]$base)
    $followerIndex=$events.IndexOf('new-follower');$readyIndex=$events.IndexOf('readiness')
    $events.RemoveAt($readyIndex);$events.Insert($followerIndex,'readiness')
    Assert-M12RecoveryRejected $events.ToArray() 'readiness-before-new-follower'
    Write-Output 'm12_recovery_negative=PASS cases=backend-recreate-before-provider-firing,readiness-before-new-follower'
}

function Test-M12BackendStaticContract {
    $files=@('lib/GeordiM12BackendReplacement.ps1','Test-GeordiM12BackendGenerations.ps1','verify-alert-scheduling.ps1','Capture-GeordiM19Generation.ps1','lib/GeordiPersistedMetricEvidence.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
    foreach($path in $files) {
        $tokens=$null;$errors=$null
        [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
        Assert-M12Backend ($errors.Count -eq 0) "PowerShell parser failed: $([IO.Path]::GetFileName($path))"
    }
    $transfer=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1') -Raw
    Assert-M12Backend ($transfer.Contains('ApplyM12BackendGeneration') -and $transfer.Contains('Invoke-GeordiM12BackendGenerationReplacement') -and
        $transfer.Contains('m12-fixture-start') -and $transfer -notmatch '(?i)down\s+-v') 'M12 transferred path lacks lifecycle/phase safety contract'
    Write-Output 'm12_backend_static_contract=PASS parser=true explicit_mode=true distinct_vm_phase=true'
}

function Test-M12TransferredProductionWiring {
    $path=Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-M12Backend ($errors.Count -eq 0) 'M12 production script did not parse for control-flow wiring verification'
    $top=@($ast.EndBlock.Statements)
    $transfer=@($top|Where-Object{$_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('Invoke-M12TransferredFixtureConsumer')})
    Assert-M12Backend ($transfer.Count -eq 1 -and $transfer[0].Extent.Text.Contains('$ApplyM12BackendGeneration') -and
        $transfer[0].Extent.Text.Contains('Invoke-M12TransferredFixtureConsumer') -and
        $transfer[0].Extent.Text.Contains('Invoke-M12TransferredFixturePreparation')) 'M11 transfer does not gate an explicit M12 backend-generation mode'
    $preparation=@($top|Where-Object{$_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Invoke-M12TransferredFixturePreparation'})
    Assert-M12Backend ($preparation.Count -eq 1) 'Transferred M12 fixture-preparation function is missing or ambiguous'
    $preparationText=$preparation[0].Extent.Text
    $orderedMarkers=@('Invoke-GeordiM12CollectorControlledReplacement',
        "'up','-d','--no-deps','--force-recreate','victoriametrics','m12-burn-demo'",'M12 initial backend generation')
    $previous=-1
    foreach($marker in $orderedMarkers){$position=$preparationText.IndexOf($marker,[StringComparison]::Ordinal);Assert-M12Backend ($position -gt $previous) "transferred fixture order missing: $marker";$previous=$position}
    Assert-M12Backend ($preparationText.Contains('-EvidencePhase m12-reset') -and
        $preparationText.Contains('Remove-GeordiM11DedicatedFixtureVolumes') -and $preparationText.Contains('-RequirePresent') -and
        $preparationText.Contains('Remove-GeordiM12DedicatedFixtureVolumes')) 'transferred M12 preparation lacks exact M11/M12 volume ownership checks'
    Assert-M12Backend ($preparationText.IndexOf('Invoke-GeordiM12BackendGenerationReplacement',[StringComparison]::Ordinal) -lt
        $preparationText.IndexOf('Remove-GeordiM11DedicatedFixtureVolumes',[StringComparison]::Ordinal)) `
        'M11 volumes are removed before the ready M12 backend generation takes ownership'
    $source=Get-Content -LiteralPath $path -Raw
    Assert-M12Backend ($source.IndexOf('-Phase m12-fixture-start',[StringComparison]::Ordinal) -lt
        $source.IndexOf('m12-scheduler-enablement',[StringComparison]::Ordinal) -and
        $source.IndexOf('-Phase m12-recovery-start',[StringComparison]::Ordinal) -lt
        $source.IndexOf('m12-provider-recovery',[StringComparison]::Ordinal)) 'M12 metric evidence phases are not published before their backend boundaries'
    Write-Output 'm12_transferred_production_wiring=PASS consumer_before_mutation=true exact_volumes=true collector_vm_backend_order=true scheduler_and_recovery_phases=true'
}

switch($Case) {
    'FirstPublication' { Test-M12ResetFirstPublication;break }
    'Reuse' { Test-M12ResetConsumerApplyReuse;break }
    'DirectOverwrite' { Test-M12ResetDirectOverwriteRejected;break }
    'ReuseIntegrity' { Test-M12ResetReuseIntegrity;break }
    'PartialMatrix' { Test-M12ResetPartialMatrix;break }
    'WrongInheritedVm' { Test-M12ResetWrongInheritedVm;break }
    'PublicationRace' { Test-M12ResetZeroNonemptyPublicationRace;break }
    'FixtureStartImmutability' { Test-M12OtherMetricPhaseImmutability 'm12-fixture-start';break }
    'RecoveryStartImmutability' { Test-M12OtherMetricPhaseImmutability 'm12-recovery-start';break }
    'RecoveryPositive' { $trace=Get-M12RecoveryPositiveTrace;Assert-M12RecoveryEventTrace $trace;Write-Output ('m12_recovery_boundary=PASS events=' + ($trace -join ','));break }
    'RecoveryNegativeSealOrder' { Test-M12RecoveryNegativeSealOrder;break }
    'RecoveryNegativeBackendQuery' { Test-M12RecoveryNegativeBackendQuery;break }
    'RecoveryNegativeProviderOrder' { Test-M12RecoveryNegativeProviderOrder;break }
    'SelfTest' {
        Test-M12ResetFirstPublication
        Test-M12ResetConsumerApplyReuse
        Test-M12ResetDirectOverwriteRejected
        Test-M12ResetReuseIntegrity
        Test-M12ResetPartialMatrix
        Test-M12ResetWrongInheritedVm
        Test-M12ResetZeroNonemptyPublicationRace
        Test-M12OtherMetricPhaseImmutability 'm12-fixture-start'
        Test-M12OtherMetricPhaseImmutability 'm12-recovery-start'
        Test-M12BackendStaticContract
        Test-M12BackendPositiveChain
        Test-M12BackendFailureCases
        Test-M12FixtureVolumeOwnership
        Test-M12BackendCommandScope
        Test-M12BackendMetricPhases
        Test-M12RecoveryNegativeSealOrder
        Test-M12RecoveryNegativeBackendQuery
        Test-M12RecoveryNegativeProviderOrder
        Test-M12TransferredProductionWiring
        Write-Output 'm12_backend_generation_selftest=PASS'
    }
}
