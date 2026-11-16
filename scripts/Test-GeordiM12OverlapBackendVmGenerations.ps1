[CmdletBinding()]
param([ValidateSet('SelfTest','Commands','Entry','Volumes','Evidence','Backend','Sequence','CrossFailure')][string]$Case='SelfTest')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM12OverlapGenerations.ps1')
function Assert-Overlap([bool]$Ok,[string]$Message){if(!$Ok){throw "M12 overlap generation self-test failed: $Message"}}
function Remove-OverlapRoot([string]$Path){if(Test-Path -LiteralPath $Path){Get-ChildItem -LiteralPath $Path -Recurse -File -Force|ForEach-Object{$_.IsReadOnly=$false};Remove-Item -LiteralPath $Path -Recurse -Force}}
function New-OverlapState {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m12-overlap-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
    $started=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o')
    $m=[ordered]@{version=2;root=$root;runId='synthetic-overlap';startedUtc=$started;captureStartedUtc=$started;captureGenerations=@{};captureHandoffs=@{};
        generationCaptures=@{backend=@();otel=@();collector=@()};additionalSources=@(@{channel='victoriametrics';control='geordi_security_authentication_attempts_total';captures=@()});captures=@();persistedMetricEvidenceBytes=0}
    $manifestPath=Join-Path $root 'manifest.json';[IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $m -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
    $volumes=@{}
    foreach($v in @(@('geordi_m12-alert-lifecycle-data','m12-alert-lifecycle-data'),@('geordi_m12-victoriametrics-data','m12-victoriametrics-data'),@('geordi_m19-alert-lifecycle-data','m19-alert-lifecycle-data'),@('geordi_m19-victoriametrics-data','m19-victoriametrics-data'))){
        $volumes[$v[0]]=[pscustomobject]@{Name=$v[0];Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'=$v[1]}}
    }
    $s=[pscustomobject]@{Root=$root;ManifestPath=$manifestPath;Repo=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot));Ids=@{backend=('a'*64);'otel-collector'=('b'*64);victoriametrics=('c'*64)};Pid=88000;Alive=@{};Volumes=$volumes;Events=[Collections.Generic.List[string]]::new();CurrentFollowerContainerId=$null;Fault='';ReplacementInvoked=$false;ReadinessCount=0}
    try{foreach($service in @('backend','otel-collector')){[void](Start-OverlapGeneration $s $service)};return $s}catch{Remove-OverlapRoot $root;throw}
}
function Get-OverlapIdentity($s,[string]$service){[pscustomobject]@{Id=[string]$s.Ids[$service];Project='geordi';Service=$service;WorkingDirectory=$s.Repo;CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}}
function Start-OverlapGeneration($s,[string]$service,[string]$handoff=''){
    $start={param($out,$err,$record,$args,$target)$s.Pid++;$now=[DateTimeOffset]::UtcNow.ToString('o');
        [IO.File]::WriteAllText($out,"$($target.service)-$($target.containerId)`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($err,'',[Text.UTF8Encoding]::new($false));
        [IO.File]::WriteAllText($record,(ConvertTo-Json -Compress -InputObject @{id=$s.Pid;name='synthetic-follower';startUtc=$now;containerId=$target.containerId;service=$target.service;project=$target.project;createdUtc=$target.createdUtc}),[Text.UTF8Encoding]::new($false));
        $s.Alive[[string]$s.Pid]=$true;$s.CurrentFollowerContainerId=[string]$target.containerId;return [pscustomobject]@{id=$s.Pid;name='synthetic-follower';startUtc=$now}}.GetNewClosure()
    Start-GeordiCaptureGeneration -CaptureRoot $s.Root -Service $service -ContainerIdentity (Get-OverlapIdentity $s $service) -DockerPath 'docker' -PowerShellPath 'pwsh' -WorkerPath 'worker' -WorkingDirectory $s.Repo -HandoffId $handoff -StartFollower $start
}
function New-OverlapAdapters($s,[string]$service){
    $resolve={param($wanted)
        if($service -ceq 'backend' -and $s.Fault -ceq 'missing-new-container' -and $s.ReplacementInvoked){return @()}
        $identity=Get-OverlapIdentity $s $wanted
        if($service -ceq 'backend' -and $s.Fault -ceq 'wrong-ownership' -and $s.ReplacementInvoked){$identity.WorkingDirectory=Join-Path $s.Repo 'other'}
        return $identity
    }.GetNewClosure();$alive={param($p)[bool]$s.Alive[[string]$p.id]}.GetNewClosure()
    $stop={param($p)
        if($service -ceq 'backend' -and $s.Fault -ceq 'seal-failure'){throw 'SYNTHETIC_SEAL_FAILURE'}
        $s.Alive[[string]$p.id]=$false;$null=$s.Events.Add("seal:$service")
    }.GetNewClosure()
    $start={param($out,$err,$record,$args,$target)$s.Pid++;$now=[DateTimeOffset]::UtcNow.ToString('o');
        if($service -ceq 'backend' -and $s.Fault -ceq 'follower-start-failure'){throw 'SYNTHETIC_FOLLOWER_START_FAILURE'}
        $recordContainerId=[string]$target.containerId
        if($service -ceq 'backend' -and $s.Fault -ceq 'follower-container-mismatch'){$recordContainerId=('9'*64)}
        [IO.File]::WriteAllText($out,"$($target.service)-$($target.containerId)`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($err,'',[Text.UTF8Encoding]::new($false));
        [IO.File]::WriteAllText($record,(ConvertTo-Json -Compress -InputObject @{id=$s.Pid;name='synthetic-follower';startUtc=$now;containerId=$recordContainerId;service=$target.service;project=$target.project;createdUtc=$target.createdUtc}),[Text.UTF8Encoding]::new($false));
        $s.Alive[[string]$s.Pid]=$true;$s.CurrentFollowerContainerId=[string]$target.containerId;$null=$s.Events.Add("follower:$service");return [pscustomobject]@{id=$s.Pid;name='synthetic-follower';startUtc=$now}}.GetNewClosure()
    $ready={param($target)
        $s.ReadinessCount++
        if($s.CurrentFollowerContainerId -cne [string]$target.containerId){throw 'FOLLOWER_NOT_RUNNING'}
        if($s.Fault -ceq 'readiness-failure'){throw 'SYNTHETIC_READINESS_FAILURE'}
        $manifest=Get-GeordiCaptureGenerationManifest $s.Root;$active=Get-GeordiActiveCaptureGenerationRecord -Manifest $manifest -Service $service
        if([string]$active.containerId -cne [string]$target.containerId -or !$active.followerProcess -or
                [int]$active.followerProcess.id -le 0 -or [string]$active.terminalStatus -cne 'capturing'){
            throw 'PERSISTED_FOLLOWER_BINDING_NOT_PUBLISHED'
        }
        $null=$s.Events.Add("binding-validated:$service");$null=$s.Events.Add("ready:$service")
    }.GetNewClosure()
    [pscustomobject]@{Resolve=$resolve;Alive=$alive;Stop=$stop;Start=$start;Ready=$ready}
}
function Invoke-OverlapHandoff($s,[string]$service,[string]$newId,[switch]$Fail){
    $a=New-OverlapAdapters $s $service
    if($service -ceq 'backend'){$handoff=Begin-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $s.Repo -ResolveIdentity $a.Resolve -TestFollowerProcess $a.Alive -TestProcessIdentity $a.Alive -StopProcess $a.Stop -Reason 'synthetic-overlap'}
    else{$handoff=Begin-GeordiCaptureHandoff -CaptureRoot $s.Root -Service $service -Reason 'synthetic-overlap' -TestProcessIdentity $a.Alive -StopProcess $a.Stop}
    $replace={if($Fail){throw 'SYNTHETIC_REPLACE_FAILED'};$s.Ids[$service]=$newId;$null=$s.Events.Add("replace:$service")}.GetNewClosure()
    $get={param($name)& $a.Resolve $name}.GetNewClosure()
    if($service -ceq 'backend'){
        return Complete-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $s.Repo -HandoffId $handoff -Replace $replace -ResolveIdentity $get -WaitReadiness $a.Ready -StartFollower $a.Start -TestProcessIdentity $a.Alive -StopProcess $a.Stop -DockerPath 'docker' -PowerShellPath 'pwsh' -WorkerPath 'worker'
    }
    $gen=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $s.Root -Service $service -HandoffId $handoff -RepositoryRoot $s.Repo -Replace $replace -GetContainerIdentity $get -StartFollower $a.Start -AfterFollowerValidated $a.Ready -StopProcess $a.Stop -DockerPath 'docker' -PowerShellPath 'pwsh' -WorkerPath 'worker'
    $m=Get-GeordiCaptureGenerationManifest $s.Root;$r=Get-GeordiCaptureGenerationRecord $m $service $gen
    [pscustomobject]@{HandoffId=$handoff;GenerationId=$gen;OldContainerId=[string]$m.captureHandoffs[$handoff].oldContainerId;NewContainerId=[string]$r.containerId;Status=[string]$m.captureHandoffs[$handoff].status}
}
function Get-OverlapVolumeInspector($s){return {param($name)if($s.Volumes.ContainsKey([string]$name)){$s.Volumes[[string]$name]}}.GetNewClosure()}
function Get-OverlapVolumeRemover($s){return {param($name)[void]$s.Volumes.Remove([string]$name)}.GetNewClosure()}
function Export-OverlapMetrics($start,$end,[string]$path,[long]$bound){$stamp=[Math]::Max($start.ToUnixTimeMilliseconds(),[Math]::Min($end.ToUnixTimeMilliseconds(),[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()));
    $line=@{metric=@{'__name__'='geordi_security_authentication_attempts_total';'service.name'='geordi-backend';'geordi.telemetry.origin'='platform'};timestamps=@($stamp);values=@('1')}|ConvertTo-Json -Compress -Depth 8;
    [IO.File]::WriteAllText($path,$line+"`n",[Text.UTF8Encoding]::new($false));$valid=Test-GeordiPersistedMetricExportFile -Path $path -StartUtc $start -EndUtc $end;
    [pscustomobject]@{Bytes=[long](Get-Item $path).Length;Series=$valid.Series;Samples=$valid.Samples;PositiveControl=$valid.PositiveControl;PositiveMetricName=$valid.PositiveMetricName}}
function Test-OverlapEntry($repo){$s=New-OverlapState;try{$a=New-OverlapAdapters $s backend;$e=Assert-GeordiM12OverlapEntryState -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $a.Resolve -InspectVolume (Get-OverlapVolumeInspector $s) -TestFollowerProcess $a.Alive;
    Assert-Overlap ($e.Backend.Id -ceq ('a'*64) -and $e.Collector.Id -ceq ('b'*64) -and $e.VictoriaMetrics.Id -ceq ('c'*64)) 'exact entry identities failed';
    $m=Get-GeordiCaptureGenerationManifest $s.Root;$m.captureHandoffs.bad=[ordered]@{logicalService='backend';status='incomplete-replacement'};Write-GeordiM19ManifestAtomic -Path $s.ManifestPath -Manifest $m;$bad=$false;
    try{[void](Assert-GeordiM12OverlapEntryState -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $a.Resolve -InspectVolume (Get-OverlapVolumeInspector $s) -TestFollowerProcess $a.Alive)}catch{$bad=$true};Assert-Overlap $bad 'incomplete handoff passed entry'}finally{Remove-OverlapRoot $s.Root};'m12_overlap_entry=PASS exact-followers+VM+volumes incomplete=fail-closed'}
function Test-OverlapVolumes{$s=New-OverlapState;try{$inspect=Get-OverlapVolumeInspector $s;$removed=[Collections.Generic.List[string]]::new();$remove={param($name)$null=$removed.Add($name);$s.Volumes.Remove($name)}.GetNewClosure();
    $inventoryState=@{Names=@();InventoryFails=$false;InspectFails=$false};$docker={param([string[]]$Arguments)
        if(($Arguments -join ' ') -ceq 'volume ls --format {{.Name}}'){
            if($inventoryState.InventoryFails){return [pscustomobject]@{ExitCode=1;Output=@()}}
            return [pscustomobject]@{ExitCode=0;Output=@($inventoryState.Names)}
        }
        if($Arguments.Count -eq 3 -and $Arguments[0] -ceq 'volume' -and $Arguments[1] -ceq 'inspect'){
            if($inventoryState.InspectFails){return [pscustomobject]@{ExitCode=1;Output=@()}}
            return [pscustomobject]@{ExitCode=0;Output=@(ConvertTo-Json -InputObject @($s.Volumes[$Arguments[2]]) -Depth 8 -Compress)}
        }
        throw 'Unexpected synthetic Docker invocation.'
    }.GetNewClosure()
    $absent=Get-GeordiM11DockerVolumeInspection -Name 'absent' -DockerCommand $docker;Assert-Overlap ($null -eq $absent) 'successful inventory absence was not distinguished';
    $inventoryState.InventoryFails=$true;$bad=$false;try{[void](Get-GeordiM11DockerVolumeInspection -Name 'absent' -DockerCommand $docker)}catch{$bad=$true};Assert-Overlap $bad 'inventory failure became absence';
    $inventoryState.InventoryFails=$false;$inventoryState.Names=@('geordi_m12-alert-lifecycle-data');$inventoryState.InspectFails=$true;$bad=$false;
    try{[void](Get-GeordiM11DockerVolumeInspection -Name 'geordi_m12-alert-lifecycle-data' -DockerCommand $docker)}catch{$bad=$true};Assert-Overlap $bad 'inspect failure became absence';
    $inventoryState.InspectFails=$false;$valid=Get-GeordiM11DockerVolumeInspection -Name 'geordi_m12-alert-lifecycle-data' -DockerCommand $docker;Assert-Overlap ($valid.Name -ceq 'geordi_m12-alert-lifecycle-data') 'valid ownership inspection failed';
    [void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume $inspect -RemoveVolume $remove);Assert-Overlap ($removed.Count -eq 2 -and $s.Volumes.ContainsKey('geordi_m19-alert-lifecycle-data') -and $s.Volumes.ContainsKey('geordi_m19-victoriametrics-data')) 'protected volume removal/allowlist failure';
    $bad=$false;try{Remove-GeordiM12DedicatedFixtureVolumes -ExpectedVolumes ([ordered]@{'m12-alert-lifecycle-data'='geordi_m19-alert-lifecycle-data';'m12-victoriametrics-data'='geordi_m12-victoriametrics-data'}) -InspectVolume $inspect -RemoveVolume $remove}catch{$bad=$true};Assert-Overlap $bad 'protected-volume substitution accepted';
    $bad=$false;try{Remove-GeordiM12DedicatedFixtureVolumes -ExpectedVolumes ([ordered]@{'m12-alert-lifecycle-data'='geordi_m12-alert-lifecycle-data';'m12-victoriametrics-data'='geordi_m19-victoriametrics-data'}) -InspectVolume $inspect -RemoveVolume $remove}catch{$bad=$true};Assert-Overlap $bad 'protected VictoriaMetrics volume substitution accepted';
    foreach($invalid in @(
        [pscustomobject]@{Project='foreign';Logical='m12-alert-lifecycle-data'},
        [pscustomobject]@{Project='geordi';Logical='wrong-volume-key'},
        [pscustomobject]@{Project='';Logical='m12-alert-lifecycle-data'}
    )){
        $s.Volumes['geordi_m12-alert-lifecycle-data']=[pscustomobject]@{Name='geordi_m12-alert-lifecycle-data';Labels=@{'com.docker.compose.project'=$invalid.Project;'com.docker.compose.volume'=$invalid.Logical}}
        $bad=$false;try{[void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume (Get-OverlapVolumeInspector $s) -RemoveVolume $remove)}catch{$bad=$true}
        Assert-Overlap $bad "invalid ownership accepted: project=$($invalid.Project);logical=$($invalid.Logical)"
    }
    $s.Volumes['geordi_m12-alert-lifecycle-data']=[pscustomobject]@{Name='geordi_m12-alert-lifecycle-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m12-alert-lifecycle-data'}}
    $s.Volumes['geordi_m12-victoriametrics-data']=[pscustomobject]@{Name='geordi_m12-victoriametrics-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='wrong-volume-key'}}
    $bad=$false;try{[void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume (Get-OverlapVolumeInspector $s) -RemoveVolume $remove)}catch{$bad=$true};Assert-Overlap $bad 'invalid VictoriaMetrics volume ownership accepted'
    $bad=$false;try{[void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume {param($n)throw 'INSPECT_FAILURE'}.GetNewClosure() -RemoveVolume $remove)}catch{$bad=$true};Assert-Overlap $bad 'inspect error became absence';
    $s.Volumes['geordi_m12-alert-lifecycle-data']=[pscustomobject]@{Name='geordi_m12-alert-lifecycle-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m12-alert-lifecycle-data'}}
    $bad=$false;try{[void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume (Get-OverlapVolumeInspector $s) -RemoveVolume {param($n)throw 'REMOVE_FAILURE'}.GetNewClosure())}catch{$bad=$true};Assert-Overlap $bad 'volume removal callback failure was ignored'}finally{Remove-OverlapRoot $s.Root};'m12_overlap_volumes=PASS inventory+inspect=fail-closed exact-two protected-preserved'}
function Test-OverlapEvidence($repo){$s=New-OverlapState;try{$resolve={param($service)Get-OverlapIdentity $s $service}.GetNewClosure();$export={param($st,$en,$p,$bound)Export-OverlapMetrics $st $en $p $bound}.GetNewClosure();
    $one=Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $s.Root -RepositoryRoot $repo -Phase m12-overlap-reset -ResolveIdentity $resolve -ExportSamples $export;$hash=(Get-FileHash $one.LedgerPath).Hash;
    $s.Ids.victoriametrics='d'*64;$two=Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $s.Root -RepositoryRoot $repo -Phase m12-overlap-recreate -ResolveIdentity $resolve -ExportSamples $export;
    $m=Get-GeordiCaptureGenerationManifest $s.Root;$source=@($m.additionalSources|Where-Object channel -ceq 'victoriametrics');$l1=Get-Content $one.LedgerPath -Raw|ConvertFrom-Json -AsHashtable;$l2=Get-Content $two.LedgerPath -Raw|ConvertFrom-Json -AsHashtable;
    Assert-Overlap ($l1.sourceContainerId -ceq ('c'*64) -and $l2.sourceContainerId -ceq ('d'*64) -and $one.LedgerPath -cne $two.LedgerPath -and $source.Count -eq 1 -and (Get-FileHash $one.LedgerPath).Hash -ceq $hash) 'VM evidence is not unique, immutable and identity bound';
    $before=@($source[0].captures).Count;$bad=$false;$changingExport={param($st,$en,$p,$bound)$result=Export-OverlapMetrics $st $en $p $bound;$s.Ids.victoriametrics='e'*64;return $result}.GetNewClosure();
    try{[void](Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $s.Root -RepositoryRoot $repo -Phase m12-overlap-recreate -ResolveIdentity $resolve -ExportSamples $changingExport)}catch{$bad=$true};
    $after=Get-GeordiCaptureGenerationManifest $s.Root;$afterSource=@($after.additionalSources|Where-Object channel -ceq 'victoriametrics');
    Assert-Overlap ($bad -and @($afterSource[0].captures).Count -eq $before -and (Get-FileHash $one.LedgerPath).Hash -ceq $hash) 'VM identity change during acquisition published evidence or changed prior evidence';
    Assert-Overlap (@($m.generationCaptures.backend).Count -eq 0 -and @($m.generationCaptures.collector).Count -eq 0 -and @($m.generationCaptures.otel).Count -eq 0) 'unbound overlap logs registered'}finally{Remove-OverlapRoot $s.Root};'m12_overlap_vm_evidence=PASS V0->V1 immutable unique artifacts identity-change=fail-closed logs=none'}
function Invoke-OverlapBackendBoundary($s,[string]$fault,[string]$newId){
    $s.Fault=$fault;$s.ReplacementInvoked=$false;$s.ReadinessCount=0;$a=New-OverlapAdapters $s backend
    if($fault -ceq 'missing-generation'){$m=Get-GeordiCaptureGenerationManifest $s.Root;$m.captureGenerations.backend=@();Write-GeordiM19ManifestAtomic -Path $s.ManifestPath -Manifest $m}
    if($fault -ceq 'live-id-mismatch'){$s.Ids.backend=('8'*64)}
    if($fault -ceq 'missing-follower'){$m=Get-GeordiCaptureGenerationManifest $s.Root;$active=Get-GeordiActiveCaptureGenerationRecord -Manifest $m -Service backend;$s.Alive[[string]$active.followerProcess.id]=$false}
    if($fault -ceq 'old-follower-mismatch'){$m=Get-GeordiCaptureGenerationManifest $s.Root;$active=Get-GeordiActiveCaptureGenerationRecord -Manifest $m -Service backend;$g=Get-GeordiCaptureGenerationRecord $m backend ([string]$active.generationId);$p=Get-Content -LiteralPath $g.processRecordPath -Raw|ConvertFrom-Json -AsHashtable;$p.containerId=('9'*64);[IO.File]::WriteAllText($g.processRecordPath,(ConvertTo-Json -InputObject $p -Compress),[Text.UTF8Encoding]::new($false))}
    $replace={
        if($s.Fault -ceq 'replacement-failure'){throw 'SYNTHETIC_REPLACEMENT_FAILURE'}
        if($s.Fault -cne 'same-id'){$s.Ids.backend=$newId}
        $s.ReplacementInvoked=$true;$null=$s.Events.Add('replace:backend')
    }.GetNewClosure()
    $beginFailure=$false;$handoff=$null
    try{$handoff=Begin-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $s.Repo -ResolveIdentity $a.Resolve -TestFollowerProcess $a.Alive -TestProcessIdentity $a.Alive -StopProcess $a.Stop -Reason "synthetic-$fault"}catch{$beginFailure=$true}
    if($beginFailure){return [pscustomobject]@{Failed=$true;BeginFailed=$true;HandoffId=$null;ReadyCount=$s.ReadinessCount}}
    $failed=$false
    try{[void](Complete-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $s.Repo -HandoffId $handoff -Replace $replace -ResolveIdentity $a.Resolve -WaitReadiness $a.Ready -StartFollower $a.Start -TestProcessIdentity $a.Alive -StopProcess $a.Stop -DockerPath 'docker' -PowerShellPath 'pwsh' -WorkerPath 'worker')}catch{$failed=$true}
    [pscustomobject]@{Failed=$failed;BeginFailed=$false;HandoffId=$handoff;ReadyCount=$s.ReadinessCount}
}
function Test-OverlapBackend($repo){$s=New-OverlapState;try{$one=Invoke-OverlapHandoff $s backend ('d'*64);$m=Get-GeordiCaptureGenerationManifest $s.Root;$g1=Get-GeordiCaptureGenerationRecord $m backend $one.GenerationId;$g1Hash=(Get-FileHash $g1.capturePath).Hash;$oneSnapshot=ConvertTo-Json $m.captureHandoffs[$one.HandoffId] -Compress -Depth 12;
    Assert-Overlap ($one.Status -ceq 'complete' -and $one.OldContainerId -ceq ('a'*64) -and $one.NewContainerId -ceq ('d'*64)) 'first backend boundary did not bind G0 to G1';
    $a=New-OverlapAdapters $s backend;$hid=Begin-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $a.Resolve -TestFollowerProcess $a.Alive -TestProcessIdentity $a.Alive -StopProcess $a.Stop -Reason 'second-failure';$bad=$false;
    try{[void](Complete-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $repo -HandoffId $hid -Replace {throw 'REPLACEMENT'} -ResolveIdentity $a.Resolve -WaitReadiness $a.Ready -StartFollower $a.Start -TestProcessIdentity $a.Alive -StopProcess $a.Stop -DockerPath 'docker' -PowerShellPath 'pwsh' -WorkerPath 'worker')}catch{$bad=$true};$m=Get-GeordiCaptureGenerationManifest $s.Root;
    $g=@($m.captureGenerations.backend);$handoffs=@($m.captureHandoffs.Values|Where-Object logicalService -ceq 'backend');
    Assert-Overlap ($bad -and (ConvertTo-Json $m.captureHandoffs[$one.HandoffId] -Compress -Depth 12) -ceq $oneSnapshot -and
        (Get-FileHash $g1.capturePath).Hash -ceq $g1Hash -and $g.Count -eq 2 -and $g[1].terminalStatus -ceq 'sealed' -and
        $handoffs.Count -eq 2 -and $handoffs[0].status -ceq 'complete' -and $handoffs[1].status -ceq 'incomplete-replacement' -and
        @($g|Where-Object containerId -ceq ('e'*64)).Count -eq 0) 'second backend boundary failure changed H1/G1 or fabricated G2'
    $faults=@('missing-generation','live-id-mismatch','missing-follower','old-follower-mismatch','seal-failure','replacement-failure','missing-new-container','same-id','wrong-ownership','follower-start-failure','follower-container-mismatch','readiness-failure')
    foreach($boundary in 1,2){foreach($fault in $faults){
        $matrix=New-OverlapState;try{
            if($boundary -eq 2){$first=Invoke-OverlapHandoff $matrix backend ('f'*64);$prior=Get-GeordiCaptureGenerationManifest $matrix.Root;$priorHandoff=ConvertTo-Json $prior.captureHandoffs[$first.HandoffId] -Compress -Depth 12;$priorGen=Get-GeordiCaptureGenerationRecord $prior backend $first.GenerationId;$priorHash=(Get-FileHash $priorGen.capturePath).Hash}
            $targetId=if($boundary -eq 1){'d'*64}else{'e'*64};$result=Invoke-OverlapBackendBoundary $matrix $fault $targetId;$after=Get-GeordiCaptureGenerationManifest $matrix.Root;$backendGenerations=@($after.captureGenerations.backend);$completeTarget=@($after.captureHandoffs.Values|Where-Object{[string]$_.logicalService -ceq 'backend' -and [string]$_.replacementReason -ceq "synthetic-$fault" -and [string]$_.status -ceq 'complete'});$targetRecord=@($backendGenerations|Where-Object{[string]$_.containerId -ceq $targetId -and [string]$_.terminalStatus -ceq 'capturing'})
            Assert-Overlap $result.Failed "boundary $boundary fault $fault unexpectedly passed"
            Assert-Overlap ($completeTarget.Count -eq 0 -and $targetRecord.Count -eq 0) "boundary $boundary fault $fault accepted a new backend generation"
            if($fault -ceq 'follower-container-mismatch'){Assert-Overlap ($result.ReadyCount -eq 0) "boundary $boundary wrong follower invoked readiness"}
            if($fault -ceq 'readiness-failure'){Assert-Overlap ($result.ReadyCount -eq 1) "boundary $boundary readiness failure was not reached"}
            if($boundary -eq 2){$currentH1=Get-GeordiCaptureGenerationManifest $matrix.Root;$priorStillIntact=$false;if($fault -ceq 'missing-generation'){$priorStillIntact=(Get-FileHash $priorGen.capturePath).Hash -ceq $priorHash}else{$currentPrior=Get-GeordiCaptureGenerationRecord $currentH1 backend $first.GenerationId;$priorStillIntact=($currentPrior -and (Get-FileHash $currentPrior.capturePath).Hash -ceq $priorHash -and [string]$currentPrior.terminalStatus -in @('capturing','sealed','sealing-failed'))};$currentHandoff=ConvertTo-Json $currentH1.captureHandoffs[$first.HandoffId] -Compress -Depth 12;Assert-Overlap ($currentHandoff -ceq $priorHandoff -and $priorStillIntact) "boundary 2 fault $fault mutated completed H1 or G1 historical evidence"}
        }finally{Remove-OverlapRoot $matrix.Root}
    }}
    }finally{Remove-OverlapRoot $s.Root};'m12_overlap_backend=PASS H1=immutable G1=sealed H2=incomplete G2=not-accepted matrices=12x2 readiness=post-binding'}
function Test-OverlapSequence($repo){$s=New-OverlapState;try{$a=New-OverlapAdapters $s backend;$resolve={param($service)Get-OverlapIdentity $s $service}.GetNewClosure();$entry=Assert-GeordiM12OverlapEntryState -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $resolve -InspectVolume (Get-OverlapVolumeInspector $s) -TestFollowerProcess $a.Alive;
    $capture={param($id)$export={param($st,$en,$p,$bound)Export-OverlapMetrics $st $en $p $bound}.GetNewClosure();Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $s.Root -RepositoryRoot $repo -Phase m12-overlap-reset -ResolveIdentity $resolve -ExportSamples $export}.GetNewClosure();
    $begin={Begin-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $a.Resolve -TestFollowerProcess $a.Alive -TestProcessIdentity $a.Alive -StopProcess $a.Stop -Reason 'reset'}.GetNewClosure();
    $c1={Invoke-OverlapHandoff $s 'otel-collector' ('d'*64)}.GetNewClosure();$c2={Invoke-OverlapHandoff $s 'otel-collector' ('e'*64)}.GetNewClosure();
    $backend={param($hid)$ad=New-OverlapAdapters $s backend;$replaceState=$s;$replace={$replaceState.Ids['backend']='f'*64;$replaceState.Volumes['geordi_m12-alert-lifecycle-data']=[pscustomobject]@{Name='geordi_m12-alert-lifecycle-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m12-alert-lifecycle-data'}}}.GetNewClosure();Complete-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $repo -HandoffId $hid -Replace $replace -ResolveIdentity $ad.Resolve -WaitReadiness $ad.Ready -StartFollower $ad.Start -TestProcessIdentity $ad.Alive -StopProcess $ad.Stop -DockerPath 'docker' -PowerShellPath 'pwsh' -WorkerPath 'worker'}.GetNewClosure();
    $provider={param($old)$null=($s.Ids.victoriametrics='1'*64);$s.Volumes['geordi_m12-victoriametrics-data']=[pscustomobject]@{Name='geordi_m12-victoriametrics-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m12-victoriametrics-data'}};return (Get-OverlapIdentity $s victoriametrics)}.GetNewClosure();
    $removeVolumes={$inspect=Get-OverlapVolumeInspector $s;$remove=Get-OverlapVolumeRemover $s;[void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume $inspect -RemoveVolume $remove)}.GetNewClosure();
    $stop={$null=$s.Events.Add('stop-traffic')}.GetNewClosure()
    $assertBeforeRemove={param($hid)
        $oldVmId=[string]$s.Ids.victoriametrics;$s.Ids.victoriametrics='f'*64;$rejected=$false
        try{Assert-GeordiM12OverlapResetRemovalPreconditions -CaptureRoot $s.Root -BackendHandoffId $hid -ExpectedBackendId ('a'*64) -ExpectedCollectorId ('b'*64) -ExpectedVictoriaMetricsId $oldVmId -ResolveIdentity $resolve -InspectVolume (Get-OverlapVolumeInspector $s)}catch{$rejected=$true}finally{$s.Ids.victoriametrics=$oldVmId}
        Assert-Overlap $rejected 'pre-removal check accepted a changed VictoriaMetrics identity'
        Assert-GeordiM12OverlapResetRemovalPreconditions -CaptureRoot $s.Root -BackendHandoffId $hid -ExpectedBackendId ('a'*64) -ExpectedCollectorId ('b'*64) -ExpectedVictoriaMetricsId $oldVmId -ResolveIdentity $resolve -InspectVolume (Get-OverlapVolumeInspector $s)
        $null=$s.Events.Add('pre-removal-validated')
    }.GetNewClosure()
    $removeContainers={if(@($s.Events|Where-Object {$_ -ceq 'pre-removal-validated'}).Count -ne 1){throw 'removal ran before exact reset preconditions'};$null=$s.Events.Add('remove-containers')}.GetNewClosure()
    $r=Invoke-GeordiM12OverlapGenerationResetSequence -IncomingVictoriaMetricsId ([string]$entry.VictoriaMetrics.Id) -CaptureResetEvidence $capture -BeginBackendHandoff $begin -StopTrafficFixture $stop `
        -AssertResetRemovalPreconditions $assertBeforeRemove -RemoveResetContainers $removeContainers -ReplaceCollectorFirst $c1 -RemoveDedicatedVolumes $removeVolumes `
        -StartProvider $provider -ReplaceCollectorSecond $c2 -CompleteBackendHandoff $backend -StartTrafficFixture {};
    $ex={param($st,$en,$p,$bound)Export-OverlapMetrics $st $en $p $bound}.GetNewClosure();$vm=Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $s.Root -RepositoryRoot $repo -Phase m12-overlap-recreate -ResolveIdentity $resolve -ExportSamples $ex;$b2=Invoke-OverlapHandoff $s backend ('2'*64);$m=Get-GeordiCaptureGenerationManifest $s.Root;
    $final=Assert-GeordiM12OverlapFinalEntryState -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $resolve -InspectVolume (Get-OverlapVolumeInspector $s) -ExpectedVictoriaMetricsId ('1'*64) -TestFollowerProcess $a.Alive;
    Assert-Overlap ($r.BackendFirst.Status -ceq 'complete' -and $b2.NewContainerId -ceq ('2'*64) -and $r.CollectorFirst.NewContainerId -ceq ('d'*64) -and $r.CollectorSecond.NewContainerId -ceq ('e'*64) -and $vm.SourceContainerId -ceq ('1'*64) -and $final.Backend.Id -ceq ('2'*64) -and $final.Collector.Id -ceq ('e'*64) -and @($m.captureHandoffs.Values|Where-Object status -cne 'complete').Count -eq 0) 'combined B/C/VM graph or final M13-entry state invalid'}finally{Remove-OverlapRoot $s.Root};'m12_overlap_sequence=PASS B=G0-H1-G1-H2-G2 C=C0-HC1-C1-HC2-C2 VM=V0-V1 M13-entry=exact'}
function Test-OverlapCrossFailure($repo){$s=New-OverlapState;try{$a=New-OverlapAdapters $s backend;$resolve={param($service)Get-OverlapIdentity $s $service}.GetNewClosure();$entry=Assert-GeordiM12OverlapEntryState -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $resolve -InspectVolume (Get-OverlapVolumeInspector $s) -TestFollowerProcess $a.Alive;
    $export={param($st,$en,$p,$bound)Export-OverlapMetrics $st $en $p $bound}.GetNewClosure();$capture={param($id)Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $s.Root -RepositoryRoot $repo -Phase m12-overlap-reset -ResolveIdentity $resolve -ExportSamples $export}.GetNewClosure();
    $begin={Begin-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $repo -ResolveIdentity $a.Resolve -TestFollowerProcess $a.Alive -TestProcessIdentity $a.Alive -StopProcess $a.Stop -Reason 'cross-failure'}.GetNewClosure();
    $c1={Invoke-OverlapHandoff $s 'otel-collector' ('d'*64)}.GetNewClosure();$c2={Invoke-OverlapHandoff $s 'otel-collector' ('e'*64)}.GetNewClosure();
    $provider={param($old)$s.Ids.victoriametrics='1'*64;$s.Volumes['geordi_m12-victoriametrics-data']=[pscustomobject]@{Name='geordi_m12-victoriametrics-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m12-victoriametrics-data'}};Get-OverlapIdentity $s victoriametrics}.GetNewClosure();
    $removeVolumes={$inspect=Get-OverlapVolumeInspector $s;$remove=Get-OverlapVolumeRemover $s;[void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume $inspect -RemoveVolume $remove)}.GetNewClosure();
    $assertBeforeRemove={param($hid)Assert-GeordiM12OverlapResetRemovalPreconditions -CaptureRoot $s.Root -BackendHandoffId $hid -ExpectedBackendId ([string]$entry.Backend.Id) -ExpectedCollectorId ([string]$entry.Collector.Id) -ExpectedVictoriaMetricsId ([string]$entry.VictoriaMetrics.Id) -ResolveIdentity $resolve -InspectVolume (Get-OverlapVolumeInspector $s)}.GetNewClosure();
    $completeFailure={param($hid)$before=Get-GeordiCaptureGenerationManifest $s.Root;$collectorSnapshot=ConvertTo-Json @($before.captureHandoffs.Values|Where-Object logicalService -ceq 'otel-collector') -Compress -Depth 16;$ledgerBefore=@($before.additionalSources|Where-Object channel -ceq 'victoriametrics')[0].captures[0];$ledgerHash=(Get-FileHash $ledgerBefore).Hash;
        $failed=$false;try{Complete-GeordiM12OverlapBackendHandoff -CaptureRoot $s.Root -RepositoryRoot $repo -HandoffId $hid -Replace {throw 'SYNTHETIC_BACKEND_REPLACEMENT_FAILURE'} -ResolveIdentity $a.Resolve -WaitReadiness $a.Ready -StartFollower $a.Start -TestProcessIdentity $a.Alive -StopProcess $a.Stop -DockerPath 'docker' -PowerShellPath 'pwsh' -WorkerPath 'worker'}catch{$failed=$true};
        $after=Get-GeordiCaptureGenerationManifest $s.Root;$collectorAfter=ConvertTo-Json @($after.captureHandoffs.Values|Where-Object logicalService -ceq 'otel-collector') -Compress -Depth 16;$handoff=$after.captureHandoffs[$hid];$backendGenerations=@($after.captureGenerations.backend);
        Assert-Overlap ($failed -and $collectorAfter -ceq $collectorSnapshot -and (Get-FileHash $ledgerBefore).Hash -ceq $ledgerHash -and $handoff.status -ceq 'incomplete-replacement' -and $backendGenerations.Count -eq 1 -and $backendGenerations[0].terminalStatus -ceq 'sealed' -and $s.Ids.victoriametrics -ceq ('1'*64)) 'cross-service failure rewrote Collector/VM evidence or accepted a backend generation'
    }.GetNewClosure();$bad=$false;
    try{[void](Invoke-GeordiM12OverlapGenerationResetSequence -IncomingVictoriaMetricsId ([string]$entry.VictoriaMetrics.Id) -CaptureResetEvidence $capture -BeginBackendHandoff $begin -StopTrafficFixture {} -AssertResetRemovalPreconditions $assertBeforeRemove -RemoveResetContainers {} -ReplaceCollectorFirst $c1 -RemoveDedicatedVolumes $removeVolumes -StartProvider $provider -ReplaceCollectorSecond $c2 -CompleteBackendHandoff $completeFailure -StartTrafficFixture {})}catch{$bad=$true};
    Assert-Overlap $bad 'cross-service backend replacement failure unexpectedly completed reset';'m12_overlap_cross_failure=PASS Collector=complete+immutable VM=V0-preserved backend=H-incomplete G2=absent'}finally{Remove-OverlapRoot $s.Root}}
function Test-OverlapCommands($repo){$compose=Get-GeordiM12OverlapComposeArguments -RepositoryRoot $repo -IsolationOverlay;$backend=Get-GeordiM12OverlapBackendReplacementArguments -ComposeArguments $compose;$provider=Get-GeordiM12OverlapProviderReplacementArguments -ComposeArguments $compose;$traffic=Get-GeordiM12OverlapTrafficFixtureArguments -ComposeArguments $compose;
    Assert-Overlap ((@($backend|Select-Object -Last 5)-join ' ') -ceq 'up -d --no-deps --force-recreate backend') 'backend mutation is not service scoped/no-deps';
    Assert-Overlap ((@($provider|Select-Object -Last 6)-join ' ') -ceq 'up -d --no-deps --force-recreate victoriametrics m12-query-gate') 'VM/provider mutation is not service scoped/no-deps';
    Assert-Overlap ((@($traffic|Select-Object -Last 5)-join ' ') -ceq 'up -d --no-deps --force-recreate m12-burn-demo') 'traffic fixture mutation is not service scoped/no-deps';
    foreach($args in @($backend,$provider,$traffic)){Assert-Overlap (@($args|Where-Object{$_ -in @('-v','--volumes','down','prune','rm')}).Count -eq 0) 'scoped up command can delete volumes or tear down project'}
    $bad=$false;try{[void](Get-GeordiM12OverlapBackendReplacementArguments -ComposeArguments (Get-GeordiM12OverlapComposeArguments -RepositoryRoot $repo))}catch{$bad=$true};Assert-Overlap $bad 'backend replacement accepted normal propagation Compose files';
    'm12_overlap_command_scope=PASS backend/provider/fixture=exact isolated=no-deps no-volume-delete'}
$repo=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
switch($Case){
    'Commands' { Test-OverlapCommands $repo }
    'Entry' { Test-OverlapEntry $repo }
    'Volumes' { Test-OverlapVolumes }
    'Evidence' { Test-OverlapEvidence $repo }
    'Backend' { Test-OverlapBackend $repo }
    'Sequence' { Test-OverlapSequence $repo }
    'CrossFailure' { Test-OverlapCrossFailure $repo }
    'SelfTest' { Test-OverlapCommands $repo;Test-OverlapEntry $repo;Test-OverlapVolumes;Test-OverlapEvidence $repo;Test-OverlapBackend $repo;Test-OverlapSequence $repo;Test-OverlapCrossFailure $repo }
}
