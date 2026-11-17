[CmdletBinding()]
param([switch] $SelfTest,[switch] $ComposeIntegration,[ValidateSet('PrimaryCleanupSuccess','PrimaryCleanupFailure','WrapperFailures',
    'SecondReplacementFailure','SecondSameIdentityFailure','SecondFollowerFailure','SecondReadinessFailure')][string] $Case)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM12OverlapCollector.ps1')

function Assert-M12Overlap([bool] $Condition,[string] $Message){
    if(!$Condition){throw "M12 overlap Collector regression failed: $Message"}
}

function New-M12OverlapComposeFixture([string] $RepositoryRoot,[switch] $CollectorReplacementOverlay,[switch] $IsolationOverlay){
    $services=[ordered]@{}
    foreach($name in @('victoriametrics','tempo','loki','otel-collector','backend','webhook-receiver','oidc-fixture','demo','burn-demo','m12-burn-demo','demo-downstream','frontend','m12-query-gate')){
        $services[$name]=[ordered]@{image='synthetic:'+$name;volumes=@()}
    }
    $services.backend.depends_on=[ordered]@{'otel-collector'=[ordered]@{condition='service_healthy';restart=$true};victoriametrics=[ordered]@{condition='service_healthy';restart=$true};'m12-query-gate'=[ordered]@{condition='service_healthy'}}
    $services.'otel-collector'.depends_on=[ordered]@{victoriametrics=[ordered]@{condition='service_healthy';restart=$true}}
    foreach($name in @('demo','burn-demo','demo-downstream','m12-burn-demo')){$services[$name].depends_on=[ordered]@{'otel-collector'=[ordered]@{condition='service_healthy';restart=$true}}}
    $services.backend.volumes=@('m19-alert-lifecycle-data:/var/lib/geordi/alerts')
    $services.victoriametrics.volumes=@('m19-victoriametrics-data:/victoria-metrics-data')
    $services.'otel-collector'.volumes=@('./otel/otel-collector-config.yaml:/etc/otelcol/config.yaml:ro')
    if($CollectorReplacementOverlay){foreach($name in @('backend','demo','burn-demo','demo-downstream','m12-burn-demo')){$services[$name].depends_on['otel-collector'].restart=$false}}
    if($IsolationOverlay){foreach($edge in (Get-GeordiM12OverlapIsolationEdges)){$services[$edge.service].depends_on[$edge.dependency].restart=$false}}
    return [ordered]@{services=$services;volumes=[ordered]@{'m19-alert-lifecycle-data'=[ordered]@{};'m19-victoriametrics-data'=[ordered]@{}};networks=[ordered]@{default=[ordered]@{}}}
}

function Test-M12OverlapComposeExecutorContract([string] $RepositoryRoot){
    $expected=@('compose')+@(Get-GeordiM12OverlapComposeArguments -RepositoryRoot $RepositoryRoot)+@('config','--format','json')
    $calls=[Collections.Generic.List[object]]::new()
    $success={param([string[]] $Arguments)$calls.Add(@($Arguments));return [pscustomobject]@{ExitCode=0;Output='{"services":{},"volumes":{},"networks":{}}'}}.GetNewClosure()
    $normal=Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $RepositoryRoot -InvokeCompose $success
    Assert-M12Overlap ($calls.Count -eq 1 -and (@($calls[0])-join "`n") -ceq ($expected -join "`n")) 'normal Compose executor argv mismatch'
    Assert-M12Overlap ($normal.Contains('services') -and $normal.Contains('volumes') -and $normal.Contains('networks')) 'executor output was not parsed'
    $expectedOverlay=@('compose')+@(Get-GeordiM12OverlapComposeArguments -RepositoryRoot $RepositoryRoot -CollectorReplacementOverlay -IsolationOverlay)+@('config','--format','json')
    $overlayCalls=[Collections.Generic.List[object]]::new()
    $overlayInvoker={param([string[]] $Arguments)$overlayCalls.Add(@($Arguments));return [pscustomobject]@{ExitCode=0;Output='{"services":{},"volumes":{},"networks":{}}'}}.GetNewClosure()
    $null=Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $RepositoryRoot -CollectorReplacementOverlay -IsolationOverlay -InvokeCompose $overlayInvoker
    Assert-M12Overlap ($overlayCalls.Count -eq 1 -and (@($overlayCalls[0])-join "`n") -ceq ($expectedOverlay -join "`n")) 'overlay Compose executor argv mismatch'
    foreach($failure in @(@{name='nonzero exit';result=[pscustomobject]@{ExitCode=17;Output=''}},@{name='malformed JSON';result=[pscustomobject]@{ExitCode=0;Output='{invalid-json'}},@{name='empty output';result=[pscustomobject]@{ExitCode=0;Output=@()}})){
        $result=$failure.result
        $failedInvoker={param([string[]] $Arguments)return $result}.GetNewClosure()
        $rejected=$false
        try{$null=Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $RepositoryRoot -InvokeCompose $failedInvoker}catch{$rejected=$true}
        Assert-M12Overlap $rejected ("Compose executor accepted "+$failure.name)
    }
    Write-Output 'm12_overlap_compose_executor_contract=PASS success=1 overlay_argv=1 failures=3 docker_invocations=0'
}
function Test-M12OverlapCiActivation([string] $Source){
    $lines=[Collections.Generic.List[string]]::new()
    foreach($line in ($Source -split "`r?`n")){
        if($line.TrimStart().StartsWith('#')){continue}
        $lines.Add(($line -replace '\s+#.*$',''))
    }
    $code=$lines -join "`n"
    return $code -match '(?i)(?:^|\s)-ApplyM12OverlapGenerations(?:\s|$)' -or
        $code -match '(?i)(?:^|\s)-ApplyM12OverlapCollectorGenerations(?:\s|$)'
}

function Test-M12OverlapSourceMap([string] $RepositoryRoot){
    $scriptPath=Join-Path $PSScriptRoot 'verify-alert-scheduling-overlap.ps1'
    $tokens=$null;$parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Current M12 overlap script did not parse during lifecycle-map validation.'}
    $modeParameter=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -ceq 'ApplyM12OverlapGenerations'})
    $modeAlias=@($modeParameter|Where-Object{@($_.Attributes|Where-Object{$_.TypeName.FullName -ceq 'Alias' -and
        @($_.PositionalArguments|Where-Object{$_.SafeGetValue() -ceq 'ApplyM12OverlapCollectorGenerations'}).Count -eq 1}).Count -eq 1})
    Assert-M12Overlap ($modeParameter.Count -eq 1 -and $modeAlias.Count -eq 1 -and
        $null -eq $modeParameter[0].DefaultValue) 'generation-aware mode is not an opt-in switch with its accepted alias'

    $adapterCalls=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-M12OverlapCollectorReplacement'},$true))
    $replacementCallbacks=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.CommandElements.Count -eq 2 -and $node.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.CommandElements[0].VariablePath.UserPath -ceq 'replaceCollector'},$true))
    $resetCallback=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$replaceCollectorFirst'},$true))
    $exerciseCallback=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$replaceCollectorSecond'},$true))
    $resetInvocation=@($replacementCallbacks|Where-Object{$_.CommandElements[1].SafeGetValue() -ceq 'overlap-reset'})
    $exerciseInvocation=@($replacementCallbacks|Where-Object{$_.CommandElements[1].SafeGetValue() -ceq 'overlap-exercise'})
    $resetSequence=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Invoke-GeordiM12OverlapGenerationResetSequence'},$true))
    $sequenceBindings=$false
    if($resetSequence.Count -eq 1){
        $elements=@($resetSequence[0].CommandElements|ForEach-Object{$_.Extent.Text})
        $firstIndex=[Array]::IndexOf($elements,'-ReplaceCollectorFirst')
        $secondIndex=[Array]::IndexOf($elements,'-ReplaceCollectorSecond')
        $sequenceBindings=$firstIndex -ge 0 -and $secondIndex -gt $firstIndex -and
            $elements[$firstIndex+1] -ceq '$replaceCollectorFirst' -and $elements[$secondIndex+1] -ceq '$replaceCollectorSecond'
    }
    Assert-M12Overlap ($adapterCalls.Count -eq 1 -and $replacementCallbacks.Count -eq 2 -and
        $resetCallback.Count -eq 1 -and $exerciseCallback.Count -eq 1 -and $resetInvocation.Count -eq 1 -and
        $exerciseInvocation.Count -eq 1 -and $sequenceBindings) `
        'generation-aware reset sequence does not bind distinct reset and exercise calls to the accepted Collector adapter'

    $legacyRestart=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match '^& docker restart geordi-otel-collector-1'},$true))
    $modeElseBranch=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -match '\$ApplyM12OverlapGenerations' -and $null -ne $node.ElseClause -and
        @($node.ElseClause.FindAll({param($child)$child -is [System.Management.Automation.Language.CommandAst] -and
            $child.Extent.Text -match '^& docker restart geordi-otel-collector-1'},$true)).Count -eq 1},$true))
    Assert-M12Overlap ($legacyRestart.Count -eq 1 -and $modeElseBranch.Count -eq 1) `
        'standalone Collector restart is not isolated to the generation-aware mode false branch'
    $ci=Get-Content -LiteralPath (Join-Path $RepositoryRoot '.gitlab-ci.yml') -Raw
    Assert-M12Overlap (!(Test-M12OverlapCiActivation $ci)) 'generation-aware overlap mode was activated in CI'
    foreach($case in @(
        @{name='new';source='verify-alert-scheduling-overlap.ps1 -ApplyM12OverlapGenerations'},
        @{name='legacy';source='verify-alert-scheduling-overlap.ps1 -ApplyM12OverlapCollectorGenerations'},
        @{name='both';source='verify-alert-scheduling-overlap.ps1 -ApplyM12OverlapGenerations -ApplyM12OverlapCollectorGenerations'})){
        Assert-M12Overlap (Test-M12OverlapCiActivation $case.source) "CI activation detector missed $($case.name) option"
    }
    Assert-M12Overlap (!(Test-M12OverlapCiActivation '# verify-alert-scheduling-overlap.ps1 -ApplyM12OverlapGenerations')) `
        'comment-only option text was counted as CI activation'
    Write-Output 'm12_overlap_collector_lifecycle_map=PASS shared_adapter=1 reset+exercise=2 standalone_default=preserved'
}

function Test-M12OverlapComposeIsolation([string] $RepositoryRoot,[System.Collections.IDictionary] $NormalConfiguration,[System.Collections.IDictionary] $IsolatedConfiguration){
    $normal=$NormalConfiguration
    $isolated=$IsolatedConfiguration
    if(!$normal -or !$isolated){throw 'Compose configurations must be supplied explicitly.'}
    $edges=Assert-GeordiM12OverlapIsolationConfiguration -NormalConfiguration $normal -IsolatedConfiguration $isolated
    Assert-M12Overlap ($edges.Count -eq 7) 'expected seven restart-only isolation edges'
    $normalPropagation=Get-GeordiM12OverlapRestartDependents -Configuration $normal -Dependencies @('otel-collector','victoriametrics','backend')
    $expected=@('backend:otel-collector','backend:victoriametrics','burn-demo:otel-collector','demo:otel-collector',
        'demo-downstream:otel-collector','m12-burn-demo:otel-collector','otel-collector:victoriametrics')
    $actual=@($normalPropagation|ForEach-Object{"$($_.service):$($_.dependency)"}|Sort-Object)
    Assert-M12Overlap (($actual -join "`n") -ceq (@($expected|Sort-Object) -join "`n")) 'normal reverse restart graph did not match the rendered topology'
    $remaining=Get-GeordiM12OverlapRestartDependents -Configuration $isolated -Dependencies @('otel-collector','victoriametrics','backend','m12-burn-demo','m12-query-gate')
    Assert-M12Overlap ($remaining.Count -eq 0) 'isolated overlap config retains a reverse restart edge'
    foreach($volume in @('m19-alert-lifecycle-data','m19-victoriametrics-data')){
        Assert-M12Overlap ($normal.volumes.Contains($volume) -eq $isolated.volumes.Contains($volume)) "protected volume mapping changed: $volume"
        if($normal.volumes.Contains($volume)){
            Assert-M12Overlap ((ConvertTo-GeordiM12OverlapCanonicalJson $normal.volumes[$volume]) -ceq
                (ConvertTo-GeordiM12OverlapCanonicalJson $isolated.volumes[$volume])) "protected volume identity changed: $volume"
        }
    }
    Assert-M12Overlap ((ConvertTo-GeordiM12OverlapCanonicalJson $normal.services.backend.volumes) -ceq
        (ConvertTo-GeordiM12OverlapCanonicalJson $isolated.services.backend.volumes)) 'backend volume mounts changed'
    Assert-M12Overlap ((ConvertTo-GeordiM12OverlapCanonicalJson $normal.services.victoriametrics.volumes) -ceq
        (ConvertTo-GeordiM12OverlapCanonicalJson $isolated.services.victoriametrics.volumes)) 'VictoriaMetrics volume mounts changed'
    Assert-M12Overlap ((ConvertTo-GeordiM12OverlapCanonicalJson $normal.services.'otel-collector'.volumes) -ceq
        (ConvertTo-GeordiM12OverlapCanonicalJson $isolated.services.'otel-collector'.volumes)) 'Collector volume mounts changed'
    Write-Output 'm12_overlap_normal_render=PASS reverse_restart_edges=7'
    Write-Output 'm12_overlap_isolated_render=PASS reverse_restart_edges=0'
    Write-Output 'm12_overlap_config_equivalence=PASS normalized_fields=depends_on.restart'
    Write-Output 'm12_overlap_protected_volume_config=PASS protected_m19_mounts_unchanged=true'

    $negative=[Collections.Generic.List[object]]::new()
    $negative.Add(@{name='demo propagation';mutate={param($config)$config.services.demo.depends_on['otel-collector'].restart=$true}})
    $negative.Add(@{name='demo-downstream propagation';mutate={param($config)$config.services.'demo-downstream'.depends_on['otel-collector'].restart=$true}})
    $negative.Add(@{name='VictoriaMetrics dependent propagation';mutate={param($config)$config.services.backend.depends_on.victoriametrics.restart=$true}})
    $negative.Add(@{name='Collector depends on VictoriaMetrics propagation';mutate={param($config)$config.services.'otel-collector'.depends_on.victoriametrics.restart=$true}})
    $negative.Add(@{name='unintended backend dependent';mutate={param($config)$config.services.'m12-query-gate'.depends_on=[ordered]@{backend=[ordered]@{condition='service_healthy';restart=$true}}}})
    $negative.Add(@{name='dependency removed';mutate={param($config)[void]$config.services.demo.depends_on.Remove('otel-collector')}})
    $negative.Add(@{name='dependency condition changed';mutate={param($config)$config.services.demo.depends_on['otel-collector'].condition='service_started'}})
    $negative.Add(@{name='non-restart service field changed';mutate={param($config)$config.services.'m12-query-gate'.command=@('python','-c','pass')}})
    foreach($case in $negative){
        $mutation=Copy-GeordiM12OverlapConfiguration $isolated
        & $case.mutate $mutation
        $rejected=$false
        try{$null=Assert-GeordiM12OverlapIsolationConfiguration -NormalConfiguration $normal -IsolatedConfiguration $mutation}catch{$rejected=$true}
        Assert-M12Overlap $rejected ("invalid overlay mutation was accepted: " + $case.name)
    }
    Write-Output 'm12_overlap_propagation_negative_matrix=PASS cases=8'
}

function Test-M12OverlapCollectorCommandScope([string] $RepositoryRoot){
    $accepted=@(Get-GeordiM12CollectorReplacementArguments -RepositoryRoot $RepositoryRoot)
    $actual=@(Get-GeordiM12OverlapCollectorReplacementArguments -RepositoryRoot $RepositoryRoot -AcceptedArguments $accepted)
    $tail=@($actual|Select-Object -Last 5)
    Assert-M12Overlap (($tail -join "`n") -ceq (@('up','-d','--no-deps','--force-recreate','otel-collector') -join "`n")) 'replacement command does not target only Collector with no dependencies'
    foreach($service in @('backend','victoriametrics','frontend','burn-demo','demo','demo-downstream','m12-burn-demo','m12-query-gate')){
        Assert-M12Overlap ($tail -notcontains $service) "Collector replacement command includes unrelated service $service"
    }
    Assert-M12Overlap (@($actual|Where-Object{$_ -in @('down','rm','-v','--volumes','prune')}).Count -eq 0) 'Collector command contains teardown or volume mutation flags'
    $fileNames=[Collections.Generic.List[string]]::new()
    for($index=0;$index -lt $actual.Count;$index++){if($actual[$index] -ceq '--file'){$fileNames.Add([IO.Path]::GetFileName($actual[$index+1]))}}
    $expectedFiles=@('compose.yaml','compose.m19.yaml','compose.m12.yaml','compose.m12-overlap.yaml',
        'compose.m12-collector-replacement.yaml','compose.m12-overlap-isolation.yaml')
    Assert-M12Overlap (($fileNames -join "`n") -ceq ($expectedFiles -join "`n")) 'Collector replacement uses an incomplete or unexpected Compose file set'
    $negative=@($accepted)
    $negative[$negative.Count-1]='backend'
    $rejected=$false
    try{$null=Get-GeordiM12OverlapCollectorReplacementArguments -RepositoryRoot $RepositoryRoot -AcceptedArguments $negative}catch{$rejected=$true}
    Assert-M12Overlap $rejected 'replacement adapter accepted a changed service target'
    Write-Output 'm12_overlap_collector_command_scope=PASS target=otel-collector no_deps=true force_recreate=true unrelated_targets=0'
}

function New-M12OverlapTestIdentity([string] $Id,[string] $RepositoryRoot){
    return [pscustomobject]@{Id=$Id;Project='geordi';Service='otel-collector';WorkingDirectory=$RepositoryRoot;
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}
}

function New-M12OverlapTestCaptureRoot{
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m12-overlap-test-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $now=[DateTimeOffset]::UtcNow.ToString('o')
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-m12-overlap';startedUtc=$now;captureStartedUtc=$now;
        captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};captures=@{}}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 32 -Compress),[Text.UTF8Encoding]::new($false))
    return $root
}

function New-M12OverlapFailureHarness([string] $RepositoryRoot){
    $root=New-M12OverlapTestCaptureRoot
    $state=[pscustomobject]@{Pid=65000;Processes=@{};CurrentId=('a'*64);NextIds=@(('b'*64),('c'*64));
        ReplacementIndex=0;FollowerCount=0;LastFollower=$null;LastFollowerPid=0;ReadinessCount=0;
        FailureStage='';FailBoundary=2;CleanupShouldFail=$false;CaptureRoot=$root}
    $identityBuilder=${function:New-M12OverlapTestIdentity}
    $assertion=${function:Assert-M12Overlap}
    $startFollower={
        param([string] $Stdout,[string] $Stderr,[string] $ProcessRecord,[string[]] $DockerArguments,$Target)
        $state.FollowerCount++
        if($state.FailureStage -ceq 'follower' -and $state.ReplacementIndex -eq $state.FailBoundary){throw 'FOLLOWER_FAILURE'}
        $state.Pid++;$start=[DateTimeOffset]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($Stdout,"synthetic-$($Target.containerId)`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($Stderr,'',[Text.UTF8Encoding]::new($false))
        $recordContainer=if($state.FailureStage -ceq 'wrong-follower' -and $state.ReplacementIndex -eq $state.FailBoundary){'f'*64}else{[string]$Target.containerId}
        $record=[ordered]@{id=$state.Pid;name='synthetic-docker-follower';startUtc=$start;
            containerId=$recordContainer;service=[string]$Target.service;project=[string]$Target.project;createdUtc=[string]$Target.createdUtc}
        [IO.File]::WriteAllText($ProcessRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
        $state.Processes[[string]$state.Pid]=$true;$state.LastFollower=[string]$Target.containerId;$state.LastFollowerPid=$state.Pid
        return [pscustomobject]@{id=$state.Pid;name='synthetic-docker-follower';startUtc=$start}
    }.GetNewClosure()
    $initialIdentity=& $identityBuilder -Id $state.CurrentId -RepositoryRoot $RepositoryRoot
    $initial=Start-GeordiCaptureGeneration -CaptureRoot $root -Service 'otel-collector' -ContainerIdentity $initialIdentity `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1' `
        -WorkingDirectory $RepositoryRoot -HandoffId '' -StartFollower $startFollower
    $renderConfiguration=${function:New-M12OverlapComposeFixture}
    $render={param([string] $RenderRoot,[bool] $ReplacementOverlay)
        return & $renderConfiguration -RepositoryRoot $RenderRoot -CollectorReplacementOverlay:$ReplacementOverlay
    }.GetNewClosure()
    $argumentBuilder=${function:Get-GeordiM12OverlapCollectorReplacementArguments}
    $acceptedBuilder=${function:Get-GeordiM12CollectorReplacementArguments}
    $invoke={
        param([string[]] $Arguments,[string] $Phase)
        $accepted=@(& $acceptedBuilder -RepositoryRoot $RepositoryRoot)
        $expected=@(& $argumentBuilder -RepositoryRoot $RepositoryRoot -AcceptedArguments $accepted)
        & $assertion (($Arguments -join "`n") -ceq ($expected -join "`n")) 'failure fixture received unscoped replacement arguments'
        $boundary=$state.ReplacementIndex+1
        if($state.FailureStage -ceq 'replace' -and $boundary -eq $state.FailBoundary){throw 'REPLACEMENT_FAILURE'}
        if($state.FailureStage -ceq 'same-id' -and $boundary -eq $state.FailBoundary){$state.ReplacementIndex=$boundary;return}
        $state.CurrentId=$state.NextIds[$state.ReplacementIndex]
        $state.ReplacementIndex=$boundary
    }.GetNewClosure()
    $resolve={
        param([string] $Service)
        if($state.FailureStage -ceq 'identity' -and $state.ReplacementIndex -eq $state.FailBoundary){throw 'IDENTITY_FAILURE'}
        return & $identityBuilder -Id $state.CurrentId -RepositoryRoot $RepositoryRoot
    }.GetNewClosure()
    $readiness={
        param($target,$process,$generationId)
        & $assertion ($state.LastFollower -ceq $state.CurrentId) 'readiness preceded the exact synthetic follower'
        $manifest=Get-GeordiCaptureGenerationManifest $root
        $published=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $generationId
        if(!$published -or [int]$published.followerProcess.id -ne [int]$process.id -or
                [string]$published.containerId -cne [string]$target.containerId){throw 'Readiness preceded shared exact Collector follower validation.'}
        $state.ReadinessCount++
        if($state.FailureStage -in @('readiness','readiness-cleanup-fails') -and $state.ReplacementIndex -eq $state.FailBoundary){
            $state.CleanupShouldFail=$state.FailureStage -ceq 'readiness-cleanup-fails'
            throw 'READINESS_FAILURE'
        }
    }.GetNewClosure()
    $identityCheck={param($process) return [bool]$state.Processes[[string]$process.id]}.GetNewClosure()
    $stop={
        param($process)
        if($state.CleanupShouldFail -and [int]$process.id -eq $state.LastFollowerPid){throw 'CLEANUP_FAILURE'}
        $state.Processes[[string]$process.id]=$false
    }.GetNewClosure()
    $invokeReplacement=${function:Invoke-GeordiM12OverlapCollectorReplacement}
    $replace={
        param([string] $Boundary)
        return & $invokeReplacement -CaptureRoot $root -RepositoryRoot $RepositoryRoot `
            -RenderComposeConfiguration $render -InvokeCompose $invoke -ResolveContainerIdentity $resolve `
            -WaitForReadiness $readiness -StartFollower $startFollower -TestProcessIdentity $identityCheck -StopProcess $stop `
            -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1'
    }.GetNewClosure()
    return [pscustomobject]@{Root=$root;State=$state;InitialGenerationId=$initial;Replace=$replace;IdentityCheck=$identityCheck;Stop=$stop}
}

function Test-M12OverlapSecondHandoffFailure([string] $RepositoryRoot,[string] $FailureStage,[bool] $CleanupFails=$false){
    $context=New-M12OverlapFailureHarness $RepositoryRoot
    try{
        $first=& $context.Replace 'first-boundary'
        $manifest=Get-GeordiCaptureGenerationManifest $context.Root
        $firstHandoff=$manifest.captureHandoffs[$first.HandoffId]
        Assert-M12Overlap ($firstHandoff.status -ceq 'complete') 'first handoff did not complete before second-boundary failure setup'
        $firstHandoffSnapshot=ConvertTo-GeordiM12OverlapCanonicalJson $firstHandoff
        $c0=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $context.InitialGenerationId
        $c0Snapshot=ConvertTo-GeordiM12OverlapCanonicalJson $c0
        $c0Hash=(Get-FileHash -LiteralPath $c0.capturePath -Algorithm SHA256).Hash
        $c1=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $first.GenerationId
        $c1Path=$c1.capturePath
        $c1Hash=(Get-FileHash -LiteralPath $c1Path -Algorithm SHA256).Hash
        $context.State.FailureStage=if($CleanupFails){'readiness-cleanup-fails'}else{$FailureStage}
        $context.State.FailBoundary=2
        $failure=$null
        try{$null=& $context.Replace 'second-boundary'}catch{$failure=$_}
        Assert-M12Overlap ($null -ne $failure) "second-boundary $FailureStage failure was accepted"
        if($FailureStage -ceq 'readiness'){
            Assert-M12Overlap ($failure.Exception.Message -ceq 'READINESS_FAILURE') 'readiness failure did not remain the top-level failure'
            if($CleanupFails){
                Assert-M12Overlap (!$failure.Exception.Message.Contains('CLEANUP_FAILURE') -and $failure.Exception.Data.Contains('FollowerCleanupFailure')) `
                    'cleanup failure masked readiness or was not retained as secondary metadata'
                Assert-M12Overlap (!$failure.Exception.Data['FollowerCleanupFailure'].ToString().Contains('CLEANUP_FAILURE')) `
                    'secondary diagnostic exposed raw cleanup exception text'
            }else{Assert-M12Overlap (!$failure.Exception.Data.Contains('FollowerCleanupFailure')) 'successful cleanup was recorded as a cleanup failure'}
        }
        $manifest=Get-GeordiCaptureGenerationManifest $context.Root
        $handoffs=@($manifest.captureHandoffs.Values)
        $hc1=$manifest.captureHandoffs[$first.HandoffId]
        Assert-M12Overlap ($handoffs.Count -eq 2 -and (ConvertTo-GeordiM12OverlapCanonicalJson $hc1) -ceq $firstHandoffSnapshot) `
            'first completed handoff changed after second-boundary failure'
        Assert-M12Overlap ((ConvertTo-GeordiM12OverlapCanonicalJson (Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $context.InitialGenerationId)) -ceq $c0Snapshot -and
            (Get-FileHash -LiteralPath $c0.capturePath -Algorithm SHA256).Hash -ceq $c0Hash) 'C0 sealed history changed after second-boundary failure'
        $c1After=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $first.GenerationId
        Assert-M12Overlap ($c1After.terminalStatus -ceq 'sealed' -and $c1After.containerId -ceq $first.NewContainerId -and
            $c1After.capturePath -ceq $c1Path -and (Get-FileHash -LiteralPath $c1Path -Algorithm SHA256).Hash -ceq $c1Hash) `
            'C1 did not remain the sealed old side of the failed second boundary'
        $hc2=@($handoffs|Where-Object{$_.oldGenerationId -ceq $first.GenerationId})
        Assert-M12Overlap ($hc2.Count -eq 1 -and $hc2[0].status -cne 'complete') 'second handoff was fabricated as complete or omitted'
        Assert-M12Overlap (@($manifest.captureGenerations['otel-collector']|Where-Object{$_.containerId -ceq ('c'*64) -and $_.terminalStatus -ceq 'capturing'}).Count -eq 0) `
            'C2 was incorrectly left active after second-boundary failure'
        $c0Handoffs=@($handoffs|Where-Object{$_.oldGenerationId -ceq $context.InitialGenerationId})
        Assert-M12Overlap ($c0Handoffs.Count -eq 1 -and $c0Handoffs[0].handoffId -ceq $first.HandoffId) 'failure created a shortcut handoff from C0 to C2'
        $c2=@($manifest.captureGenerations['otel-collector']|Where-Object{$_.containerId -ceq ('c'*64)})
        Assert-M12Overlap (@($c2|Where-Object{$_.terminalStatus -in @('capturing','sealed')}).Count -eq 0) 'failed C2 was active or sealed as accepted evidence'
        if($FailureStage -ceq 'readiness'){
            if($CleanupFails){
                Assert-M12Overlap ($context.State.Processes[[string]$context.State.LastFollowerPid]) 'cleanup-failure fixture did not retain the simulated live follower state'
            }else{
                Assert-M12Overlap (!$context.State.Processes[[string]$context.State.LastFollowerPid]) 'failed readiness follower was not stopped through the injected stop seam'
            }
        }
        Write-Output "m12_overlap_second_handoff_failure=PASS stage=$FailureStage cleanupFailure=$CleanupFails HC1=immutable HC2=incomplete C2=not_active"
    }finally{Remove-Item -LiteralPath $context.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

function Test-M12OverlapWrapperFailures([string] $RepositoryRoot){
    foreach($stage in @('replace','identity','follower','wrong-follower','readiness','readiness-cleanup-fails')){
        $context=New-M12OverlapFailureHarness $RepositoryRoot
        try{
            $context.State.FailureStage=$stage;$context.State.FailBoundary=1
            $failure=$null;try{$null=& $context.Replace 'first-boundary'}catch{$failure=$_}
            Assert-M12Overlap ($null -ne $failure) "wrapper accepted $stage failure"
            $manifest=Get-GeordiCaptureGenerationManifest $context.Root
            Assert-M12Overlap (@($manifest.captureHandoffs.Values|Where-Object{$_.status -ceq 'complete'}).Count -eq 0) `
                "$stage failure fabricated a completed handoff"
            Assert-M12Overlap (@($manifest.captureHandoffs.Values|Where-Object{$_.status -in @('incomplete-replacement','incomplete-new-generation')}).Count -eq 1) `
                "$stage failure was not retained as an incomplete handoff"
            if($stage -eq 'wrong-follower'){
                Assert-M12Overlap ($context.State.ReadinessCount -eq 0 -and
                    @($manifest.captureGenerations['otel-collector']|Where-Object terminalStatus -ceq 'incomplete-start').Count -eq 1) `
                    'wrong first-boundary Collector follower reached readiness or was accepted'
            }
            if($stage -in @('readiness','readiness-cleanup-fails')){
                Assert-M12Overlap ($context.State.ReadinessCount -eq 1) 'first-boundary readiness was not reached exactly once after follower validation'
                if($stage -eq 'readiness-cleanup-fails'){
                    $handoff=@($manifest.captureHandoffs.Values)[0]
                    $failed=@($manifest.captureGenerations['otel-collector']|Where-Object terminalStatus -ceq 'incomplete-start')[0]
                    Assert-M12Overlap ($context.State.Processes[[string]$context.State.LastFollowerPid] -and
                        $failed -and $handoff.status -ceq 'incomplete-new-generation') 'cleanup/readiness failure did not leave truthful incomplete state'
                }else{
                    Assert-M12Overlap (!$context.State.Processes[[string]$context.State.LastFollowerPid]) 'readiness failure did not stop the new follower'
                }
            }
        }finally{Remove-Item -LiteralPath $context.Root -Recurse -Force -ErrorAction SilentlyContinue}
    }
    Write-Output 'm12_overlap_wrapper_failures=PASS adapter=argv invoke_compose identity follower_start readiness_fail_closed=true'
}

function Test-M12OverlapWrongCollectorFollowerAtBoundary([string] $RepositoryRoot,[int] $Boundary){
    $context=New-M12OverlapFailureHarness $RepositoryRoot
    try{
        if($Boundary -eq 2){[void](& $context.Replace 'first-boundary')}
        $expectedNewId=if($Boundary -eq 1){'b'*64}else{'c'*64}
        $manifestBefore=Get-GeordiCaptureGenerationManifest $context.Root
        $firstHandoff=$null;$c0Snapshot=$null;$c0Hash=$null
        if($Boundary -eq 2){
            $first=@($manifestBefore.captureHandoffs.Values|Where-Object{$_.status -ceq 'complete'})[0]
            $firstHandoff=ConvertTo-GeordiM12OverlapCanonicalJson $first
            $c0=Get-GeordiCaptureGenerationRecord $manifestBefore 'otel-collector' $context.InitialGenerationId
            $c0Snapshot=ConvertTo-GeordiM12OverlapCanonicalJson $c0;$c0Hash=(Get-FileHash $c0.capturePath).Hash
        }
        $context.State.FailureStage='wrong-follower';$context.State.FailBoundary=$Boundary
        $failure=$null;try{[void](& $context.Replace 'wrong-follower-boundary')}catch{$failure=$_}
        $manifest=Get-GeordiCaptureGenerationManifest $context.Root
        Assert-M12Overlap ($null -ne $failure -and $context.State.ReadinessCount -eq ($Boundary-1)) "boundary $Boundary wrong follower reached readiness or succeeded"
        Assert-M12Overlap (@($manifest.captureGenerations['otel-collector']|Where-Object terminalStatus -ceq 'incomplete-start').Count -eq 1 -and
            @($manifest.captureGenerations['otel-collector']|Where-Object{[string]$_.containerId -ceq $expectedNewId -and $_.terminalStatus -ceq 'capturing'}).Count -eq 0) `
            "boundary $Boundary wrong follower was accepted or not marked incomplete"
        if($Boundary -eq 2){
            $completed=@($manifest.captureHandoffs.Values|Where-Object{$_.status -ceq 'complete'})
            $c0After=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $context.InitialGenerationId
            Assert-M12Overlap ($completed.Count -eq 1 -and (ConvertTo-GeordiM12OverlapCanonicalJson $completed[0]) -ceq $firstHandoff -and
                (ConvertTo-GeordiM12OverlapCanonicalJson $c0After) -ceq $c0Snapshot -and (Get-FileHash $c0After.capturePath).Hash -ceq $c0Hash) `
                'second-boundary wrong follower modified first completed history'
            Assert-M12Overlap (@($manifest.captureHandoffs.Values|Where-Object{$_.status -ceq 'incomplete-new-generation'}).Count -eq 1) `
                'second-boundary wrong follower did not leave its handoff incomplete'
        }
        Write-Output "m12_overlap_collector_wrong_follower=PASS boundary=$Boundary readiness_calls=$($Boundary-1) generation=not_active"
    }finally{Remove-Item -LiteralPath $context.Root -Recurse -Force -ErrorAction SilentlyContinue}
}

function Test-M12OverlapSequentialCollectorHandoffs([string] $RepositoryRoot){
    $root=New-M12OverlapTestCaptureRoot
    try{
        $state=[pscustomobject]@{Pid=64000;Processes=@{};Order=[Collections.Generic.List[string]]::new();CurrentId=('a'*64);
            NextIds=@(('b'*64),('c'*64));ReplacementIndex=0;LastFollower=$null;ReadinessCount=0}
        $startFollower={
            param([string] $Stdout,[string] $Stderr,[string] $ProcessRecord,[string[]] $DockerArguments,$Target)
            $state.Pid++
            $start=[DateTimeOffset]::UtcNow.ToString('o')
            [IO.File]::WriteAllText($Stdout,"synthetic-$($Target.containerId)`n",[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($Stderr,'',[Text.UTF8Encoding]::new($false))
            $record=[ordered]@{id=$state.Pid;name='synthetic-docker-follower';startUtc=$start;
                containerId=[string]$Target.containerId;service=[string]$Target.service;project=[string]$Target.project;createdUtc=[string]$Target.createdUtc}
            [IO.File]::WriteAllText($ProcessRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
            $state.Processes[[string]$state.Pid]=$true
            $state.LastFollower=[string]$Target.containerId
            $state.Order.Add("follower:$($Target.containerId)")
            return [pscustomobject]@{id=$state.Pid;name='synthetic-docker-follower';startUtc=$start}
        }.GetNewClosure()
        $identity=& ${function:New-M12OverlapTestIdentity} -Id $state.CurrentId -RepositoryRoot $RepositoryRoot
        $initial=Start-GeordiCaptureGeneration -CaptureRoot $root -Service 'otel-collector' -ContainerIdentity $identity `
            -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1' `
            -WorkingDirectory $RepositoryRoot -HandoffId '' -StartFollower $startFollower
        $initialRecord=Get-GeordiCaptureGenerationRecord (Get-GeordiCaptureGenerationManifest $root) 'otel-collector' $initial
        $initialHash=(Get-FileHash -LiteralPath $initialRecord.capturePath -Algorithm SHA256).Hash
        $renderConfiguration=${function:New-M12OverlapComposeFixture}
        $render={
            param([string] $RenderRoot,[bool] $ReplacementOverlay)
            return & $renderConfiguration -RepositoryRoot $RenderRoot -CollectorReplacementOverlay:$ReplacementOverlay
        }.GetNewClosure()
        $invoke={
            param([string[]] $Arguments,[string] $Phase)
            $accepted=@(Get-GeordiM12CollectorReplacementArguments -RepositoryRoot $RepositoryRoot)
            $expected=@(Get-GeordiM12OverlapCollectorReplacementArguments -RepositoryRoot $RepositoryRoot -AcceptedArguments $accepted)
            Assert-M12Overlap (($Arguments -join "`n") -ceq ($expected -join "`n")) 'synthetic replacement received unexpected command scope'
            $manifest=Get-GeordiCaptureGenerationManifest $root
            $oldSealed=@($manifest.captureGenerations['otel-collector']|Where-Object{$_.terminalStatus -ceq 'sealed'})
            $pending=@($manifest.captureHandoffs.Values|Where-Object{$_.status -ceq 'old-sealed'})
            Assert-M12Overlap ($pending.Count -eq 1 -and $oldSealed.Count -eq ($state.ReplacementIndex+1)) 'replacement ran before exact old generation seal'
            $newId=$state.NextIds[$state.ReplacementIndex]
            $state.ReplacementIndex++
            $state.CurrentId=$newId
            $state.Order.Add("replace:$newId")
        }.GetNewClosure()
        $identityBuilder=${function:New-M12OverlapTestIdentity}
        $resolve={
            param([string] $Service)
            $identity=& $identityBuilder -Id $state.CurrentId -RepositoryRoot $RepositoryRoot
            $missing=@('Id','Project','Service','WorkingDirectory','CreatedUtc'|Where-Object{
                $name=$_;[string]::IsNullOrWhiteSpace([string]$identity.$name)
            })
            if($missing.Count){throw ('Synthetic identity factory omitted fields: '+($missing -join ','))}
            return $identity
        }.GetNewClosure()
        $assertion=${function:Assert-M12Overlap}
        $readiness={
            & $assertion ($state.LastFollower -ceq $state.CurrentId) 'readiness ran before exact new follower startup'
            $state.ReadinessCount++
            $state.Order.Add("ready:$($state.CurrentId)")
        }.GetNewClosure()
        $identityCheck={param($process) return [bool]$state.Processes[[string]$process.id]}.GetNewClosure()
        $stop={param($process) $state.Processes[[string]$process.id]=$false}.GetNewClosure()
        $invokeReplacement=${function:Invoke-GeordiM12OverlapCollectorReplacement}
        $replace={
            param([string] $Boundary)
            & $invokeReplacement -CaptureRoot $root -RepositoryRoot $RepositoryRoot `
                -RenderComposeConfiguration $render -InvokeCompose $invoke -ResolveContainerIdentity $resolve `
                -WaitForReadiness $readiness -StartFollower $startFollower -TestProcessIdentity $identityCheck -StopProcess $stop `
                -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1'
        }.GetNewClosure()
        $first=& $replace 'overlap-reset'
        $firstHash=(Get-FileHash -LiteralPath (Get-GeordiCaptureGenerationRecord (Get-GeordiCaptureGenerationManifest $root) 'otel-collector' $first.GenerationId).capturePath -Algorithm SHA256).Hash
        $state.Order.Add('fixture-provider-reset')
        $provider={
            & $assertion ($state.CurrentId -ceq ('b'*64)) 'provider fixture started before the first Collector generation was active'
            $state.Order.Add('provider-services-ready')
        }.GetNewClosure()
        $backend={
            & $assertion ($state.CurrentId -ceq ('c'*64)) 'backend fixture started before the second Collector generation was active'
            $state.Order.Add('backend-and-traffic-fixture-ready')
        }.GetNewClosure()
        $sequence=Invoke-GeordiM12OverlapCollectorStartupSequence -FirstReplacement $first -ReplaceCollector $replace `
            -StartProviderServices $provider -StartBackendAndTrafficFixture $backend
        $manifest=Get-GeordiCaptureGenerationManifest $root
        $records=@($manifest.captureGenerations['otel-collector'])
        $handoffs=@($manifest.captureHandoffs.Values)
        Assert-M12Overlap ($sequence.First.NewContainerId -ceq ('b'*64) -and $sequence.Second.NewContainerId -ceq ('c'*64)) 'two distinct sequential Collector identities were not returned'
        Assert-M12Overlap ($records.Count -eq 3 -and $records[0].terminalStatus -ceq 'sealed' -and
            $records[1].terminalStatus -ceq 'sealed' -and $records[2].terminalStatus -ceq 'capturing') 'generation chain did not retain two sealed generations and one active generation'
        Assert-M12Overlap ($handoffs.Count -eq 2 -and @($handoffs|Where-Object{$_.status -ceq 'complete'}).Count -eq 2) 'two completed handoffs were not recorded'
        $handoffOne=@($handoffs|Where-Object{$_.oldGenerationId -ceq $records[0].generationId})
        $handoffTwo=@($handoffs|Where-Object{$_.oldGenerationId -ceq $records[1].generationId})
        Assert-M12Overlap ($handoffOne.Count -eq 1 -and $handoffOne[0].newGenerationId -ceq $records[1].generationId -and
            $handoffTwo.Count -eq 1 -and $handoffTwo[0].newGenerationId -ceq $records[2].generationId) 'handoff adjacency or reverse references are incorrect'
        $activeFinal=@($manifest.captureGenerations['otel-collector']|Where-Object{$_.terminalStatus -ceq 'capturing' -and $_.containerId -ceq $sequence.FinalCollectorContainerId})
        Assert-M12Overlap ($records[2].containerId -ceq $sequence.FinalCollectorContainerId -and $activeFinal.Count -eq 1) 'final exact Collector follower is not active'
        Assert-M12Overlap ($state.ReadinessCount -eq 2) 'readiness was not checked once after each exact follower startup'
        $finalRecord=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $sequence.FinalCollectorGenerationId
        Assert-M12Overlap ((Get-Content -LiteralPath $finalRecord.processRecordPath -Raw|ConvertFrom-Json).containerId -ceq $sequence.FinalCollectorContainerId) 'final follower process record is not bound to the exact new container'
        Assert-M12Overlap ((Get-FileHash -LiteralPath $initialRecord.capturePath -Algorithm SHA256).Hash -ceq $initialHash -and
            (Get-FileHash -LiteralPath (Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $first.GenerationId).capturePath -Algorithm SHA256).Hash -ceq $firstHash) 'sealed historical Collector evidence changed'
        $firstOrder=$state.Order
        Assert-M12Overlap ($firstOrder.IndexOf('provider-services-ready') -gt $firstOrder.IndexOf('fixture-provider-reset') -and
            $firstOrder.IndexOf('replace:'+('c'*64)) -gt $firstOrder.IndexOf('provider-services-ready') -and
            $firstOrder.IndexOf('backend-and-traffic-fixture-ready') -gt $firstOrder.IndexOf('ready:'+('c'*64))) 'Collector/provider/backend ordering changed'
        $null=Seal-GeordiCaptureGeneration -CaptureRoot $root -Service 'otel-collector' -GenerationId $sequence.FinalCollectorGenerationId `
            -TestProcessIdentity $identityCheck -StopProcess $stop
        Assert-GeordiCaptureGenerationManifest (Get-GeordiCaptureGenerationManifest $root)
        Write-Output 'm12_overlap_collector_handoffs=PASS graph=C0-H1-C1-H2-C2 exact_followers=true readiness_after_follower=true immutable=true'
        Write-Output 'm12_overlap_collector_startup_order=PASS reset_then_provider_then_collector_then_backend_fixture=true'
        Write-Output 'm12_overlap_m13_entry_collector_state=PASS active_generation=exact_C2 backend_generation=deferred_to_next_slice'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

if($ComposeIntegration -and ($SelfTest -or $Case)){throw 'Use -ComposeIntegration separately from -SelfTest and -Case.'}
if(!$SelfTest -and !$Case -and !$ComposeIntegration){throw 'Use -SelfTest, -ComposeIntegration or a focused -Case for M12 overlap Collector validation.'}
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($Case){
    switch($Case){
        'PrimaryCleanupSuccess' { Test-M12OverlapSecondHandoffFailure $root 'readiness' $false }
        'PrimaryCleanupFailure' { Test-M12OverlapSecondHandoffFailure $root 'readiness' $true }
        'WrapperFailures' { Test-M12OverlapCollectorCommandScope $root;Test-M12OverlapWrapperFailures $root }
        'SecondReplacementFailure' { Test-M12OverlapSecondHandoffFailure $root 'replace' }
        'SecondSameIdentityFailure' { Test-M12OverlapSecondHandoffFailure $root 'same-id' }
        'SecondFollowerFailure' { Test-M12OverlapSecondHandoffFailure $root 'follower' }
        'SecondReadinessFailure' { Test-M12OverlapSecondHandoffFailure $root 'readiness' $false }
    }
}
if($ComposeIntegration){
    $normal=Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $root
    $isolated=Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $root -CollectorReplacementOverlay -IsolationOverlay
    Test-M12OverlapComposeIsolation $root $normal $isolated
    Write-Output 'm12_overlap_compose_integration=PASS docker_operation=config_render_only lifecycle=NOT_INVOKED'
}
if($SelfTest){
    Test-M12OverlapComposeExecutorContract $root
    Test-M12OverlapSourceMap $root
    $normalFixture=New-M12OverlapComposeFixture
    $isolatedFixture=New-M12OverlapComposeFixture -IsolationOverlay
    Test-M12OverlapComposeIsolation $root $normalFixture $isolatedFixture
    Test-M12OverlapCollectorCommandScope $root
    Test-M12OverlapSequentialCollectorHandoffs $root
    Test-M12OverlapWrapperFailures $root
    Test-M12OverlapWrongCollectorFollowerAtBoundary $root 1
    Test-M12OverlapWrongCollectorFollowerAtBoundary $root 2
    Test-M12OverlapSecondHandoffFailure $root 'replace'
    Test-M12OverlapSecondHandoffFailure $root 'same-id'
    Test-M12OverlapSecondHandoffFailure $root 'follower'
    Test-M12OverlapSecondHandoffFailure $root 'readiness' $false
    Test-M12OverlapSecondHandoffFailure $root 'readiness' $true
    Write-Output 'm12_overlap_collector_self_test=PASS runtime=NOT_RUN ci=unchanged backend_generation=deferred'
}
