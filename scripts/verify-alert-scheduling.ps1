[CmdletBinding()]
param([ValidateRange(120, 360)][int] $TimeoutSeconds = 300,
      [string] $BackendBaseUrl = 'https://geordi.localhost:8443',
      [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8084',
      [string] $ReceiverBaseUrl = 'http://127.0.0.1:18080',
      [string] $StatusFile,
      [switch] $RunRecoveryBarrierSelfTest,
      [switch] $RunFixtureResetOnly,
      [switch] $ConsumeTransferredM11Fixture,
      [switch] $ApplyM12BackendGeneration)

$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM12CollectorReplacement.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM11M12FixtureTransfer.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM12BackendReplacement.ps1')
$script:M12TransferredFixturePrepared=$false
$PolicyId = 'm12-scheduling-alert'
$DisabledPolicyId = 'm12-disabled-scheduling-alert'
$M12ErrorRateTarget = 0.10
$M12PolicyBurnThreshold = 1.0
function Set-SmokeStatus([string] $Phase,[string] $CurrentWait,[string] $LastObservation){
  if([string]::IsNullOrWhiteSpace($StatusFile)){return}
  $temporary="$StatusFile.tmp"
  [pscustomobject]@{updatedAt=[DateTime]::UtcNow.ToString('O');phase=$Phase;currentWait=$CurrentWait;lastObservation=$LastObservation}|ConvertTo-Json -Compress|Set-Content -LiteralPath $temporary -NoNewline
  Move-Item -LiteralPath $temporary -Destination $StatusFile -Force
}
function Remaining-DeadlineSeconds { if($null -eq $script:SmokeDeadline){return 300}; $left=[math]::Floor(($script:SmokeDeadline-(Get-Date)).TotalSeconds); if($left -le 0){throw 'Global smoke deadline expired.'}; [int]$left }
function Remaining-Seconds { [math]::Min(15,(Remaining-DeadlineSeconds)) }
function Invoke-Compose([string[]] $Arguments,[string] $Phase) { $remaining=Remaining-DeadlineSeconds; $stdout=[IO.Path]::GetTempFileName(); $stderr=[IO.Path]::GetTempFileName(); try { $p=Start-Process -FilePath docker -ArgumentList (@('compose') + $Arguments) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden; if(-not $p.WaitForExit($remaining * 1000)){ & taskkill /PID $p.Id /T /F | Out-Null; throw "Native process timeout during $Phase after $remaining seconds." }; if($p.ExitCode -ne 0){throw "Compose failed during $Phase (exit $($p.ExitCode)): $([IO.File]::ReadAllText($stderr))"} } finally { Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue } }
function Get-M12ComposeConfiguration([string] $Root,[bool] $ReplacementOverlay) {
  $arguments=Get-GeordiM12CollectorComposeArguments -RepositoryRoot $Root -ReplacementOverlay:$ReplacementOverlay
  $arguments+=@('config','--format','json')
  $stdout=[IO.Path]::GetTempFileName(); $stderr=[IO.Path]::GetTempFileName(); $process=$null
  try {
    $remaining=[Math]::Min(30,(Remaining-DeadlineSeconds))
    $process=Start-Process -FilePath docker -ArgumentList (@('compose') + $arguments) -WorkingDirectory $Root `
      -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    if(-not $process.WaitForExit($remaining * 1000)){
      & taskkill /PID $process.Id /T /F | Out-Null
      throw 'Native process timeout while validating M12 Collector replacement configuration.'
    }
    if($process.ExitCode -ne 0){throw 'Compose failed to render M12 Collector replacement configuration.'}
    return [IO.File]::ReadAllText($stdout) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  } finally { Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue }
}
function Resolve-M12CollectorIdentity([string] $Service) {
  if($Service -cne 'otel-collector'){throw 'M12 Collector replacement requested an unexpected service identity.'}
  return Get-GeordiCurrentCaptureContainerIdentity -Service 'otel-collector' -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
}
function Resolve-M12ServiceIdentity([string] $Service,[string] $Root) {
  return Get-GeordiCurrentCaptureContainerIdentity -Service $Service -RepositoryRoot $Root
}
function Invoke-M12TransferredFixturePreparation([string] $Root,[string] $CaptureRoot) {
  $expectedM12Volumes=Get-GeordiM12DedicatedFixtureVolumeAllowlist
  $rendered=& docker compose --project-directory $Root config --format json | ConvertFrom-Json -AsHashtable
  if($LASTEXITCODE -ne 0){throw 'Unable to render M12 Compose configuration before the transferred fixture boundary.'}
  foreach($logicalName in $expectedM12Volumes.Keys){
    $renderedName=[string]$rendered.volumes[$logicalName].name
    if([string]::IsNullOrWhiteSpace($renderedName) -or $renderedName -cne [string]$expectedM12Volumes[$logicalName]){
      throw 'M12 rendered volume identity does not match the exact dedicated fixture allowlist.'
    }
  }
  $dockerCommand={
    param([string[]]$Arguments)
    $output=@(& docker @Arguments 2>&1);$code=$LASTEXITCODE
    return [pscustomobject]@{ExitCode=$code;Output=$output}
  }.GetNewClosure()
  $inspectM11Volume={param([string]$Name) Get-GeordiM11DockerVolumeInspection -Name $Name -DockerCommand $dockerCommand}.GetNewClosure()
  $removeM11Volume={param([string]$Name) $result=& $dockerCommand @('volume','rm',$Name);if($result.ExitCode -ne 0){throw 'Unable to remove an exact owned M11 fixture volume.'}}.GetNewClosure()
  $inspectM12Volume={
    param([string]$Name)
    return Get-GeordiM11DockerVolumeInspection -Name $Name -DockerCommand $dockerCommand
  }.GetNewClosure()
  $removeM12Volume={param([string]$Name) $result=& $dockerCommand @('volume','rm',$Name);if($result.ExitCode -ne 0){throw 'Unable to remove an exact owned M12 fixture volume.'}}.GetNewClosure()
  $replace={
    # Only the transferred M11 backend and VictoriaMetrics are removed here.
    # The shared Collector is replaced separately through its accepted lifecycle.
    Invoke-Compose @('--project-directory',$Root,'rm','-sf','backend','victoriametrics') 'M11-to-M12 service boundary'
    Remove-GeordiM12DedicatedFixtureVolumes -ExpectedVolumes $expectedM12Volumes `
      -InspectVolume $inspectM12Volume -RemoveVolume $removeM12Volume
    $configRenderer={param([string]$RepositoryRoot,[bool]$ReplacementOverlay) Get-M12ComposeConfiguration $RepositoryRoot $ReplacementOverlay}.GetNewClosure()
    $composeInvoker={param([string[]]$Arguments,[string]$Phase) Invoke-Compose $Arguments $Phase}.GetNewClosure()
    $collectorResolver={param([string]$Service) Resolve-M12CollectorIdentity $Service}.GetNewClosure()
    $collectorReadiness={Wait-Until {(Http-Status 'http://127.0.0.1:13133/') -eq 200} $script:SmokeDeadline 'Collector did not become ready at the M12 provider boundary.'}.GetNewClosure()
    $null=Invoke-GeordiM12CollectorControlledReplacement -CaptureRoot $CaptureRoot -RepositoryRoot $Root `
      -RenderComposeConfiguration $configRenderer -InvokeCompose $composeInvoker -ResolveContainerIdentity $collectorResolver `
      -WaitForReadiness $collectorReadiness
    Invoke-Compose @('--project-directory',$Root,'up','-d','--no-deps','--force-recreate','victoriametrics','m12-burn-demo') 'M12 fixture services'
    Wait-Until {(Http-Status 'http://127.0.0.1:8428/-/healthy') -eq 200} $script:SmokeDeadline 'M12 VictoriaMetrics did not become ready.'
    Wait-Until {(Http-Status "$BurnDemoBaseUrl/actuator/health") -eq 200} $script:SmokeDeadline 'M12 burn-demo did not become ready.'
    Invoke-Compose (Get-GeordiM12BackendRecreationArguments -RepositoryRoot $Root -Boundary initial-fixture) 'M12 initial backend generation'
  }.GetNewClosure()
  $resolve={param([string]$Service) Resolve-M12ServiceIdentity $Service $Root}.GetNewClosure()
  $backendReadiness={param($Target) Wait-Until {(Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200} $script:SmokeDeadline 'M12 backend did not become ready after generation replacement.'}.GetNewClosure()
  $result=Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $CaptureRoot -RepositoryRoot $Root `
    -EvidencePhase m12-reset -Reason 'm11-to-m12-transferred-fixture-reset' -Replace $replace `
    -ResolveContainerIdentity $resolve -WaitForReadiness $backendReadiness
  Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes (Get-GeordiM11TransferVolumeAllowlist) `
    -InspectVolume $inspectM11Volume -RemoveVolume $removeM11Volume -RequirePresent
  return $result
}
function Reset-M12FixtureVolumes([string] $Root) {
  $expectedVolumes = [ordered]@{
    'm12-alert-lifecycle-data' = 'geordi_m12-alert-lifecycle-data'
    'm12-victoriametrics-data' = 'geordi_m12-victoriametrics-data'
  }
  $rendered = & docker compose --project-directory $Root config --format json | ConvertFrom-Json
  if($LASTEXITCODE -ne 0){throw 'Unable to render the M12 Compose configuration for fixture reset.'}
  foreach($logicalName in $expectedVolumes.Keys){
    $candidate = $rendered.volumes.$logicalName.name
    if([string]::IsNullOrWhiteSpace($candidate) -or $candidate -ne $expectedVolumes[$logicalName]){throw "Refusing fixture reset for unexpected volume '$candidate'."}
  }
  $m12CaptureServices=@('backend','victoriametrics','otel-collector','m12-burn-demo')
  $legacyCaptureServices=Get-GeordiM12LegacyResetCaptureServices -Services $m12CaptureServices
  & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m12-reset -Services $legacyCaptureServices
  # The Collector owns an in-memory sending queue and retry state.  Quiesce the
  # M12 producer before replacing the provider, then restart the shared Collector
  # so a prior M12 batch cannot cross the fresh-provider boundary.
  Invoke-Compose @('--project-directory',$Root,'stop','m12-burn-demo') 'M12 telemetry producer quiescence'
  Invoke-Compose @('--project-directory',$Root,'rm','-sf','backend','m12-burn-demo','victoriametrics') 'M12 fixture reset preparation'
  $configRenderer={ param([string]$RepositoryRoot,[bool]$ReplacementOverlay) Get-M12ComposeConfiguration $RepositoryRoot $ReplacementOverlay }.GetNewClosure()
  $composeInvoker={ param([string[]]$Arguments,[string]$Phase) Invoke-Compose $Arguments $Phase }.GetNewClosure()
  $identityResolver={ param([string]$Service) Resolve-M12CollectorIdentity $Service }.GetNewClosure()
  $collectorReadiness={ Wait-Until { (Http-Status 'http://127.0.0.1:13133/') -eq 200 } $script:SmokeDeadline 'Collector did not become ready after M12 telemetry reset.' }.GetNewClosure()
  $capturePointer=Join-Path $Root '.runtime/m19-capture-root.txt'
  if(!(Test-Path -LiteralPath $capturePointer -PathType Leaf)){throw 'M19 capture pointer is required for the M12 Collector handoff.'}
  $captureRoot=[IO.Path]::GetFullPath([IO.File]::ReadAllText($capturePointer).Trim())
  $null=Invoke-GeordiM12CollectorControlledReplacement -CaptureRoot $captureRoot `
    -RepositoryRoot $Root -RenderComposeConfiguration $configRenderer -InvokeCompose $composeInvoker `
    -ResolveContainerIdentity $identityResolver -WaitForReadiness $collectorReadiness
  foreach($logicalName in $expectedVolumes.Keys){
    $candidate = $expectedVolumes[$logicalName]
    $inspection = & docker volume inspect $candidate 2>$null
    if($LASTEXITCODE -eq 0){
      $volume = @($inspection | ConvertFrom-Json)[0]
      if($volume.Name -ne $candidate -or $volume.Labels.'com.docker.compose.project' -ne 'geordi' -or $volume.Labels.'com.docker.compose.volume' -ne $logicalName){throw "Refusing fixture reset for non-M12 volume '$candidate'."}
      & docker volume rm $candidate | Out-Null
      if($LASTEXITCODE -ne 0){throw "Unable to remove dedicated M12 volume '$candidate'."}
    }
  }
}
function Json([string] $Uri, [string] $Method = 'GET', $Body = $null) {
  if($Uri.StartsWith($BackendBaseUrl,[StringComparison]::OrdinalIgnoreCase) -and $Uri.Substring($BackendBaseUrl.Length).StartsWith('/api/',[StringComparison]::Ordinal)) {
    if(!$script:GeordiAuthState.Identity){Initialize-GeordiAuthentication -Identity REGRESSION -RepositoryRoot (Split-Path -Parent $PSScriptRoot)}
    $result=Invoke-GeordiAuthenticatedRequest -Uri $Uri -Method $Method -Body $Body -TimeoutSeconds (Remaining-Seconds)
    if($result.StatusCode -lt 200 -or $result.StatusCode -ge 300){throw "Authenticated M12 API request returned HTTP $($result.StatusCode)."}
    return $result.Content|ConvertFrom-Json
  }
  $a=@{Uri=$Uri;Method=$Method;TimeoutSec=(Remaining-Seconds);UseBasicParsing=$true}; if($null -ne $Body){$a.ContentType='application/json';$a.Body=$Body|ConvertTo-Json -Compress}; (Invoke-WebRequest @a).Content|ConvertFrom-Json
}
function Http-Status([string] $Uri) {
  if($Uri.StartsWith($BackendBaseUrl,[StringComparison]::OrdinalIgnoreCase) -and $Uri.Substring($BackendBaseUrl.Length).StartsWith('/actuator/health/',[StringComparison]::Ordinal)) {
    return (Invoke-GeordiAnonymousRequest -Uri $Uri -TimeoutSeconds (Remaining-Seconds)).StatusCode
  }
  (Invoke-WebRequest -Uri $Uri -TimeoutSec (Remaining-Seconds) -UseBasicParsing).StatusCode
}
function Wait-Until([scriptblock] $Condition,[datetime] $Deadline,[string] $Message){$lastError=$null;Set-SmokeStatus 'waiting' $Message 'awaiting first observation';while((Get-Date)-lt $Deadline){try{if(& $Condition){Set-SmokeStatus 'waiting' $Message 'condition satisfied';return};Set-SmokeStatus 'waiting' $Message 'condition not yet satisfied'}catch [System.Net.WebException]{$lastError=$_.Exception.Message;Set-SmokeStatus 'waiting' $Message "transient WebException: $lastError"}catch [System.Net.Http.HttpRequestException]{$lastError=$_.Exception.Message;Set-SmokeStatus 'waiting' $Message "transient HttpRequestException: $lastError"}catch [System.TimeoutException]{$lastError=$_.Exception.Message;Set-SmokeStatus 'waiting' $Message "transient TimeoutException: $lastError"}catch{throw}; $remaining=[math]::Max(1,[math]::Min(250,[int](($Deadline-(Get-Date)).TotalMilliseconds)));Start-Sleep -Milliseconds $remaining};if($lastError){throw "$Message Last transient error: $lastError"};throw $Message}
function State { @((Json "$BackendBaseUrl/api/alert-states").alertStates | Where-Object { $_.policy.id -eq $PolicyId })[0] }
function Disabled-State { @((Json "$BackendBaseUrl/api/alert-states").alertStates | Where-Object { $_.policy.id -eq $DisabledPolicyId })[0] }
function Traffic([string] $Path,[int] $Count){1..$Count|ForEach-Object -Parallel {[void](Invoke-WebRequest -Uri "$using:BurnDemoBaseUrl$using:Path" -TimeoutSec 10 -UseBasicParsing -SkipHttpErrorCheck)} -ThrottleLimit 16}
function Metric-Series([string] $Selector) { @((Json "http://127.0.0.1:8428/api/v1/series?match%5B%5D=$([uri]::EscapeDataString($Selector))").data) }
function Metric-Query([string] $Query) { @((Json "http://127.0.0.1:8428/api/v1/query?query=$([uri]::EscapeDataString($Query))").data.result) }
function Counter-HasBaseline([string] $Selector) { @((Metric-Query "count_over_time($Selector[60s])") | Where-Object { [double]$_.value[1] -ge 2 }).Count -gt 0 }
function Test-CanonicalM12Firing([double] $ErrorCount,[double] $RequestCount) {
  if($RequestCount -le 0){return $false}
  ($ErrorCount / ($RequestCount * $M12ErrorRateTarget)) -ge $M12PolicyBurnThreshold
}
function Provider-Firing { $s='"geordi.telemetry.origin"="monitored","service.name"="geordi-m12-scheduling-service","deployment.environment.name"="development","service.namespace"="geordi-m12-scheduling"'; $q="sum(increase_pure({__name__=`"http.server.request.duration_count`",$s,`"http.response.status_code`"=~`"5..`"}[300s])) / (sum(increase_pure({__name__=`"http.server.request.duration_count`",$s}[300s])) * $M12ErrorRateTarget)"; @((Metric-Query $q) | Where-Object { [double]$_.value[1] -ge $M12PolicyBurnThreshold }).Count -gt 0 }
function Scheduler-Series { Metric-Series '{__name__=~"geordi.alert.scheduler.(attempts|completed|failures|overlap_skips|rejections|duration_count)"}' }
function Invoke-M12TransferredFixtureConsumer([string] $Root,[string] $CaptureRoot) {
  $dockerCommand={
    param([string[]] $Arguments)
    $output=& docker @Arguments 2>$null
    $exitCode=$LASTEXITCODE
    return [pscustomobject]@{ExitCode=$exitCode;Output=@($output)}
  }.GetNewClosure()
  $resolveIdentity={param([string]$Service) Get-GeordiCurrentCaptureContainerIdentity -Service $Service -RepositoryRoot $Root}.GetNewClosure()
  $inspectVolume={param([string]$Name) Get-GeordiM11DockerVolumeInspection -Name $Name -DockerCommand $dockerCommand}.GetNewClosure()
  $testFollower={param($Record) Test-GeordiM11TransferFollowerProcess -FollowerRecord $Record}.GetNewClosure()
  $captureReset={
    param($Transfer)
    $capture={ & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m12-reset -Services backend -SkipLogSnapshot | Out-Null }.GetNewClosure()
    [void](Ensure-GeordiM12ResetTransferEvidence -CaptureRoot $CaptureRoot `
      -ExpectedVictoriaMetricsContainerId ([string]$Transfer.VictoriaMetricsContainerId) -Capture $capture)
  }.GetNewClosure()
  return Invoke-GeordiM11M12FixtureTransferConsumer -CaptureRoot $CaptureRoot -RepositoryRoot $Root `
    -ResolveIdentity $resolveIdentity -InspectVolume $inspectVolume -TestFollowerProcess $testFollower `
    -ExpectedVolumes (Get-GeordiM11TransferVolumeAllowlist) -CaptureM12Reset $captureReset
}
if($ConsumeTransferredM11Fixture -and ($RunFixtureResetOnly -or $RunRecoveryBarrierSelfTest)) {
  throw 'M12 transfer-consumer mode cannot be combined with another fixture mode.'
}
if($ApplyM12BackendGeneration -and !$ConsumeTransferredM11Fixture){
  throw 'M12 backend-generation application requires the explicitly validated M11 fixture transfer.'
}
if($ApplyM12BackendGeneration -and ($RunFixtureResetOnly -or $RunRecoveryBarrierSelfTest)){
  throw 'M12 backend-generation application cannot be combined with another fixture mode.'
}
if($RunRecoveryBarrierSelfTest) {
  if(Test-CanonicalM12Firing 9 100){throw 'Below-target recovery barrier case incorrectly fired.'}
  if(-not (Test-CanonicalM12Firing 10 100)){throw 'Boundary recovery barrier case did not fire.'}
  if(-not (Test-CanonicalM12Firing 180 272)){throw 'Historical recovery barrier case did not fire.'}
  if(Test-CanonicalM12Firing 1 0){throw 'Zero-denominator recovery barrier case incorrectly fired.'}
  Write-Output 'Recovery barrier self-test PASS.'
  exit 0
}
if($ConsumeTransferredM11Fixture) {
  $root=Split-Path -Parent $PSScriptRoot
  $script:SmokeDeadline=(Get-Date).AddSeconds($TimeoutSeconds)
  $env:COMPOSE_FILE=(Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m19.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m12.yaml')
  $capturePointer=Join-Path $root '.runtime/m19-capture-root.txt'
  if(!(Test-Path -LiteralPath $capturePointer -PathType Leaf)){throw 'M19 capture pointer is required for M12 transfer consumption.'}
  $captureRoot=[IO.Path]::GetFullPath([IO.File]::ReadAllText($capturePointer).Trim())
  $result=Invoke-M12TransferredFixtureConsumer $root $captureRoot
  if([string]$result.Status -cne 'TRANSFER_VALIDATED'){throw 'M12 inherited fixture transfer did not validate.'}
  if(!$ApplyM12BackendGeneration){
    Write-Output 'TRANSFER_VALIDATED m12-reset=passed log_snapshot=skipped destructive_m12_boundary=not_run'
    exit 0
  }
  $env:GEORDI_SCHEDULING_ALERT_ENABLED='false';$env:GEORDI_SCHEDULING_ALERT_INTERVAL='10s'
  $boundary=Invoke-M12TransferredFixturePreparation $root $captureRoot
  if([string]$boundary.Status -cne 'complete'){throw 'M11-to-M12 backend generation handoff did not complete.'}
  $script:M12TransferredFixturePrepared=$true
  Write-Output ("M12_BACKEND_GENERATION_READY old={0} new={1} handoff={2}" -f $boundary.OldContainerId,$boundary.NewContainerId,$boundary.HandoffId)
}
if($RunFixtureResetOnly) {
  $root=Split-Path -Parent $PSScriptRoot
  $script:SmokeDeadline=(Get-Date).AddSeconds($TimeoutSeconds)
  $env:COMPOSE_FILE=(Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m19.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m12.yaml')
  Reset-M12FixtureVolumes $root
  Write-Output 'M12 fixture reset PASS.'
  exit 0
}
try {
  $root=Split-Path -Parent $PSScriptRoot
  if($null -eq $script:SmokeDeadline){$script:SmokeDeadline=(Get-Date).AddSeconds($TimeoutSeconds)}
  $deadline=$script:SmokeDeadline
  $env:COMPOSE_FILE=(Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m19.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m12.yaml')
  # Start with scheduling disabled so the fixture can prove the dedicated M12
  # policies have no durable lifecycle or delivery history before enabling it.
  # This avoids treating a STARTED delivery from an interrupted prior run as a
  # delivery produced by this run after the receiver has been reset.
  $env:GEORDI_SCHEDULING_ALERT_ENABLED='false'; $env:GEORDI_SCHEDULING_ALERT_INTERVAL='10s'
  if(!$script:M12TransferredFixturePrepared){
    Reset-M12FixtureVolumes $root
    Invoke-Compose @('--project-directory',$root,'up','-d','--force-recreate','backend','m12-burn-demo') 'fixture preparation'
  }
  Wait-Until { (Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200 } $deadline 'Backend did not become ready.'
  Wait-Until { (Http-Status "$BurnDemoBaseUrl/actuator/health") -eq 200 } $deadline 'Burn-demo did not become ready.'
  $initial=State; if($null -ne $initial -and ($initial.initialized -or $null -ne $initial.latestTransition)){throw 'M12 fixture has durable lifecycle history; reset the local alert lifecycle volume before rerunning this smoke.'}
  $initialDisabled=Disabled-State; if($null -ne $initialDisabled -and ($initialDisabled.initialized -or $null -ne $initialDisabled.latestTransition)){throw 'Disabled M12 fixture has durable lifecycle history; reset the local alert lifecycle volume before rerunning this smoke.'}
  if((Metric-Series '{__name__="http.server.request.duration_count","service.name"="geordi-m12-scheduling-service","http.route"=~"/demo/(success|error)"}').Count -ne 0){throw 'M12 fixture has controlled traffic history; reset the local VictoriaMetrics volume before rerunning this smoke.'}
  [void](Json "$ReceiverBaseUrl/control" 'POST' @{mode='success';failures=0;reset=$true})
  $env:GEORDI_SCHEDULING_ALERT_ENABLED='true'
  if($script:M12TransferredFixturePrepared){
    & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m12-fixture-start -Services backend -SkipLogSnapshot
    $replaceSchedulerBackend={Invoke-Compose (Get-GeordiM12BackendRecreationArguments -RepositoryRoot $root -Boundary scheduler-enablement) 'scheduler enablement'}.GetNewClosure()
    $resolveBackend={param([string]$Service) Resolve-M12ServiceIdentity $Service $root}.GetNewClosure()
    $readyBackend={param($Target) Wait-Until {(Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200} $deadline 'Backend did not become ready with M12 scheduling enabled.'}.GetNewClosure()
    $null=Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $captureRoot -RepositoryRoot $root -EvidencePhase m12-fixture-start `
      -Reason 'm12-scheduler-enablement' -Replace $replaceSchedulerBackend -ResolveContainerIdentity $resolveBackend -WaitForReadiness $readyBackend
  } else {
    & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m12-fixture-start -Services backend -SkipLogSnapshot
    Invoke-Compose @('--project-directory',$root,'up','-d','--force-recreate','backend') 'scheduler enablement'
    Wait-Until { (Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200 } $deadline 'Backend did not become ready with M12 scheduling enabled.'
  }
  # Establish and persist both counter series before their controlled increments.
  # A first OTLP export containing only an increment has no prior sample for the
  # canonical M9 increase() query to measure.
  Traffic '/demo/success' 1
  Wait-Until { (Metric-Series '{__name__="http.server.request.duration_count","service.name"="geordi-m12-scheduling-service","http.route"="/demo/success","http.response.status_code"="200"}').Count -gt 0 } $deadline 'Controlled traffic baseline was not persisted.'
  Wait-Until { Counter-HasBaseline '{__name__="http.server.request.duration_count","service.name"="geordi-m12-scheduling-service","http.route"="/demo/success","http.response.status_code"="200"}' } $deadline 'Controlled traffic baseline did not receive a second sample.'
  Traffic '/demo/error' 1
  Wait-Until { (Metric-Series '{__name__="http.server.request.duration_count","service.name"="geordi-m12-scheduling-service","http.route"="/demo/error","http.response.status_code"="500"}').Count -gt 0 } $deadline 'Controlled error baseline was not persisted.'
  Wait-Until { Counter-HasBaseline '{__name__="http.server.request.duration_count","service.name"="geordi-m12-scheduling-service","http.route"="/demo/error","http.response.status_code"="500"}' } $deadline 'Controlled error baseline did not receive a second sample.'
  Traffic '/demo/error' 179
  Wait-Until { (State).state -eq 'FIRING' } $deadline 'Automatic scheduler did not start the alert.'
  $started=(State).latestTransition; if($started.type -ne 'ALERT_STARTED'){throw 'Automatic evaluation did not produce ALERT_STARTED.'}
  Wait-Until { @((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.transitionType -eq 'ALERT_STARTED' }).Count -eq 1 } $deadline 'STARTED webhook was not delivered.'
  $beforeDuplicate=(State).lastProcessedAt
  Wait-Until { (State).lastProcessedAt -ne $beforeDuplicate } $deadline 'Scheduler did not perform a second firing evaluation.'
  if((State).state -ne 'FIRING' -or (State).latestTransition.type -ne 'ALERT_STARTED' -or @((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.transitionType -eq 'ALERT_STARTED' }).Count -ne 1){throw 'Continuous firing duplicated STARTED behavior.'}
  $disabled=Disabled-State
  if($null -eq $disabled -or $disabled.policy.enabled -or $disabled.initialized -or $null -ne $disabled.latestTransition){throw 'Disabled policy was not present and suppressed.'}
  if($script:M12TransferredFixturePrepared){
    & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m12-recovery-start -Services backend -SkipLogSnapshot
    $beforeRecoveryHandoff={
      Invoke-Compose @('--project-directory',$root,'stop','victoriametrics') 'provider outage'
      Wait-Until { (State).latestEvaluation.status -eq 'UNAVAILABLE' } $deadline 'Scheduler did not expose provider unavailability.'
      if((State).state -ne 'FIRING' -or (State).latestTransition.type -ne 'ALERT_STARTED'){throw 'Provider outage fabricated a lifecycle transition.'}
    }.GetNewClosure()
    $replaceRecoveryBackend={
      Invoke-Compose @('--project-directory',$root,'stop','backend') 'backlog stabilization'
      Invoke-Compose @('--project-directory',$root,'start','victoriametrics') 'provider recovery'
      Wait-Until { Provider-Firing } $deadline 'Recovered provider did not expose queued firing evidence.'
      Invoke-Compose (Get-GeordiM12BackendRecreationArguments -RepositoryRoot $root -Boundary provider-recovery) 'backend recovery generation'
    }.GetNewClosure()
    $resolveBackend={param([string]$Service) Resolve-M12ServiceIdentity $Service $root}.GetNewClosure()
    $readyBackend={param($Target) Wait-Until {(Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200} $deadline 'Backend did not recover after provider restoration.'}.GetNewClosure()
    $null=Invoke-GeordiM12BackendGenerationReplacement -CaptureRoot $captureRoot -RepositoryRoot $root -EvidencePhase m12-recovery-start `
      -Reason 'm12-provider-recovery' -Replace $replaceRecoveryBackend -ResolveContainerIdentity $resolveBackend `
      -WaitForReadiness $readyBackend -BeforeHandoff $beforeRecoveryHandoff
  } else {
    Invoke-Compose @('--project-directory',$root,'stop','victoriametrics') 'provider outage'
    Wait-Until { (State).latestEvaluation.status -eq 'UNAVAILABLE' } $deadline 'Scheduler did not expose provider unavailability.'
    if((State).state -ne 'FIRING' -or (State).latestTransition.type -ne 'ALERT_STARTED'){throw 'Provider outage fabricated a lifecycle transition.'}
    Invoke-Compose @('--project-directory',$root,'stop','backend') 'backlog stabilization'
    Invoke-Compose @('--project-directory',$root,'start','victoriametrics') 'provider recovery'
    Wait-Until { Provider-Firing } $deadline 'Recovered provider did not expose queued firing evidence.'
    Invoke-Compose @('--project-directory',$root,'restart','backend') 'backend restart'
    Wait-Until { (Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200 } $deadline 'Backend did not recover after restart.'
  }
  # The Collector may now deliver queued 5xx samples.  Prove two automatic
  # canonical firing evaluations before adding healthy traffic, so recovery
  # cannot accept a transient ratio based on partially drained telemetry.
  $firstRecovered=(State).lastProcessedAt
  Wait-Until { $s=State; $s.state -eq 'FIRING' -and $s.latestEvaluation.status -eq 'CONDITION_MET' -and $s.lastProcessedAt -ne $firstRecovered } $deadline 'Recovered provider did not expose queued firing evidence.'
  $secondRecovered=(State).lastProcessedAt
  Wait-Until { $s=State; $s.state -eq 'FIRING' -and $s.latestEvaluation.status -eq 'CONDITION_MET' -and $s.lastProcessedAt -ne $secondRecovered } $deadline 'Recovered provider evidence did not stabilize while firing.'
  if(@((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.transitionType -eq 'ALERT_STARTED' }).Count -ne 1){throw 'Recovery produced a duplicate STARTED before healthy traffic.'}
  $beforeRecovery=(State).lastProcessedAt
  Traffic '/demo/success' 2000
  Wait-Until { (State).state -eq 'INACTIVE' -and (State).lastProcessedAt -ne $beforeRecovery } $deadline 'Automatic scheduler did not resume and resolve the alert.'
  if((State).latestTransition.type -ne 'ALERT_RESOLVED'){throw 'Automatic evaluation did not produce ALERT_RESOLVED.'}
  Wait-Until { @((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.transitionType -eq 'ALERT_RESOLVED' }).Count -eq 1 } $deadline 'RESOLVED webhook was not delivered.'
  $stableOne=(State).lastProcessedAt
  Wait-Until { $s=State; $s.state -eq 'INACTIVE' -and $s.latestEvaluation.status -eq 'CONDITION_NOT_MET' -and $s.lastProcessedAt -ne $stableOne } $deadline 'First post-resolution automatic evaluation was not stable.'
  $stableTwo=(State).lastProcessedAt
  Wait-Until { $s=State; $s.state -eq 'INACTIVE' -and $s.latestEvaluation.status -eq 'CONDITION_NOT_MET' -and $s.lastProcessedAt -ne $stableTwo } $deadline 'Second post-resolution automatic evaluation was not stable.'
  if((State).state -ne 'INACTIVE' -or @((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.transitionType -eq 'ALERT_STARTED' }).Count -ne 1 -or @((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.payload.transitionType -eq 'ALERT_RESOLVED' }).Count -ne 1){throw 'Recovery was not transition-stable.'}
  $schedulerMetrics=Scheduler-Series
  if($schedulerMetrics.Count -eq 0 -or $schedulerMetrics.Count -gt 6){throw 'Scheduler telemetry was absent or unbounded.'}
  foreach($series in $schedulerMetrics){foreach($name in $series.PSObject.Properties.Name){if($name.StartsWith('geordi.alert.scheduler.') -and $name -match 'policy|slo|service|namespace|environment|webhook|delivery|trace|span'){throw 'Scheduler telemetry exposed high-cardinality context.'}}}
  $publicResponse=Invoke-GeordiScriptRequest -Uri "$BackendBaseUrl/api/platform"
  if($publicResponse.StatusCode -ne 200 -or $publicResponse.Content -match [regex]::Escape('local-dev-only-token')){throw 'Public API failed or exposed a notification secret.'}
  Write-Host 'PASS: automatic M9/M10/M11 alert scheduling and restart recovery verified.'
} catch { Write-Error "Alert scheduling smoke failed: $($_.Exception.Message)"; exit 1 }
