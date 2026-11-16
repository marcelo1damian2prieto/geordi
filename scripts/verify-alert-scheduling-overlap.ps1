[CmdletBinding()]
param(
    [ValidateRange(180, 360)][int] $TimeoutSeconds = 300,
    [string] $BackendBaseUrl = 'https://geordi.localhost:8443',
    [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8084',
    [string] $ReceiverBaseUrl = 'http://127.0.0.1:18080',
    [string] $GateBaseUrl = 'http://127.0.0.1:18083',
    [Alias('ApplyM12OverlapCollectorGenerations')][switch] $ApplyM12OverlapGenerations
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiSchedulerIsolation.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM12OverlapCollector.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM12OverlapGenerations.ps1')
$PolicyId = 'm12-scheduling-alert'

function Invoke-Compose([string[]] $Arguments) {
    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'M12 overlap Compose operation failed.' }
}

function Json([string] $Uri, [string] $Method = 'GET', $Body = $null) {
    if ($Uri.StartsWith($BackendBaseUrl, [StringComparison]::OrdinalIgnoreCase)) {
        $response = Invoke-GeordiScriptRequest -Uri $Uri -Method $Method -Body $Body -TimeoutSeconds 15
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "M12 overlap API returned HTTP $($response.StatusCode)." }
        return $response.Content | ConvertFrom-Json
    }
    $parameters = @{ Uri = $Uri; Method = $Method; TimeoutSec = 15; UseBasicParsing = $true }
    if ($null -ne $Body) { $parameters.ContentType = 'application/json'; $parameters.Body = $Body | ConvertTo-Json -Compress }
    $content = (Invoke-WebRequest @parameters).Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    $content | ConvertFrom-Json
}

function Wait-Until([scriptblock] $Condition, [datetime] $Deadline, [string] $Message) {
    while ((Get-Date) -lt $Deadline) {
        try { if (& $Condition) { return } } catch { }
        Start-Sleep -Milliseconds 250
    }
    throw $Message
}

function State {
    @((Json "$BackendBaseUrl/api/alert-states").alertStates | Where-Object { $_.policy.id -eq $PolicyId })[0]
}

function Traffic([string] $Path, [int] $Count) {
    1..$Count | ForEach-Object -Parallel {
        [void](Invoke-WebRequest -Uri "$using:BurnDemoBaseUrl$using:Path" -TimeoutSec 10 -UseBasicParsing -SkipHttpErrorCheck)
    } -ThrottleLimit 16
}

function Invoke-M12OverlapCollectorReplacement([string] $Root,[string] $CaptureRoot,[datetime] $Deadline) {
    $render={
        param([string] $RepositoryRoot,[bool] $ReplacementOverlay)
        return Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $RepositoryRoot `
            -CollectorReplacementOverlay:$ReplacementOverlay
    }.GetNewClosure()
    $invoke={param([string[]] $Arguments,[string] $Phase) Invoke-Compose $Arguments $Phase}.GetNewClosure()
    $resolve={param([string] $Service) Get-GeordiCurrentCaptureContainerIdentity -Service $Service -RepositoryRoot $Root}.GetNewClosure()
    $readiness={
        Wait-Until { (Invoke-WebRequest -Uri 'http://127.0.0.1:13133/' -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200 } `
            $Deadline 'M12 overlap Collector did not become ready after its follower started.'
    }.GetNewClosure()
    return Invoke-GeordiM12OverlapCollectorReplacement -CaptureRoot $CaptureRoot -RepositoryRoot $Root `
        -RenderComposeConfiguration $render -InvokeCompose $invoke -ResolveContainerIdentity $resolve -WaitForReadiness $readiness
}

Invoke-GeordiWithProcessEnvironmentRestore -Names @(
    'COMPOSE_FILE', 'GEORDI_SCHEDULING_ALERT_ENABLED', 'GEORDI_SCHEDULING_ALERT_INTERVAL') -Action {
try {
    $root = Split-Path -Parent $PSScriptRoot
    $captureRoot=$null
    if($ApplyM12OverlapGenerations){
        $capturePointer=Join-Path $root '.runtime/m19-capture-root.txt'
        if(!(Test-Path -LiteralPath $capturePointer -PathType Leaf)){throw 'M12 overlap Collector-generation mode requires the active M19 capture pointer.'}
        $captureRoot=[IO.Path]::GetFullPath([IO.File]::ReadAllText($capturePointer).Trim())
        $expectedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedTemp -or
                (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$' -or
                !(Test-Path -LiteralPath $captureRoot -PathType Container) -or
                ((Get-Item -LiteralPath $captureRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                !(Test-Path -LiteralPath (Join-Path $captureRoot 'manifest.json') -PathType Leaf)){
            throw 'M12 overlap capture root failed private evidence validation.'
        }
    }
    $compose=Get-GeordiM12OverlapComposeArguments -RepositoryRoot $root -IsolationOverlay:$ApplyM12OverlapGenerations
    $composeFiles=@((Join-Path $root 'compose.yaml'),(Join-Path $root 'compose.m19.yaml'),
        (Join-Path $root 'compose.m12.yaml'),(Join-Path $root 'compose.m12-overlap.yaml'))
    if($ApplyM12OverlapGenerations){$composeFiles+=Join-Path $root 'compose.m12-overlap-isolation.yaml'}
    $env:COMPOSE_FILE=$composeFiles -join [IO.Path]::PathSeparator
    $env:GEORDI_SCHEDULING_ALERT_ENABLED = 'false'
    $env:GEORDI_SCHEDULING_ALERT_INTERVAL = '10s'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    $normalConfiguration=$null
    $isolatedConfiguration=$null
    if($ApplyM12OverlapGenerations){
        $normalConfiguration=Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $root
        $isolatedConfiguration=Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $root -CollectorReplacementOverlay -IsolationOverlay
        $isolationEdges=Assert-GeordiM12OverlapIsolationConfiguration -NormalConfiguration $normalConfiguration -IsolatedConfiguration $isolatedConfiguration
        Write-Host ("M12 overlap propagation isolated for {0} dependency edges." -f $isolationEdges.Count)
    }

    $rendered=if($ApplyM12OverlapGenerations){$isolatedConfiguration}else{Get-GeordiM12OverlapComposeConfiguration -RepositoryRoot $root}
    [void](Assert-GeordiM12OverlapRenderedVolumes -Configuration $rendered)
    $firstCollectorReplacement=$null
    if($ApplyM12OverlapGenerations){
        $dockerCommand={
            param([string[]] $Arguments)
            $output=& docker @Arguments 2>$null
            $exitCode=$LASTEXITCODE
            return [pscustomobject]@{ExitCode=$exitCode;Output=@($output)}
        }.GetNewClosure()
        $inspectVolume={param([string] $Name) Get-GeordiM11DockerVolumeInspection -Name $Name -DockerCommand $dockerCommand}.GetNewClosure()
        $removeVolume={
            param([string] $Name)
            & docker volume rm $Name 2>$null | Out-Null
            if($LASTEXITCODE -ne 0){throw 'M12 overlap owned volume removal failed.'}
        }.GetNewClosure()
        $resolveIdentity={param([string] $Service) Get-GeordiCurrentCaptureContainerIdentity -Service $Service -RepositoryRoot $root}.GetNewClosure()
        $entry=Assert-GeordiM12OverlapEntryState -CaptureRoot $captureRoot -RepositoryRoot $root -ResolveIdentity $resolveIdentity -InspectVolume $inspectVolume
        $replaceCollector={param([string] $Boundary) Invoke-M12OverlapCollectorReplacement -Root $root -CaptureRoot $captureRoot -Deadline $deadline}.GetNewClosure()
        $captureResetEvidence={
            param([string] $ExpectedVictoriaMetricsId)
            $evidence=Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $captureRoot -RepositoryRoot $root `
                -Phase m12-overlap-reset -ResolveIdentity $resolveIdentity
            if([string]$evidence.SourceContainerId -cne $ExpectedVictoriaMetricsId){throw 'M12 overlap reset evidence did not bind the authenticated incoming VictoriaMetrics source.'}
            return $evidence
        }.GetNewClosure()
        $beginBackendHandoff={
            Begin-GeordiM12OverlapBackendHandoff -CaptureRoot $captureRoot -RepositoryRoot $root -ResolveIdentity $resolveIdentity `
                -Reason 'm12-overlap-reset'
        }.GetNewClosure()
        $stopTrafficFixture={$null=Invoke-Compose ($compose + @('stop','m12-burn-demo'))}.GetNewClosure()
        $assertResetRemovalPreconditions={
            param([string] $BackendHandoffId)
            Assert-GeordiM12OverlapResetRemovalPreconditions -CaptureRoot $captureRoot -BackendHandoffId $BackendHandoffId `
                -ExpectedBackendId ([string]$entry.Backend.Id) -ExpectedCollectorId ([string]$entry.Collector.Id) `
                -ExpectedVictoriaMetricsId ([string]$entry.VictoriaMetrics.Id) -ResolveIdentity $resolveIdentity -InspectVolume $inspectVolume
        }.GetNewClosure()
        $removeResetContainers={$null=Invoke-Compose ($compose + @('rm','-sf','backend','m12-burn-demo','victoriametrics'))}.GetNewClosure()
        $replaceCollectorFirst={& $replaceCollector 'overlap-reset'}.GetNewClosure()
        $removeDedicatedVolumes={
            [void](Remove-GeordiM12OverlapDedicatedVolumes -InspectVolume $inspectVolume -RemoveVolume $removeVolume)
        }.GetNewClosure()
        $startProvider={
            param([string] $OldVictoriaMetricsId)
            $null=Invoke-Compose (Get-GeordiM12OverlapProviderReplacementArguments -ComposeArguments $compose)
            Wait-Until { (Invoke-WebRequest -Uri 'http://127.0.0.1:8428/-/healthy' -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200 } `
                $deadline 'M12 overlap VictoriaMetrics did not become ready.'
            Wait-Until { (Json "$GateBaseUrl/__control/health").status -eq 'ok' } $deadline 'M12 overlap query gate did not become ready.'
            $identity=& $resolveIdentity 'victoriametrics'
            if([string]$identity.Id -ceq $OldVictoriaMetricsId){throw 'M12 overlap VictoriaMetrics reset reused the old container identity.'}
            return $identity
        }.GetNewClosure()
        $replaceCollectorSecond={& $replaceCollector 'overlap-exercise'}.GetNewClosure()
        $replaceBackend={Invoke-Compose (Get-GeordiM12OverlapBackendReplacementArguments -ComposeArguments $compose)}.GetNewClosure()
        $backendReadiness={
            param($Target)
            Wait-Until { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 } `
                $deadline 'M12 overlap backend did not become ready after its exact follower started.'
        }.GetNewClosure()
        $completeBackendHandoff={
            param([string] $HandoffId)
            Complete-GeordiM12OverlapBackendHandoff -CaptureRoot $captureRoot -RepositoryRoot $root -HandoffId $HandoffId `
                -Replace $replaceBackend -ResolveIdentity $resolveIdentity -WaitReadiness $backendReadiness -Reason 'm12-overlap-reset'
        }.GetNewClosure()
        $startTrafficFixture={
            $null=Invoke-Compose (Get-GeordiM12OverlapTrafficFixtureArguments -ComposeArguments $compose)
            Wait-Until { (Json "$BurnDemoBaseUrl/actuator/health").status -eq 'UP' } $deadline 'M12 overlap traffic fixture did not become ready.'
        }.GetNewClosure()
        $reset=Invoke-GeordiM12OverlapGenerationResetSequence -IncomingVictoriaMetricsId ([string]$entry.VictoriaMetrics.Id) `
            -CaptureResetEvidence $captureResetEvidence -BeginBackendHandoff $beginBackendHandoff -StopTrafficFixture $stopTrafficFixture `
            -AssertResetRemovalPreconditions $assertResetRemovalPreconditions -RemoveResetContainers $removeResetContainers `
            -ReplaceCollectorFirst $replaceCollectorFirst -RemoveDedicatedVolumes $removeDedicatedVolumes `
            -StartProvider $startProvider -ReplaceCollectorSecond $replaceCollectorSecond -CompleteBackendHandoff $completeBackendHandoff `
            -StartTrafficFixture $startTrafficFixture
        $firstCollectorReplacement=$reset.CollectorFirst
        $overlapVictoriaMetricsId=[string]$reset.VictoriaMetricsAfterId
    }else{
        $legacyCaptureServices=@('backend','victoriametrics','otel-collector','m12-burn-demo')
        & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m12-overlap-reset -Services $legacyCaptureServices
        $resetCompose=@('--project-directory',$root,'--file',(Join-Path $root 'compose.yaml'),
            '--file',(Join-Path $root 'compose.m19.yaml'),'--file',(Join-Path $root 'compose.m12.yaml'))
        Invoke-Compose ($resetCompose + @('stop','m12-burn-demo'))
        Invoke-Compose ($resetCompose + @('rm','-sf','backend','m12-burn-demo','victoriametrics'))
        $collector=& docker inspect geordi-otel-collector-1 | ConvertFrom-Json
        if($LASTEXITCODE -ne 0 -or $collector[0].Config.Labels.'com.docker.compose.project' -ne 'geordi' -or
                $collector[0].Config.Labels.'com.docker.compose.service' -ne 'otel-collector'){
            throw 'Refusing M12 overlap reset for an unexpected shared Collector.'
        }
        & docker restart geordi-otel-collector-1 | Out-Null
        if($LASTEXITCODE -ne 0){throw 'M12 overlap Collector reset failed.'}
        foreach($logicalName in @('m12-alert-lifecycle-data','m12-victoriametrics-data')){
            $volumeName="geordi_$logicalName";$inspection=& docker volume inspect $volumeName 2>$null
            if($LASTEXITCODE -eq 0){$volume=@($inspection|ConvertFrom-Json)[0]
                if($volume.Labels.'com.docker.compose.project' -ne 'geordi' -or $volume.Labels.'com.docker.compose.volume' -ne $logicalName){throw "Refusing M12 overlap reset for unexpected volume '$volumeName'."}
                & docker volume rm $volumeName | Out-Null;if($LASTEXITCODE -ne 0){throw "Unable to remove dedicated M12 volume '$volumeName'."}
            }
        }
        Invoke-Compose ($compose + @('up','-d','--force-recreate','victoriametrics','otel-collector','backend','m12-burn-demo','m12-query-gate'))
        Wait-Until { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 } $deadline 'M12 overlap backend did not become ready.'
        Wait-Until { (Json "$BurnDemoBaseUrl/actuator/health").status -eq 'UP' } $deadline 'M12 overlap traffic fixture did not become ready.'
    }
    [void](Json "$ReceiverBaseUrl/control" 'POST' @{ mode = 'success'; failures = 0; reset = $true })
    Initialize-GeordiAuthentication -Identity EVALUATOR -RepositoryRoot $root

    # Seed both counter series and the met condition while scheduling is off.
    Traffic '/demo/success' 1
    Start-Sleep -Seconds 14
    Traffic '/demo/success' 1
    Traffic '/demo/error' 1
    Start-Sleep -Seconds 14
    Traffic '/demo/error' 1
    Traffic '/demo/error' 179
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$PolicyId/evaluation").status -eq 'CONDITION_MET' } $deadline 'M12 overlap controlled condition did not become met.'

    [void](Json "$GateBaseUrl/__control/arm" 'POST' @{})
    $env:GEORDI_SCHEDULING_ALERT_ENABLED = 'true'
    if($ApplyM12OverlapGenerations){
        $recreateEvidence=Publish-GeordiM12OverlapPersistedMetricEvidence -CaptureRoot $captureRoot -RepositoryRoot $root `
            -Phase m12-overlap-recreate -ResolveIdentity $resolveIdentity
        if([string]$recreateEvidence.SourceContainerId -cne $overlapVictoriaMetricsId){
            throw 'M12 overlap recreate evidence did not bind the active overlap VictoriaMetrics identity.'
        }
        $exerciseHandoff=Begin-GeordiM12OverlapBackendHandoff -CaptureRoot $captureRoot -RepositoryRoot $root `
            -ResolveIdentity $resolveIdentity -Reason 'm12-overlap-exercise'
        $exerciseBackend=Complete-GeordiM12OverlapBackendHandoff -CaptureRoot $captureRoot -RepositoryRoot $root `
            -HandoffId $exerciseHandoff -Replace $replaceBackend -ResolveIdentity $resolveIdentity `
            -WaitReadiness $backendReadiness -Reason 'm12-overlap-exercise'
        if([string]$exerciseBackend.OldContainerId -cne [string]$reset.BackendFirst.NewContainerId -or
                [string]$exerciseBackend.NewContainerId -ceq [string]$exerciseBackend.OldContainerId){
            throw 'M12 overlap exercise did not complete the second distinct backend generation boundary.'
        }
    }else{
        & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m12-overlap-recreate -Services backend
        Invoke-Compose ($compose + @('up','-d','--force-recreate','backend'))
    }
    Wait-Until { (Json "$GateBaseUrl/__control/status").entered } $deadline 'M12 scheduler never entered the deterministic provider barrier.'

    Initialize-GeordiAuthentication -Identity OPERATOR -RepositoryRoot $root
    $operator = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-policies/$PolicyId/lifecycle-evaluations" -Method POST -TimeoutSeconds 15
    if ($operator.StatusCode -ne 403) { throw "M12 overlap OPERATOR request expected 403, received $($operator.StatusCode)." }

    Initialize-GeordiAuthentication -Identity EVALUATOR -RepositoryRoot $root
    $manual = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-policies/$PolicyId/lifecycle-evaluations" -Method POST -TimeoutSeconds 15
    if ($manual.StatusCode -ne 409) { throw "M12 overlapping EVALUATOR request expected 409, received $($manual.StatusCode)." }
    if ((State).latestTransition) { throw 'Lifecycle transitioned before the scheduled provider barrier was released.' }

    [void](Json "$GateBaseUrl/__control/release" 'POST' @{})
    Wait-Until { (State).latestTransition.type -eq 'ALERT_STARTED' } $deadline 'Scheduled lifecycle did not commit after the provider barrier release.'
    Wait-Until { @((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.policy.id -eq $PolicyId -and $_.payload.transitionType -eq 'ALERT_STARTED' }).Count -eq 1 } $deadline 'M12 overlap did not create exactly one STARTED delivery.'
    Start-Sleep -Seconds 3

    $transitions = @((Json "$BackendBaseUrl/api/alert-transitions?policyId=$PolicyId&limit=100").alertTransitions)
    if ($transitions.Count -ne 1 -or $transitions[0].type -ne 'ALERT_STARTED') { throw 'M12 overlap produced duplicate or unexpected transition history.' }
    $episodeId = $transitions[0].episodeId
    $detail = Json "$BackendBaseUrl/api/alert-episodes/$episodeId"
    if (@($detail.transitions).Count -ne 1 -or $detail.transitions[0].notification.disposition -ne 'MATCHED') {
        throw 'M12 overlap did not persist exactly one matched transition notification disposition.'
    }
    $events = @((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.policy.id -eq $PolicyId -and $_.payload.transitionType -eq 'ALERT_STARTED' })
    if ($events.Count -ne 1) { throw 'M12 overlap produced duplicate delivery work.' }

    foreach ($name in @('geordi_m19-alert-lifecycle-data', 'geordi_m19-victoriametrics-data')) {
        $preserved = & docker volume inspect $name 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $preserved[0].Name -ne $name -or
            $preserved[0].Labels.'com.docker.compose.project' -ne 'geordi' -or
            $preserved[0].Labels.'com.docker.compose.volume' -notmatch '^m19-(alert-lifecycle|victoriametrics)-data$') {
            throw "Required M19 durable volume '$name' is missing or has unexpected labels."
        }
    }
    if($ApplyM12OverlapGenerations){
        $finalState=Assert-GeordiM12OverlapFinalEntryState -CaptureRoot $captureRoot -RepositoryRoot $root `
            -ResolveIdentity $resolveIdentity -InspectVolume $inspectVolume -ExpectedVictoriaMetricsId $overlapVictoriaMetricsId
        if([string]$finalState.Backend.Id -cne [string]$exerciseBackend.NewContainerId -or
                [string]$finalState.Collector.Id -cne [string]$reset.CollectorSecond.NewContainerId){
            throw 'M12 overlap final backend or Collector capture generation is not the exact live M13-entry identity.'
        }
    }
    Write-Host 'PASS: scheduler/manual overlap held at provider barrier; OPERATOR=403, EVALUATOR=409; one transition, matched disposition, and one delivery.'
} catch {
    try { [void](Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 3) } catch { }
    try { [void](Invoke-WebRequest -Uri "$GateBaseUrl/__control/release" -Method POST -UseBasicParsing -TimeoutSec 3) } catch { }
    Write-Error "M12 scheduler/manual overlap smoke failed: $($_.Exception.Message)"
    throw
}
}
