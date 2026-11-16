[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('ConfigOnly','PropagationOnly','ProtectedVolumeOnly','PositiveHandoffOnly','FailClosedOnly','DuplicateCaptureOnly','StaticSemanticsOnly')]
    [string] $Case
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM10BackendReplacement.ps1')

function Assert-M10Replacement([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "M10 backend replacement regression failed: $Message" }
}
function New-M10SyntheticRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m10-replacement-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-m10';startedUtc=[DateTimeOffset]::UtcNow.ToString('o')
        captureStartedUtc=[DateTimeOffset]::UtcNow.ToString('o');captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{}
        generationCapturesByAttempt=@{};captures=@{};generationCaptureEvents=@{}}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 48 -Compress),[Text.UTF8Encoding]::new($false))
    return $root
}
function Remove-M10SyntheticRoot([string] $Root) {
    if (Test-Path -LiteralPath $Root) {
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object { $_.IsReadOnly=$false }
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}
function Read-M10Manifest([string] $Root) { return [IO.File]::ReadAllText((Join-Path $Root 'manifest.json')) | ConvertFrom-Json -AsHashtable }
function New-M10Identity([string] $Id,[string] $Service='backend',[string] $WorkingDirectory=(Get-Location).Path) {
    return [pscustomobject]@{Id=$Id;Project='geordi';Service=$Service;WorkingDirectory=$WorkingDirectory
        CreatedUtc=[DateTimeOffset]::UtcNow;Running=$true}
}
function New-M10FollowerHarness {
    $state=[ordered]@{Pid=52000;Alive=@{}}
    $state.Start={
        param($stdout,$stderr,$processRecord,$arguments,$target)
        $state.Pid++
        $startUtc=[DateTimeOffset]::UtcNow.ToString('o')
        $record=[ordered]@{id=$state.Pid;name='synthetic-follower';startUtc=$startUtc;containerId=[string]$target.containerId
            service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc}
        [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stdout,"synthetic-$($target.containerId)`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
        $state.Alive[[string]$state.Pid]=$true
        return [pscustomobject]@{id=$state.Pid;name='synthetic-follower';startUtc=$startUtc}
    }.GetNewClosure()
    $state.Test={param($record) return [bool]$state.Alive[[string]$record.id]}.GetNewClosure()
    $state.Stop={param($record) $state.Alive[[string]$record.id]=$false}.GetNewClosure()
    return $state
}
function Start-M10OldGeneration([string] $Root,[string] $Id='aaaaaaaaaaaaaaaaaaaaaaaa',$Harness) {
    if(!$Harness){$Harness=New-M10FollowerHarness}
    $generation=Start-GeordiCaptureGeneration -CaptureRoot $Root -Service backend -ContainerIdentity (New-M10Identity $Id) `
        -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' `
        -WorkingDirectory (Get-Location).Path -StartFollower $Harness.Start
    return [pscustomobject]@{GenerationId=[string]$generation;Harness=$Harness}
}
function Invoke-M10SyntheticReplacement([string] $Root,[scriptblock] $Configure={}) {
    $oldId='aaaaaaaaaaaaaaaaaaaaaaaa'
    $newId='bbbbbbbbbbbbbbbbbbbbbbbb'
    $state=[ordered]@{Current=(New-M10Identity $oldId);Commands=[Collections.Generic.List[object]]::new()
        VolumeCalls=[Collections.Generic.List[string]]::new();ReplaceState='before';NewId=$newId;ComposeFailure=''
        ResolveFailure=$false;MissingIdentity=$false;WrongOwner=$false;FollowerMismatch=$false;MissingActiveGeneration=$false
        NewFollowerFailure=$false;NewPublicationFailure=$false
        Harness=(New-M10FollowerHarness)}
    $invokeCompose={
        param([string[]]$Arguments,[string]$Phase)
        $state.Commands.Add([pscustomobject]@{Arguments=@($Arguments);Phase=$Phase})
        if ($Arguments -contains 'up') {
            if ($state.ReplaceState -cne 'removed') { throw 'Synthetic replacement ran before old container removal.' }
            if ($state.NewId) { $state.Current=New-M10Identity ([string]$state.NewId) }
            $state.ReplaceState='recreated'
        } elseif ($Arguments -contains 'rm') {
            $manifest=Read-M10Manifest $Root
            $old=Get-GeordiCaptureGenerationRecord $manifest backend ([string]$state.OldGeneration)
            if (!$old -or [string]$old.terminalStatus -cne 'sealed') { throw 'Synthetic removal ran before old seal.' }
            $state.ReplaceState='removed'
        }
        if ($state.ComposeFailure -ceq $Phase) { throw 'Synthetic Compose failure.' }
        Write-Output ("compose-" + $Phase + '-stdout')
    }.GetNewClosure()
    $removeVolume={
        $manifest=Read-M10Manifest $Root
        $old=Get-GeordiCaptureGenerationRecord $manifest backend ([string]$state.OldGeneration)
        if (!$old -or [string]$old.terminalStatus -cne 'sealed') { throw 'Synthetic volume reset preceded capture seal.' }
        $state.VolumeCalls.Add('geordi_m10-alert-lifecycle-data')
        Write-Output 'volume-remove-stdout'
    }.GetNewClosure()
    $resolve={
        param([string]$Service)
        if ($Service -cne 'backend') { throw 'Unexpected service identity lookup.' }
        if ($state.ResolveFailure) { throw 'Synthetic identity resolution failure.' }
        if ($state.MissingIdentity -and $state.ReplaceState -ceq 'recreated') { return $null }
        if ($state.WrongOwner) { return New-M10Identity ([string]$state.Current.Id) 'backend' ([IO.Path]::GetTempPath()) }
        return $state.Current
    }.GetNewClosure()
    & $Configure $state
    $old=Start-M10OldGeneration $Root $oldId $state.Harness
    $oldGeneration=[string]$old.GenerationId;$state.OldGeneration=$oldGeneration
    if($state.NewFollowerFailure){$state.Harness.Start={throw 'Synthetic new follower failure.'}.GetNewClosure()}
    if($state.NewPublicationFailure){
        $state.Harness.Start={
            param($stdout,$stderr,$processRecord,$arguments,$target)
            [IO.File]::WriteAllText($processRecord,'{}',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($stdout,'synthetic',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{id=9;name='wrong';startUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        }.GetNewClosure()
    }
    $manifestBefore=Read-M10Manifest $Root
    $oldRecord=Get-GeordiCaptureGenerationRecord $manifestBefore backend $oldGeneration
    $state.OldRecord=$oldRecord
    $state.OldHash=(Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash
    if($state.FollowerMismatch){
        $process=[IO.File]::ReadAllText($oldRecord.processRecordPath)|ConvertFrom-Json -AsHashtable
        $process.containerId='cccccccccccccccccccccccc'
        [IO.File]::WriteAllText($oldRecord.processRecordPath,(ConvertTo-Json -InputObject $process -Compress),[Text.UTF8Encoding]::new($false))
    }
    if($state.MissingActiveGeneration){
        $oldRecord.terminalStatus='sealed'
        Write-GeordiM19ManifestAtomic -Path (Join-Path $Root 'manifest.json') -Manifest $manifestBefore
    }
    $result=$null; $failure=$null
    try {
        $result=Invoke-GeordiM10BackendControlledReplacement -CaptureRoot $Root -RepositoryRoot (Get-Location).Path `
            -InvokeCompose $invokeCompose -RemoveFixtureVolume $removeVolume -ResolveContainerIdentity $resolve `
            -StartFollower $state.Harness.Start -TestProcessIdentity $state.Harness.Test -StopProcess $state.Harness.Stop `
            -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker'
    } catch { $failure=$_.Exception.Message }
    return [pscustomobject]@{Root=$Root;OldGeneration=$oldGeneration;OldCapturePath=[string]$state.OldRecord.capturePath
        OldHash=[string]$state.OldHash;Result=$result;Failure=$failure;Commands=$state.Commands
        VolumeCalls=$state.VolumeCalls;State=$state.ReplaceState;OldId=$oldId;NewId=$newId;Harness=$state.Harness}
}

switch ($Case) {
    'ConfigOnly' {
        $repo=Split-Path -Parent $PSScriptRoot
        $files=@('compose.yaml','compose.m19.yaml','compose.m10.yaml')
        $args=@('compose','--project-directory',$repo)
        foreach($file in $files){$args+=@('--file',(Join-Path $repo $file))}
        $args+=@('config','--format','json')
        $renderedJson=& docker @args
        if($LASTEXITCODE -ne 0){throw 'M10 Compose configuration rendering failed.'}
        $config=$renderedJson | ConvertFrom-Json
        $backend=$config.services.backend
        $mounts=@($backend.volumes | ForEach-Object { if($_ -is [string]){$_}else{[string]$_.source+':'+[string]$_.target} })
        Assert-M10Replacement ($backend.environment.SPRING_DATASOURCE_URL -like 'jdbc:h2:file:/var/lib/geordi/alerts-m10/*') 'M10 datasource no longer uses its dedicated fixture path'
        Assert-M10Replacement (@($mounts | Where-Object {$_ -like 'm10-alert-lifecycle-data:/var/lib/geordi/alerts-m10*'}).Count -eq 1) 'dedicated M10 volume mount changed'
        Assert-M10Replacement (@($mounts | Where-Object {$_ -like 'm19-alert-lifecycle-data:/var/lib/geordi/alerts-m19*'}).Count -eq 1) 'protected M19 alert volume mount classification changed'
        Assert-M10Replacement (@($mounts | Where-Object {$_ -like 'victoriametrics-data:*'}).Count -eq 0) 'VictoriaMetrics volume unexpectedly became a backend mount'
        Write-Output 'm10_compose_render=PASS datasource=m10-volume protected-m19-alert-mounted=true vm-volume-mounted=false'
    }
    'PropagationOnly' {
        $repo=Split-Path -Parent $PSScriptRoot
        $files=@('compose.yaml','compose.m19.yaml','compose.m10.yaml');$args=@('compose','--project-directory',$repo)
        foreach($file in $files){$args+=@('--file',(Join-Path $repo $file))};$args+=@('config','--format','json')
        $config=(& docker @args | ConvertFrom-Json)
        if($LASTEXITCODE -ne 0){throw 'M10 dependency graph rendering failed.'}
        $dependents=[Collections.Generic.List[string]]::new()
        foreach($serviceName in $config.services.PSObject.Properties.Name){
            $service=$config.services.$serviceName
            $dependsProperty=$service.PSObject.Properties['depends_on']
            if(!$dependsProperty){continue}
            $depends=$dependsProperty.Value
            if($depends -and $depends.PSObject.Properties.Name -contains 'backend' -and $depends.backend.restart){$dependents.Add($serviceName)}
        }
        Assert-M10Replacement ($dependents.Count -eq 0) ('backend replacement has dependents with restart propagation: '+($dependents -join ','))
        Write-Output 'm10_replacement_propagation=PASS backend_dependents_restart_true=0'
    }
    'ProtectedVolumeOnly' {
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lib/GeordiM10BackendReplacement.ps1') -Raw
        $function=$source.Substring($source.IndexOf('function Invoke-GeordiM10BackendControlledReplacement'))
        Assert-M10Replacement ($function -match "@\('rm','-sf','backend'\)" -and $function -match "@\('up','-d','--force-recreate','backend'\)") 'replacement is not scoped to backend rm/up operations'
        Assert-M10Replacement ($function -notmatch "(?:^|[,\s])-(?:v|volumes)(?:[,\s]|$)|compose\s+(?:down|rm\s+-v|prune)") 'replacement contains a volume-delete or project-teardown flag'
        $script=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-alert-lifecycle.ps1') -Raw
        Assert-M10Replacement ($script -match 'if\(\$Candidate -cne \$expectedName\)' -and $script -match 'docker volume rm \$Candidate') 'dedicated volume removal guard changed'
        Assert-M10Replacement ($script -match "geordi_m10-alert-lifecycle-data" -and $script -notmatch "docker volume rm geordi_m19-alert-lifecycle-data|docker volume rm geordi_m19-victoriametrics-data") 'protected M19 volume is removable in M10 path'
        Write-Output 'm10_protected_volume_safety=PASS backend-only no-volume-flags dedicated-m10-only'
    }
    'PositiveHandoffOnly' {
        $root=New-M10SyntheticRoot
        try {
            $result=Invoke-M10SyntheticReplacement $root
            $replacementResult=$result.Result
            Assert-M10Replacement (!$result.Failure -and $replacementResult -and $replacementResult -isnot [array]) 'positive replacement failed or returned multiple objects'
            Assert-M10Replacement ($replacementResult.OldContainerId -ceq $result.OldId -and $replacementResult.NewContainerId -ceq $result.NewId) 'handoff identities are incorrect'
            Assert-M10Replacement ($replacementResult.NewGenerationId -is [string] -and [string]$replacementResult.NewGenerationId -match '^[0-9a-f]{32}$') 'new generation ID is not one scalar generation identity'
            $manifest=Read-M10Manifest $root
            $old=Get-GeordiCaptureGenerationRecord $manifest backend $result.OldGeneration
            $new=Get-GeordiCaptureGenerationRecord $manifest backend $replacementResult.NewGenerationId
            Assert-M10Replacement ([string]$new.terminalStatus -ceq 'capturing' -and [string]$manifest.captureHandoffs[$replacementResult.HandoffId].status -ceq 'complete') 'new active generation or handoff state was not published'
            $oldHash=(Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash
            $follower=[IO.File]::ReadAllText($new.processRecordPath)|ConvertFrom-Json -AsHashtable
            Assert-M10Replacement ($old.terminalStatus -ceq 'sealed' -and (Get-Item -LiteralPath $old.capturePath -Force).IsReadOnly) 'old generation was not sealed immutably'
            Assert-M10Replacement ([string]$follower.containerId -ceq $result.NewId -and [string]$new.containerId -ceq $result.NewId) 'new follower is not bound to exact backend ID'
            Assert-M10Replacement ((Get-FileHash -LiteralPath $old.capturePath -Algorithm SHA256).Hash -ceq $oldHash) 'historical evidence changed'
            Assert-M10Replacement ($result.VolumeCalls.Count -eq 1 -and $result.VolumeCalls[0] -ceq 'geordi_m10-alert-lifecycle-data') 'unexpected volume reset target'
            Assert-M10Replacement ($result.Commands.Count -eq 2 -and ($result.Commands[0].Arguments -join ' ') -ceq 'rm -sf backend' -and ($result.Commands[1].Arguments -join ' ') -ceq 'up -d --force-recreate backend') 'replacement command scope/order changed'
            Seal-GeordiCaptureGeneration -CaptureRoot $root -Service backend -GenerationId $replacementResult.NewGenerationId `
                -TestProcessIdentity $result.Harness.Test -StopProcess $result.Harness.Stop | Out-Null
            Assert-GeordiCaptureGenerationManifest (Read-M10Manifest $root)
            Write-Output 'm10_positive_handoff=PASS old-sealed=true old-follower-bound=true new-id-bound=true manifest-valid=true history-immutable=true'
        } finally { Remove-M10SyntheticRoot $root }
    }
    'FailClosedOnly' {
        $cases=@(
            @{name='missing old identity';configure={param($state)$state.ResolveFailure=$true};before=$true},
            @{name='wrong repository owner';configure={param($state)$state.WrongOwner=$true};before=$true},
            @{name='missing active generation';configure={param($state)$state.MissingActiveGeneration=$true};before=$true},
            @{name='old follower/container mismatch';configure={param($state)$state.FollowerMismatch=$true};before=$true},
            @{name='seal failure';configure={param($state)$state.Harness.Test={param($record)return $false}.GetNewClosure()};before=$true},
            @{name='replacement failure';configure={param($state)$state.ComposeFailure='M10 backend removal'};before=$false},
            @{name='missing new backend';configure={param($state)$state.MissingIdentity=$true};before=$false},
            @{name='same old/new ID';configure={param($state)$state.NewId='aaaaaaaaaaaaaaaaaaaaaaaa'};before=$false},
            @{name='follower startup failure';configure={param($state)$state.NewFollowerFailure=$true};before=$false},
            @{name='generation publication failure';configure={param($state)$state.NewPublicationFailure=$true};before=$false}
        )
        foreach($failureCase in $cases){
            $root=New-M10SyntheticRoot
            try {
                $attempt=Invoke-M10SyntheticReplacement $root $failureCase.configure
                Assert-M10Replacement ([bool]$attempt.Failure) ($failureCase.name+' unexpectedly succeeded')
                Assert-M10Replacement (($attempt.Commands.Count -eq 0) -eq [bool]$failureCase.before) ($failureCase.name+' mutated before/after replacement boundary incorrectly')
                $manifest=Read-M10Manifest $root
                $old=Get-GeordiCaptureGenerationRecord $manifest backend $attempt.OldGeneration
                Assert-M10Replacement ($old -and (Test-Path -LiteralPath ([string]$attempt.OldCapturePath) -PathType Leaf)) ($failureCase.name+' removed old capture bytes')
                Assert-M10Replacement ((Get-FileHash -LiteralPath $attempt.OldCapturePath -Algorithm SHA256).Hash -ceq $attempt.OldHash) ($failureCase.name+' changed old capture bytes')
                if(@($manifest.captureHandoffs.Values).Count -gt 0){
                    $incomplete=@($manifest.captureHandoffs.Values | Where-Object { [string]$_.status -like 'incomplete-*' })
                    Assert-M10Replacement ($incomplete.Count -eq 1) ($failureCase.name+' failed replacement without an incomplete handoff')
                }
            } finally { Remove-M10SyntheticRoot $root }
        }
        Write-Output ("m10_fail_closed=PASS cases=" + $cases.Count + ' preflight-and-post-boundary-failures=incomplete-preserved')
    }
    'DuplicateCaptureOnly' {
        $captureScript=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Raw
        $m10=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-alert-lifecycle.ps1') -Raw
        Assert-M10Replacement ($m10 -match "-Phase m10-reset -Services backend -SkipLogSnapshot") 'normal M10 path still takes a duplicate backend log snapshot'
        $metricSnapshotIndex=$captureScript.IndexOf('vm_generation_snapshot=PASS')
        $skipIndex=$captureScript.IndexOf('if($SkipLogSnapshot)')
        $logSnapshotIndex=$captureScript.IndexOf('$generationRoot = Join-Path $captureRoot', $skipIndex)
        Assert-M10Replacement ($metricSnapshotIndex -ge 0 -and $skipIndex -gt $metricSnapshotIndex -and
            $captureScript.IndexOf('return',$skipIndex) -gt $skipIndex -and $logSnapshotIndex -gt $captureScript.IndexOf('return',$skipIndex)) `
            'metric persistence does not precede the explicit early return that skips duplicate service logs'
        Assert-M10Replacement ($m10 -match "function Reset-M10FixtureVolume[\s\S]*?Capture-GeordiM19Generation.ps1'\) -Phase m10-reset -Services backend[\s\S]*?docker compose[\s\S]*?rm -sf backend") 'reset-only setup no longer retains its legacy setup capture behavior'
        Write-Output 'm10_capture_ownership=PASS metric-snapshot-retained active-follower-owns-backend-logs duplicate-normal-snapshot=absent'
    }
    'StaticSemanticsOnly' {
        $path=Join-Path $PSScriptRoot 'verify-alert-lifecycle.ps1';$tokens=$null;$errors=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Assert-M10Replacement ($errors.Count -eq 0) 'M10 authoritative script failed AST parse'
        $functions=@{};foreach($functionAst in $ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){$functions[$functionAst.Name]=$functionAst.Body.Extent.Text}
        $prepare=$functions['Prepare-M10Fixture'];$reset=$functions['Reset-M10FixtureVolume']
        Assert-M10Replacement ($prepare.IndexOf('Capture-GeordiM19Generation.ps1') -lt $prepare.IndexOf('Invoke-GeordiM10BackendControlledReplacement')) 'normal path does not snapshot persisted metrics before backend replacement'
        Assert-M10Replacement ($prepare -match 'SkipLogSnapshot' -and $prepare -match 'Invoke-GeordiM10BackendControlledReplacement') 'normal fixture setup bypasses capture lifecycle or duplicate log guard'
        Assert-M10Replacement ($reset -match 'Capture-GeordiM19Generation.ps1' -and $reset -match "rm -sf backend" -and $reset -match 'Remove-M10FixtureVolume') 'reset-only behavior no longer preserves original setup/reset sequence'
        $script=Get-Content -LiteralPath $path -Raw
        Assert-M10Replacement ($script -match "Invoke-GeordiM10BackendControlledReplacement" -and $script -match 'Wait-ForHttp200' -and $script -match 'restart backend') 'M10 traffic/readiness or later durability restart disappeared'
        Assert-M10Replacement ($functions.ContainsKey('Assert-Transition') -and $functions.ContainsKey('Assert-NoTransition') -and
            $script -match 'Assert-Transition \$started ''ALERT_STARTED''' -and
            $script -match 'Assert-Transition \$resolved ''ALERT_RESOLVED''' -and
            $script -match 'Assert-NoTransition \$repeatedNotMet') 'M10 functional transition assertions changed'
        Write-Output 'm10_static_semantics=PASS reset-purpose preserved metric-capture-before-replacement traffic-assertions-preserved later-same-id-restart-preserved'
    }
}
