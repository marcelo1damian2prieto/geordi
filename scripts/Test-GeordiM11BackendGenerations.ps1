[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM11BackendReplacement.ps1')

function Assert-M11Backend([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M11 backend generation regression failed: $Message" }
}

function New-M11BackendRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m11-backend-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $started = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
    $manifest = [ordered]@{ version=2;root=$root;runId='synthetic-m11';startedUtc=$started;captureStartedUtc=$started
        captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};generationCaptureEvents=@{};additionalSources=@();captures=@() }
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
    return $root
}

function Remove-M11BackendRoot([string] $Root) {
    if (!(Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $Root -Recurse -Force
}

function Read-M11BackendManifest([string] $Root) {
    return [IO.File]::ReadAllText((Join-Path $Root 'manifest.json')) | ConvertFrom-Json -AsHashtable
}

function New-M11BackendIdentity([string] $Id,[string] $Service='backend',[string] $Directory=(Get-Location).Path) {
    return [pscustomobject]@{ Id=$Id;Project='geordi';Service=$Service;WorkingDirectory=$Directory
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true }
}

function New-M11BackendHarness {
    $state = [pscustomobject]@{ Pid=61000;Alive=@{};Starts=[Collections.Generic.List[object]]::new();Readiness=[Collections.Generic.List[object]]::new()
        Root=$null;WrongFollower=$false;FailNewCleanup=$false;FailStopPid=$null;Events=[Collections.Generic.List[string]]::new()
        Start=$null;Test=$null;Stop=$null;Wait=$null }
    $state.Start = {
        param($stdout,$stderr,$processRecord,$arguments,$target)
        $state.Pid++
        $started = [DateTimeOffset]::UtcNow.ToString('o')
        $recordContainer=if($state.WrongFollower -and [string]$target.containerId -cne ('a'*64)){'f'*64}else{[string]$target.containerId}
        $record = [ordered]@{ id=$state.Pid;name='synthetic-m11-follower';startUtc=$started;containerId=$recordContainer
            service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc }
        [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stdout,"synthetic-$($target.containerId)`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
        $state.Alive[[string]$state.Pid] = $true
        $state.Starts.Add([pscustomobject]@{Pid=$state.Pid;Target=$target;ProcessRecordPath=$processRecord})
        if($state.FailNewCleanup -and [string]$target.containerId -cne ('a'*64)){$state.FailStopPid=$state.Pid}
        $state.Events.Add('follower-started')
        return [pscustomobject]@{ id=$state.Pid;name='synthetic-m11-follower';startUtc=$started }
    }.GetNewClosure()
    $state.Test = { param($record) return [bool]$state.Alive[[string]$record.id] }.GetNewClosure()
    $state.Stop = {
        param($record)
        if($state.FailNewCleanup -and [int]$record.id -eq [int]$state.FailStopPid){throw [InvalidOperationException]::new('SYNTHETIC_CLEANUP_PRIVATE_DETAIL')}
        $state.Alive[[string]$record.id] = $false
    }.GetNewClosure()
    $state.Wait = {
        param($target)
        if (!$state.Alive.ContainsKey([string]$state.Pid) -or !$state.Alive[[string]$state.Pid]) { throw 'Follower was not active during readiness.' }
        if ([string]$target.service -cne 'backend') { throw 'Readiness was requested for a non-backend target.' }
        $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $state.Root
        $active=@($manifest.captureGenerations.backend|Where-Object{$_.terminalStatus -ceq 'capturing' -and $_.containerId -ceq [string]$target.containerId})
        if($active.Count -ne 1 -or [int]$active[0].followerProcess.id -ne [int]$state.Pid){throw 'Readiness preceded shared exact follower publication.'}
        $disk=[IO.File]::ReadAllText([string]$state.Starts[$state.Starts.Count-1].ProcessRecordPath)|ConvertFrom-Json -AsHashtable
        if([string]$disk.containerId -cne [string]$target.containerId){throw 'Readiness observed a mismatched persisted follower binding.'}
        $state.Events.Add('follower-binding-validated')
        $state.Readiness.Add([string]$target.containerId)
        $state.Events.Add('readiness')
    }.GetNewClosure()
    return $state
}

function Start-M11BackendGeneration([string] $Root,[string] $Id,[object] $Harness) {
    $Harness.Root=$Root
    $generation = Start-GeordiCaptureGeneration -CaptureRoot $Root -Service backend -ContainerIdentity (New-M11BackendIdentity $Id) `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' `
        -WorkingDirectory (Get-Location).Path -StartFollower $Harness.Start
    return [string]$generation
}

function Add-M11ResetMetricSource([string] $Root,[string] $SourceContainerId) {
    $directory = Join-Path $Root 'victoriametrics-generations'
    [void][IO.Directory]::CreateDirectory($directory)
    $snapshotPath = Join-Path $directory 'm11-reset.jsonl'
    $ledgerPath = Join-Path $directory 'm11-reset.snapshot.json'
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $sample = @{ metric=@{ '__name__'='geordi_security_authentication_attempts';'service.name'='geordi-backend';'geordi.telemetry.origin'='platform' }
        timestamps=@($timestamp);values=@('1') } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($snapshotPath,$sample,[Text.UTF8Encoding]::new($false))
    $bytes = [long](Get-Item -LiteralPath $snapshotPath).Length
    $start = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    $end = [DateTimeOffset]::UtcNow.ToString('o')
    $ledger = [ordered]@{ intervalStartUtc=$start;intervalEndUtc=$end;source='victoriametrics-export';complete=$true;runStartBound=$true
        series=1;samples=1;bytes=$bytes;sourceService='victoriametrics';sourceContainerId=$SourceContainerId
        snapshotSha256=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    [IO.File]::WriteAllText($ledgerPath,(ConvertTo-Json -InputObject $ledger -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    $manifest = Read-M11BackendManifest $Root
    $manifest.additionalSources = @(@{ channel='victoriametrics';control='geordi_security_authentication_attempts';captures=@($snapshotPath,$ledgerPath) })
    Write-GeordiM19ManifestAtomic -Path (Join-Path $Root 'manifest.json') -Manifest $manifest
}

function Invoke-M11SyntheticBoundary([string] $Root,[object] $State,[string] $Reason,[scriptblock] $Replace,[switch] $RequireVmBoundary) {
    $replacement = {
        param($OldBackend,$OldVm)
        $manifest = Read-M11BackendManifest $Root
        $oldRecord = Get-GeordiCaptureGenerationRecord $manifest backend ([string]$State.ActiveGeneration)
        if (!$oldRecord -or [string]$oldRecord.terminalStatus -cne 'sealed') { throw 'M11 mutation ran before old-generation sealing.' }
        $null = & $Replace
    }.GetNewClosure()
    $resolver = {
        param([string]$Service)
        if ($Service -ceq 'backend') { return $State.Backend }
        if ($Service -ceq 'victoriametrics') { return $State.VictoriaMetrics }
        throw 'Unexpected M11 service identity request.'
    }.GetNewClosure()
    $result = Invoke-GeordiM11BackendGenerationReplacement -CaptureRoot $Root -RepositoryRoot (Get-Location).Path `
        -Replace $replacement -ResolveContainerIdentity $resolver -WaitReadiness $State.Harness.Wait -Reason $Reason `
        -RequireVictoriaMetricsReplacement:$RequireVmBoundary `
        -StartFollower $State.Harness.Start -TestProcessIdentity $State.Harness.Test -StopProcess $State.Harness.Stop `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
    $State.ActiveGeneration = [string]$result.NewGenerationId
    return $result
}

function Test-M11PositiveBoundaryChain {
    $root = New-M11BackendRoot
    try {
        $harness = New-M11BackendHarness
        $state = [pscustomobject]@{ Harness=$harness;Backend=(New-M11BackendIdentity ('a'*64));VictoriaMetrics=(New-M11BackendIdentity ('1'*64) 'victoriametrics')
            ActiveGeneration='';DowntimeReceiverChanged=$false;Commands=[Collections.Generic.List[object]]::new();VolumeRemovals=[Collections.Generic.List[string]]::new() }
        Add-M11ResetMetricSource $root ([string]$state.VictoriaMetrics.Id)
        $state.ActiveGeneration = Start-M11BackendGeneration $root ([string]$state.Backend.Id) $harness
        $manifest = Read-M11BackendManifest $root
        $oldRecord = Get-GeordiCaptureGenerationRecord $manifest backend $state.ActiveGeneration
        $oldCaptureHash = (Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash

        $initialReset = {
            $state.Commands.Add(@('rm','-sf','backend','victoriametrics'))
            $state.VolumeRemovals.Add('geordi_m11-alert-lifecycle-data');$state.VolumeRemovals.Add('geordi_m11-victoriametrics-data')
            $state.Commands.Add(@('up','-d','--no-deps','--force-recreate','victoriametrics','backend'))
            $state.Backend = New-M11BackendIdentity ('b'*64)
            $state.VictoriaMetrics = New-M11BackendIdentity ('2'*64) 'victoriametrics'
            Write-Output 'simulated-compose-stdout'
        }.GetNewClosure()
        $first = Invoke-M11SyntheticBoundary $root $state 'm11-initial-joint-reset' $initialReset -RequireVmBoundary
        Assert-M11Backend ($first.OldContainerId -ceq ('a'*64) -and $first.NewContainerId -ceq ('b'*64)) 'initial joint reset container IDs changed unexpectedly'
        Assert-M11Backend ($first.OldVictoriaMetricsContainerId -ceq ('1'*64) -and $first.NewVictoriaMetricsContainerId -ceq ('2'*64)) 'VM reset did not prove VM_OLD -> VM_NEW'
        Assert-M11Backend ((Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash -ceq $oldCaptureHash) 'initial reset mutated sealed history'

        $downtimeReplacement = {
            $state.Commands.Add(@('rm','-sf','backend'))
            $state.DowntimeReceiverChanged = $true
            $state.Commands.Add(@('up','-d','--no-deps','backend'))
            $state.Backend = New-M11BackendIdentity ('c'*64)
        }.GetNewClosure()
        $second = Invoke-M11SyntheticBoundary $root $state 'm11-pending-delivery-downtime' $downtimeReplacement
        Assert-M11Backend ($state.DowntimeReceiverChanged -and $second.OldContainerId -ceq ('b'*64) -and $second.NewContainerId -ceq ('c'*64)) `
            'downtime boundary did not retain the intended outage/recovery order'

        $applicationRestart = {
            $state.Commands.Add(@('rm','-sf','backend'))
            $state.Commands.Add(@('up','-d','--no-deps','--force-recreate','backend'))
            $state.Backend = New-M11BackendIdentity ('d'*64)
        }.GetNewClosure()
        $third = Invoke-M11SyntheticBoundary $root $state 'm11-terminal-delivery-application-restart' $applicationRestart
        Assert-M11Backend ($third.OldContainerId -ceq ('c'*64) -and $third.NewContainerId -ceq ('d'*64)) 'application restart did not use a distinct backend ID'
        Assert-M11Backend ($harness.Starts.Count -eq 4 -and $harness.Readiness.Count -eq 3) 'follower or readiness cardinality is incorrect'
        $bindingIndices=@(for($i=0;$i -lt $harness.Events.Count;$i++){if($harness.Events[$i] -ceq 'follower-binding-validated'){$i}})
        $readinessIndices=@(for($i=0;$i -lt $harness.Events.Count;$i++){if($harness.Events[$i] -ceq 'readiness'){$i}})
        Assert-M11Backend ($bindingIndices.Count -eq 3 -and $readinessIndices.Count -eq 3 -and
            @((0..2|Where-Object{$bindingIndices[$_] -ge $readinessIndices[$_]})).Count -eq 0) `
            'M11 readiness did not follow shared exact follower validation at every boundary'
        Assert-M11Backend (@($harness.Readiness | Select-Object -Unique).Count -eq 3 -and $harness.Readiness -contains ('d'*64)) `
            'readiness was not proven while exact new-ID followers were active'
        Assert-M11Backend ($state.VolumeRemovals.Count -eq 2 -and ($state.VolumeRemovals -join ',') -ceq 'geordi_m11-alert-lifecycle-data,geordi_m11-victoriametrics-data') `
            'only the initial joint reset may remove the two M11 fixture volumes'
        Assert-M11Backend ($state.Commands.Count -eq 6 -and @($state.Commands | Where-Object { $_ -contains 'otel-collector' }).Count -eq 0) `
            'replacement commands escaped the owned backend/VM service scope'

        $manifest = Read-M11BackendManifest $root
        $backendRecords = @($manifest.captureGenerations.backend)
        $handoffs = @($manifest.captureHandoffs.Values | Where-Object logicalService -ceq 'backend')
        Assert-M11Backend ($backendRecords.Count -eq 4 -and @($backendRecords | Where-Object terminalStatus -ceq 'sealed').Count -eq 3 -and
            @($backendRecords | Where-Object terminalStatus -ceq 'capturing').Count -eq 1) 'generation chain did not retain three sealed generations and one active generation'
        Assert-M11Backend ($handoffs.Count -eq 3 -and @($handoffs | Where-Object status -ceq 'complete').Count -eq 3) 'not all handoffs completed'
        foreach ($record in $backendRecords) {
            $follower = [IO.File]::ReadAllText([string]$record.processRecordPath) | ConvertFrom-Json -AsHashtable
            Assert-M11Backend ([string]$follower.containerId -ceq [string]$record.containerId) 'follower does not bind exact generation container'
        }
        Assert-M11Backend ((Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash -ceq $oldCaptureHash) 'historical capture changed after chain completion'
        $finalRecord = Get-GeordiActiveCaptureGenerationRecord -Manifest $manifest -Service backend
        Assert-M11Backend ([string]$finalRecord.containerId -ceq ('d'*64)) 'final backend generation is not active on the new container'
        Assert-M11Backend ((@($manifest.captureHandoffs.Values | ForEach-Object { $_.gapDurationMilliseconds } | Where-Object { $_ -lt 0 }).Count -eq 0)) `
            'handoff chronology contains a negative interval'

        $composeArgs = @(Get-GeordiM11ControlledReplacementComposeArguments -RepositoryRoot (Get-Location).Path)
        $composeFiles = [Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $composeArgs.Count; $index++) {
            if ($composeArgs[$index] -ceq '--file') { $index++;$composeFiles.Add([IO.Path]::GetFileName($composeArgs[$index])) }
        }
        Assert-M11Backend (($composeFiles -join ',') -ceq 'compose.yaml,compose.m19.yaml,compose.m11.yaml,compose.m11-victoriametrics-isolation.yaml') `
            'controlled M11 replacement omitted or added a Compose file'
        Assert-M11Backend ($composeArgs -notcontains 'down' -and $composeArgs -notcontains 'prune' -and $composeArgs -notcontains '-v') `
            'controlled M11 Compose argv contains broad cleanup or volume deletion'
        Write-Output 'm11_backend_positive_chain=PASS boundaries=3 vm_old_new_distinct=true exact_followers=true old_evidence_immutable=true readiness_after_follower=true'
        Write-Output 'm11_backend_command_scope=PASS overlay_scoped=true services=backend,victoriametrics protected_volumes=not_targeted'
    } finally { Remove-M11BackendRoot $root }
}

function Test-M11FailureCases {
    $cases = @('compose-failure','missing-new-identity','same-new-id','wrong-owner','readiness-failure','readiness-cleanup-fails',
        'wrong-new-follower','follower-failure','old-follower-mismatch','vm-identity-mismatch')
    foreach ($case in $cases) {
        $root = New-M11BackendRoot
        try {
            $harness = New-M11BackendHarness
            $state = [pscustomobject]@{ Harness=$harness;Backend=(New-M11BackendIdentity ('a'*64));VictoriaMetrics=(New-M11BackendIdentity ('1'*64) 'victoriametrics')
                ActiveGeneration='';Mutation=$false;Failure=$case;Current=$null }
            if ($case -eq 'vm-identity-mismatch') { Add-M11ResetMetricSource $root ('2'*64) }
            $state.ActiveGeneration = Start-M11BackendGeneration $root ([string]$state.Backend.Id) $harness
            if($case -eq 'wrong-new-follower'){$harness.WrongFollower=$true}
            if($case -eq 'readiness-cleanup-fails'){$harness.FailNewCleanup=$true;$harness.Wait={param($target)throw 'Synthetic readiness failure.'}.GetNewClosure()}
            $oldRecord = Get-GeordiCaptureGenerationRecord (Read-M11BackendManifest $root) backend $state.ActiveGeneration
            $oldHash = (Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash
            if ($case -eq 'old-follower-mismatch') {
                $process = [IO.File]::ReadAllText([string]$oldRecord.processRecordPath) | ConvertFrom-Json -AsHashtable
                $process.containerId = 'f'*64
                [IO.File]::WriteAllText([string]$oldRecord.processRecordPath,(ConvertTo-Json -InputObject $process -Compress),[Text.UTF8Encoding]::new($false))
            }
            if ($case -eq 'follower-failure') { $harness.Start = { throw 'Synthetic follower failure.' }.GetNewClosure() }
            if ($case -eq 'readiness-failure') { $harness.Wait = { param($target) throw 'Synthetic readiness failure.' }.GetNewClosure() }
            $replace = {
                $state.Mutation = $true
                if ($case -eq 'compose-failure') { throw 'Synthetic Compose failure.' }
                if ($case -eq 'vm-identity-mismatch') { $state.VictoriaMetrics = New-M11BackendIdentity ('1'*64) 'victoriametrics' }
                $newId = switch ($case) {
                    'same-new-id' { 'a'*64 }
                    default { 'b'*64 }
                }
                $state.Backend = if($case -eq 'wrong-owner'){New-M11BackendIdentity $newId 'backend' ([IO.Path]::GetTempPath())}else{New-M11BackendIdentity $newId}
                if ($case -eq 'missing-new-identity') { $state.Backend = $null }
            }.GetNewClosure()
            $replacement = {
                $manifest = Read-M11BackendManifest $root
                if ([string](Get-GeordiCaptureGenerationRecord $manifest backend $state.ActiveGeneration).terminalStatus -cne 'sealed') {
                    throw 'Mutation preceded old seal.'
                }
                $null = & $replace
            }.GetNewClosure()
            $resolver = { param([string]$service) if($service -ceq 'backend'){return $state.Backend};if($service -ceq 'victoriametrics'){return $state.VictoriaMetrics};throw 'Unexpected service.' }.GetNewClosure()
            $wait = if ($case -eq 'readiness-failure') {$harness.Wait} else {$harness.Wait}
            $expectedVm = if($case -eq 'vm-identity-mismatch'){('1'*64)}else{$null}
            $failed = $false;$failureRecord=$null
            try {
                Invoke-GeordiM11BackendGenerationReplacement -CaptureRoot $root -RepositoryRoot (Get-Location).Path -Replace $replacement `
                    -ResolveContainerIdentity $resolver -WaitReadiness $wait -Reason ('negative-' + $case) -RequireVictoriaMetricsReplacement:($case -eq 'vm-identity-mismatch') `
                    -StartFollower $harness.Start -TestProcessIdentity $harness.Test -StopProcess $harness.Stop `
                    -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' | Out-Null
            } catch { $failed = $true;$failureRecord=$_ }
            Assert-M11Backend $failed "$case unexpectedly succeeded"
            Assert-M11Backend ((Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash -ceq $oldHash) "$case changed historical capture"
            $manifest = Read-M11BackendManifest $root
            if ($case -eq 'vm-identity-mismatch') {
                Assert-M11Backend (!$state.Mutation -and @($manifest.captureHandoffs.Values).Count -eq 0) 'VM snapshot mismatch mutated before preflight rejection'
            } elseif ($case -eq 'old-follower-mismatch') {
                Assert-M11Backend (!$state.Mutation -and @($manifest.captureHandoffs.Values | Where-Object status -ceq 'incomplete-old-seal').Count -eq 1) `
                    'old follower mismatch did not stop at the sealing boundary'
            } else {
                Assert-M11Backend ($state.Mutation -and @($manifest.captureHandoffs.Values | Where-Object { [string]$_.status -like 'incomplete-*' }).Count -eq 1) `
                    "$case did not preserve an incomplete handoff after mutation"
            }
            if ($case -in @('readiness-failure','readiness-cleanup-fails')) {
                Assert-M11Backend ($failureRecord.Exception.Message -ceq 'Synthetic readiness failure.') "$case did not preserve the original readiness error"
                if($case -eq 'readiness-failure'){
                    Assert-M11Backend (@($harness.Alive.Values | Where-Object { $_ -eq $true }).Count -eq 0) 'new follower remained active after readiness failure'
                }else{
                    Assert-M11Backend (@($harness.Alive.Values | Where-Object { $_ -eq $true }).Count -eq 1) 'cleanup-failure case did not retain exactly the un-stopped new follower'
                }
            }
            if($case -eq 'readiness-cleanup-fails'){
                Assert-M11Backend ([string]$failureRecord.Exception.Data['FollowerCleanupFailure'] -ceq 'System.InvalidOperationException' -and
                    !$failureRecord.Exception.Message.Contains('SYNTHETIC_CLEANUP_PRIVATE_DETAIL')) 'cleanup failure masked readiness or exposed its message'
            }
            if($case -eq 'wrong-new-follower'){
                Assert-M11Backend ($harness.Readiness.Count -eq 0 -and @($manifest.captureGenerations.backend|Where-Object terminalStatus -ceq 'incomplete-start').Count -eq 1) `
                    'wrong new follower reached readiness or became active'
            }
        } finally { Remove-M11BackendRoot $root }
    }
    Write-Output ('m11_backend_fail_closed=PASS cases=' + $cases.Count + ' history_immutable=true incomplete_handoffs_recorded=true')
}

function Test-M11DedicatedVolumeRemoval {
    $expected = [ordered]@{
        'm11-alert-lifecycle-data' = 'geordi_m11-alert-lifecycle-data'
        'm11-victoriametrics-data' = 'geordi_m11-victoriametrics-data'
    }
    $inventory = @{
        'geordi_m11-alert-lifecycle-data' = [pscustomobject]@{ Name='geordi_m11-alert-lifecycle-data';Labels=@{
            'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-alert-lifecycle-data' } }
        'geordi_m11-victoriametrics-data' = [pscustomobject]@{ Name='geordi_m11-victoriametrics-data';Labels=@{
            'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-victoriametrics-data' } }
    }
    $inspected = [Collections.Generic.List[string]]::new()
    $removed = [Collections.Generic.List[string]]::new()
    $inspect = { param([string]$Name) $inspected.Add($Name); if ($inventory.ContainsKey($Name)) { return $inventory[$Name] } }.GetNewClosure()
    $remove = { param([string]$Name) $removed.Add($Name) }.GetNewClosure()

    Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes $expected -InspectVolume $inspect -RemoveVolume $remove
    Assert-M11Backend (($inspected -join ',') -ceq 'geordi_m11-alert-lifecycle-data,geordi_m11-victoriametrics-data' -and
        ($removed -join ',') -ceq 'geordi_m11-alert-lifecycle-data,geordi_m11-victoriametrics-data') `
        'dedicated-volume removal did not inspect and remove exactly the two owned M11 volumes'

    $dockerCalls = [Collections.Generic.List[string]]::new()
    $dockerSuccess = {
        param([string[]] $Arguments)
        $dockerCalls.Add(($Arguments -join ' '))
        if (($Arguments -join ' ') -ceq 'volume ls --format {{.Name}}') {
            return [pscustomobject]@{ ExitCode=0;Output=@('geordi_m11-alert-lifecycle-data','geordi_m11-victoriametrics-data') }
        }
        if ($Arguments.Count -eq 3 -and $Arguments[0] -ceq 'volume' -and $Arguments[1] -ceq 'inspect') {
            $logical = if ($Arguments[2] -ceq 'geordi_m11-alert-lifecycle-data') { 'm11-alert-lifecycle-data' } else { 'm11-victoriametrics-data' }
            $json = @([ordered]@{ Name=$Arguments[2];Labels=@{ 'com.docker.compose.project'='geordi';'com.docker.compose.volume'=$logical } }) | ConvertTo-Json -Compress
            return [pscustomobject]@{ ExitCode=0;Output=@($json) }
        }
        throw 'unexpected Docker command in success regression'
    }.GetNewClosure()
    $inspectedVolume = Get-GeordiM11DockerVolumeInspection -Name 'geordi_m11-alert-lifecycle-data' -DockerCommand $dockerSuccess
    Assert-M11Backend ($inspectedVolume.Name -ceq 'geordi_m11-alert-lifecycle-data' -and
        ($dockerCalls -join '|') -ceq 'volume ls --format {{.Name}}|volume inspect geordi_m11-alert-lifecycle-data') `
        'successful Docker inventory and exact inspection did not bind the M11 volume identity'

    $dockerCalls.Clear()
    $dockerMissing = {
        param([string[]] $Arguments)
        $dockerCalls.Add(($Arguments -join ' '))
        return [pscustomobject]@{ ExitCode=0;Output=@('unrelated-volume') }
    }.GetNewClosure()
    $absentVolume = Get-GeordiM11DockerVolumeInspection -Name 'geordi_m11-alert-lifecycle-data' -DockerCommand $dockerMissing
    Assert-M11Backend ($null -eq $absentVolume -and $dockerCalls.Count -eq 1) 'successful inventory did not prove target volume absence without inspection'

    $removed.Clear();$inspected.Clear()
    $inventory.Clear()
    Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes $expected -InspectVolume $inspect -RemoveVolume $remove
    Assert-M11Backend ($inspected.Count -eq 2 -and $removed.Count -eq 0) 'missing dedicated M11 volumes were not treated as already absent'

    $removed.Clear();$inspected.Clear();$requiredMissing=$false
    try { Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes $expected -InspectVolume $inspect -RemoveVolume $remove -RequirePresent }
    catch { $requiredMissing=$_.Exception.Message -match 'disappeared before transfer cleanup' }
    Assert-M11Backend ($requiredMissing -and $removed.Count -eq 0 -and $inspected.Count -eq 1) `
        'transfer cleanup did not fail closed when a previously validated M11 volume disappeared'

    $removed.Clear();$inspected.Clear()
    $inventory['geordi_m11-alert-lifecycle-data'] = [pscustomobject]@{ Name='geordi_m11-alert-lifecycle-data';Labels=@{
        'com.docker.compose.project'='other';'com.docker.compose.volume'='m11-alert-lifecycle-data' } }
    $rejected = $false
    try { Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes $expected -InspectVolume $inspect -RemoveVolume $remove }
    catch { $rejected = $true }
    Assert-M11Backend ($rejected -and $removed.Count -eq 0) 'foreign-owned volume was not rejected before removal'

    $removed.Clear()
    $dockerCommand = {
        param([string[]] $Arguments)
        if (($Arguments -join ' ') -ceq 'volume ls --format {{.Name}}') {
            return [pscustomobject]@{ ExitCode=1;Output=@() }
        }
        throw 'unexpected Docker command in inventory-failure regression'
    }
    $inventoryFailed = {
        param([string]$Name)
        Get-GeordiM11DockerVolumeInspection -Name $Name -DockerCommand $dockerCommand
    }.GetNewClosure()
    $rejected = $false
    try { Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes $expected -InspectVolume $inventoryFailed -RemoveVolume $remove }
    catch { $rejected = $_.Exception.Message -match 'inventory Docker volumes' }
    Assert-M11Backend ($rejected -and $removed.Count -eq 0) 'nonzero Docker inventory was accepted as absence or reached removal'

    $extra = [ordered]@{} + $expected
    $extra['geordi_m19-alert-lifecycle-data'] = 'geordi_m19-alert-lifecycle-data'
    $rejected = $false
    try { Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes $extra -InspectVolume $inspect -RemoveVolume $remove }
    catch { $rejected = $true }
    Assert-M11Backend ($rejected -and $removed.Count -eq 0) 'protected M19 volume added to the removal allowlist was not rejected'

    Write-Output 'm11_backend_dedicated_volume_removal=PASS exact_allowlist=true inventory_fail_closed=true transfer_volume_presence_required=true foreign_owner_rejected=true protected_volume_rejected=true'
}

function Test-M11ProductionWiring {
    $path = Join-Path $PSScriptRoot 'verify-notification-delivery.ps1'
    $tokens = $null;$errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-M11Backend ($errors.Count -eq 0) 'authoritative M11 script does not parse'
    $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-M11BackendGenerationReplacement' },$true))
    $sharedCalls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-GeordiM11BackendGenerationReplacement' },$true))
    Assert-M11Backend ($calls.Count -eq 3 -and $sharedCalls.Count -eq 1) 'M11 production script does not route exactly three boundaries through its shared lifecycle wrapper'
    $source = [IO.File]::ReadAllText($path)
    foreach ($reason in @('m11-initial-joint-reset','m11-pending-delivery-downtime','m11-terminal-delivery-application-restart')) {
        Assert-M11Backend ($source.Contains($reason,[StringComparison]::Ordinal)) "production stage contract is missing: $reason"
    }
    Assert-M11Backend ($source -match "-Phase m11-reset -Services backend,victoriametrics -SkipLogSnapshot" -and
        $source -match "-Phase m11-final -Services backend,victoriametrics -SkipLogSnapshot") 'M11 VM snapshots or log ownership changed'
    Assert-M11Backend ($source -notmatch 'docker compose\s+@(.*?)\s+(?:stop|start|restart)\s+backend') 'raw same-container backend lifecycle operation remains'
    Assert-M11Backend ($source.Contains('Get-GeordiM11ControlledReplacementComposeArguments',[StringComparison]::Ordinal)) 'production M11 replacement does not use the isolation overlay argument builder'
    $resetCaptureAt = $source.IndexOf("-Phase m11-reset -Services backend,victoriametrics -SkipLogSnapshot",[StringComparison]::Ordinal)
    $resetHandoffAt = $source.IndexOf("-Reason 'm11-initial-joint-reset'",[StringComparison]::Ordinal)
    Assert-M11Backend ($resetCaptureAt -ge 0 -and $resetHandoffAt -gt $resetCaptureAt -and
        $source.Contains('-RequireVictoriaMetricsReplacement',[StringComparison]::Ordinal)) 'm11-reset evidence is not captured/bound before the joint reset handoff'
    foreach ($operation in @("'rm', '-sf', 'backend', 'victoriametrics'", "'up', '-d', '--no-deps', '--force-recreate', 'victoriametrics', 'backend'",
            "'rm', '-sf', 'backend'", "'up', '-d', '--no-deps', 'backend'", "'up', '-d', '--no-deps', '--force-recreate', 'backend'")) {
        Assert-M11Backend ($source.Contains($operation,[StringComparison]::Ordinal)) "production replacement operation is missing: $operation"
    }
    $cleanupStart = $source.IndexOf('function Remove-M11Fixture(',[StringComparison]::Ordinal)
    $sealAt = $source.IndexOf('Seal-M11ActiveBackendGeneration $Root $CaptureRoot',$cleanupStart,[StringComparison]::Ordinal)
    $cleanupRmAt = $source.IndexOf("@('rm', '-sf', 'backend', 'victoriametrics')",$cleanupStart,[StringComparison]::Ordinal)
    Assert-M11Backend ($cleanupStart -ge 0 -and $sealAt -gt $cleanupStart -and $cleanupRmAt -gt $sealAt) `
        'standalone cleanup removes the backend before sealing its active generation'
    Assert-M11Backend ($source.Contains('geordi_m11-alert-lifecycle-data',[StringComparison]::Ordinal) -and
        $source.Contains('geordi_m11-victoriametrics-data',[StringComparison]::Ordinal) -and
        !$source.Contains('docker volume rm geordi_m19-alert-lifecycle-data',[StringComparison]::Ordinal) -and
        !$source.Contains('docker volume rm geordi_m19-victoriametrics-data',[StringComparison]::Ordinal)) 'fixture cleanup target is not restricted to dedicated M11 volumes'
    Assert-M11Backend ($source -match 'function Remove-M11FixtureVolumes\(\[System\.Collections\.IDictionary\] \$Expected\)' -and
        $source.Contains('Remove-GeordiM11DedicatedFixtureVolumes',[StringComparison]::Ordinal) -and
        $source.Contains('Get-GeordiM11DockerVolumeInspection',[StringComparison]::Ordinal)) 'production volume cleanup does not pass its map through the tested allowlisted helper and fail-closed inventory adapter'
    Write-Output 'm11_backend_production_wiring=PASS three_shared_handoffs=true raw_same_id_restart=false vm_snapshot_ledger_retained=true'
}

if (!$SelfTest) { throw 'Pass -SelfTest to run the synthetic M11 backend generation regression.' }
Test-M11PositiveBoundaryChain
Test-M11FailureCases
Test-M11DedicatedVolumeRemoval
Test-M11ProductionWiring
