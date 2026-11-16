[CmdletBinding()]
param([ValidateSet('SelfTest','ConsumerWorker','M11Standalone','M12Standalone','M12AstNegatives','ConsumerOnly')][string] $Case='SelfTest',[string] $CaptureRoot,[string] $FixtureMetadataPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM11M12FixtureTransfer.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM12CollectorReplacement.ps1')

function Assert-M11M12([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "M11→M12 fixture-transfer regression failed: $Message" }
}

function New-M11M12SyntheticRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-capture-transfer-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $runStart = [DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o')
    $manifest = [ordered]@{ version=2;root=$root;runId='synthetic-m11-m12-transfer';startedUtc=$runStart
        captureStartedUtc=$runStart;captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};generationCaptureEvents=@{}
        additionalSources=@();captures=@();persistedMetricEvidenceBytes=0 }
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Root=$root;RepositoryRoot=$repositoryRoot;RunStart=$runStart;ManifestPath=(Join-Path $root 'manifest.json')
        BackendId=('a'*64);VmOldId=('b'*64);VmId=('c'*64);CollectorId=('d'*64);BackendGenerationId='';CollectorGenerationId=''
        Pid=72000;Alive=@{};VolumeInventory=@{};ExpectedVolumes=$null }
}

function Remove-M11M12SyntheticRoot([string] $Root) {
    if (!(Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object { $_.IsReadOnly=$false }
    Remove-Item -LiteralPath $Root -Recurse -Force
}

function New-M11M12SyntheticIdentity($Fixture,[string] $Service,[string] $Id) {
    return [pscustomobject]@{Id=$Id;Project='geordi';Service=$Service;WorkingDirectory=$Fixture.RepositoryRoot
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}
}

function Start-M11M12SyntheticGeneration($Fixture,[string] $Service,[string] $Id) {
    $identity=New-M11M12SyntheticIdentity $Fixture $Service $Id
    $startFollower={
        param($stdout,$stderr,$processRecord,$arguments,$target)
        $Fixture.Pid++
        $started=[DateTimeOffset]::UtcNow.ToString('o')
        $record=[ordered]@{id=$Fixture.Pid;name='synthetic-follower';startUtc=$started;containerId=[string]$target.containerId
            service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc}
        [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stdout,"capture-$($target.service)-$($target.containerId)`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
        $Fixture.Alive[[string]$Fixture.Pid]=$true
        return [pscustomobject]@{id=$Fixture.Pid;name='synthetic-follower';startUtc=$started}
    }.GetNewClosure()
    return [string](Start-GeordiCaptureGeneration -CaptureRoot $Fixture.Root -Service $Service -ContainerIdentity $identity `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' `
        -WorkingDirectory $Fixture.RepositoryRoot -StartFollower $startFollower)
}

function Add-M11M12SyntheticMetricLedger($Fixture,[string] $Phase,[string] $SourceContainerId) {
    $directory=Join-Path $Fixture.Root 'victoriametrics-generations'
    [void][IO.Directory]::CreateDirectory($directory)
    $snapshotPath=Join-Path $directory "$Phase.jsonl"
    $ledgerPath=Join-Path $directory "$Phase.snapshot.json"
    $intervalStart=ConvertTo-GeordiCaptureUtcInstant -Value $Fixture.RunStart -Field 'synthetic.captureStartedUtc'
    $intervalEnd=[DateTimeOffset]::UtcNow.AddSeconds(1)
    $sampleTime=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $sample=@{metric=@{'__name__'='geordi_security_authentication_attempts_total';'service.name'='geordi-backend';'geordi.telemetry.origin'='platform'}
        timestamps=@($sampleTime);values=@('1')} | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($snapshotPath,$sample+"`n",[Text.UTF8Encoding]::new($false))
    $bytes=[long](Get-Item -LiteralPath $snapshotPath).Length
    $ledger=[ordered]@{intervalStartUtc=$intervalStart.ToString('o');intervalEndUtc=$intervalEnd.ToString('o');source='victoriametrics-export'
        complete=$true;runStartBound=$true;series=1;samples=1;bytes=$bytes;sourceService='victoriametrics';sourceContainerId=$SourceContainerId
        snapshotSha256=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    [IO.File]::WriteAllText($ledgerPath,(ConvertTo-Json -InputObject $ledger -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $Fixture.Root
    $sources=@($manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
    if ($sources.Count -eq 0) {
        $manifest.additionalSources=@(@{channel='victoriametrics';control='geordi_security_authentication_attempts_total';captures=@()})
        $sources=@($manifest.additionalSources)
    }
    $sources[0].captures=@(@($sources[0].captures)+@($snapshotPath,$ledgerPath))
    $manifest.persistedMetricEvidenceBytes=[long](@($sources[0].captures | ForEach-Object { if(Test-Path -LiteralPath $_ -PathType Leaf){(Get-Item -LiteralPath $_).Length}else{0} } | Measure-Object -Sum).Sum)
    Write-GeordiM19ManifestAtomic -Path $Fixture.ManifestPath -Manifest $manifest
}

function New-M11M12SyntheticFixture {
    $fixture=New-M11M12SyntheticRoot
    try {
        $fixture.BackendGenerationId=Start-M11M12SyntheticGeneration $fixture 'backend' $fixture.BackendId
        $fixture.CollectorGenerationId=Start-M11M12SyntheticGeneration $fixture 'otel-collector' $fixture.CollectorId
        Add-M11M12SyntheticMetricLedger $fixture 'm11-reset' $fixture.VmOldId
        Add-M11M12SyntheticMetricLedger $fixture 'm11-final' $fixture.VmId
        $fixture.VolumeInventory=@{
            'geordi_m11-alert-lifecycle-data'=[pscustomobject]@{Name='geordi_m11-alert-lifecycle-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-alert-lifecycle-data'}}
            'geordi_m11-victoriametrics-data'=[pscustomobject]@{Name='geordi_m11-victoriametrics-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-victoriametrics-data'}}
        }
        $fixture.ExpectedVolumes=Get-GeordiM11TransferVolumeAllowlist
        return $fixture
    } catch { Remove-M11M12SyntheticRoot $fixture.Root; throw }
}

function New-M11M12Adapters($Fixture,[string] $Failure='') {
    $resolver={
        param([string]$Service)
        if ($Failure -ceq 'backend-missing' -and $Service -ceq 'backend') { throw 'Synthetic backend absent.' }
        if ($Failure -ceq 'backend-ambiguous' -and $Service -ceq 'backend') { throw 'Synthetic backend ambiguous.' }
        if ($Failure -ceq 'vm-missing' -and $Service -ceq 'victoriametrics') { throw 'Synthetic VictoriaMetrics absent.' }
        $id= switch ($Service) {
            'backend' { if($Failure -ceq 'backend-id-mismatch'){('e'*64)}else{$Fixture.BackendId} }
            'victoriametrics' { if($Failure -ceq 'vm-id-mismatch'){('f'*64)}else{$Fixture.VmId} }
            'otel-collector' { if($Failure -ceq 'collector-mismatch'){('9'*64)}else{$Fixture.CollectorId} }
            default { throw 'Synthetic resolver received an unexpected service.' }
        }
        $identity=New-M11M12SyntheticIdentity $Fixture $Service $id
        if ($Failure -ceq 'backend-wrong-owner' -and $Service -ceq 'backend') { $identity.Project='other' }
        if ($Failure -ceq 'vm-wrong-owner' -and $Service -ceq 'victoriametrics') { $identity.Project='other' }
        return $identity
    }.GetNewClosure()
    $inspect={
        param([string]$Name)
        if ($Failure -ceq 'backend-volume-missing' -and $Name -ceq 'geordi_m11-alert-lifecycle-data') { return }
        if ($Failure -ceq 'vm-volume-missing' -and $Name -ceq 'geordi_m11-victoriametrics-data') { return }
        if ($Failure -in @('volume-owner-mismatch','protected-backend-volume','protected-vm-volume')) {
            if ($Failure -ceq 'protected-backend-volume' -and $Name -ceq 'geordi_m11-alert-lifecycle-data') {
                return [pscustomobject]@{Name='geordi_m19-alert-lifecycle-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m19-alert-lifecycle-data'}}
            }
            if ($Failure -ceq 'protected-vm-volume' -and $Name -ceq 'geordi_m11-victoriametrics-data') {
                return [pscustomobject]@{Name='geordi_m19-victoriametrics-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m19-victoriametrics-data'}}
            }
            $volume=$Fixture.VolumeInventory[$Name]
            if ($Failure -ceq 'volume-owner-mismatch') { $volume.Labels['com.docker.compose.project']='other' }
            return $volume
        }
        if (!$Fixture.VolumeInventory.ContainsKey($Name)) { return }
        return $Fixture.VolumeInventory[$Name]
    }.GetNewClosure()
    $testFollower={
        param($Record)
        if ($Failure -ceq 'backend-follower-missing' -and [string]$Record.service -ceq 'backend') { return $false }
        if ($Failure -ceq 'collector-mismatch' -and [string]$Record.service -ceq 'otel-collector') { return $false }
        return [int]$Record.id -gt 0 -and [string]$Record.project -ceq 'geordi' -and
            [string]$Record.service -in @('backend','otel-collector')
    }.GetNewClosure()
    return [pscustomobject]@{Resolve=$resolver;Inspect=$inspect;TestFollower=$testFollower}
}

function Set-M11M12Failure($Fixture,[string] $Failure) {
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $Fixture.Root
    $record=Get-GeordiCaptureGenerationRecord -Manifest $manifest -Service backend -GenerationId $Fixture.BackendGenerationId
    switch ($Failure) {
        'generation-sealed' { $record.terminalStatus='sealed' }
        'follower-missing' { $record.followerProcess=$null }
        'follower-wrong-container' {
            $disk=Get-Content -LiteralPath $record.processRecordPath -Raw | ConvertFrom-Json -AsHashtable
            $disk.containerId='e'*64
            [IO.File]::WriteAllText($record.processRecordPath,(ConvertTo-Json -InputObject $disk -Compress),[Text.UTF8Encoding]::new($false))
        }
    }
    if ($Failure -in @('generation-sealed','follower-missing')) { Write-GeordiM19ManifestAtomic -Path $Fixture.ManifestPath -Manifest $manifest }
    if ($Failure -eq 'm11-final-missing') { Remove-Item -LiteralPath (Join-Path $Fixture.Root 'victoriametrics-generations/m11-final.snapshot.json') -Force }
    if ($Failure -eq 'm11-final-hash-invalid') {
        $path=Join-Path $Fixture.Root 'victoriametrics-generations/m11-final.snapshot.json'
        $ledger=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable;$ledger.snapshotSha256='0'*64
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $ledger -Compress),[Text.UTF8Encoding]::new($false))
    }
    if ($Failure -eq 'm11-final-interval-invalid') {
        $path=Join-Path $Fixture.Root 'victoriametrics-generations/m11-final.snapshot.json'
        $ledger=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable;$ledger.intervalEndUtc=$Fixture.RunStart
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $ledger -Compress),[Text.UTF8Encoding]::new($false))
    }
}

function Invoke-M11M12TransferPositive($Fixture) {
    $adapters=New-M11M12Adapters $Fixture
    $resetCallback={ param($Transfer) Add-M11M12SyntheticMetricLedger $Fixture 'm12-reset' $Transfer.VictoriaMetricsContainerId }.GetNewClosure()
    return Invoke-GeordiM11M12FixtureTransferConsumer -CaptureRoot $Fixture.Root -RepositoryRoot $Fixture.RepositoryRoot `
        -ResolveIdentity $adapters.Resolve -InspectVolume $adapters.Inspect -TestFollowerProcess $adapters.TestFollower `
        -ExpectedVolumes $Fixture.ExpectedVolumes -CaptureM12Reset $resetCallback
}

function Test-M11M12SuccessfulCrossProcessTransfer {
    $fixture=New-M11M12SyntheticFixture
    try {
        $metadataPath=Join-Path $fixture.Root 'synthetic-identities.json'
        $metadata=[ordered]@{RepositoryRoot=$fixture.RepositoryRoot;RunStart=$fixture.RunStart;BackendId=$fixture.BackendId;BackendGenerationId=$fixture.BackendGenerationId
            VmId=$fixture.VmId;CollectorId=$fixture.CollectorId}
        [IO.File]::WriteAllText($metadataPath,(ConvertTo-Json -InputObject $metadata -Compress),[Text.UTF8Encoding]::new($false))
        $m11Snapshot=Join-Path $fixture.Root 'victoriametrics-generations/m11-final.jsonl'
        $m11Ledger=Join-Path $fixture.Root 'victoriametrics-generations/m11-final.snapshot.json'
        $snapshotHash=(Get-FileHash -LiteralPath $m11Snapshot -Algorithm SHA256).Hash
        $ledgerHash=(Get-FileHash -LiteralPath $m11Ledger -Algorithm SHA256).Hash
        $manifestBefore=Get-GeordiCaptureGenerationManifest -CaptureRoot $fixture.Root
        $handoffsBefore=@($manifestBefore.captureHandoffs.Keys)
        $pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
        $output=@(& $pwsh -NoLogo -NoProfile -File $PSCommandPath -Case ConsumerWorker `
            -CaptureRoot $fixture.Root -FixtureMetadataPath $metadataPath 2>&1)
        $exitCode=$LASTEXITCODE
        if ($exitCode -ne 0) { throw ('Fresh M12 consumer process failed: ' + (($output | ForEach-Object { [string]$_ }) -join ' ')) }
        $manifestAfter=Get-GeordiCaptureGenerationManifest -CaptureRoot $fixture.Root
        Assert-M11M12 ((Get-FileHash -LiteralPath $m11Snapshot -Algorithm SHA256).Hash -ceq $snapshotHash -and
            (Get-FileHash -LiteralPath $m11Ledger -Algorithm SHA256).Hash -ceq $ledgerHash) 'consumer modified immutable M11 final evidence'
        Assert-M11M12 ((@($manifestAfter.captureHandoffs.Keys) -join ',') -ceq ($handoffsBefore -join ',')) 'consumer created a transfer handoff'
        Assert-M11M12 (@($manifestAfter.additionalSources[0].captures | Where-Object { [string]$_ -like '*m12-reset*' }).Count -eq 2) `
            'fresh consumer did not publish m12-reset snapshot and ledger'
        Assert-M11M12 (!$manifestAfter.ContainsKey('transfer') -and !$manifestAfter.ContainsKey('transferId') -and
            !$manifestAfter.ContainsKey('transferGeneration')) 'consumer introduced a transfer schema/artifact'
        Write-Output 'transfer_cross_process_positive=PASS reloaded_manifest=true backend_follower_exact=true vm_m11final_exact=true volumes_owned=true collector_continuous=true m12_reset_bound=true'
        Write-Output 'transfer_m11_evidence_immutable=PASS no_handoff=true no_transfer_schema=true'
    } finally { Remove-M11M12SyntheticRoot $fixture.Root }
}

function Test-M11M12ResetIntervalBinding {
    $fixture=New-M11M12SyntheticFixture
    try {
        $null=Invoke-M11M12TransferPositive $fixture
        $ledgerPath=Join-Path $fixture.Root 'victoriametrics-generations/m12-reset.snapshot.json'
        $ledger=Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
        $ledger.intervalStartUtc=([DateTimeOffset]::Parse($fixture.RunStart).AddSeconds(1)).ToString('o')
        [IO.File]::WriteAllText($ledgerPath,(ConvertTo-Json -InputObject $ledger -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
        $rejected=$false
        try { [void](Assert-GeordiM12ResetTransferEvidence -CaptureRoot $fixture.Root -ExpectedVictoriaMetricsContainerId $fixture.VmId) }
        catch { $rejected=$true }
        Assert-M11M12 $rejected 'M12 reset evidence with a shifted run-start interval was accepted'
        Write-Output 'm12_reset_interval_binding=PASS interval_start_recomputed_against_manifest=true'
    } finally { Remove-M11M12SyntheticRoot $fixture.Root }
}

function Test-M12RejectsMixedTransferModes {
    $script=Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'
    foreach($arguments in @(@('-RunRecoveryBarrierSelfTest','-ConsumeTransferredM11Fixture'),@('-RunFixtureResetOnly','-ConsumeTransferredM11Fixture'))) {
        $null=& (Get-Command pwsh.exe -ErrorAction Stop).Source -NoLogo -NoProfile -File $script @arguments 2>$null
        Assert-M11M12 ($LASTEXITCODE -ne 0) "M12 accepted incompatible modes: $($arguments -join ',')"
    }
    Write-Output 'm12_mixed_transfer_modes=PASS rejection_precedes_all_early_return_modes=true'
}

function Test-M11M12ConsumerFailureMatrix {
    $cases=@('backend-missing','backend-ambiguous','backend-wrong-owner','backend-id-mismatch','generation-sealed',
        'follower-missing','follower-wrong-container','vm-missing','vm-wrong-owner','vm-id-mismatch','m11-final-missing',
        'm11-final-hash-invalid','m11-final-interval-invalid','backend-volume-missing','vm-volume-missing','volume-owner-mismatch',
        'protected-backend-volume','protected-vm-volume','collector-mismatch')
    foreach($case in $cases) {
        $fixture=New-M11M12SyntheticFixture
        try {
            Set-M11M12Failure $fixture $case
            $adapters=New-M11M12Adapters $fixture $case
            $before=Get-GeordiCaptureGenerationManifest -CaptureRoot $fixture.Root
            $beforeJson=ConvertTo-Json -InputObject $before -Depth 48 -Compress
            $captureCalls=[Collections.Generic.List[string]]::new()
            $capture={ param($Transfer) $captureCalls.Add('m12-reset') }.GetNewClosure()
            $rejected=$false
            try {
                Invoke-GeordiM11M12FixtureTransferConsumer -CaptureRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot `
                    -ResolveIdentity $adapters.Resolve -InspectVolume $adapters.Inspect -TestFollowerProcess $adapters.TestFollower `
                    -ExpectedVolumes $fixture.ExpectedVolumes -CaptureM12Reset $capture | Out-Null
            } catch { $rejected=$true }
            $after=Get-GeordiCaptureGenerationManifest -CaptureRoot $fixture.Root
            Assert-M11M12 ($rejected -and $captureCalls.Count -eq 0) "$case was accepted or m12-reset was invoked"
            Assert-M11M12 ((ConvertTo-Json -InputObject $after -Depth 48 -Compress) -ceq $beforeJson) "$case changed the manifest before transfer validation"
            Assert-M11M12 (@($after.captureHandoffs.Keys).Count -eq 0) "$case created a handoff"
        } finally { Remove-M11M12SyntheticRoot $fixture.Root }
        Write-Output "transfer_consumer_rejection=PASS case=$case no_m12_reset=true no_handoff=true"
    }
    Write-Output 'transfer_consumer_failure_matrix=PASS cases=19'
}

function Test-M11ProducerFailureAndStandaloneModes {
    $owned=$true;$mutated=$false
    Assert-M11M12 (Test-GeordiM11FixtureCleanupRequired -FixtureOwned $owned -MutationStarted $mutated -TransferCommitted $false) `
        'standalone M11 no longer cleans a successful fixture by default'
    Write-Output 'm11_standalone_cleanup=PASS default_false_flag_runs_existing_cleanup=true'
}

function Test-M11StandaloneDefaultOnly {
    $path=Join-Path $PSScriptRoot 'verify-notification-delivery.ps1'
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
    $parameter=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -ceq 'PreserveFixtureForNextStage'})
    Assert-M11M12 ($parameter.Count -eq 1 -and $parameter[0].StaticType.Name -ceq 'SwitchParameter') 'M11 preserve option is not an explicit default-false switch'
    Assert-M11M12 ((Test-GeordiM11FixtureCleanupRequired -FixtureOwned $true -MutationStarted $false -TransferCommitted $false)) `
        'standalone M11 default no longer selects its existing cleanup behavior'
    Write-Output 'm11_standalone_default=PASS preserve_flag_explicit_opt_in=true cleanup_default=true'
}

function Get-M12ConditionCore($Ast) {
    while($true) {
        if($Ast -is [Management.Automation.Language.PipelineAst]) {
            if($Ast.PipelineElements.Count -ne 1) { return $Ast }
            $Ast=$Ast.PipelineElements[0];continue
        }
        if($Ast -is [Management.Automation.Language.CommandExpressionAst]) { $Ast=$Ast.Expression;continue }
        if($Ast -is [Management.Automation.Language.ParenExpressionAst]) { $Ast=$Ast.Pipeline;continue }
        return $Ast
    }
}

function Replace-M12AstExtentExactlyOnce([string] $SourceText,$AstNode,[string] $ReplacementText) {
    Assert-M11M12 ($null -ne $AstNode) 'AST mutation node is null'
    $start=[int]$AstNode.Extent.StartOffset;$end=[int]$AstNode.Extent.EndOffset
    Assert-M11M12 ($start -ge 0 -and $end -ge $start -and $end -le $SourceText.Length) 'AST mutation extent is outside source bounds'
    $before=$SourceText.Substring(0,$start);$after=$SourceText.Substring($end)
    $mutated=$before+$ReplacementText+$after
    Assert-M11M12 ($mutated -cne $SourceText) 'AST replacement was a no-op'
    return $mutated
}

function Insert-M12AstTextAtOffset([string] $SourceText,[int] $Offset,[string] $InsertionText) {
    Assert-M11M12 ($Offset -ge 0 -and $Offset -le $SourceText.Length) 'AST insertion offset is outside source bounds'
    $mutated=$SourceText.Substring(0,$Offset)+$InsertionText+$SourceText.Substring($Offset)
    Assert-M11M12 ($mutated -cne $SourceText) 'AST insertion was a no-op'
    return $mutated
}

function Get-M12StandaloneAstNodes([string] $ScriptText) {
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($ScriptText,[ref]$tokens,[ref]$parseErrors)
    Assert-M11M12 ($parseErrors.Count -eq 0) 'M12 standalone AST fixture did not parse'
    $branches=[Collections.Generic.List[Management.Automation.Language.IfStatementAst]]::new()
    foreach($statement in @($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst]})) {
        $calls=@($statement.Clauses[0].Item2.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-M12TransferredFixtureConsumer'},$true))
        if($calls.Count -gt 0){$branches.Add($statement)}
    }
    Assert-M11M12 ($branches.Count -eq 1) 'cannot locate unique authoritative M12 consumer branch in mutation fixture'
    $consumer=$branches[0];$body=$consumer.Clauses[0].Item2
    $consumerCall=@($body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-M12TransferredFixtureConsumer'},$true))
    $preparationCalls=@($body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-M12TransferredFixturePreparation'},$true))
    $earlyBranches=@($body.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst]},$true)|Where-Object{
        @($_.Clauses[0].Item1.FindAll({param($child)$child -is [Management.Automation.Language.VariableExpressionAst] -and
            $child.VariablePath.UserPath -ceq 'ApplyM12BackendGeneration'},$true)).Count -eq 1
    })
    Assert-M11M12 ($earlyBranches.Count -eq 1 -and $consumerCall.Count -ge 1 -and $preparationCalls.Count -ge 1) `
        'cannot locate unique early branch, transfer call, and fixture preparation in mutation fixture'
    $early=$earlyBranches[0]
    $exits=@($early.Clauses[0].Item2.Statements|Where-Object{$_ -is [Management.Automation.Language.ExitStatementAst]})
    Assert-M11M12 ($exits.Count -eq 1) 'cannot locate unique exact ExitStatementAst in mutation fixture'
    return [pscustomobject]@{Ast=$ast;Consumer=$consumer;ConsumerBody=$body;ConsumerCall=$consumerCall[0];PreparationCalls=$preparationCalls;
        Early=$early;Exit=$exits[0]}
}

function Get-M12ExitExpression($ExitAst) {
    if($ExitAst -isnot [Management.Automation.Language.ExitStatementAst] -or !$ExitAst.Pipeline -or $ExitAst.Pipeline.PipelineElements.Count -ne 1 -or
        $ExitAst.Pipeline.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) { return $null }
    return $ExitAst.Pipeline.PipelineElements[0].Expression
}

function Get-M12ExitValue($ExitAst) {
    $expression=Get-M12ExitExpression $ExitAst
    if($expression -isnot [Management.Automation.Language.ConstantExpressionAst]) { return $null }
    $typeName=$expression.Value.GetType().FullName
    if($typeName -notin @('System.SByte','System.Byte','System.Int16','System.UInt16','System.Int32','System.UInt32','System.Int64','System.UInt64')) { return $null }
    if($expression.Value -eq 0) { return $expression.Value }
    return $null
}

function Assert-M12StandaloneContract([string] $ScriptText) {
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($ScriptText,[ref]$tokens,[ref]$parseErrors)
    Assert-M11M12 ($parseErrors.Count -eq 0) 'M12 standalone contract fixture did not parse'
    foreach($name in @('ConsumeTransferredM11Fixture','ApplyM12BackendGeneration')) {
        $parameter=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -ceq $name})
        Assert-M11M12 ($parameter.Count -eq 1 -and $parameter[0].StaticType.Name -ceq 'SwitchParameter' -and $null -eq $parameter[0].DefaultValue) `
            "M12 $name is not a default-false switch"
    }
    $consumerBranches=[Collections.Generic.List[System.Management.Automation.Language.IfStatementAst]]::new()
    foreach($statement in @($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst]})) {
        $body=$statement.Clauses[0].Item2
        $invocations=@($body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-M12TransferredFixtureConsumer'},$true))
        if($invocations.Count -gt 0){$consumerBranches.Add($statement)}
    }
    Assert-M11M12 ($consumerBranches.Count -eq 1) 'authoritative M12 consumer branch is missing or ambiguous'
    $consumer=$consumerBranches[0];$body=$consumer.Clauses[0].Item2
    $consumerCondition=Get-M12ConditionCore $consumer.Clauses[0].Item1
    Assert-M11M12 ($consumerCondition -is [Management.Automation.Language.VariableExpressionAst] -and
        $consumerCondition.VariablePath.UserPath -ceq 'ConsumeTransferredM11Fixture') 'authoritative consumer branch does not use the direct positive transfer switch condition'
    $allConsumerCalls=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-M12TransferredFixtureConsumer'},$true))
    Assert-M11M12 ($allConsumerCalls.Count -eq 1) 'transfer consumer invocation exists outside or duplicates the selected branch'
    $consumerCommands=@($body.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))
    $consumerCalls=@($consumerCommands|Where-Object{$_.GetCommandName() -ceq 'Invoke-M12TransferredFixtureConsumer'})
    $preparationCalls=@($consumerCommands|Where-Object{$_.GetCommandName() -ceq 'Invoke-M12TransferredFixturePreparation'})
    Assert-M11M12 ($consumerCalls.Count -eq 1 -and $preparationCalls.Count -eq 1) 'authoritative branch must validate transfer once and contain one gated fixture preparation'

    $applyOnlyBranches=@($body.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst]},$true)|Where-Object{
        $condition=Get-M12ConditionCore $_.Clauses[0].Item1
        if($condition -isnot [Management.Automation.Language.UnaryExpressionAst] -or
            $condition.TokenKind -notin @([Management.Automation.Language.TokenKind]::Exclaim,[Management.Automation.Language.TokenKind]::Not)) { return $false }
        $child=Get-M12ConditionCore $condition.Child
        $child -is [Management.Automation.Language.VariableExpressionAst] -and $child.VariablePath.UserPath -ceq 'ApplyM12BackendGeneration'
    })
    Assert-M11M12 ($applyOnlyBranches.Count -eq 1) 'consumer-only early branch is missing or ambiguous'
    $early=$applyOnlyBranches[0];$exitStatements=@($early.Clauses[0].Item2.Statements|Where-Object{$_ -is [Management.Automation.Language.ExitStatementAst]})
    $exitValue=if($exitStatements.Count -eq 1){Get-M12ExitValue $exitStatements[0]}else{$null}
    Assert-M11M12 ($exitStatements.Count -eq 1 -and $null -ne $exitValue -and
        $consumerCalls[0].Extent.StartOffset -lt $early.Extent.StartOffset -and
        $exitStatements[0].Extent.EndOffset -lt $preparationCalls[0].Extent.StartOffset) `
        'consumer-only mode does not exit successfully after transfer validation and before destructive fixture preparation'
}

function Test-M12StandaloneDefaultOnly {
    $path=Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'
    Assert-M12StandaloneContract ([IO.File]::ReadAllText($path))
    Write-Output 'm12_standalone_default=PASS consume_and_apply_explicit_opt_in=true existing_standalone_path_preserved=true'
}

function Test-M12StandaloneAstNegativeControls {
    $path=Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1';$source=[IO.File]::ReadAllText($path)
    $nodes=Get-M12StandaloneAstNodes $source
    $cases=[Collections.Generic.List[object]]::new()
    $consumerCondition=Get-M12ConditionCore $nodes.Consumer.Clauses[0].Item1
    $cases.Add([pscustomobject]@{Name='A-negative-consumer-switch';Text=(Replace-M12AstExtentExactlyOnce $source $consumerCondition '-not $ConsumeTransferredM11Fixture');Expected='negated-consumer'})
    $cases.Add([pscustomobject]@{Name='B-composed-consumer-condition';Text=(Replace-M12AstExtentExactlyOnce $source $consumerCondition '($OtherFlag -or $ConsumeTransferredM11Fixture)');Expected='composed-consumer'})
    $applyCondition=Get-M12ConditionCore $nodes.Early.Clauses[0].Item1
    $cases.Add([pscustomobject]@{Name='C-positive-apply-branch';Text=(Replace-M12AstExtentExactlyOnce $source $applyCondition '$ApplyM12BackendGeneration');Expected='positive-apply'})
    $cases.Add([pscustomobject]@{Name='D-exit-one';Text=(Replace-M12AstExtentExactlyOnce $source $nodes.Exit 'exit 1');Expected='exit-one'})
    $cases.Add([pscustomobject]@{Name='E-bare-exit';Text=(Replace-M12AstExtentExactlyOnce $source $nodes.Exit 'exit');Expected='bare-exit'})
    $cases.Add([pscustomobject]@{Name='H-exit-fractional';Text=(Replace-M12AstExtentExactlyOnce $source $nodes.Exit 'exit 0.1');Expected='exit-fractional'})
    $cases.Add([pscustomobject]@{Name='I-exit-decimal-zero';Text=(Replace-M12AstExtentExactlyOnce $source $nodes.Exit 'exit 0.0');Expected='exit-decimal-zero'})
    $cases.Add([pscustomobject]@{Name='J-exit-negative-fractional';Text=(Replace-M12AstExtentExactlyOnce $source $nodes.Exit 'exit -0.1');Expected='exit-negative-fractional'})
    $cases.Add([pscustomobject]@{Name='K-exit-false-variable';Text=(Replace-M12AstExtentExactlyOnce $source $nodes.Exit 'exit $false');Expected='exit-false-variable'})
    $cases.Add([pscustomobject]@{Name='F-preparation-before-exit';Text=(Insert-M12AstTextAtOffset $source $nodes.Exit.Extent.StartOffset "Invoke-M12TransferredFixturePreparation `$root `$captureRoot`n");Expected='preparation-before-exit'})
    $endOffset=[int]$nodes.Ast.EndBlock.Extent.EndOffset
    $cases.Add([pscustomobject]@{Name='G-consumer-outside-branch';Text=(Insert-M12AstTextAtOffset $source $endOffset "`nInvoke-M12TransferredFixtureConsumer `$root `$captureRoot`n");Expected='duplicate-outside-consumer'})

    foreach($case in $cases) {
        $mutated=[string]$case.Text
        Assert-M11M12 ($mutated -cne $source) "$($case.Name) mutation was not applied"
        $mutatedNodes=Get-M12StandaloneAstNodes $mutated
        switch($case.Expected) {
            'negated-consumer' {
                $condition=Get-M12ConditionCore $mutatedNodes.Consumer.Clauses[0].Item1
                $child=if($condition -is [Management.Automation.Language.UnaryExpressionAst]){Get-M12ConditionCore $condition.Child}else{$null}
                $applied=$condition -is [Management.Automation.Language.UnaryExpressionAst] -and
                    $condition.TokenKind -in @([Management.Automation.Language.TokenKind]::Not,[Management.Automation.Language.TokenKind]::Exclaim) -and
                    $child -is [Management.Automation.Language.VariableExpressionAst] -and $child.VariablePath.UserPath -ceq 'ConsumeTransferredM11Fixture'
                Assert-M11M12 $applied 'A mutation did not create the intended negated consumer condition'
            }
            'composed-consumer' {
                $condition=Get-M12ConditionCore $mutatedNodes.Consumer.Clauses[0].Item1
                $applied=$condition -is [Management.Automation.Language.BinaryExpressionAst] -and
                    $condition.Operator -eq [Management.Automation.Language.TokenKind]::Or -and
                    @($condition.FindAll({param($node)$node -is [Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -ceq 'OtherFlag'},$true)).Count -eq 1
                Assert-M11M12 $applied 'B mutation did not create the intended composed consumer condition'
            }
            'positive-apply' {
                $condition=Get-M12ConditionCore $mutatedNodes.Early.Clauses[0].Item1
                $applied=$condition -is [Management.Automation.Language.VariableExpressionAst] -and $condition.VariablePath.UserPath -ceq 'ApplyM12BackendGeneration'
                Assert-M11M12 $applied 'C mutation did not create the intended positive Apply branch'
            }
            'exit-one' {
                $expression=Get-M12ExitExpression $mutatedNodes.Exit
                Assert-M11M12 ($expression -is [Management.Automation.Language.ConstantExpressionAst] -and
                    $expression.Value.GetType().FullName -ceq 'System.Int32' -and $expression.Value -eq 1) 'D mutation did not inject exact integral exit 1'
                Write-Output 'm12_ast_negative_detail=D-exit-one mutation_applied=true mutated_exit_value=1'
            }
            'bare-exit' {
                $expression=Get-M12ExitExpression $mutatedNodes.Exit
                Assert-M11M12 ($null -eq $expression -and $mutatedNodes.Exit.Extent.Text.Trim() -ceq 'exit') 'E mutation did not inject a bare exit'
                Write-Output 'm12_ast_negative_detail=E-bare-exit mutation_applied=true bare_exit=true'
            }
            'exit-fractional' {
                $expression=Get-M12ExitExpression $mutatedNodes.Exit
                Assert-M11M12 ($expression -is [Management.Automation.Language.ConstantExpressionAst] -and
                    $expression.Value.GetType().FullName -ceq 'System.Double' -and $expression.Value -eq 0.1) 'H mutation did not inject exact floating exit 0.1'
            }
            'exit-decimal-zero' {
                $expression=Get-M12ExitExpression $mutatedNodes.Exit
                Assert-M11M12 ($expression -is [Management.Automation.Language.ConstantExpressionAst] -and
                    $expression.Value.GetType().FullName -ceq 'System.Double' -and $expression.Value -eq 0.0) 'I mutation did not inject exact floating exit 0.0'
            }
            'exit-negative-fractional' {
                $expression=Get-M12ExitExpression $mutatedNodes.Exit
                $exitValue=Get-M12ExitValue $mutatedNodes.Exit
                Assert-M11M12 ($expression -is [Management.Automation.Language.ConstantExpressionAst] -and
                    $expression.Value.GetType().FullName -ceq 'System.Double' -and $expression.Value -eq -0.1 -and $null -eq $exitValue) `
                    'J mutation did not inject the parser-emitted signed floating exit value or the exit validator accepted it'
                $fractionText=([double]$expression.Value).ToString('R',[Globalization.CultureInfo]::InvariantCulture)
                Write-Output ('m12_ast_negative_detail=J-exit-negative-fractional mutation_applied=true expression_ast={0} value_type={1} value={2} get_exit_value=null' -f
                    $expression.GetType().Name,$expression.Value.GetType().FullName,$fractionText)
            }
            'exit-false-variable' {
                $expression=Get-M12ExitExpression $mutatedNodes.Exit
                Assert-M11M12 ($expression -is [Management.Automation.Language.VariableExpressionAst] -and
                    $expression.VariablePath.UserPath -ceq 'false') 'K mutation did not inject exit $false'
            }
            'preparation-before-exit' {
                $beforeCalls=@($mutatedNodes.ConsumerBody.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -ceq 'Invoke-M12TransferredFixturePreparation'},$true)|Where-Object{
                        $_.Extent.StartOffset -lt $mutatedNodes.Exit.Extent.StartOffset
                    })
                Assert-M11M12 ($beforeCalls.Count -eq 1 -and (Get-M12ExitValue $mutatedNodes.Exit) -eq 0) 'F mutation did not place fixture preparation before exit 0'
                Write-Output 'm12_ast_negative_detail=F-preparation-before-exit mutation_applied=true preparation_before_exit=true'
            }
            'duplicate-outside-consumer' {
                $allCalls=@($mutatedNodes.Ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -ceq 'Invoke-M12TransferredFixtureConsumer'},$true))
                $outside=@($allCalls|Where-Object{$_.Extent.StartOffset -lt $mutatedNodes.ConsumerBody.Extent.StartOffset -or
                    $_.Extent.StartOffset -ge $mutatedNodes.ConsumerBody.Extent.EndOffset})
                Assert-M11M12 ($allCalls.Count -eq 2 -and $outside.Count -eq 1) 'G mutation did not add a consumer call outside the selected branch'
            }
        }
        $rejected=$false
        try { Assert-M12StandaloneContract $mutated } catch { $rejected=$true }
        Assert-M11M12 $rejected "M12 semantic AST negative control was accepted: $($case.Name)"
        Write-Output "m12_ast_negative=PASS case=$($case.Name) mutation_applied=true rejected=true"
        if($case.Expected -in @('exit-fractional','exit-decimal-zero','exit-negative-fractional','exit-false-variable')) {
            Write-Output "m12_ast_negative_detail=$($case.Name) mutation_applied=true rejected=true"
        }
    }
}

function Test-M11ProducerPreserveSuccess {
    $fixture=New-M11M12SyntheticFixture
    try {
        $adapters=New-M11M12Adapters $fixture
        $committed=$false
        $transfer=Assert-GeordiM11M12FixtureTransfer -CaptureRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot `
            -ResolveIdentity $adapters.Resolve -InspectVolume $adapters.Inspect -TestFollowerProcess $adapters.TestFollower `
            -ExpectedVolumes $fixture.ExpectedVolumes -ExpectedCollectorContainerId $fixture.CollectorId
        $committed=$true
        Assert-M11M12 (!(Test-GeordiM11FixtureCleanupRequired -FixtureOwned $true -MutationStarted $false -TransferCommitted $committed)) `
            'validated M11 preservation would still run fixture cleanup'
        $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $fixture.Root
        $backend=Get-GeordiActiveCaptureGenerationRecord -Manifest $manifest -Service backend
        Assert-M11M12 ([string]$backend.generationId -ceq $fixture.BackendGenerationId -and
            [string]$backend.containerId -ceq $transfer.BackendContainerId -and [string]$backend.terminalStatus -ceq 'capturing') `
            'preserve mode sealed or replaced G3'
        Assert-M11M12 ([string]$transfer.CollectorContainerId -ceq $fixture.CollectorId -and
            [string]$transfer.CollectorGenerationId -ceq $fixture.CollectorGenerationId) 'preserve mode did not retain Collector identity/capture'
        Assert-M11M12 (@($manifest.Keys | Where-Object { [string]$_ -match '^transfer' }).Count -eq 0) 'preserve mode wrote a transfer artifact/schema'
        Write-Output 'm11_preserve_success=PASS g3_active=true exact_follower=true live_backend_vm=true m11_final_valid=true volumes_owned=true collector_unchanged=true cleanup_suppressed_after_commit=true'
    } finally { Remove-M11M12SyntheticRoot $fixture.Root }
}

function Test-M11ProducerFailureMatrix {
    $cases=@('m11-final-hash-invalid','backend-missing','vm-missing','backend-volume-missing','backend-follower-missing','collector-baseline-mismatch')
    foreach($case in $cases) {
        $fixture=New-M11M12SyntheticFixture
        try {
            if($case -eq 'm11-final-hash-invalid'){Set-M11M12Failure $fixture 'm11-final-hash-invalid'}
            $adapters=New-M11M12Adapters $fixture $(if($case -eq 'collector-baseline-mismatch'){'none'}else{$case})
            $committed=$false
            $rejected=$false
            try {
                $expectedCollector=if($case -eq 'collector-baseline-mismatch'){('e'*64)}else{$fixture.CollectorId}
                $null=Assert-GeordiM11M12FixtureTransfer -CaptureRoot $fixture.Root -RepositoryRoot $fixture.RepositoryRoot `
                    -ResolveIdentity $adapters.Resolve -InspectVolume $adapters.Inspect -TestFollowerProcess $adapters.TestFollower `
                    -ExpectedVolumes $fixture.ExpectedVolumes -ExpectedCollectorContainerId $expectedCollector
                $committed=$true
            } catch { $rejected=$true }
            Assert-M11M12 ($rejected -and !$committed -and
                (Test-GeordiM11FixtureCleanupRequired -FixtureOwned $true -MutationStarted $true -TransferCommitted $committed)) `
                "$case producer precondition did not fail closed into cleanup"
        } finally { Remove-M11M12SyntheticRoot $fixture.Root }
        Write-Output "m11_preserve_failure=PASS case=$case cleanup_required=true transfer_uncommitted=true"
    }
    Write-Output 'm11_producer_failure_matrix=PASS cases=6'
}

function Test-M11M12StaticControlFlow {
    $m11Path=Join-Path $PSScriptRoot 'verify-notification-delivery.ps1'
    $m12Path=Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'
    foreach($path in @($m11Path,$m12Path)) {
        $tokens=$null;$errors=$null
        [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
        Assert-M11M12 ($errors.Count -eq 0) "affected production script fails parser: $([IO.Path]::GetFileName($path))"
    }
    $m11Ast=[System.Management.Automation.Language.Parser]::ParseFile($m11Path,[ref]$null,[ref]$null)
    $m11Try=@($m11Ast.FindAll({param($node)$node -is [System.Management.Automation.Language.TryStatementAst]},$true) | Where-Object { $_.Finally }) | Select-Object -Last 1
    Assert-M11M12 ($m11Try -and $m11Try.Finally.Extent.Text.Contains('Test-GeordiM11FixtureCleanupRequired') -and
        $m11Try.Finally.Extent.Text.Contains('TransferCommitted')) 'M11 finally does not preserve standalone/failure cleanup decision'
    $m11Commands=@($m11Try.Body.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst]},$true))
    $finalCapture=$m11Commands | Where-Object { $_.Extent.Text -match 'Capture-GeordiM19Generation\.ps1.*-Phase m11-final' } | Select-Object -First 1
    $transferCheck=$m11Commands | Where-Object { $_.GetCommandName() -ceq 'Assert-GeordiM11M12FixtureTransfer' } | Select-Object -First 1
    $commitAssignment=$m11Try.Body.FindAll({param($node)$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -match 'TransferCommitted'},$true) | Select-Object -Last 1
    Assert-M11M12 ($finalCapture -and $transferCheck -and $commitAssignment -and
        $finalCapture.Extent.StartOffset -lt $transferCheck.Extent.StartOffset -and
        $transferCheck.Extent.StartOffset -lt $commitAssignment.Extent.StartOffset) 'M11 m11-final -> validation -> transfer commit order is invalid'
    $m12Ast=[System.Management.Automation.Language.Parser]::ParseFile($m12Path,[ref]$null,[ref]$null)
    $topStatements=@($m12Ast.EndBlock.Statements)
    $consumerIndex=-1;$resetOnlyIndex=-1;$mainTryIndex=-1
    for($i=0;$i -lt $topStatements.Count;$i++) {
        $statement=$topStatements[$i]
        if($statement -is [System.Management.Automation.Language.IfStatementAst] -and $statement.Clauses[0].Item1.Extent.Text -match 'ConsumeTransferredM11Fixture'){$consumerIndex=$i}
        if($statement -is [System.Management.Automation.Language.IfStatementAst] -and $statement.Clauses[0].Item1.Extent.Text -match 'RunFixtureResetOnly'){$resetOnlyIndex=$i}
        if($statement -is [System.Management.Automation.Language.TryStatementAst]){$mainTryIndex=$i}
    }
    Assert-M11M12 ($consumerIndex -ge 0 -and $resetOnlyIndex -gt $consumerIndex -and $mainTryIndex -gt $resetOnlyIndex) `
        'M12 transfer consumer is not an explicit early branch before standalone reset and normal runtime flow'
    $consumerBody=$topStatements[$consumerIndex].Clauses[0].Item2.Extent.Text
    Assert-M11M12 ($consumerBody.Contains('Invoke-M12TransferredFixtureConsumer') -and
        !$consumerBody.Contains('Reset-M12FixtureVolumes') -and !$consumerBody.Contains("'rm'")) 'M12 consumer branch reaches destructive fixture operations'
    $consumerFunction=@($m12Ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-M12TransferredFixtureConsumer'},$true))[0]
    Assert-M11M12 ($consumerFunction -and $consumerFunction.Body.Extent.Text.Contains('Invoke-GeordiM11M12FixtureTransferConsumer') -and
        $consumerFunction.Body.Extent.Text.Contains('-Phase m12-reset') -and $consumerFunction.Body.Extent.Text.Contains('-SkipLogSnapshot')) `
        'M12 consumer does not authenticate, then capture m12-reset while skipping duplicate logs'
    Write-Output 'transfer_control_flow=PASS m11_final_validate_commit_cleanup=true m12_validate_reset_before_destructive=true'
}

function Test-M11M12CompatibilityScriptWiring {
    $m11Ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'verify-notification-delivery.ps1'),[ref]$null,[ref]$null)
    $m11Param=$m11Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'PreserveFixtureForNextStage' }
    Assert-M11M12 ($null -ne $m11Param -and $m11Param.StaticType.Name -ceq 'SwitchParameter') 'M11 preserve mode is not an explicit default-false switch'
    $m12Ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'),[ref]$null,[ref]$null)
    $m12Param=$m12Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'ConsumeTransferredM11Fixture' }
    Assert-M11M12 ($null -ne $m12Param -and $m12Param.StaticType.Name -ceq 'SwitchParameter') 'M12 consume mode is not an explicit default-false switch'
    Assert-M11M12 ((Get-GeordiM12LegacyResetCaptureServices -Services @('backend','victoriametrics','otel-collector','m12-burn-demo')) -contains 'backend') `
        'M12 default capture-service behavior changed'
    Write-Output 'standalone_modes=PASS M11_default_cleanup=true M12_default_path_unchanged=true'
}

function Test-M11M12AffectedScriptParser {
    $files=@('lib/GeordiM11M12FixtureTransfer.ps1','Test-GeordiM11M12FixtureTransfer.ps1',
        'verify-notification-delivery.ps1','verify-alert-scheduling.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
    foreach($path in $files) {
        $tokens=$null;$errors=$null
        [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
        if($errors.Count){throw "PowerShell parser failed: $([IO.Path]::GetFileName($path))"}
    }
    Write-Output 'transfer_parser=PASS affected_scripts=4'
}

if ($Case -ceq 'ConsumerWorker') {
    if (!(Test-Path -LiteralPath $FixtureMetadataPath -PathType Leaf)) { throw 'Synthetic fixture identity file is missing.' }
    $fixture=Get-Content -LiteralPath $FixtureMetadataPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $state=[pscustomobject]@{RepositoryRoot=[string]$fixture.RepositoryRoot;RunStart=$fixture.RunStart;Root=[IO.Path]::GetFullPath($CaptureRoot)
        ManifestPath=(Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'manifest.json')
        BackendId=[string]$fixture.BackendId;BackendGenerationId=[string]$fixture.BackendGenerationId
        VmId=[string]$fixture.VmId;CollectorId=[string]$fixture.CollectorId
        VolumeInventory=@{
            'geordi_m11-alert-lifecycle-data'=[pscustomobject]@{Name='geordi_m11-alert-lifecycle-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-alert-lifecycle-data'}}
            'geordi_m11-victoriametrics-data'=[pscustomobject]@{Name='geordi_m11-victoriametrics-data';Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m11-victoriametrics-data'}}
        }}
    $adapters=New-M11M12Adapters $state
    $capture={param($Transfer) Add-M11M12SyntheticMetricLedger $state 'm12-reset' $Transfer.VictoriaMetricsContainerId}.GetNewClosure()
    $result=Invoke-GeordiM11M12FixtureTransferConsumer -CaptureRoot $state.Root -RepositoryRoot $state.RepositoryRoot `
        -ResolveIdentity $adapters.Resolve -InspectVolume $adapters.Inspect -TestFollowerProcess $adapters.TestFollower `
        -ExpectedVolumes (Get-GeordiM11TransferVolumeAllowlist) -CaptureM12Reset $capture
    if ($result.Status -cne 'TRANSFER_VALIDATED' -or $result.VictoriaMetricsContainerId -cne $state.VmId) { throw 'Synthetic consumer did not validate inherited M11 state.' }
    Write-Output 'synthetic-fresh-consumer=TRANSFER_VALIDATED'
    exit 0
}

if ($Case -ceq 'M11Standalone') { Test-M11StandaloneDefaultOnly;exit 0 }
if ($Case -ceq 'M12Standalone') { Test-M12StandaloneDefaultOnly;exit 0 }
if ($Case -ceq 'M12AstNegatives') { Test-M12StandaloneAstNegativeControls;exit 0 }
if ($Case -ceq 'ConsumerOnly') { Test-M11M12SuccessfulCrossProcessTransfer;exit 0 }

if ($Case -cne 'SelfTest') { throw 'Unsupported transfer regression case.' }
Test-M11M12AffectedScriptParser
Test-M11ProducerFailureAndStandaloneModes
Test-M11M12StaticControlFlow
Test-M11M12CompatibilityScriptWiring
Test-M11ProducerPreserveSuccess
Test-M11ProducerFailureMatrix
Test-M11M12SuccessfulCrossProcessTransfer
Test-M11M12ResetIntervalBinding
Test-M12RejectsMixedTransferModes
Test-M11M12ConsumerFailureMatrix
Write-Output 'm11_m12_fixture_transfer_selftest=PASS'
