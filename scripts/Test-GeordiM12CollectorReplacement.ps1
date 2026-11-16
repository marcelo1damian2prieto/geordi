[CmdletBinding()]
param([switch] $SelfTest,[switch] $NormalizationOnly,[switch] $CommandScopeOnly,[switch] $DuplicateCaptureOnly,[switch] $StaticSemanticsOnly,[switch] $PositiveHandoffOnly,[switch] $DuplicateMatrixOnly,[switch] $DuplicateBoundaryOnly,[switch] $OverlayPropagationOnly,[switch] $FailClosedOnly,[switch] $ScenarioDispatchOnly,[switch] $ProtectedVolumeOnly)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM12CollectorReplacement.ps1')

function Assert-M12Replacement([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "M12 Collector replacement regression failed: $Message" }
}

function Get-TestComposeConfiguration([string] $Root,[bool] $ReplacementOverlay) {
    $arguments=Get-GeordiM12CollectorComposeArguments -RepositoryRoot $Root -ReplacementOverlay:$ReplacementOverlay
    $arguments+=@('config','--format','json')
    $json=& docker compose @arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'M12 replacement config-only render failed.' }
    return $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Test-M12OverlayAndPropagation([string] $RepositoryRoot) {
    $normal=Get-TestComposeConfiguration $RepositoryRoot $false
    $replacement=Get-TestComposeConfiguration $RepositoryRoot $true
    $dependents=Assert-GeordiM12CollectorReplacementConfiguration -NormalConfiguration $normal -ReplacementConfiguration $replacement
    $expectedDependents=@('backend','burn-demo','demo','demo-downstream','m12-burn-demo')
    Assert-M12Replacement ((@($dependents | Sort-Object) -join ',') -ceq (@($expectedDependents | Sort-Object) -join ',')) 'the replacement renderer did not discover every known restart edge'
    $normalRenderedDependents=@($normal.services.Keys | Where-Object { $normal.services[$_].Contains('depends_on') -and $normal.services[$_].depends_on.Contains('otel-collector') } | Sort-Object)
    $replacementRenderedDependents=@($replacement.services.Keys | Where-Object { $replacement.services[$_].Contains('depends_on') -and $replacement.services[$_].depends_on.Contains('otel-collector') } | Sort-Object)
    Assert-M12Replacement ((@($normalRenderedDependents) -join ',') -ceq (@($expectedDependents | Sort-Object) -join ',') -and
        (@($replacementRenderedDependents) -join ',') -ceq (@($expectedDependents | Sort-Object) -join ',')) 'normal and replacement renders do not retain the expected dependency set'
    $normalTrueEdges=@($normalRenderedDependents | Where-Object { Get-GeordiM12EffectiveDependencyRestart $normal.services[$_].depends_on['otel-collector'] })
    $replacementTrueEdges=@($replacementRenderedDependents | Where-Object { Get-GeordiM12EffectiveDependencyRestart $replacement.services[$_].depends_on['otel-collector'] })
    Assert-M12Replacement ($normalTrueEdges.Count -eq 5 -and $replacementTrueEdges.Count -eq 0) 'effective propagation did not change from five normal edges to zero isolated edges'
    foreach ($name in $expectedDependents) {
        Assert-M12Replacement ($normal.services[$name].depends_on['otel-collector'].condition -ceq $replacement.services[$name].depends_on['otel-collector'].condition) "dependency condition changed for $name"
    }
    Write-Output 'm12_replacement_overlay_render=PASS dependencies_discovered=true conditions_preserved=true config_equivalent=true'
    Write-Output 'm12_restart_propagation=PASS normal_true_edges=5 replacement_true_edges=0'
    return [pscustomobject]@{NormalTrueEdges=$normalTrueEdges.Count;ReplacementTrueEdges=$replacementTrueEdges.Count;Replacement=$replacement}
}

function Test-M12ProtectedVolumeConfiguration([string] $RepositoryRoot) {
    $replacementConfiguration=Get-TestComposeConfiguration $RepositoryRoot $true
    $protected=@('geordi_m19-alert-lifecycle-data','geordi_m19-victoriametrics-data')
    Assert-M12Replacement (@($replacementConfiguration.services['otel-collector'].volumes | Where-Object { $_.source -in $protected -or $_.target -in $protected }).Count -eq 0) `
        'Collector mounts a protected M19 volume'
    Assert-M12Replacement (@($replacementConfiguration.volumes.Keys | Where-Object { $_ -in @('m12-alert-lifecycle-data','m12-victoriametrics-data') }).Count -eq 2) `
        'M12 dedicated volumes were not preserved in configuration'
    Write-Output 'm12_protected_volume_regression=PASS collector_protected_mounts=0 m12_volumes_preserved=true'
}

function New-TestCollectorIdentity([string] $Id,[string] $Service='otel-collector',[string] $Project='geordi') {
    return [pscustomobject]@{Id=$Id;Project=$Project;Service=$Service;WorkingDirectory=(Get-Location).Path;
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}
}

function New-TestCaptureRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m12-collector-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-m12-candidate';startedUtc=[DateTimeOffset]::UtcNow.ToString('o');
        captureStartedUtc=[DateTimeOffset]::UtcNow.ToString('o');captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};captures=@{}}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 32 -Compress),[Text.UTF8Encoding]::new($false))
    return $root
}

function Start-TestFollower {
    param([string] $Stdout,[string] $Stderr,[string] $ProcessPath,[string[]] $Arguments,$Target)
    $script:testPid++
    $started=if($script:followerStartUtc){[string]$script:followerStartUtc}else{[DateTimeOffset]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($Stdout,"synthetic-$($Target.service)-$($Target.containerId)`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($Stderr,'',[Text.UTF8Encoding]::new($false))
    $record=[ordered]@{id=$script:testPid;name='synthetic-docker';startUtc=$started;containerId=[string]$Target.containerId;
        service=[string]$Target.service;project=[string]$Target.project;createdUtc=[string]$Target.createdUtc}
    [IO.File]::WriteAllText($ProcessPath,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
    $script:testProcesses[[string]$script:testPid]=$true
    return [pscustomobject]@{id=$script:testPid;name='synthetic-docker';startUtc=$started}
}

function Test-TestFollowerIdentity($Record) { return [bool]$script:testProcesses[[string]$Record.id] }
function Stop-TestFollower($Record) { $script:testProcesses[[string]$Record.id]=$false }

function ConvertTo-M12BoundedDiagnosticText([AllowNull()][string] $Text) {
    if ($null -eq $Text) { return $null }
    $safe=$Text -replace '[\r\n\t]+',' ' -replace '(?i)(token|password|secret|authorization)\s*[:=]\s*\S+','$1=[redacted]' -replace 'https?://\S+','[url]'
    if ($safe.Length -gt 240) { $safe=$safe.Substring(0,240) }
    return $safe
}

function New-M12FailureDiagnostic([System.Management.Automation.ErrorRecord] $ErrorRecord,[string] $Stage) {
    $inner=$ErrorRecord.Exception.InnerException
    $scriptName=$null;$functionName=$null;$line=0
    if ($ErrorRecord.InvocationInfo) {
        $scriptName=[string]$ErrorRecord.InvocationInfo.ScriptName
        $line=[int]$ErrorRecord.InvocationInfo.ScriptLineNumber
        if ($ErrorRecord.InvocationInfo.MyCommand) { $functionName=[string]$ErrorRecord.InvocationInfo.MyCommand.Name }
    }
    return [pscustomobject]@{
        Stage=$Stage
        Type=$ErrorRecord.Exception.GetType().FullName
        Message=ConvertTo-M12BoundedDiagnosticText ([string]$ErrorRecord.Exception.Message)
        InnerType=if($inner){$inner.GetType().FullName}else{$null}
        InnerMessage=if($inner){ConvertTo-M12BoundedDiagnosticText ([string]$inner.Message)}else{$null}
        Script=ConvertTo-M12BoundedDiagnosticText $scriptName
        Function=ConvertTo-M12BoundedDiagnosticText $functionName
        Line=$line
    }
}

function Start-TestGeneration([string] $Root,[string] $Id) {
    return Start-GeordiCaptureGeneration -CaptureRoot $Root -Service 'otel-collector' -ContainerIdentity (New-TestCollectorIdentity $Id) `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1' `
        -WorkingDirectory (Get-Location).Path -StartFollower ${function:Start-TestFollower}
}

function New-TestSealedCollectorHandoff([string] $Root,[string] $OldId=('1'*64),[string] $NewId=('2'*64)) {
    $script:testPid=60000;$script:testProcesses=@{};$script:followerStartUtc=$null
    $oldGeneration=Start-TestGeneration $Root $OldId
    $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $Root -Service 'otel-collector' -Reason 'synthetic-duplicate-matrix' `
        -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
    $newGeneration=Start-GeordiCaptureGeneration -CaptureRoot $Root -Service 'otel-collector' -ContainerIdentity (New-TestCollectorIdentity $NewId) `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1' `
        -WorkingDirectory (Get-Location).Path -HandoffId $handoff -StartFollower ${function:Start-TestFollower}
    $null=Seal-GeordiCaptureGeneration -CaptureRoot $Root -Service 'otel-collector' -GenerationId $newGeneration `
        -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
    $manifest=Get-GeordiCaptureGenerationManifest $Root
    $oldRecord=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $oldGeneration
    $newRecord=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $newGeneration
    return [pscustomobject]@{OldGeneration=$oldGeneration;NewGeneration=$newGeneration;OldId=$OldId;NewId=$NewId;HandoffId=$handoff;
        OldCapturePath=[string]$oldRecord.capturePath;NewCapturePath=[string]$newRecord.capturePath}
}

function New-TestComposeConfiguration([switch] $Replacement,[switch] $BadCollector,[switch] $UnexpectedPropagation) {
    $collector=[ordered]@{image='geordi-otel-collector:0.157.0';command=@('--config=/etc/otelcol/config.yaml');environment=@{};
        volumes=@(@{type='bind';source=(Join-Path (Get-Location).Path 'otel/otel-collector-config.yaml');target='/etc/otelcol/config.yaml';read_only=$true});
        networks=@{default=@{}};ports=@(@{target=4318;published='4318';protocol='tcp'});healthcheck=@{test=@('CMD','/health');interval='2s'};
        security_opt=@();deploy=@{resources=@{limits=@{memory='256M'}}};restart='unless-stopped';labels=@{'com.docker.compose.service'='otel-collector'};
        depends_on=@{victoriametrics=@{condition='service_healthy';restart=$true};tempo=@{condition='service_healthy';restart=$true};loki=@{condition='service_healthy';restart=$true}}}
    if ($BadCollector) { $collector.image='unexpected-collector-image' }
    $services=[ordered]@{'otel-collector'=$collector}
    foreach ($name in @('backend','demo','burn-demo','demo-downstream','m12-burn-demo')) {
        $dependencies=[ordered]@{'otel-collector'=@{condition='service_healthy';restart=$true}}
        if ($name -eq 'backend') { $dependencies['victoriametrics']=@{condition='service_healthy';restart=$true} }
        if ($Replacement) { $dependencies['otel-collector'].restart=$false }
        $services[$name]=[ordered]@{image="geordi-$name:local";depends_on=$dependencies;environment=@{};volumes=@();networks=@{default=@{}}}
    }
    $services.frontend=[ordered]@{image='geordi-frontend:local';environment=@{};volumes=@();networks=@{default=@{}}}
    $services['webhook-receiver-a']=[ordered]@{image='python:3.13-alpine';environment=@{};volumes=@();networks=@{default=@{}}}
    $services['webhook-receiver-b']=[ordered]@{image='python:3.13-alpine';environment=@{};volumes=@();networks=@{default=@{}}}
    if ($UnexpectedPropagation) { $services['new-collector-dependent']=[ordered]@{depends_on=@{'otel-collector'=@{condition='service_started';restart=$true}}} }
    return [ordered]@{services=$services;volumes=[ordered]@{'m12-alert-lifecycle-data'=@{name='geordi_m12-alert-lifecycle-data'};
        'm12-victoriametrics-data'=@{name='geordi_m12-victoriametrics-data'}};networks=@{default=@{name='geordi_default'}}}
}

function Test-M12RestartNormalization {
    $restartCases=@(
        @{name='true';value=$true;expected=$true;omit=$false},
        @{name='false';value=$false;expected=$false;omit=$false},
        @{name='absent';value=$null;expected=$false;omit=$true}
    )
    foreach ($case in $restartCases) {
        $edge=[ordered]@{condition='service_healthy'}
        if (!$case.omit) { $edge.restart=$case.value }
        Assert-M12Replacement ((Get-GeordiM12EffectiveDependencyRestart $edge) -eq $case.expected) "effective restart normalization failed for $($case.name)"
    }
    foreach ($badValue in @($null,'false')) {
        $badEdge=[ordered]@{condition='service_healthy';restart=$badValue};$rejected=$false
        try { $null=Get-GeordiM12EffectiveDependencyRestart $badEdge } catch { $rejected=$true }
        Assert-M12Replacement $rejected 'malformed null or string restart value was not rejected'
    }
    $malformedRejected=$false
    try { $null=Get-GeordiM12EffectiveDependencyRestart 'not-an-edge' } catch { $malformedRejected=$true }
    Assert-M12Replacement $malformedRejected 'malformed dependency entry was not rejected'

    $normal=New-TestComposeConfiguration
    $replacement=New-TestComposeConfiguration -Replacement
    foreach ($serviceName in @($replacement.services.Keys)) {
        $service=$replacement.services[$serviceName]
        if ($service.Contains('depends_on') -and $service.depends_on.Contains('otel-collector')) {
            $service.depends_on['otel-collector'].Remove('restart')
        }
    }
    $expected=@(Assert-GeordiM12CollectorReplacementConfiguration -NormalConfiguration $normal -ReplacementConfiguration $replacement)
    Assert-M12Replacement ($expected.Count -eq 5) 'rendered replacement with omitted restart fields did not retain all expected dependencies'

    $missingDependency=New-TestComposeConfiguration -Replacement
    $missingDependency.services['backend'].depends_on.Remove('otel-collector')
    $missingRejected=$false
    try { $null=Assert-GeordiM12CollectorReplacementConfiguration -NormalConfiguration $normal -ReplacementConfiguration $missingDependency } catch { $missingRejected=$true }
    Assert-M12Replacement $missingRejected 'replacement config was allowed to remove an expected Collector dependency'

    $changedCondition=New-TestComposeConfiguration -Replacement
    $changedCondition.services['backend'].depends_on['otel-collector'].condition='service_started'
    $conditionRejected=$false
    try { $null=Assert-GeordiM12CollectorReplacementConfiguration -NormalConfiguration $normal -ReplacementConfiguration $changedCondition } catch { $conditionRejected=$true }
    Assert-M12Replacement $conditionRejected 'replacement config was allowed to change the Collector dependency condition'

    $remainingPropagation=New-TestComposeConfiguration -Replacement
    $remainingPropagation.services['backend'].depends_on['otel-collector'].restart=$true
    $propagationRejected=$false
    try { $null=Assert-GeordiM12CollectorReplacementConfiguration -NormalConfiguration $normal -ReplacementConfiguration $remainingPropagation } catch { $propagationRejected=$true }
    Assert-M12Replacement $propagationRejected 'a remaining effective restart=true edge was not rejected'
    Write-Output 'm12_effective_restart_normalization=PASS true=false=absent malformed_null_string rejected missing_dependency=rejected condition_change=rejected'
}

function Get-TestM12CommandModel {
    param([Parameter(Mandatory)][string[]] $Arguments,[Parameter(Mandatory)][string] $ExpectedRoot,
        [Parameter(Mandatory)][string[]] $ExpectedComposeFiles)
    $files=[Collections.Generic.List[string]]::new();$projectDirectory=$null;$index=0
    while ($index -lt $Arguments.Count) {
        $token=[string]$Arguments[$index]
        if ($token -ceq 'up') { break }
        if ($token -in @('--file','-f','--project-directory','--project-name')) {
            if (($index+1) -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace([string]$Arguments[$index+1])) {
                throw "Malformed Compose option/value pair for $token."
            }
            $value=[string]$Arguments[$index+1]
            if ($token -in @('--file','-f')) { $files.Add([IO.Path]::GetFullPath($value)) }
            if ($token -ceq '--project-directory') { $projectDirectory=[IO.Path]::GetFullPath($value) }
            $index+=2;continue
        }
        if ($token -in @('down','rm','prune')) { throw "Forbidden Compose operation: $token" }
        throw "Unexpected Compose configuration token: $token"
    }
    if ($index -ge $Arguments.Count -or [string]$Arguments[$index] -cne 'up') { throw 'Compose up operation is missing.' }
    $index++
    $flags=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $targets=[Collections.Generic.List[string]]::new()
    for (; $index -lt $Arguments.Count; $index++) {
        $token=[string]$Arguments[$index]
        if ($token -in @('-d','--no-deps','--force-recreate','--always-recreate-deps','-v','--volumes')) { [void]$flags.Add($token);continue }
        if ($token.StartsWith('-', [StringComparison]::Ordinal)) { throw "Unexpected Compose up option: $token" }
        $targets.Add($token)
    }
    if (($files.ToArray() -join "`n") -cne ($ExpectedComposeFiles -join "`n")) { throw 'Effective Compose file selection does not match the M12 replacement stack.' }
    if (!$projectDirectory -or [IO.Path]::GetFullPath($projectDirectory) -cne [IO.Path]::GetFullPath($ExpectedRoot)) { throw 'Compose project directory is missing or incorrect.' }
    if ($targets.Count -ne 1 -or $targets[0] -cne 'otel-collector') { throw 'Compose service target set is not exactly otel-collector.' }
    if (!$flags.Contains('-d') -or !$flags.Contains('--no-deps') -or !$flags.Contains('--force-recreate')) { throw 'Compose replacement is missing a required operation flag.' }
    if ($flags.Contains('--always-recreate-deps') -or $flags.Contains('-v') -or $flags.Contains('--volumes')) { throw 'Compose replacement includes a forbidden dependency or volume flag.' }
    return [pscustomobject]@{Files=$files.ToArray();ProjectDirectory=$projectDirectory;Flags=@($flags);Targets=$targets.ToArray()}
}

function Test-M12CommandScope([string] $RepositoryRoot) {
    $scopeRoot=Join-Path ([IO.Path]::GetTempPath()) 'geordi test root backend'
    $arguments=Get-GeordiM12CollectorReplacementArguments -RepositoryRoot $scopeRoot
    $expectedFiles=@(@('compose.yaml','compose.m19.yaml','compose.m12.yaml','compose.m12-collector-replacement.yaml') | ForEach-Object { Join-Path $scopeRoot $_ })
    $model=Get-TestM12CommandModel -Arguments $arguments -ExpectedRoot $scopeRoot -ExpectedComposeFiles $expectedFiles
    $mockComposeExecutor={param([string[]]$Arguments,[string]$Phase) $Arguments}
    $capturedArguments=@(& $mockComposeExecutor $arguments 'M12 Collector controlled replacement')
    Assert-M12Replacement ($capturedArguments.Count -eq 15 -and $capturedArguments[0] -ceq '--file' -and
        $capturedArguments[1] -ceq (Join-Path $scopeRoot 'compose.yaml') -and $capturedArguments[10] -ceq 'up') 'production argument vector was flattened, reordered, or lost a path containing spaces'
    Assert-M12Replacement ($model.Targets.Count -eq 1 -and $model.Targets[0] -ceq 'otel-collector') 'production command has extra or missing service targets'

    $negativeCases=[Collections.Generic.List[object]]::new()
    $copy=[Collections.Generic.List[string]]::new();$copy.AddRange([string[]]$arguments);$copy.Remove('--no-deps');$negativeCases.Add(@{name='missing --no-deps';args=$copy.ToArray()})
    $copy=[Collections.Generic.List[string]]::new();$copy.AddRange([string[]]$arguments);$copy.Remove('--force-recreate');$negativeCases.Add(@{name='missing --force-recreate';args=$copy.ToArray()})
    $copy=[Collections.Generic.List[string]]::new();$copy.AddRange([string[]]$arguments);$copy.Add('--always-recreate-deps');$negativeCases.Add(@{name='always recreate dependencies';args=$copy.ToArray()})
    $copy=[Collections.Generic.List[string]]::new();$copy.AddRange([string[]]$arguments);$copy.Remove('otel-collector');$negativeCases.Add(@{name='no target';args=$copy.ToArray()})
    foreach ($target in @('backend','frontend','demo','burn-demo','demo-downstream','m12-burn-demo','webhook-receiver-a')) {
        $copy=[Collections.Generic.List[string]]::new();$copy.AddRange([string[]]$arguments);$copy.Add($target);$negativeCases.Add(@{name="extra target $target";args=$copy.ToArray()})
    }
    $copy=[Collections.Generic.List[string]]::new();$copy.AddRange([string[]]$arguments);$overlayIndex=$copy.IndexOf((Join-Path $scopeRoot 'compose.m12-collector-replacement.yaml'));$copy.RemoveAt($overlayIndex);$copy.RemoveAt($overlayIndex-1);$negativeCases.Add(@{name='overlay absent';args=$copy.ToArray()})
    foreach ($operation in @('down','rm','prune')) {
        $copy=[Collections.Generic.List[string]]::new();$copy.AddRange([string[]]$arguments);$operationIndex=$copy.IndexOf('up');$copy[$operationIndex]=$operation
        if ($operation -ceq 'rm') { $copy.RemoveAt($copy.Count-1);$copy.Add('-v') }
        $negativeCases.Add(@{name="forbidden operation $operation";args=$copy.ToArray()})
    }
    $negativeCases.Add(@{name='malformed option/value pair';args=[string[]]@('--file')})
    foreach ($negative in $negativeCases) {
        $rejected=$false
        try { $null=Get-TestM12CommandModel -Arguments ([string[]]$negative.args) -ExpectedRoot $scopeRoot -ExpectedComposeFiles $expectedFiles } catch { $rejected=$true }
        Assert-M12Replacement $rejected ("command parser accepted " + $negative.name)
    }
    $optionValueRoot=Join-Path ([IO.Path]::GetTempPath()) 'geordi test root backend'
    $optionValueArguments=Get-GeordiM12CollectorReplacementArguments -RepositoryRoot $optionValueRoot
    $optionValueFiles=@(@('compose.yaml','compose.m19.yaml','compose.m12.yaml','compose.m12-collector-replacement.yaml') | ForEach-Object { Join-Path $optionValueRoot $_ })
    $optionValueModel=Get-TestM12CommandModel -Arguments $optionValueArguments -ExpectedRoot $optionValueRoot -ExpectedComposeFiles $optionValueFiles
    Assert-M12Replacement ($optionValueModel.Targets.Count -eq 1 -and $optionValueModel.Targets[0] -ceq 'otel-collector') 'project-directory option value was misclassified as a service target'
    Write-Output 'm12_replacement_command_scope=PASS executable=docker target=otel-collector no_deps=true force_recreate=true overlay=true option_values_not_targets=true negative_cases=PASS'
}

function Test-M12DuplicateCapturePrevention {
    $resetServices=Get-GeordiM12LegacyResetCaptureServices -Services @('backend','victoriametrics','otel-collector','m12-burn-demo')
    $m12Path=Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($m12Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'M12 source parser failed during Collector capture-prevention regression.'}
    $resetFunction=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Reset-M12FixtureVolumes'},$true))
    if($resetFunction.Count -ne 1){throw 'M12 reset helper is missing or ambiguous during Collector capture-prevention regression.'}
    $resetText=$resetFunction[0].Extent.Text
    $captureCall=$resetText.IndexOf('-Services $legacyCaptureServices',[StringComparison]::Ordinal)
    $replacementCall=$resetText.IndexOf('Invoke-GeordiM12CollectorControlledReplacement',[StringComparison]::Ordinal)
    $directRestart=$resetText -match 'docker\s+restart\s+.*otel-collector'
    Assert-M12Replacement ('otel-collector' -notin $resetServices -and @('backend','victoriametrics','m12-burn-demo' | Where-Object { $_ -notin $resetServices }).Count -eq 0) 'legacy M12 snapshot did not preserve non-Collector evidence while excluding Collector'
    Assert-M12Replacement ($captureCall -ge 0 -and $replacementCall -gt $captureCall -and !$directRestart) 'M12 reset does not use the filtered legacy capture and controlled replacement path'
    $m13Source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-alert-routing.ps1') -Raw
    Assert-M12Replacement ($m13Source.Contains('compose.m13.yaml') -and !$m13Source.Contains('compose.m12-collector-replacement.yaml')) 'M12 isolation overlay leaked into M13 configuration'
    Write-Output 'm12_duplicate_capture_prevention=PASS legacy_snapshot_excludes_collector backend_vm_burn_evidence_preserved=true'
}

function Assert-M12DuplicateMatrixFailure([string] $Name,[string] $ExpectedMessage,[scriptblock] $Action) {
    $actualMessage=$null
    try { & $Action } catch { $actualMessage=[string]$_.Exception.Message }
    Assert-M12Replacement ($actualMessage -and $actualMessage -match $ExpectedMessage) ("duplicate matrix case did not fail for its intended invariant: " + $Name)
    Write-Output ("m12_duplicate_matrix_case=PASS case=" + $Name)
}

function Test-M12DuplicateCaptureNegativeMatrix {
    # A: A generation that has already been sealed cannot be sealed again.
    $root=New-TestCaptureRoot
    try {
        $script:testPid=61000;$script:testProcesses=@{};$script:followerStartUtc=$null
        $generation=Start-TestGeneration $root ('a'*64)
        $null=Seal-GeordiCaptureGeneration -CaptureRoot $root -Service 'otel-collector' -GenerationId $generation `
            -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
        Assert-M12DuplicateMatrixFailure 'same old generation sealed twice' 'Active capture generation cannot be sealed' {
            Seal-GeordiCaptureGenerationCore -CaptureRoot $root -Service 'otel-collector' -GenerationId $generation `
                -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

    # B: Sealing refuses a physical stdout path already registered to a channel.
    $root=New-TestCaptureRoot
    try {
        $script:testPid=62000;$script:testProcesses=@{};$script:followerStartUtc=$null
        $generation=Start-TestGeneration $root ('b'*64)
        $record=Get-GeordiCaptureGenerationRecord (Get-GeordiCaptureGenerationManifest $root) 'otel-collector' $generation
        $recordPath=[string]$record.capturePath;$runId='synthetic-m12-candidate';$manifestPath=Join-Path $root 'manifest.json'
        $mutation={param($manifest)$manifest.generationCaptures.otel=@($manifest.generationCaptures.otel)+$recordPath}.GetNewClosure()
        $null=Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId $runId -Mutation $mutation
        Assert-M12DuplicateMatrixFailure 'same physical capture path registered twice' 'Capture generation path was already registered' {
            Seal-GeordiCaptureGenerationCore -CaptureRoot $root -Service 'otel-collector' -GenerationId $generation `
                -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

    # C: The manifest validator rejects duplicate publication of one generation record.
    $root=New-TestCaptureRoot
    try {
        $chain=New-TestSealedCollectorHandoff $root ('c'*64) ('d'*64)
        $manifest=Get-GeordiCaptureGenerationManifest $root
        $records=@($manifest.captureGenerations['otel-collector'])
        $manifest.captureGenerations['otel-collector']=@($records)+$records[-1]
        Assert-M12DuplicateMatrixFailure 'same new Collector generation registered twice' 'Capture generation manifest is incomplete or ambiguous' {
            Assert-GeordiCaptureGenerationManifest $manifest
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

    # D: The authoritative legacy reset filter removes Collector before its separate handoff owner.
    $requestedLegacy=@('backend','victoriametrics','otel-collector','m12-burn-demo')
    $legacyOwners=Get-GeordiM12LegacyResetCaptureServices -Services $requestedLegacy
    $handoffOwners=@('otel-collector')
    $conflict=@($requestedLegacy | Where-Object { $_ -in $handoffOwners })
    Assert-M12Replacement ($conflict.Count -eq 1 -and 'otel-collector' -notin $legacyOwners -and 'otel-collector' -in $handoffOwners) `
        'legacy M12 capture and Collector handoff both retained the same transition owner'
    Write-Output 'm12_duplicate_matrix_case=PASS case=legacy-reset-and-handoff-double-claim-filtered'

    # E: A sealed old/new pair cannot point at one physical stdout file.
    $root=New-TestCaptureRoot
    try {
        $chain=New-TestSealedCollectorHandoff $root ('e'*64) ('f'*64)
        $manifest=Get-GeordiCaptureGenerationManifest $root
        $old=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $chain.OldGeneration
        $new=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $chain.NewGeneration
        $new.capturePath=[string]$old.capturePath;$new.captureFileIdentity=[string]$old.captureFileIdentity
        foreach($channel in @('otel','collector')) {
            $paths=@($manifest.generationCaptures[$channel] | Where-Object { [string]$_ -cne [string]$chain.NewCapturePath })
            $manifest.generationCaptures[$channel]=@($paths)+[string]$old.capturePath
        }
        Assert-M12DuplicateMatrixFailure 'old and new generations reuse physical capture file' 'Capture generation path is missing, duplicated or misidentified' {
            Assert-GeordiCaptureGenerationManifest $manifest
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

    # F: A second handoff record for the same old/new boundary must not validate.
    $root=New-TestCaptureRoot
    try {
        $chain=New-TestSealedCollectorHandoff $root ('1'*64) ('2'*64)
        $manifest=Get-GeordiCaptureGenerationManifest $root
        $duplicateId=[guid]::NewGuid().ToString('N')
        $duplicate=[ordered]@{}
        foreach($key in $manifest.captureHandoffs[$chain.HandoffId].Keys){$duplicate[$key]=$manifest.captureHandoffs[$chain.HandoffId][$key]}
        $duplicate.handoffId=$duplicateId;$manifest.captureHandoffs[$duplicateId]=$duplicate
        Assert-M12DuplicateMatrixFailure 'duplicate handoff for same old/new boundary' 'Capture handoff|duplicate' {
            Assert-GeordiCaptureGenerationManifest $manifest
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

    # G: Sealed evidence bytes remain hash-bound and tampering is rejected.
    $root=New-TestCaptureRoot
    try {
        $chain=New-TestSealedCollectorHandoff $root ('3'*64) ('4'*64)
        $manifest=Get-GeordiCaptureGenerationManifest $root
        $old=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $chain.OldGeneration
        (Get-Item -LiteralPath $old.capturePath -Force).IsReadOnly=$false
        [IO.File]::AppendAllText([string]$old.capturePath,'tampered')
        Assert-M12DuplicateMatrixFailure 'sealed historical evidence modified after sealing' 'Capture generation integrity verification failed' {
            Assert-GeordiCaptureGenerationManifest $manifest
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

    # H: The old container identity cannot be registered as its own replacement.
    $root=New-TestCaptureRoot
    try {
        $script:testPid=63000;$script:testProcesses=@{};$script:followerStartUtc=$null
        $oldGeneration=Start-TestGeneration $root ('5'*64)
        $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service 'otel-collector' -Reason 'same-old-new-negative' `
            -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
        Assert-M12DuplicateMatrixFailure 'old follower/container reused for new generation' 'Replacement container identity does not prove a new generation' {
            Start-GeordiCaptureGeneration -CaptureRoot $root -Service 'otel-collector' -ContainerIdentity (New-TestCollectorIdentity ('5'*64)) `
                -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1' `
                -WorkingDirectory (Get-Location).Path -HandoffId $handoff -StartFollower ${function:Start-TestFollower}
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

    # I: A second publication for one new container is rejected while its generation is active.
    $root=New-TestCaptureRoot
    try {
        $script:testPid=64000;$script:testProcesses=@{};$script:followerStartUtc=$null
        $null=Start-TestGeneration $root ('6'*64)
        $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service 'otel-collector' -Reason 'duplicate-new-publication' `
            -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
        $newId='7'*64
        $null=Start-GeordiCaptureGeneration -CaptureRoot $root -Service 'otel-collector' -ContainerIdentity (New-TestCollectorIdentity $newId) `
            -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1' `
            -WorkingDirectory (Get-Location).Path -HandoffId $handoff -StartFollower ${function:Start-TestFollower}
        Assert-M12DuplicateMatrixFailure 'new container generation published more than once' 'A capture generation is already active for this service' {
            Start-GeordiCaptureGeneration -CaptureRoot $root -Service 'otel-collector' -ContainerIdentity (New-TestCollectorIdentity $newId) `
                -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1' `
                -WorkingDirectory (Get-Location).Path -HandoffId $handoff -StartFollower ${function:Start-TestFollower}
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output 'm12_duplicate_capture_negative_matrix=PASS cases=9'
}

function Test-M12DuplicateHandoffBoundary {
    $root=New-TestCaptureRoot
    try {
        $chain=New-TestSealedCollectorHandoff $root ('8'*64) ('9'*64)
        $manifest=Get-GeordiCaptureGenerationManifest $root
        Assert-GeordiCaptureGenerationManifest $manifest
        $duplicateId=[guid]::NewGuid().ToString('N')
        $duplicate=[ordered]@{}
        foreach($key in $manifest.captureHandoffs[$chain.HandoffId].Keys){$duplicate[$key]=$manifest.captureHandoffs[$chain.HandoffId][$key]}
        $duplicate.handoffId=$duplicateId
        $duplicate.replacementReason='different-reason'
        $old=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $chain.OldGeneration
        $new=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $chain.NewGeneration
        $duplicate.startedUtc=$old.captureEndedUtc
        $duplicate.completedUtc=$new.captureStartedUtc
        $manifest.captureHandoffs[$duplicateId]=$duplicate
        Assert-M12DuplicateMatrixFailure 'duplicate handoff for same old/new boundary' 'Duplicate completed capture handoff boundary' {
            Assert-GeordiCaptureGenerationManifest $manifest
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output 'm12_duplicate_matrix_case=PASS case=duplicate_handoff_same_old_new_boundary'
}

function Get-M12StaticControlFlowModel([Parameter(Mandatory)][string] $Source) {
    $tokens=$null;$parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'M12 static control-flow fixture did not parse.' }
    $top=@($ast.EndBlock.Statements)
    $resetBranch=@($top | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Clauses.Count -gt 0 -and $_.Clauses[0].Item1.Extent.Text.Trim() -ceq '$RunFixtureResetOnly' })
    $resetFunction=@($top | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Reset-M12FixtureVolumes' })
    $normalTry=@($top | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
    if ($resetBranch.Count -ne 1 -or $resetFunction.Count -ne 1 -or $normalTry.Count -ne 1) {
        throw 'M12 static control-flow branches could not be identified uniquely.'
    }
    return [pscustomobject]@{
        ResetOnly=@($resetBranch[0].Clauses[0].Item2.Statements)
        ResetHelper=@($resetFunction[0].Body.EndBlock.Statements)
        Normal=@($normalTry[0].Body.Statements)
        NormalFinally=if ($normalTry[0].Finally) {@($normalTry[0].Finally.Statements)} else {@()}
    }
}

function Get-M12ControlFlowEventIndex([System.Management.Automation.Language.StatementAst[]] $Statements,[string] $Marker) {
    $matches=[Collections.Generic.List[System.Management.Automation.Language.StatementAst]]::new()
    foreach($statement in $Statements) {
        if($statement.Extent.Text.Contains($Marker)){$matches.Add($statement)}
        foreach($child in $statement.FindAll({param($node) $node -is [System.Management.Automation.Language.StatementAst] -and $node.Extent.Text.Contains($Marker)},$true)){
            $matches.Add($child)
        }
    }
    if($matches.Count -eq 0){return -1}
    $narrowest=$matches|Sort-Object { $_.Extent.EndOffset-$_.Extent.StartOffset }|Select-Object -First 1
    return [int]$narrowest.Extent.StartOffset
}

function Assert-M12ControlFlowSequence([System.Management.Automation.Language.StatementAst[]] $Statements,[string[]] $Markers,[string] $Message) {
    $previous=-1
    foreach ($marker in $Markers) {
        $index=Get-M12ControlFlowEventIndex -Statements $Statements -Marker $marker
        Assert-M12Replacement ($index -gt $previous) $Message
        $previous=$index
    }
}

function Test-M12StaticControlFlow([string] $Source,[string] $Label) {
    $model=Get-M12StaticControlFlowModel -Source $Source
    $resetText=(@($model.ResetOnly | ForEach-Object { $_.Extent.Text }) -join "`n")
    Assert-M12Replacement ($resetText.Contains('Reset-M12FixtureVolumes $root') -and $resetText -match '(?m)^\s*exit\s+0\s*$') 'M12 reset-only branch must reset and exit before normal execution'
    Assert-M12Replacement (!$resetText.Contains('$env:GEORDI_SCHEDULING_ALERT_ENABLED=''true''') -and !$resetText.Contains('Traffic ')) 'M12 reset-only branch unexpectedly enters scheduler/traffic flow'

    Assert-M12ControlFlowSequence -Statements $model.ResetHelper -Markers @(
        "'stop','m12-burn-demo'",
        "'rm','-sf','backend','m12-burn-demo','victoriametrics'",
        "'http://127.0.0.1:13133/'",
        'Invoke-GeordiM12CollectorControlledReplacement',
        'docker volume rm $candidate'
    ) -Message 'M12 producer quiescence, Collector replacement/readiness, and provider reset ordering changed'
    Assert-M12Replacement ((Get-M12ControlFlowEventIndex $model.ResetHelper 'Invoke-GeordiM12CollectorControlledReplacement') -ge 0) 'M12 controlled Collector replacement is missing from its reset helper'

    $normalMarkers=@(
        '$env:GEORDI_SCHEDULING_ALERT_ENABLED=''false''',
        'Reset-M12FixtureVolumes $root',
        "'up','-d','--force-recreate','backend','m12-burn-demo'",
        'Backend did not become ready.',
        'Burn-demo did not become ready.',
        'ReceiverBaseUrl/control',
        '$env:GEORDI_SCHEDULING_ALERT_ENABLED=''true''',
        "Traffic '/demo/success' 1"
    )
    if($Label -ceq 'production') {
        $normalMarkers=@($normalMarkers | Where-Object { $_ -cne "Traffic '/demo/success' 1" })
        Assert-M12ControlFlowSequence -Statements $model.Normal -Markers $normalMarkers -Message 'M12 normal-path scheduler/provider/backend/readiness ordering changed'
        $schedulerBranches=@($model.Normal | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Extent.Text.Contains('$script:M12TransferredFixturePrepared') -and $_.Extent.Text.Contains('scheduler enablement') })
        Assert-M12Replacement ($schedulerBranches.Count -eq 1) 'M12 scheduler recreation branches are missing or ambiguous'
        $transferSchedulerText=$schedulerBranches[0].Clauses[0].Item2.Extent.Text
        Assert-M12Replacement ($transferSchedulerText.Contains('-Phase m12-fixture-start') -and
            $transferSchedulerText.Contains('Invoke-GeordiM12BackendGenerationReplacement') -and
            $transferSchedulerText.Contains('m12-scheduler-enablement')) 'Transferred M12 scheduler boundary bypasses the backend generation lifecycle'
        $standaloneSchedulerText=$schedulerBranches[0].ElseClause.Extent.Text
        $standaloneMarkers=@('-Phase m12-fixture-start -Services backend',"'up','-d','--force-recreate','backend') 'scheduler enablement'",'Backend did not become ready with M12 scheduling enabled.')
        $standalonePrevious=-1
        foreach($marker in $standaloneMarkers){
            $position=$standaloneSchedulerText.IndexOf($marker,[StringComparison]::Ordinal)
            Assert-M12Replacement ($position -gt $standalonePrevious) 'Standalone M12 scheduler boundary order changed'
            $standalonePrevious=$position
        }
        $trafficIndex=Get-M12ControlFlowEventIndex $model.Normal "Traffic '/demo/error' 179"
        Assert-M12Replacement ($trafficIndex -gt $schedulerBranches[0].Extent.EndOffset) 'M12 traffic began before scheduler backend generation readiness'
    } else {
        Assert-M12ControlFlowSequence -Statements $model.Normal -Markers @($normalMarkers[0..6] + @(
            '-Phase m12-fixture-start -Services backend',"'up','-d','--force-recreate','backend') 'scheduler enablement'",'Backend did not become ready with M12 scheduling enabled.',"Traffic '/demo/success' 1")) `
            -Message 'Synthetic M12 normal-path scheduler/provider/backend/readiness/traffic ordering changed'
    }
    Assert-M12Replacement (@($model.NormalFinally).Count -ge 0 -and @($model.Normal).Count -gt 0) 'M12 normal try control flow was not retained'
    return $true
}

function Test-M12StaticSemantics([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SchedulingScriptPath) {
    if (!(Test-Path -LiteralPath $SchedulingScriptPath -PathType Leaf)) { throw 'M12 scheduling source path does not identify a file.' }
    $m12Source=Get-Content -LiteralPath $SchedulingScriptPath -Raw -ErrorAction Stop
    Test-M12StaticControlFlow -Source $m12Source -Label 'production'
    $fixture=@'
if($RunRecoveryBarrierSelfTest){exit 0}
if($RunFixtureResetOnly){
 Reset-M12FixtureVolumes $root
 exit 0
}
function Reset-M12FixtureVolumes {
 Invoke-Compose @('stop','m12-burn-demo') 'producer quiescence'
 Invoke-Compose @('rm','-sf','backend','m12-burn-demo','victoriametrics') 'provider reset preparation'
 $collectorReadiness={ Wait-Until { (Http-Status 'http://127.0.0.1:13133/') -eq 200 } }
 Invoke-GeordiM12CollectorControlledReplacement
 docker volume rm $candidate
}
try {
 $env:GEORDI_SCHEDULING_ALERT_ENABLED='false'
 Reset-M12FixtureVolumes $root
 Invoke-Compose @('up','-d','--force-recreate','backend','m12-burn-demo') 'fixture preparation'
 Wait-Until { } $deadline 'Backend did not become ready.'
 Wait-Until { } $deadline 'Burn-demo did not become ready.'
 Json $ReceiverBaseUrl/control
 $env:GEORDI_SCHEDULING_ALERT_ENABLED='true'
  Capture -Phase m12-fixture-start -Services backend
 Invoke-Compose @('up','-d','--force-recreate','backend') 'scheduler enablement'
 Wait-Until { } $deadline 'Backend did not become ready with M12 scheduling enabled.'
 Traffic '/demo/success' 1
} finally { Write-Output cleanup }
'@
    Test-M12StaticControlFlow -Source $fixture -Label 'synthetic baseline'
    $negativeCases=[Collections.Generic.List[object]]::new()
    $negativeCases.Add(@{name='scheduler misplaced';source=$fixture.Replace("`$env:GEORDI_SCHEDULING_ALERT_ENABLED='false'`n Reset-M12FixtureVolumes", "Reset-M12FixtureVolumes`n `$env:GEORDI_SCHEDULING_ALERT_ENABLED='false'")})
    $collectorMisplaced=$fixture.Replace(' Invoke-GeordiM12CollectorControlledReplacement','').Replace(' Reset-M12FixtureVolumes $root',' Reset-M12FixtureVolumes $root; Invoke-GeordiM12CollectorControlledReplacement')
    $negativeCases.Add(@{name='Collector replacement outside helper';source=$collectorMisplaced})
    $negativeCases.Add(@{name='health wait removed';source=$fixture.Replace(" Wait-Until { } `$deadline 'Backend did not become ready.'",'')})
    $backendBeforeReady=$fixture.Replace(" Wait-Until { } `$deadline 'Backend did not become ready with M12 scheduling enabled.'",'').Replace(" Traffic '/demo/success' 1", " Traffic '/demo/success' 1; Wait-Until { } `$deadline 'Backend did not become ready with M12 scheduling enabled.'")
    $negativeCases.Add(@{name='backend continuation before readiness';source=$backendBeforeReady})
    foreach ($negative in $negativeCases) {
        $rejected=$false
        try { Test-M12StaticControlFlow -Source $negative.source -Label $negative.name } catch { $rejected=$true }
        Assert-M12Replacement $rejected ("static control-flow check accepted " + $negative.name)
    }
    Write-Output 'm12_semantic_static=PASS ast_branches=separate reset_only_exit=true normal_path_ordered=true collector_handoff_scoped=true negative_control_flow=PASS'
}

function Test-M12StaticSemanticsScope([string] $SchedulingScriptPath) {
    $m12Source='stale outer-scope fixture must not be used'
    Test-M12StaticSemantics -SchedulingScriptPath $SchedulingScriptPath
    $missingPathRejected=$false
    try { Test-M12StaticSemantics -SchedulingScriptPath (Join-Path ([IO.Path]::GetTempPath()) ('missing-m12-source-' + [guid]::NewGuid().ToString('N') + '.ps1')) } catch { $missingPathRejected=$true }
    Assert-M12Replacement $missingPathRejected 'static semantic helper did not fail clearly for a missing source file'
    $emptyPathRejected=$false
    try { Test-M12StaticSemantics -SchedulingScriptPath '' } catch { $emptyPathRejected=$true }
    Assert-M12Replacement $emptyPathRejected 'static semantic helper accepted an absent source path'
    Write-Output 'm12_semantic_scope=PASS explicit_path isolated_scope missing_and_empty_rejected stale_outer_state_ignored=true'
}

function Invoke-SyntheticM12Replacement {
    param([string] $Root,[string] $OldId,[string] $NewId,[switch] $BadOldOwner,[switch] $BadConfig,
        [switch] $PropagationRemaining,[switch] $FailCompose,[switch] $MissingNewIdentity,[switch] $SameNewIdentity,
        [switch] $FailFollower,[switch] $MalformedFollower,[switch] $OverlapFollower,[switch] $FailSeal,
        [switch] $MissingOldIdentity,[switch] $MalformedOldFollower,[switch] $FailGenerationPublication)
    $script:testPid=50000;$script:testProcesses=@{};$script:followerStartUtc=$null
    $oldGeneration=Start-TestGeneration $Root $OldId
    $oldRecord=Get-GeordiCaptureGenerationRecord (Get-GeordiCaptureGenerationManifest $Root) 'otel-collector' $oldGeneration
    $oldHash=(Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash
    if($MalformedOldFollower){$oldDisk=Get-Content -LiteralPath $oldRecord.processRecordPath -Raw|ConvertFrom-Json -AsHashtable;$oldDisk.containerId='0'*64;[IO.File]::WriteAllText($oldRecord.processRecordPath,(ConvertTo-Json -InputObject $oldDisk -Compress))}
    if ($BadOldOwner) { $oldIdentity=New-TestCollectorIdentity $OldId 'backend' } else { $oldIdentity=New-TestCollectorIdentity $OldId }
    if ($OverlapFollower) { $script:followerStartUtc=([DateTimeOffset]$oldRecord.captureStartedUtc).AddSeconds(-1).ToString('o') }
    $identities=[Collections.Generic.Queue[object]]::new();if(!$MissingOldIdentity){$identities.Enqueue($oldIdentity)}
    if (!$MissingNewIdentity) {
        if ($SameNewIdentity) { $identities.Enqueue((New-TestCollectorIdentity $OldId)) }
        else { $identities.Enqueue((New-TestCollectorIdentity $NewId)) }
    }
    $mockState=@{composeCalls=[Collections.Generic.List[object]]::new();replaceCalled=$false;readyCalled=$false}
    $stageState=@{last='OLD_GENERATION_REGISTERED';identityResolutions=0;processIdentityChecks=0}
    $render={ param($repo,$replacement) if($replacement){if($PropagationRemaining){New-TestComposeConfiguration -UnexpectedPropagation}else{New-TestComposeConfiguration -Replacement};$stageState.last='PROPAGATION_CONFIGURATION_RENDERED'}else{New-TestComposeConfiguration} }.GetNewClosure()
    if ($BadConfig) { $render={ param($repo,$replacement) if($replacement){New-TestComposeConfiguration -Replacement -BadCollector}else{New-TestComposeConfiguration} }.GetNewClosure() }
    $invoke={ param($arguments,$phase)
        $mockState.replaceCalled=$true;$mockState.composeCalls.Add(@($arguments))
        $handoffState=Get-GeordiCaptureGenerationManifest $Root
        $active=Get-GeordiCaptureGenerationRecord $handoffState 'otel-collector' $oldGeneration
        if ([string]$active.terminalStatus -cne 'sealed' -or [string]$handoffState.captureHandoffs.Values[0].status -cne 'old-sealed') {
            throw 'mock observed replacement before old generation seal'
        }
        $stageState.last='HANDOFF_BEGUN';$stageState.last='OLD_GENERATION_SEALED';$stageState.last='REPLACEMENT_INVOKED'
        if ($FailCompose) { throw 'synthetic replacement command failure token=diagnostic-sentinel' }
    }.GetNewClosure()
    $resolve={ param($service)
        if($MissingOldIdentity -and $stageState.identityResolutions -eq 0){throw 'synthetic old container missing'}
        if($identities.Count -eq 0){throw 'synthetic replacement container missing'}
        if($stageState.identityResolutions -eq 0){$stageState.last='PROPAGATION_VALIDATED'}
        $identity=$identities.Dequeue();$stageState.identityResolutions++
        Assert-GeordiCaptureContainerIdentity -Identity $identity -Service 'otel-collector'
        if ([IO.Path]::GetFullPath([string]$identity.WorkingDirectory) -cne [IO.Path]::GetFullPath((Get-Location).Path) -or !$identity.Running) { throw 'synthetic container ownership did not match the candidate repository' }
        if($stageState.identityResolutions -eq 1){$stageState.last='OLD_CONTAINER_RESOLVED'}else{
            if([string]$identity.Id -ceq $OldId){throw 'synthetic replacement reused the old container ID'}
            $stageState.last='NEW_CONTAINER_RESOLVED'
        }
        return $identity
    }.GetNewClosure()
    $readiness={ $mockState.readyCalled=$true;$stageState.last='COLLECTOR_READY' }.GetNewClosure()
    $startFollower={ param($stdout,$stderr,$process,$args,$target)
        if($FailFollower){throw 'synthetic follower startup failure'}
        $created=Start-TestFollower $stdout $stderr $process $args $target
        if($FailGenerationPublication -and [string]$target.containerId -ceq $NewId){
            $manifest=Get-GeordiCaptureGenerationManifest $Root
            $active=@($manifest.captureGenerations['otel-collector']|Where-Object terminalStatus -ceq 'capturing')[-1]
            $manifestPath=Join-Path $Root 'manifest.json';$runId=[string]$manifest.runId;$generationId=[string]$active.generationId
            Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId $runId -Mutation {
                param($latest)
                $record=Get-GeordiCaptureGenerationRecord $latest 'otel-collector' $generationId
                $record.containerId='f'*64
            }.GetNewClosure() | Out-Null
        }
        if($MalformedFollower){$disk=Get-Content -LiteralPath $process -Raw|ConvertFrom-Json -AsHashtable;$disk.containerId='f'*64;[IO.File]::WriteAllText($process,(ConvertTo-Json -InputObject $disk -Compress))}
        if($OverlapFollower){$script:followerStartUtc=([DateTimeOffset]$oldRecord.captureStartedUtc).AddSeconds(-1).ToString('o')}
        if ([string]$target.containerId -cne $NewId) { throw 'synthetic new follower target did not match the distinct container ID' }
        $stageState.last='NEW_FOLLOWER_STARTED'
        return $created
    }.GetNewClosure()
    $identityCheck={ param($record)
        $stageState.processIdentityChecks++
        $isAlive=Test-TestFollowerIdentity $record
        if($stageState.processIdentityChecks -eq 1 -and $isAlive){$stageState.last='OLD_FOLLOWER_VALIDATED'}
        return $isAlive
    }.GetNewClosure()
    $stop={ param($record) if($FailSeal){throw 'synthetic seal stop failure'};Stop-TestFollower $record }.GetNewClosure()
    $failure=$null;$result=$null
    try {
        $result=Invoke-GeordiM12CollectorControlledReplacement -CaptureRoot $Root -RepositoryRoot (Get-Location).Path `
            -RenderComposeConfiguration $render -InvokeCompose $invoke -ResolveContainerIdentity $resolve `
            -WaitForReadiness $readiness -StartFollower $startFollower -TestProcessIdentity $identityCheck `
            -StopProcess $stop -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker.ps1'
        $stageState.last='NEW_GENERATION_REGISTERED'
        $manifest=Get-GeordiCaptureGenerationManifest $Root
        if ($result.Status -ceq 'complete' -and [string]$manifest.captureHandoffs[$result.HandoffId].status -ceq 'complete') { $stageState.last='HANDOFF_COMPLETED' }
    } catch { $failure=New-M12FailureDiagnostic -ErrorRecord $_ -Stage ([string]$stageState.last) }
    return [pscustomobject]@{Failure=$failure;Result=$result;OldGeneration=$oldGeneration;OldRecord=$oldRecord;OldHash=$oldHash;
        Root=$Root;Stage=[string]$stageState.last;ComposeCalls=@($mockState.composeCalls.ToArray());ReplaceCalled=[bool]$mockState.replaceCalled;ReadyCalled=[bool]$mockState.readyCalled;
        ParameterState=[ordered]@{BadOldOwner=[bool]$BadOldOwner;BadConfig=[bool]$BadConfig;PropagationRemaining=[bool]$PropagationRemaining;
            FailCompose=[bool]$FailCompose;MissingNewIdentity=[bool]$MissingNewIdentity;SameNewIdentity=[bool]$SameNewIdentity;
            FailFollower=[bool]$FailFollower;MalformedFollower=[bool]$MalformedFollower;OverlapFollower=[bool]$OverlapFollower;
            FailSeal=[bool]$FailSeal;MissingOldIdentity=[bool]$MissingOldIdentity;MalformedOldFollower=[bool]$MalformedOldFollower;
            FailGenerationPublication=[bool]$FailGenerationPublication}}
}

function Test-M12PositiveHandoff {
    $successRoot=New-TestCaptureRoot
    try {
        $success=Invoke-SyntheticM12Replacement $successRoot ('a'*64) ('b'*64)
        if ($success.Failure) {
            $detail=$success.Failure
            throw ('positive synthetic handoff failed stage={0} exception={1} message={2} innerType={3} innerMessage={4} location={5}:{6} function={7}' -f
                $detail.Stage,$detail.Type,$detail.Message,$detail.InnerType,$detail.InnerMessage,$detail.Script,$detail.Line,$detail.Function)
        }
        Assert-M12Replacement ($success.Result.Status -ceq 'complete' -and $success.ReadyCalled) 'synthetic production handoff did not complete'
        Assert-M12Replacement ($success.Result.OldContainerId -ceq ('a'*64) -and $success.Result.NewContainerId -ceq ('b'*64) -and $success.Result.GenerationId) 'replacement identity was not bound to a new generation'
        $mid=Get-GeordiCaptureGenerationManifest $successRoot
        $old=Get-GeordiCaptureGenerationRecord $mid 'otel-collector' $success.OldGeneration
        $new=Get-GeordiCaptureGenerationRecord $mid 'otel-collector' $success.Result.GenerationId
        Assert-M12Replacement ($old.terminalStatus -ceq 'sealed' -and $new.terminalStatus -ceq 'capturing' -and $new.containerId -ceq ('b'*64) -and
            $mid.captureGenerations['otel-collector'].Count -eq 2) 'old/new generation records are missing or duplicated'
        Assert-M12Replacement ((Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash -ceq $success.OldHash -and (Get-Item -LiteralPath $old.capturePath).IsReadOnly) 'sealed historical capture changed'
        $null=Seal-GeordiCaptureGeneration -CaptureRoot $successRoot -Service 'otel-collector' -GenerationId $new.generationId `
            -TestProcessIdentity ${function:Test-TestFollowerIdentity} -StopProcess ${function:Stop-TestFollower}
        Assert-GeordiCaptureGenerationManifest (Get-GeordiCaptureGenerationManifest $successRoot)
        Assert-M12Replacement ($success.ComposeCalls.Count -eq 1 -and $success.ComposeCalls[0][-1] -ceq 'otel-collector') 'mock executor did not receive the exact targeted operation'
        Write-Output 'm12_generation_handoff=PASS owner_follower_seal_new_id_new_follower_manifest_bounded_gap_immutable=true stage=HANDOFF_COMPLETED'
    } finally { Remove-Item -LiteralPath $successRoot -Recurse -Force -ErrorAction SilentlyContinue }

    $failureRoot=New-TestCaptureRoot
    try {
        $injected=Invoke-SyntheticM12Replacement $failureRoot ('c'*64) ('d'*64) -FailCompose
        Assert-M12Replacement ($injected.Failure -and $injected.Failure.Type -and $injected.Failure.Message -and
            $injected.Failure.Stage -ceq 'REPLACEMENT_INVOKED') 'injected handoff failure did not preserve its exception and stage'
        Assert-M12Replacement ($injected.Failure.Message -ceq 'synthetic replacement command failure token=[redacted]' -and
            ($injected.Failure | ConvertTo-Json -Compress) -notmatch 'diagnostic-sentinel') 'failure diagnostic was not sanitized or bounded'
        Write-Output 'm12_handoff_failure_diagnostic=PASS stage=REPLACEMENT_INVOKED original_type_message_preserved sensitive_sentinel_redacted=true'
    } finally { Remove-Item -LiteralPath $failureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Test-M12FailClosedOrchestration {
    $scenarios=@(
        @{name='old container missing';params=@{MissingOldIdentity=$true};replace=$false;handoffStatus='none'},
        @{name='old ownership mismatch';params=@{BadOldOwner=$true};replace=$false;handoffStatus='none'},
        @{name='old follower/container mismatch';params=@{MalformedOldFollower=$true};replace=$false;handoffStatus='incomplete-old-seal'},
        @{name='old seal failure';params=@{FailSeal=$true};replace=$false;handoffStatus='incomplete-old-seal'},
        @{name='replacement isolation failure';params=@{PropagationRemaining=$true};replace=$false;handoffStatus='none'},
        @{name='Collector config equivalence failure';params=@{BadConfig=$true};replace=$false;handoffStatus='none'},
        @{name='replacement command failure';params=@{FailCompose=$true};replace=$true;handoffStatus='incomplete-replacement'},
        @{name='new container missing';params=@{MissingNewIdentity=$true};replace=$true;handoffStatus='incomplete-replacement'},
        @{name='old ID equals new ID';params=@{SameNewIdentity=$true};replace=$true;handoffStatus='incomplete-replacement'},
        @{name='new follower startup failure';params=@{FailFollower=$true};replace=$true;handoffStatus='incomplete-new-generation'},
        @{name='malformed new follower record';params=@{MalformedFollower=$true};replace=$true;handoffStatus='incomplete-new-generation'},
        @{name='new generation registration failure';params=@{FailGenerationPublication=$true};replace=$true;handoffStatus='incomplete-new-generation'},
        @{name='invalid handoff chronology';params=@{OverlapFollower=$true};replace=$true;handoffStatus='incomplete-new-generation'}
    )
    foreach ($scenario in $scenarios) {
        $root=New-TestCaptureRoot
        try {
            $scenarioParams=$scenario.params
            $outcome=Invoke-SyntheticM12Replacement -Root $root -OldId ('c'*64) -NewId ('d'*64) @scenarioParams
            Assert-M12Replacement ($null -ne $outcome.Failure) ("scenario did not fail closed: " + $scenario.name)
            Assert-M12Replacement ([bool]$outcome.ReplaceCalled -eq [bool]$scenario.replace) ("replacement invocation state was wrong: " + $scenario.name)
            $manifest=Get-GeordiCaptureGenerationManifest $root
            $handoffs=@($manifest.captureHandoffs.Values)
            if([string]$scenario.handoffStatus -ceq 'none'){
                Assert-M12Replacement ($handoffs.Count -eq 0) ("pre-handoff failure mutated handoff state: " + $scenario.name)
            }else{
                Assert-M12Replacement ($handoffs.Count -eq 1 -and [string]$handoffs[0].status -ceq [string]$scenario.handoffStatus) `
                    ("failure phase did not retain its expected incomplete handoff status: " + $scenario.name)
            }
            Assert-M12Replacement (@($handoffs | Where-Object { $_.status -ceq 'complete' }).Count -eq 0) ("failed scenario claimed a complete handoff: " + $scenario.name)
            $old=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $outcome.OldGeneration
            Assert-M12Replacement ((Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash -ceq $outcome.OldHash) ("old evidence changed: " + $scenario.name)
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Output 'm12_replacement_fail_closed=PASS scenarios=13 preflight_not_invoked=true post_replace_incomplete=true historical_immutable=true'
}

function Test-M12ScenarioDispatch {
    foreach($scenario in @(
        @{name='old container missing';params=@{MissingOldIdentity=$true};expected=@{MissingOldIdentity=$true;BadOldOwner=$false;FailCompose=$false};replace=$false},
        @{name='replacement command failure';params=@{FailCompose=$true};expected=@{MissingOldIdentity=$false;BadOldOwner=$false;FailCompose=$true};replace=$true}
    )){
        $root=New-TestCaptureRoot
        try{
            $scenarioParams=$scenario.params
            $outcome=Invoke-SyntheticM12Replacement -Root $root -OldId ('c'*64) -NewId ('d'*64) @scenarioParams
            foreach($parameterName in $scenario.expected.Keys){
                Assert-M12Replacement ([bool]$outcome.ParameterState[$parameterName] -eq [bool]$scenario.expected[$parameterName]) `
                    ("scenario switch was not bound as requested: " + $scenario.name + ':' + $parameterName)
            }
            Assert-M12Replacement ($null -ne $outcome.Failure) ("dispatch regression did not produce a failure diagnostic: " + $scenario.name)
            Assert-M12Replacement ([bool]$outcome.ReplaceCalled -eq [bool]$scenario.replace) ("dispatch regression replacement state was wrong: " + $scenario.name)
            if($scenario.name -ceq 'old container missing'){
                $manifest=Get-GeordiCaptureGenerationManifest $root
                Assert-M12Replacement (@($manifest.captureHandoffs.Values).Count -eq 0) 'missing old container mutated handoff state'
                $old=Get-GeordiCaptureGenerationRecord $manifest 'otel-collector' $outcome.OldGeneration
                Assert-M12Replacement ((Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash -ceq $outcome.OldHash) 'missing old container changed historical evidence'
            }
        }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
    }
    Write-Output 'm12_scenario_dispatch=PASS named_splatting=active old_missing=true compose_failure=true unrelated_switches=false'
}

if (!$SelfTest) { throw 'Use -SelfTest for offline M12 Collector replacement validation.' }
if ($NormalizationOnly) { Test-M12RestartNormalization; exit 0 }
if ($CommandScopeOnly) { Test-M12CommandScope (Resolve-Path (Join-Path $PSScriptRoot '..')).Path; exit 0 }
if ($DuplicateCaptureOnly) { Test-M12DuplicateCapturePrevention; exit 0 }
if ($StaticSemanticsOnly) { Test-M12StaticSemanticsScope (Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'); exit 0 }
if ($PositiveHandoffOnly) { Test-M12PositiveHandoff; exit 0 }
if ($DuplicateMatrixOnly) { Test-M12DuplicateCaptureNegativeMatrix; exit 0 }
if ($DuplicateBoundaryOnly) { Test-M12DuplicateHandoffBoundary; exit 0 }
if ($OverlayPropagationOnly) { Test-M12OverlayAndPropagation (Resolve-Path (Join-Path $PSScriptRoot '..')).Path; exit 0 }
if ($FailClosedOnly) { Test-M12FailClosedOrchestration; exit 0 }
if ($ScenarioDispatchOnly) { Test-M12ScenarioDispatch; exit 0 }
if ($ProtectedVolumeOnly) { Test-M12ProtectedVolumeConfiguration (Resolve-Path (Join-Path $PSScriptRoot '..')).Path; exit 0 }

$repositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Test-M12OverlayAndPropagation $repositoryRoot

Test-M12RestartNormalization

$arguments=Get-GeordiM12CollectorReplacementArguments -RepositoryRoot $repositoryRoot
Test-M12CommandScope $repositoryRoot

Test-M12DuplicateCapturePrevention
Test-M12DuplicateCaptureNegativeMatrix
Test-M12StaticSemanticsScope (Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1')

Test-M12ProtectedVolumeConfiguration $repositoryRoot

Test-M12PositiveHandoff
Test-M12FailClosedOrchestration
