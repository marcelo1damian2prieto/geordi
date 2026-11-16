[CmdletBinding()]
param([ValidateSet('SelfTest','CiContract','NegativeMatrix','MetricFingerprintNegatives','OrderedOffline','ProducerWorker','ConsumerWorker')][string] $Case='SelfTest',
    [string] $CaptureRoot,[string] $MetadataPath,[switch] $PreserveFixtureForNextStage,
    [switch] $ConsumeTransferredM11Fixture,[switch] $ApplyM12BackendGeneration)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM11M12FixtureTransfer.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM12BackendReplacement.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM12CollectorReplacement.ps1')

function Assert-M11M12Ci([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "M11->M12 CI activation regression failed: $Message" }
}

function New-GeordiCiOfflineRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-capture-ci-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $now=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o')
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-ordered-m11-m12';startedUtc=$now;captureStartedUtc=$now;
        captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};generationCaptureEvents=@{};additionalSources=@();captures=@();persistedMetricEvidenceBytes=0}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
    return $root
}

function Remove-GeordiCiOfflineRoot([string] $Root) {
    if (!(Test-Path -LiteralPath $Root)) { return }
    $resolved=[IO.Path]::GetFullPath($Root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^geordi-m19-capture-ci-[0-9a-f]{32}$') {
        throw 'Refusing cleanup of an unowned ordered CI synthetic root.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function New-GeordiCiStageState([string] $Root,[System.Collections.IDictionary] $Data) {
    $runStart=if($Data.RunStart -is [DateTime]){$Data.RunStart.ToString('o')}else{[string]$Data.RunStart}
    $m11Vm=if($Data.VmM11Id){[string]$Data.VmM11Id}else{[string]$Data.VmInitialId}
    return [pscustomobject]@{Root=$Root;RepositoryRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot));
        RunStart=$runStart;BackendId=[string]$Data.BackendId;VmM11Id=$m11Vm;
        VmCurrentId=[string]$(if($Data.Contains('VmInitialId')){$Data.VmInitialId}else{$Data.VmM11Id});CollectorId=[string]$Data.CollectorId;Pid=83000;Alive=@{};
        Starts=[Collections.Generic.List[string]]::new();Readiness=[Collections.Generic.List[string]]::new();
        Replacements=[Collections.Generic.List[string]]::new();VolumeRemovals=[Collections.Generic.List[string]]::new();
        Events=[Collections.Generic.List[string]]::new();ExpectedNewBackendId=$null }
}

function New-GeordiCiIdentity($State,[string] $Service,[string] $Id) {
    return [pscustomobject]@{Id=$Id;Project='geordi';Service=$Service;WorkingDirectory=$State.RepositoryRoot;
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}
}

function Start-GeordiCiGeneration($State,[string] $Service,[string] $Id) {
    $identity=New-GeordiCiIdentity $State $Service $Id
    $start={param($stdout,$stderr,$processRecord,$arguments,$target)
        $State.Pid++;$now=[DateTimeOffset]::UtcNow.ToString('o')
        $record=[ordered]@{id=$State.Pid;name='synthetic-follower';startUtc=$now;containerId=[string]$target.containerId;
            service=[string]$target.service;project='geordi';createdUtc=[string]$target.createdUtc}
        [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stdout,"synthetic-$($target.service)-$($target.containerId)`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false));$State.Alive[[string]$State.Pid]=$true
        $State.Starts.Add("$($target.service):$($target.containerId)")
        return [pscustomobject]@{id=$State.Pid;name='synthetic-follower';startUtc=$now}
    }.GetNewClosure()
    return [string](Start-GeordiCaptureGeneration -CaptureRoot $State.Root -Service $Service -ContainerIdentity $identity `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' `
        -WorkingDirectory $State.RepositoryRoot -StartFollower $start)
}

function Add-GeordiCiMetricPhase($State,[string] $Phase,[string] $ContainerId) {
    $directory=Join-Path $State.Root 'victoriametrics-generations';[void][IO.Directory]::CreateDirectory($directory)
    $snapshot=Join-Path $directory "$Phase.jsonl";$ledgerPath=Join-Path $directory "$Phase.snapshot.json"
    if ((Test-Path -LiteralPath $snapshot) -or (Test-Path -LiteralPath $ledgerPath)) { throw "Metric phase $Phase already exists." }
    $stamp=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $line=@{metric=@{'__name__'='geordi_security_authentication_attempts_total';'service.name'='geordi-backend';'geordi.telemetry.origin'='platform'};timestamps=@($stamp);values=@('1')}|ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($snapshot,$line+"`n",[Text.UTF8Encoding]::new($false))
    $start=ConvertTo-GeordiCaptureUtcInstant -Value $State.RunStart -Field 'manifest.captureStartedUtc'
    $end=[DateTimeOffset]::UtcNow.AddSeconds(1);$bytes=[long](Get-Item -LiteralPath $snapshot).Length
    $ledger=[ordered]@{intervalStartUtc=$start.ToString('o');intervalEndUtc=$end.ToString('o');source='victoriametrics-export';complete=$true;
        runStartBound=$true;series=1;samples=1;bytes=$bytes;sourceService='victoriametrics';sourceContainerId=$ContainerId;
        snapshotSha256=(Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash.ToLowerInvariant()}
    [IO.File]::WriteAllText($ledgerPath,(ConvertTo-Json -InputObject $ledger -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    $manifest=Get-GeordiCaptureGenerationManifest $State.Root
    $source=@($manifest.additionalSources|Where-Object channel -ceq 'victoriametrics')
    if (!$source) {$manifest.additionalSources=@(@{channel='victoriametrics';control='geordi_security_authentication_attempts_total';captures=@()});$source=@($manifest.additionalSources)}
    $source[0].captures=@(@($source[0].captures)+@($snapshot,$ledgerPath))
    $manifest.persistedMetricEvidenceBytes=[long](@($source[0].captures|ForEach-Object{if(Test-Path -LiteralPath $_ -PathType Leaf){(Get-Item -LiteralPath $_).Length}else{0}}|Measure-Object -Sum).Sum)
    Write-GeordiM19ManifestAtomic -Path (Join-Path $State.Root 'manifest.json') -Manifest $manifest
}

function New-GeordiCiMetricFingerprint($State,[string] $Phase,[string] $ExpectedContainerId) {
    $directory=Join-Path $State.Root 'victoriametrics-generations'
    $snapshot=Join-Path $directory "$Phase.jsonl";$ledgerPath=Join-Path $directory "$Phase.snapshot.json"
    foreach($path in @($snapshot,$ledgerPath)) { Assert-M11M12Ci (Test-Path -LiteralPath $path -PathType Leaf) "$Phase metric evidence is not fully published" }
    $manifest=Get-GeordiCaptureGenerationManifest $State.Root
    $source=@($manifest.additionalSources|Where-Object channel -ceq 'victoriametrics')
    Assert-M11M12Ci ($source.Count -eq 1) "$Phase metric manifest source is missing or ambiguous"
    $captures=@($source[0].captures|ForEach-Object{[IO.Path]::GetFullPath([string]$_)})
    foreach($path in @($snapshot,$ledgerPath)) {
        Assert-M11M12Ci (@($captures|Where-Object{$_ -ceq [IO.Path]::GetFullPath($path)}).Count -eq 1) "$Phase metric artifact is not referenced exactly once"
    }
    $ledger=Get-Content -LiteralPath $ledgerPath -Raw|ConvertFrom-Json -AsHashtable
    Assert-M11M12Ci ($ledger.sourceContainerId -ceq $ExpectedContainerId -and $ledger.complete -and $ledger.runStartBound) "$Phase metric ledger identity/completeness is invalid"
    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath -Captures ([string[]]$source[0].captures))
    return [pscustomobject]@{Phase=$Phase;SnapshotPath=[IO.Path]::GetFullPath($snapshot);SnapshotBytes=[long](Get-Item -LiteralPath $snapshot).Length;
        SnapshotSha256=(Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash.ToLowerInvariant();LedgerPath=[IO.Path]::GetFullPath($ledgerPath);
        LedgerBytes=[long](Get-Item -LiteralPath $ledgerPath).Length;LedgerSha256=(Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash.ToLowerInvariant();
        SnapshotReferenceCount=1;LedgerReferenceCount=1;SourceContainerId=[string]$ledger.sourceContainerId;
        IntervalStartUtc=[string]$ledger.intervalStartUtc;IntervalEndUtc=[string]$ledger.intervalEndUtc}
}

function Assert-GeordiCiMetricFingerprint($State,$Fingerprint) {
    $current=New-GeordiCiMetricFingerprint $State $Fingerprint.Phase $Fingerprint.SourceContainerId
    foreach($property in @('SnapshotBytes','SnapshotSha256','LedgerBytes','LedgerSha256','SnapshotReferenceCount','LedgerReferenceCount',
            'SourceContainerId','IntervalStartUtc','IntervalEndUtc')) {
        Assert-M11M12Ci ([string]$current.$property -ceq [string]$Fingerprint.$property) "$($Fingerprint.Phase) metric fingerprint changed at a later boundary ($property)"
    }
}

function Test-GeordiCiMetricFingerprintNegatives {
    $root=New-GeordiCiOfflineRoot
    try {
        $data=[ordered]@{RunStart=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o');BackendId=('a'*64);VmM11Id=('1'*64);VmInitialId=('2'*64);CollectorId=('d'*64)}
        $state=New-GeordiCiStageState $root $data
        Add-GeordiCiMetricPhase $state 'm12-fixture-start' $state.VmM11Id
        $baseline=New-GeordiCiMetricFingerprint $state 'm12-fixture-start' $state.VmM11Id
        [IO.File]::AppendAllText($baseline.SnapshotPath,'mutation' + "`n")
        $rejected=$false
        try { Assert-GeordiCiMetricFingerprint $state $baseline } catch { $rejected=$true }
        Assert-M11M12Ci $rejected 'intermediate metric snapshot mutation was not detected against publication-time baseline'
        Write-Output 'metric_intermediate_mutation=PASS phase=m12-fixture-start rejected=true'

        Add-GeordiCiMetricPhase $state 'm12-recovery-start' $state.VmM11Id
        $reference=New-GeordiCiMetricFingerprint $state 'm12-recovery-start' $state.VmM11Id
        $manifest=Get-GeordiCaptureGenerationManifest $root
        $manifest.additionalSources[0].captures=@($manifest.additionalSources[0].captures|Where-Object{[IO.Path]::GetFullPath([string]$_) -cne $reference.LedgerPath})
        Write-GeordiM19ManifestAtomic -Path (Join-Path $root 'manifest.json') -Manifest $manifest
        $rejected=$false
        try { Assert-GeordiCiMetricFingerprint $state $reference } catch { $rejected=$true }
        Assert-M11M12Ci $rejected 'metric manifest-reference mutation was not detected against publication-time baseline'
        Write-Output 'metric_manifest_mutation=PASS phase=m12-recovery-start rejected=true'
    } finally { Remove-GeordiCiOfflineRoot $root }
}

function Invoke-GeordiCiM11Producer {
    $root=[IO.Path]::GetFullPath($CaptureRoot)
    if (!(Test-Path -LiteralPath $root -PathType Container) -or @(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) { throw 'M11 worker requires an empty pre-created capture root.' }
    $data=[ordered]@{RunStart=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o');BackendId=('a'*64);VmM11Id=('1'*64);VmInitialId=('2'*64);CollectorId=('d'*64)}
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-ordered-m11-m12';startedUtc=$data.RunStart;captureStartedUtc=$data.RunStart;
        captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};generationCaptureEvents=@{};additionalSources=@();captures=@();persistedMetricEvidenceBytes=0}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
    $state=New-GeordiCiStageState $root $data
    $null=Start-GeordiCiGeneration $state 'backend' $state.BackendId
    $null=Start-GeordiCiGeneration $state 'otel-collector' $state.CollectorId
    Add-GeordiCiMetricPhase $state 'm11-reset' $data.VmInitialId
    $testProcess={param($record)[bool]$state.Alive[[string]$record.id]}.GetNewClosure()
    $stopProcess={param($record)$state.Alive[[string]$record.id]=$false}.GetNewClosure()
    $resolver={param($service)switch($service){'backend'{New-GeordiCiIdentity $state 'backend' $state.BackendId};'victoriametrics'{New-GeordiCiIdentity $state 'victoriametrics' $state.VmCurrentId};default{throw 'Unexpected M11 producer identity request.'}}}.GetNewClosure()
    for($i=0;$i -lt 3;$i++) {
        $old=$state.BackendId;$next=[char]([int][char]'b'+$i);$nextId=([string]$next)*64
        $replace={
            $manifest=Get-GeordiCaptureGenerationManifest $root
            $pending=@($manifest.captureHandoffs.Values|Where-Object {$_.logicalService -ceq 'backend' -and $_.status -ceq 'old-sealed'})
            $oldRecord=if($pending.Count -eq 1){Get-GeordiCaptureGenerationRecord -Manifest $manifest -Service backend -GenerationId ([string]$pending[0].oldGenerationId)}else{$null}
            if (!$oldRecord -or $oldRecord.terminalStatus -cne 'sealed' -or $oldRecord.containerId -cne $old) {throw 'M11 synthetic callback ran before exact old backend sealing.'}
            $state.Replacements.Add("M11:$old->$nextId")
            if($i -eq 0){$state.VmCurrentId=$data.VmM11Id}
            $state.BackendId=$nextId
        }.GetNewClosure()
        $null=Invoke-GeordiM11BackendGenerationReplacement -CaptureRoot $root -RepositoryRoot $state.RepositoryRoot `
            -Replace $replace -ResolveContainerIdentity $resolver -WaitReadiness {param($target)$state.Readiness.Add("$($target.service):$($target.containerId)")} `
            -Reason @('m11-initial-joint-reset','m11-pending-delivery-downtime','m11-terminal-delivery-application-restart')[$i] `
            -RequireVictoriaMetricsReplacement:($i -eq 0) -StartFollower {param($o,$e,$p,$a,$t)
                $state.Pid++;$started=[DateTimeOffset]::UtcNow.ToString('o');$rec=[ordered]@{id=$state.Pid;name='synthetic-follower';startUtc=$started;containerId=$t.containerId;service=$t.service;project='geordi';createdUtc=$t.createdUtc}
                [IO.File]::WriteAllText($p,(ConvertTo-Json $rec -Compress),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($o,"synthetic-$($t.containerId)`n");[IO.File]::WriteAllText($e,'');$state.Alive[[string]$state.Pid]=$true
                return [pscustomobject]@{id=$state.Pid;name='synthetic-follower';startUtc=$started}}.GetNewClosure() `
            -TestProcessIdentity $testProcess -StopProcess $stopProcess -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
    }
    Add-GeordiCiMetricPhase $state 'm11-final' $state.VmCurrentId
    $data.BackendId=$state.BackendId;$data.BackendGenerationId=[string](Get-GeordiActiveCaptureGenerationRecord -Manifest (Get-GeordiCaptureGenerationManifest $root) -Service backend).generationId
    $data.CollectorGenerationId=[string](Get-GeordiActiveCaptureGenerationRecord -Manifest (Get-GeordiCaptureGenerationManifest $root) -Service 'otel-collector').generationId
    $data.M11BackendGenerations=4;$data.M11Handoffs=3
    [IO.File]::WriteAllText($MetadataPath,(ConvertTo-Json -InputObject $data -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Write-Output 'ordered_worker=M11_PRODUCER_PRESERVED'
}

function Invoke-GeordiCiM12Consumer {
    $root=[IO.Path]::GetFullPath($CaptureRoot);$data=Get-Content -LiteralPath $MetadataPath -Raw|ConvertFrom-Json -AsHashtable
    $state=New-GeordiCiStageState $root $data;$state.BackendId=[string]$data.BackendId;$state.CollectorId=[string]$data.CollectorId
    $state.VmCurrentId=[string]$data.VmM11Id
    # Reconstruct liveness only from the persisted exact follower records in the active manifest.
    $loaded=Get-GeordiCaptureGenerationManifest $root
    foreach($service in @('backend','otel-collector')) {
        $active=@($loaded.captureGenerations[$service]|Where-Object terminalStatus -ceq 'capturing')
        if($active.Count -ne 1){throw "M12 worker found no unique persisted active $service generation."}
        $disk=Get-Content -LiteralPath $active[0].processRecordPath -Raw|ConvertFrom-Json -AsHashtable
        if($disk.containerId -cne $active[0].containerId -or $disk.service -cne $service){throw 'M12 worker rejected a persisted follower/container mismatch.'}
        $state.Alive[[string]$disk.id]=$true
    }
    $volumes=@{'geordi_m11-alert-lifecycle-data'=[pscustomobject]@{Name='geordi_m11-alert-lifecycle-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-alert-lifecycle-data'}};
        'geordi_m11-victoriametrics-data'=[pscustomobject]@{Name='geordi_m11-victoriametrics-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-victoriametrics-data'}}}
    $resolver={param($service)switch($service){'backend'{New-GeordiCiIdentity $state 'backend' $state.BackendId};'victoriametrics'{New-GeordiCiIdentity $state 'victoriametrics' $state.VmCurrentId};'otel-collector'{New-GeordiCiIdentity $state 'otel-collector' $state.CollectorId};default{throw 'Unexpected M12 identity lookup.'}}}.GetNewClosure()
    $inspect={param($name)if($volumes.ContainsKey($name)){$volumes[$name]}}.GetNewClosure()
    $testFollower={param($record)[bool]$state.Alive[[string]$record.id] -and $record.containerId -match '^[a-f0-9]{64}$'}.GetNewClosure()
    $resetFingerprintBox=[pscustomobject]@{Value=$null}
    $captureReset={param($transfer)
        Add-GeordiCiMetricPhase $state 'm12-reset' $transfer.VictoriaMetricsContainerId
        $resetFingerprintBox.Value=New-GeordiCiMetricFingerprint $state 'm12-reset' $transfer.VictoriaMetricsContainerId
    }.GetNewClosure()
    $transfer=Invoke-GeordiM11M12FixtureTransferConsumer -CaptureRoot $root -RepositoryRoot $state.RepositoryRoot `
        -ResolveIdentity $resolver -InspectVolume $inspect -TestFollowerProcess $testFollower -ExpectedVolumes (Get-GeordiM11TransferVolumeAllowlist) -CaptureM12Reset $captureReset
    # Prove canonical reset reuse is authenticated, with no second capture attempt.
    $resetBefore=(Get-FileHash -LiteralPath (Join-Path $root 'victoriametrics-generations/m12-reset.snapshot.json') -Algorithm SHA256).Hash
    $captureCount=[pscustomobject]@{Count=0};$reuse=Ensure-GeordiM12ResetTransferEvidence -CaptureRoot $root -ExpectedVictoriaMetricsContainerId $transfer.VictoriaMetricsContainerId `
        -Capture {$captureCount.Count++}.GetNewClosure()
    Assert-M11M12Ci ($reuse.sourceContainerId -ceq $data.VmM11Id -and $captureCount.Count -eq 0 -and
        (Get-FileHash -LiteralPath (Join-Path $root 'victoriametrics-generations/m12-reset.snapshot.json') -Algorithm SHA256).Hash -ceq $resetBefore) 'm12-reset reuse recaptured or changed accepted evidence'
    if(!$resetFingerprintBox.Value){$resetFingerprintBox.Value=New-GeordiCiMetricFingerprint $state 'm12-reset' $data.VmM11Id}
    $resetFingerprint=$resetFingerprintBox.Value
    $m11Root=Join-Path $root 'victoriametrics-generations/m11-final.jsonl';$oldHash=(Get-FileHash -LiteralPath $m11Root -Algorithm SHA256).Hash

    $testProcess={param($record)[bool]$state.Alive[[string]$record.id]}.GetNewClosure()
    $stopProcess={param($record)$state.Alive[[string]$record.id]=$false}.GetNewClosure()
    $startFollower={param($o,$e,$p,$a,$t)
        $state.Pid++;$started=[DateTimeOffset]::UtcNow.ToString('o');$rec=[ordered]@{id=$state.Pid;name='synthetic-follower';startUtc=$started;containerId=$t.containerId;service=$t.service;project='geordi';createdUtc=$t.createdUtc}
        [IO.File]::WriteAllText($p,(ConvertTo-Json $rec -Compress),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($o,"synthetic-$($t.containerId)`n");[IO.File]::WriteAllText($e,'');$state.Alive[[string]$state.Pid]=$true
        $state.Starts.Add("$($t.service):$($t.containerId)");return [pscustomobject]@{id=$state.Pid;name='synthetic-follower';startUtc=$started}}.GetNewClosure()
    $readiness={param($target)$state.Readiness.Add("$($target.service):$($target.containerId)");if($target.containerId -cne $state.BackendId){throw 'M12 readiness did not bind the exact backend.'}}.GetNewClosure()
    $normal={param($repo,$overlay)$depRestart=if($overlay){$false}else{$true};return @{services=@{'otel-collector'=@{depends_on=@{victoriametrics=@{condition='service_healthy';restart=$true}};volumes=@()};
        backend=@{depends_on=@{'otel-collector'=@{condition='service_healthy';restart=$depRestart}}}};volumes=@{};networks=@{}}}.GetNewClosure()
    $collectorReplaceCount=[pscustomobject]@{Value=0}
    $invokeCompose={param($arguments,$description)
        if($description -cne 'M12 Collector controlled replacement' -or ($arguments -join ' ') -notmatch '--no-deps.*--force-recreate.*otel-collector'){throw 'M12 collector operation escaped its exact targeted replacement.'}
        $collectorReplaceCount.Value++;$old=$state.CollectorId;$state.CollectorId='e'*64
        if($old -ceq $state.CollectorId){throw 'Synthetic Collector replacement reused its identity.'}
    }.GetNewClosure()
    $resolveCollector={param($service)if($service -cne 'otel-collector'){throw 'Unexpected Collector lookup.'};New-GeordiCiIdentity $state 'otel-collector' $state.CollectorId}.GetNewClosure()
    $collectorResultBox=[pscustomobject]@{Value=$null}
    $replaceBackend={
        if($state.BackendId -cne $data.BackendId){throw 'M12 initial boundary did not inherit the exact M11 backend.'}
        $collectorResultBox.Value=Invoke-GeordiM12CollectorControlledReplacement -CaptureRoot $root -RepositoryRoot $state.RepositoryRoot `
            -RenderComposeConfiguration $normal -InvokeCompose $invokeCompose -ResolveContainerIdentity $resolveCollector `
            -StartFollower $startFollower -TestProcessIdentity $testProcess -StopProcess $stopProcess `
            -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
        $state.VmCurrentId='f'*64;$state.BackendId='e'*64;$state.Replacements.Add('M12:initial-fixture')
    }.GetNewClosure()
    $resolve={param($service)switch($service){'backend'{New-GeordiCiIdentity $state 'backend' $state.BackendId};'victoriametrics'{New-GeordiCiIdentity $state 'victoriametrics' $state.VmCurrentId};default{throw 'Unexpected backend lifecycle identity lookup.'}}}.GetNewClosure()
    $first=Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $root -RepositoryRoot $state.RepositoryRoot -EvidencePhase m12-reset `
        -Reason 'm12-initial-fixture-boundary' -Replace $replaceBackend -ResolveContainerIdentity $resolve -WaitForReadiness $readiness `
        -StartFollower $startFollower -TestFollowerProcess $testFollower -TestProcessIdentity $testProcess -StopProcess $stopProcess `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
    Assert-GeordiCiMetricFingerprint $state $resetFingerprint
    $state.VolumeRemovals.Add('geordi_m11-alert-lifecycle-data');$state.VolumeRemovals.Add('geordi_m11-victoriametrics-data')
    Add-GeordiCiMetricPhase $state 'm12-fixture-start' $state.VmCurrentId
    $fixtureFingerprint=New-GeordiCiMetricFingerprint $state 'm12-fixture-start' $state.VmCurrentId
    $replaceScheduler={$state.BackendId='f'*64;$state.Replacements.Add('M12:scheduler-enablement')}.GetNewClosure()
    $second=Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $root -RepositoryRoot $state.RepositoryRoot -EvidencePhase m12-fixture-start `
        -Reason 'm12-scheduler-enablement' -Replace $replaceScheduler -ResolveContainerIdentity $resolve -WaitForReadiness $readiness `
        -StartFollower $startFollower -TestFollowerProcess $testFollower -TestProcessIdentity $testProcess -StopProcess $stopProcess `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
    Assert-GeordiCiMetricFingerprint $state $resetFingerprint
    Assert-GeordiCiMetricFingerprint $state $fixtureFingerprint
    Add-GeordiCiMetricPhase $state 'm12-recovery-start' $state.VmCurrentId
    $recoveryFingerprint=New-GeordiCiMetricFingerprint $state 'm12-recovery-start' $state.VmCurrentId
    $beforeRecovery={param($old,$vm)
        $active=Get-GeordiActiveCaptureGenerationRecord -Manifest (Get-GeordiCaptureGenerationManifest $root) -Service backend
        if($active.containerId -cne $old.Id -or !$state.Alive[[string]$active.followerProcess.id] -or $vm.Id -cne $state.VmCurrentId){throw 'M12 pre-handoff recovery evidence lost exact active identities.'}
        $state.Events.AddRange([string[]]@('vm-stop','backend-outage-observed','lifecycle-state-verified'))
    }.GetNewClosure()
    $replaceRecovery={
        $manifest=Get-GeordiCaptureGenerationManifest $root;$pending=@($manifest.captureHandoffs.Values|Where-Object status -ceq 'old-sealed')
        if($pending.Count -ne 1){throw 'M12 recovery did not begin after one sealed old generation.'}
        $state.Events.AddRange([string[]]@('old-follower-sealed','backend-stop','vm-start','provider-firing','backend-recreate'))
        $state.BackendId='9'*64;$state.Replacements.Add('M12:provider-recovery')
    }.GetNewClosure()
    $third=Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $root -RepositoryRoot $state.RepositoryRoot -EvidencePhase m12-recovery-start `
        -Reason 'm12-provider-recovery' -Replace $replaceRecovery -ResolveContainerIdentity $resolve -WaitForReadiness $readiness -BeforeHandoff $beforeRecovery `
        -StartFollower $startFollower -TestFollowerProcess $testFollower -TestProcessIdentity $testProcess -StopProcess $stopProcess `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
    Assert-GeordiCiMetricFingerprint $state $resetFingerprint
    Assert-GeordiCiMetricFingerprint $state $fixtureFingerprint
    Assert-GeordiCiMetricFingerprint $state $recoveryFingerprint
    $backendGenerations=@((Get-GeordiCaptureGenerationManifest $root).captureGenerations.backend)
    $manifest=Get-GeordiCaptureGenerationManifest $root
    $backendGenerations=@($manifest.captureGenerations.backend)
    $backendHandoffs=@($manifest.captureHandoffs.Values|Where-Object logicalService -ceq backend)
    Assert-M11M12Ci ($backendGenerations.Count -eq 7 -and $backendHandoffs.Count -eq 6 -and @($backendHandoffs|Where-Object status -cne complete).Count -eq 0) 'combined generation graph does not contain seven ordered backend generations/six completed handoffs'
    Assert-M11M12Ci ($first.OldContainerId -ceq $data.BackendId -and $second.OldContainerId -ceq $first.NewContainerId -and $third.OldContainerId -ceq $second.NewContainerId -and $third.NewContainerId -ceq ('9'*64)) 'combined M11->M12 backend graph lost adjacency'
    Assert-M11M12Ci ($collectorReplaceCount.Value -eq 1 -and $collectorResultBox.Value -and $collectorResultBox.Value.NewContainerId -ceq ('e'*64)) 'M12 Collector transition count/identity differs from accepted design'
    Assert-M11M12Ci (@($manifest.captureHandoffs.Values|Where-Object status -in @('old-sealed','replacement-failed','new-generation-failed')).Count -eq 0) 'successful M11->M12 chain contains a partial handoff'
    $allBackendContainerIds=@($backendGenerations|ForEach-Object{[string]$_.containerId})
    Assert-M11M12Ci (@($allBackendContainerIds|Select-Object -Unique).Count -eq 7) 'backend generations reused a container ID'
    for($index=1;$index -lt $backendGenerations.Count;$index++) {
        $old=$backendGenerations[$index-1];$new=$backendGenerations[$index]
        $handoff=@($backendHandoffs|Where-Object {[string]$_.newGenerationId -ceq [string]$new.generationId})
        Assert-M11M12Ci ($handoff.Count -eq 1 -and $handoff[0].oldGenerationId -ceq $old.generationId -and
            $handoff[0].oldContainerId -ceq $old.containerId -and $handoff[0].newContainerId -ceq $new.containerId -and
            $handoff[0].status -ceq 'complete') 'handoff graph has a missing, duplicate, or non-adjacent reverse reference'
        $oldEnded=ConvertTo-GeordiCaptureUtcInstant -Value $handoff[0].oldCaptureEndedUtc -Field 'handoff.oldCaptureEndedUtc'
        $newStarted=ConvertTo-GeordiCaptureUtcInstant -Value $handoff[0].newCaptureStartedUtc -Field 'handoff.newCaptureStartedUtc'
        Assert-M11M12Ci ($oldEnded -le $newStarted -and [long]$handoff[0].gapDurationMilliseconds -ge 0) 'handoff chronology is inconsistent'
    }
    foreach($record in $backendGenerations) {
        $disk=Get-Content -LiteralPath $record.processRecordPath -Raw|ConvertFrom-Json -AsHashtable
        Assert-M11M12Ci ($disk.containerId -ceq $record.containerId -and $disk.service -ceq 'backend' -and $disk.project -ceq 'geordi') 'backend follower is not bound to its exact recorded container'
        if($record.terminalStatus -ceq 'sealed') {
            Assert-M11M12Ci ((Get-FileHash -LiteralPath $record.capturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $record.sha256 -and
                (Get-FileHash -LiteralPath $record.stderrCapturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $record.stderrSha256) 'sealed backend history/follower integrity changed'
        }
    }
    Assert-M11M12Ci ((Get-FileHash -LiteralPath $m11Root -Algorithm SHA256).Hash -ceq $oldHash) 'M12 mutated immutable M11 final metric evidence'
    $phaseBindings=@{ 'm11-final'=$data.VmM11Id;'m12-reset'=$data.VmM11Id;'m12-fixture-start'=$state.VmCurrentId;'m12-recovery-start'=$state.VmCurrentId }
    foreach($phase in $phaseBindings.Keys){
        $snapshot=Join-Path $root "victoriametrics-generations/$phase.jsonl";$ledgerPath=Join-Path $root "victoriametrics-generations/$phase.snapshot.json"
        $ledger=Get-Content -LiteralPath $ledgerPath -Raw|ConvertFrom-Json -AsHashtable
        Assert-M11M12Ci ($ledger.sourceContainerId -ceq $phaseBindings[$phase] -and $ledger.complete -and $ledger.runStartBound) "$phase metric evidence is bound to wrong VM or incomplete"
        [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath -Captures ([string[]]((Get-GeordiCaptureGenerationManifest $root).additionalSources|Where-Object channel -ceq victoriametrics|ForEach-Object captures)))
    }
    $manifest=Get-GeordiCaptureGenerationManifest $root
    $collectorGens=@($manifest.captureGenerations['otel-collector']);$collectorHandoffs=@($manifest.captureHandoffs.Values|Where-Object logicalService -ceq 'otel-collector')
    Assert-M11M12Ci ($collectorGens.Count -eq 2 -and $collectorHandoffs.Count -eq 1 -and $collectorHandoffs[0].status -ceq 'complete' -and $collectorGens[0].terminalStatus -ceq 'sealed' -and $collectorGens[1].terminalStatus -ceq 'capturing') 'M12 Collector continuity did not produce exactly one accepted replacement handoff'
    Assert-M11M12Ci ($collectorGens[0].containerId -cne $collectorGens[1].containerId -and
        (Get-Content -LiteralPath $collectorGens[0].processRecordPath -Raw|ConvertFrom-Json -AsHashtable).containerId -ceq $collectorGens[0].containerId -and
        (Get-Content -LiteralPath $collectorGens[1].processRecordPath -Raw|ConvertFrom-Json -AsHashtable).containerId -ceq $collectorGens[1].containerId -and
        (Get-FileHash -LiteralPath $collectorGens[0].capturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $collectorGens[0].sha256) `
        'Collector replacement did not preserve exact follower binding and sealed capture integrity'
    Assert-M11M12Ci ($state.VolumeRemovals.Count -eq 2 -and @($state.VolumeRemovals|Where-Object {$_ -in @('geordi_m19-alert-lifecycle-data','geordi_m19-victoriametrics-data')}).Count -eq 0) 'synthetic fixture ownership touched protected M19 volumes'
    foreach($fingerprint in @($resetFingerprint,$fixtureFingerprint,$recoveryFingerprint)) { Assert-GeordiCiMetricFingerprint $state $fingerprint }
    $sources=@($manifest.additionalSources|Where-Object channel -ceq 'victoriametrics')
    $resetSnapshot=[IO.Path]::GetFullPath((Join-Path $root 'victoriametrics-generations/m12-reset.jsonl'))
    $resetLedger=[IO.Path]::GetFullPath((Join-Path $root 'victoriametrics-generations/m12-reset.snapshot.json'))
    Assert-M11M12Ci (@($sources[0].captures|Where-Object{[IO.Path]::GetFullPath([string]$_) -ceq $resetSnapshot}).Count -eq 1 -and
        @($sources[0].captures|Where-Object{[IO.Path]::GetFullPath([string]$_) -ceq $resetLedger}).Count -eq 1) 'm12-reset is not registered exactly once in persisted metric evidence'
    Write-Output 'ordered_cross_process_transfer=PASS M11_preserved=true M12_reloaded=true transfer_authenticated=true'
    Write-Output 'combined_generation_graph=PASS backend_generations=7 backend_handoffs=6 collector_generations=2 collector_handoffs=1'
    Write-Output 'metric_phase_order=PASS m11-final=VM_M11 m12-reset=VM_M11 m12-fixture-start=VM_M12 m12-recovery-start=VM_M12 immutable=true'
}

function Test-GeordiM11M12CiOrderedOffline {
    $ciPath=Join-Path (Split-Path -Parent $PSScriptRoot) '.gitlab-ci.yml'
    $contract=Get-GeordiM11M12CiContract ([IO.File]::ReadAllLines($ciPath))
    Assert-M11M12Ci ($contract.M11.Arguments -contains '-PreserveFixtureForNextStage' -and
        $contract.M12.Arguments -contains '-ConsumeTransferredM11Fixture' -and $contract.M12.Arguments -contains '-ApplyM12BackendGeneration') `
        'ordered synthetic stages are not driven by the activated authoritative CI flag contract'
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-capture-ci-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root);$metadata=Join-Path $root 'ordered-metadata.json'
    try {
        $pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
        $producerArgs=@('-NoLogo','-NoProfile','-File',$PSCommandPath,'-Case','ProducerWorker','-CaptureRoot',$root,'-MetadataPath',$metadata,'-PreserveFixtureForNextStage')
        $producerOutput=@(& $pwsh @producerArgs 2>&1);$producerExit=$LASTEXITCODE
        if($producerExit -ne 0){throw ('M11 synthetic producer process failed: '+(($producerOutput|ForEach-Object{[string]$_}) -join ' '))}
        Assert-M11M12Ci (Test-Path -LiteralPath $metadata -PathType Leaf) 'M11 producer did not persist transfer metadata before process exit'
        $producerManifest=Get-GeordiCaptureGenerationManifest $root
        $active=Get-GeordiActiveCaptureGenerationRecord -Manifest $producerManifest -Service backend
        Assert-M11M12Ci ($active.terminalStatus -ceq 'capturing' -and @($producerManifest.captureHandoffs.Values|Where-Object logicalService -ceq backend).Count -eq 3) `
            'M11 preserve stage did not leave its accepted active generation/three completed handoffs'
        $m11Snapshot=Join-Path $root 'victoriametrics-generations/m11-final.jsonl';$m11Ledger=Join-Path $root 'victoriametrics-generations/m11-final.snapshot.json'
        $m11Hashes=@{Snapshot=(Get-FileHash -LiteralPath $m11Snapshot -Algorithm SHA256).Hash;Ledger=(Get-FileHash -LiteralPath $m11Ledger -Algorithm SHA256).Hash}
        $m12Args=@('-NoLogo','-NoProfile','-File',$PSCommandPath,'-Case','ConsumerWorker','-CaptureRoot',$root,'-MetadataPath',$metadata,
            '-ConsumeTransferredM11Fixture','-ApplyM12BackendGeneration')
        $consumerOutput=@(& $pwsh @m12Args 2>&1);$consumerExit=$LASTEXITCODE
        if($consumerExit -ne 0){throw ('Fresh M12 synthetic consumer process failed: '+(($consumerOutput|ForEach-Object{[string]$_}) -join ' '))}
        $manifest=Get-GeordiCaptureGenerationManifest $root
        Assert-M11M12Ci ((Get-FileHash -LiteralPath $m11Snapshot -Algorithm SHA256).Hash -ceq $m11Hashes.Snapshot -and
            (Get-FileHash -LiteralPath $m11Ledger -Algorithm SHA256).Hash -ceq $m11Hashes.Ledger) 'M12 process changed immutable M11 final snapshot/ledger'
        Write-Output 'ordered_offline_positive=PASS authoritative_flags=true separate_pwsh_processes=true persisted_state_reloaded=true'
        Write-Output 'ordered_offline_graph=PASS backend_generations=7 backend_handoffs=6 collector_handoffs=1 m12_reset_exactly_once=true'
        Write-Output 'ordered_offline_metric_phases=PASS phases=m11-final,m12-reset,m12-fixture-start,m12-recovery-start immutable=true'
        Write-Output 'ordered_offline_protected_state=PASS protected_volumes_touched=false'
    } finally { Remove-GeordiCiOfflineRoot $root }
}

function Get-GeordiCiScriptItems([string[]] $Lines) {
    $jobStart=-1
    for($i=0;$i -lt $Lines.Count;$i++) {
        if($Lines[$i] -match '^local_stack_smoke:\s*(?:#.*)?$') { $jobStart=$i;break }
    }
    if($jobStart -lt 0) { throw 'Authoritative local_stack_smoke job is missing.' }
    $jobEnd=$Lines.Count
    for($i=$jobStart+1;$i -lt $Lines.Count;$i++) {
        if($Lines[$i] -match '^[A-Za-z0-9_.-]+:\s*(?:#.*)?$') { $jobEnd=$i;break }
    }
    $scriptStart=-1
    for($i=$jobStart+1;$i -lt $jobEnd;$i++) {
        if($Lines[$i] -match '^  script:\s*(?:#.*)?$') { $scriptStart=$i;break }
    }
    if($scriptStart -lt 0) { throw 'Authoritative local_stack_smoke script list is missing.' }
    $items=[Collections.Generic.List[object]]::new()
    for($i=$scriptStart+1;$i -lt $jobEnd;$i++) {
        if($Lines[$i] -match '^    - (.*)$') {
            $items.Add([pscustomobject]@{LineIndex=$i;Text=[string]$Matches[1]})
            continue
        }
        if($Lines[$i] -match '^  [A-Za-z0-9_-]+:') { break }
        if($Lines[$i] -match '^    -\s*$') { throw 'Unsupported empty YAML script item.' }
    }
    return $items.ToArray()
}

function ConvertFrom-GeordiCiScalar([string] $Scalar) {
    $value=$Scalar.Trim()
    if($value.Length -ge 2 -and $value[0] -ceq "'" -and $value[$value.Length-1] -ceq "'") {
        return $value.Substring(1,$value.Length-2).Replace("''", "'")
    }
    if($value.Length -ge 2 -and $value[0] -ceq '"' -and $value[$value.Length-1] -ceq '"') {
        return [string](ConvertFrom-Json -InputObject $value -ErrorAction Stop)
    }
    return $value
}

function Get-GeordiCiAstValue($Ast) {
    if($Ast -is [Management.Automation.Language.StringConstantExpressionAst]) { return [string]$Ast.Value }
    if($Ast -is [Management.Automation.Language.ConstantExpressionAst]) { return [string]$Ast.Value }
    return $null
}

function Get-GeordiCiPowerShellInvocations([object[]] $Items) {
    $result=[Collections.Generic.List[object]]::new()
    foreach($item in $Items) {
        $scalar=ConvertFrom-GeordiCiScalar ([string]$item.Text)
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($scalar,[ref]$tokens,[ref]$parseErrors)
        if($parseErrors.Count -gt 0) { throw 'A local_stack_smoke command scalar is not valid PowerShell syntax.' }
        $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))
        foreach($command in $commands) {
            $name=[IO.Path]::GetFileName([string]$command.GetCommandName())
            if($name -ine 'pwsh' -and $name -ine 'pwsh.exe') { continue }
            $argv=[Collections.Generic.List[string]]::new()
            $parameters=[Collections.Generic.List[object]]::new()
            foreach($element in $command.CommandElements) {
                if($element -is [Management.Automation.Language.CommandParameterAst]) {
                    $parameters.Add([pscustomobject]@{Name=[string]$element.ParameterName;HasAttachedArgument=($null -ne $element.Argument);
                        AttachedArgumentAst=$element.Argument;Extent=$element.Extent})
                    $argv.Add('-'+[string]$element.ParameterName)
                    if($null -ne $element.Argument) { $argumentValue=Get-GeordiCiAstValue $element.Argument;if($null -eq $argumentValue){$argv.Add('<nonliteral>')}else{$argv.Add($argumentValue)} }
                } else {
                    $elementValue=Get-GeordiCiAstValue $element
                    if($null -eq $elementValue) { $argv.Add('<nonliteral>') } else { $argv.Add($elementValue) }
                }
            }
            $fileIndex=-1
            for($j=1;$j -lt $argv.Count;$j++){if($argv[$j] -ieq '-File'){$fileIndex=$j;break}}
            if($fileIndex -lt 0 -or $fileIndex+1 -ge $argv.Count) { continue }
            $script=([string]$argv[$fileIndex+1]).Replace('\','/').TrimStart('./')
            $scriptArguments=@();if($fileIndex+2 -lt $argv.Count){$scriptArguments=@($argv[($fileIndex+2)..($argv.Count-1)])}
            $result.Add([pscustomobject]@{LineIndex=$item.LineIndex;Script=$script;Arguments=$scriptArguments;Parameters=$parameters.ToArray();Command=[string]$item.Text})
        }
    }
    return $result.ToArray()
}

function Get-GeordiM11M12CiContract([string[]] $Lines) {
    $items=@(Get-GeordiCiScriptItems $Lines)
    $invocations=@(Get-GeordiCiPowerShellInvocations $items)
    $semantic=@('scripts/verify-alert-lifecycle.ps1','scripts/verify-notification-delivery.ps1',
        'scripts/verify-alert-scheduling.ps1','scripts/verify-alert-scheduling-overlap.ps1',
        'scripts/verify-alert-routing.ps1','scripts/verify-alert-history.ps1')
    $ordered=@($invocations | Where-Object { $_.Script -in $semantic })
    if($ordered.Count -ne $semantic.Count) { throw 'Authoritative alert smoke sequence has a missing or duplicate semantic stage.' }
    for($i=0;$i -lt $semantic.Count;$i++) {
        if($ordered[$i].Script -cne $semantic[$i]) { throw 'Authoritative M9-M14 smoke order differs from the required semantic chain.' }
    }
    $m11=@($ordered | Where-Object Script -ceq 'scripts/verify-notification-delivery.ps1')
    $m12=@($ordered | Where-Object Script -ceq 'scripts/verify-alert-scheduling.ps1')
    if($m11.Count -ne 1 -or $m12.Count -ne 1 -or $m12[0].LineIndex -ne ($m11[0].LineIndex+1)) {
        throw 'M11 and M12 must each run once and occupy adjacent authoritative script entries.'
    }
    foreach($entry in @($m11[0],$m12[0])) {
        $timeoutIndexes=@(for($i=0;$i -lt $entry.Arguments.Count;$i++){if($entry.Arguments[$i] -ceq '-TimeoutSeconds'){$i}})
        if($timeoutIndexes.Count -ne 1 -or $timeoutIndexes[0]+1 -ge $entry.Arguments.Count -or $entry.Arguments[$timeoutIndexes[0]+1] -cne '300') {
            throw 'M11/M12 timeout differs from the accepted authoritative 300-second setting.'
        }
    }
    Assert-GeordiCiUniqueBareSwitch $m11[0] 'PreserveFixtureForNextStage'
    Assert-GeordiCiNoSwitch $m11[0] 'ConsumeTransferredM11Fixture'
    Assert-GeordiCiNoSwitch $m11[0] 'ApplyM12BackendGeneration'
    Assert-GeordiCiUniqueBareSwitch $m12[0] 'ConsumeTransferredM11Fixture'
    Assert-GeordiCiUniqueBareSwitch $m12[0] 'ApplyM12BackendGeneration'
    Assert-GeordiCiNoSwitch $m12[0] 'PreserveFixtureForNextStage'
    if($m11[0].Arguments -contains '-ConsumeTransferredM11Fixture' -or $m11[0].Arguments -contains '-ApplyM12BackendGeneration' -or
        $m12[0].Arguments -contains '-PreserveFixtureForNextStage') {
        throw 'Authoritative CI has missing, partial, duplicate, or cross-wired M11/M12 transfer flags.'
    }
    return [pscustomobject]@{Items=$items;Invocations=$invocations;M11=$m11[0];M12=$m12[0];Semantic=$ordered}
}

function Get-GeordiCiNamedParameters($Invocation,[string] $Name) {
    return @($Invocation.Parameters|Where-Object{$_.Name -ieq $Name})
}

function Assert-GeordiCiUniqueBareSwitch($Invocation,[string] $Name) {
    $matches=@(Get-GeordiCiNamedParameters $Invocation $Name)
    if($matches.Count -ne 1 -or $matches[0].HasAttachedArgument) {
        throw "Required CI activation switch must occur exactly once as a bare parameter: -$Name"
    }
}

function Assert-GeordiCiNoSwitch($Invocation,[string] $Name) {
    if(@(Get-GeordiCiNamedParameters $Invocation $Name).Count -ne 0) {
        throw "CI activation switch is cross-wired into the wrong stage: -$Name"
    }
}

function Test-GeordiCiContractMutation([string] $Name,[string[]] $Lines,[scriptblock] $Mutate) {
    $changed=[Collections.Generic.List[string]]::new();$changed.AddRange([string[]]$Lines)
    & $Mutate $changed
    Assert-M11M12Ci (($changed.ToArray() -join "`n") -cne ($Lines -join "`n")) "CI negative fixture mutation was a no-op: $Name"
    $rejected=$false
    try { [void](Get-GeordiM11M12CiContract $changed.ToArray()) } catch { $rejected=$true }
    Assert-M11M12Ci $rejected "negative authoritative CI case was accepted: $Name"
    Write-Output "ci_negative=PASS case=$Name rejected=true"
}

function Test-GeordiM11M12CiContract {
    $path=Join-Path (Split-Path -Parent $PSScriptRoot) '.gitlab-ci.yml'
    $lines=[IO.File]::ReadAllLines($path)
    $contract=Get-GeordiM11M12CiContract $lines
    Assert-M11M12Ci ($contract.M11.Arguments -contains '-PreserveFixtureForNextStage') 'M11 preserve flag missing from authoritative CI argv'
    Assert-M11M12Ci ($contract.M12.Arguments -contains '-ConsumeTransferredM11Fixture' -and
        $contract.M12.Arguments -contains '-ApplyM12BackendGeneration') 'M12 transfer/apply flags missing from authoritative CI argv'
    Assert-M11M12Ci ($contract.Semantic.Count -eq 6 -and $contract.Semantic[0].Script -ceq 'scripts/verify-alert-lifecycle.ps1' -and
        $contract.Semantic[-1].Script -ceq 'scripts/verify-alert-history.ps1') 'authoritative six-stage alert order was not parsed'
    Write-Output 'ci_atomic_flags=PASS m11_preserve=true m12_consume_apply=true authoritative_invocations=true'
    Write-Output 'ci_order=PASS lifecycle,notification,scheduling,scheduling-overlap,routing,history m11_m12_adjacent=true'
    Write-Output 'ci_timeouts=PASS M11=300 M12=300'
}

function Test-GeordiM11M12CiNegativeMatrix {
    $lines=[IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $PSScriptRoot) '.gitlab-ci.yml'))
    $contract=Get-GeordiM11M12CiContract $lines
    $m11Line=$contract.M11.LineIndex;$m12Line=$contract.M12.LineIndex
    Test-GeordiCiContractMutation 'A-m11-preserve-absent' $lines {param($copy)$copy[$m11Line]=$copy[$m11Line].Replace(' -PreserveFixtureForNextStage','')}.GetNewClosure()
    Test-GeordiCiContractMutation 'B-m12-consume-absent' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace(' -ConsumeTransferredM11Fixture','')}.GetNewClosure()
    Test-GeordiCiContractMutation 'C-m12-apply-absent' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace(' -ApplyM12BackendGeneration','')}.GetNewClosure()
    Test-GeordiCiContractMutation 'D-apply-without-consume' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace(' -ConsumeTransferredM11Fixture','')}.GetNewClosure()
    Test-GeordiCiContractMutation 'E-nonadjacent-semantic-chain' $lines {param($copy)$tmp=$copy[$m12Line];$copy[$m12Line]=$copy[$m12Line+1];$copy[$m12Line+1]=$tmp}.GetNewClosure()
    Test-GeordiCiContractMutation 'F-m12-before-m11' $lines {param($copy)$tmp=$copy[$m12Line];$copy[$m12Line]=$copy[$m11Line];$copy[$m11Line]=$tmp}.GetNewClosure()
    Test-GeordiCiContractMutation 'G-duplicate-m11' $lines {param($copy)$copy.Insert($m12Line,$copy[$m11Line])}.GetNewClosure()
    Test-GeordiCiContractMutation 'H-duplicate-m12' $lines {param($copy)$copy.Insert($m12Line+1,$copy[$m12Line])}.GetNewClosure()
    Test-GeordiCiContractMutation 'I-flags-only-in-comment' $lines {param($copy)
        $copy[$m11Line]=$copy[$m11Line].Replace(' -PreserveFixtureForNextStage','')
        $copy[$m12Line]=$copy[$m12Line].Replace(' -ConsumeTransferredM11Fixture','').Replace(' -ApplyM12BackendGeneration','')
        $copy.Insert($copy.Count,'# pwsh -File ./scripts/verify-notification-delivery.ps1 -PreserveFixtureForNextStage')
        $copy.Insert($copy.Count,'# pwsh -File ./scripts/verify-alert-scheduling.ps1 -ConsumeTransferredM11Fixture -ApplyM12BackendGeneration')
    }.GetNewClosure()
    Test-GeordiCiContractMutation 'J-timeout-widened' $lines {param($copy)$copy[$m11Line]=$copy[$m11Line].Replace('-TimeoutSeconds 300','-TimeoutSeconds 360')}.GetNewClosure()
    Test-GeordiCiContractMutation 'K-m11-preserve-comment-only' $lines {param($copy)
        $copy[$m11Line]=$copy[$m11Line].Replace(' -PreserveFixtureForNextStage','') + ' # -PreserveFixtureForNextStage'
    }.GetNewClosure()
    Test-GeordiCiContractMutation 'L-m12-consume-comment-only' $lines {param($copy)
        $copy[$m12Line]=$copy[$m12Line].Replace(' -ConsumeTransferredM11Fixture','') + ' # -ConsumeTransferredM11Fixture'
    }.GetNewClosure()
    Test-GeordiCiContractMutation 'M-m12-apply-comment-only' $lines {param($copy)
        $copy[$m12Line]=$copy[$m12Line].Replace(' -ApplyM12BackendGeneration','') + ' # -ApplyM12BackendGeneration'
    }.GetNewClosure()
    Test-GeordiCiContractMutation 'N-required-flag-in-other-job-only' $lines {param($copy)
        $copy[$m11Line]=$copy[$m11Line].Replace(' -PreserveFixtureForNextStage','')
        $copy.Add('unrelated_job:');$copy.Add('  script:');$copy.Add('    - pwsh -NoProfile -File ./scripts/verify-notification-delivery.ps1 -PreserveFixtureForNextStage')
    }.GetNewClosure()
    Test-GeordiCiContractMutation 'O-required-flag-in-unrelated-command' $lines {param($copy)
        $copy[$m11Line]=$copy[$m11Line].Replace(' -PreserveFixtureForNextStage','')
        $copy.Insert($m11Line+1,'    - pwsh -NoProfile -File ./scripts/unrelated.ps1 -PreserveFixtureForNextStage')
    }.GetNewClosure()
    Test-GeordiCiContractMutation 'P-required-flag-in-echo-string' $lines {param($copy)
        $copy[$m11Line]=$copy[$m11Line].Replace(' -PreserveFixtureForNextStage','')
        $copy.Insert($m11Line+1,'    - pwsh -NoProfile -Command "Write-Output ''-PreserveFixtureForNextStage''"')
    }.GetNewClosure()
    Test-GeordiCiContractMutation 'Q-m11-preserve-false' $lines {param($copy)$copy[$m11Line]=$copy[$m11Line].Replace('-PreserveFixtureForNextStage','-PreserveFixtureForNextStage:$false')}.GetNewClosure()
    Test-GeordiCiContractMutation 'R-m12-consume-false' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace('-ConsumeTransferredM11Fixture','-ConsumeTransferredM11Fixture:$false')}.GetNewClosure()
    Test-GeordiCiContractMutation 'S-m12-apply-false' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace('-ApplyM12BackendGeneration','-ApplyM12BackendGeneration:$false')}.GetNewClosure()
    Test-GeordiCiContractMutation 'T-m11-preserve-true' $lines {param($copy)$copy[$m11Line]=$copy[$m11Line].Replace('-PreserveFixtureForNextStage','-PreserveFixtureForNextStage:$true')}.GetNewClosure()
    Test-GeordiCiContractMutation 'U-m12-consume-true' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace('-ConsumeTransferredM11Fixture','-ConsumeTransferredM11Fixture:$true')}.GetNewClosure()
    Test-GeordiCiContractMutation 'V-m12-apply-true' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace('-ApplyM12BackendGeneration','-ApplyM12BackendGeneration:$true')}.GetNewClosure()
    Test-GeordiCiContractMutation 'W-bare-plus-false-duplicate' $lines {param($copy)$copy[$m11Line]=$copy[$m11Line].Replace('-PreserveFixtureForNextStage','-PreserveFixtureForNextStage -PreserveFixtureForNextStage:$false')}.GetNewClosure()
    Test-GeordiCiContractMutation 'X-duplicate-bare-switch' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace('-ConsumeTransferredM11Fixture','-ConsumeTransferredM11Fixture -ConsumeTransferredM11Fixture')}.GetNewClosure()
    Test-GeordiCiContractMutation 'Y-false-plus-true' $lines {param($copy)$copy[$m12Line]=$copy[$m12Line].Replace('-ApplyM12BackendGeneration','-ApplyM12BackendGeneration:$false -ApplyM12BackendGeneration:$true')}.GetNewClosure()
    Test-GeordiCiContractMutation 'Z-attached-expression' $lines {param($copy)$copy[$m11Line]=$copy[$m11Line].Replace('-PreserveFixtureForNextStage','-PreserveFixtureForNextStage:$env:CI_PRESERVE')}.GetNewClosure()
    Write-Output 'ci_partial_activation_matrix=PASS cases=A-Z comments_noncommands_and_switch_semantics_rejected=true'
}

if($Case -in @('SelfTest','CiContract')) { Test-GeordiM11M12CiContract }
if($Case -in @('SelfTest','NegativeMatrix')) { Test-GeordiM11M12CiNegativeMatrix }
if($Case -in @('SelfTest','MetricFingerprintNegatives')) { Test-GeordiCiMetricFingerprintNegatives }
if($Case -ceq 'ProducerWorker') {
    if(!$PreserveFixtureForNextStage){throw 'M11 synthetic producer requires the explicit preserve invocation contract.'}
    Invoke-GeordiCiM11Producer
    exit 0
}
if($Case -ceq 'ConsumerWorker') {
    if(!$ConsumeTransferredM11Fixture -or !$ApplyM12BackendGeneration){throw 'M12 synthetic consumer requires both explicit transfer/apply invocation flags.'}
    Invoke-GeordiCiM12Consumer
    exit 0
}
if($Case -ceq 'OrderedOffline') { Test-GeordiM11M12CiOrderedOffline }
