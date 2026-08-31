[CmdletBinding()]
param([ValidateRange(120, 360)][int] $TimeoutSeconds = 300,
      [string] $BackendBaseUrl = 'http://127.0.0.1:8080',
      [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8084',
      [string] $ReceiverBaseUrl = 'http://127.0.0.1:18080',
      [string] $StatusFile,
      [switch] $RunRecoveryBarrierSelfTest,
      [switch] $RunFixtureResetOnly)

$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
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
function Restart-M12Collector {
  $expectedName = 'geordi-otel-collector-1'
  $inspectionJson = & docker inspect $expectedName
  if($LASTEXITCODE -ne 0){throw "Unable to inspect Collector '$expectedName' before M12 telemetry reset."}
  $inspection = @($inspectionJson | ConvertFrom-Json)[0]
  if($inspection.Name -ne "/$expectedName" -or $inspection.Config.Labels.'com.docker.compose.project' -ne 'geordi' -or $inspection.Config.Labels.'com.docker.compose.service' -ne 'otel-collector'){throw "Refusing M12 telemetry reset for unexpected Collector '$expectedName'."}
  $remaining=Remaining-DeadlineSeconds; $stdout=[IO.Path]::GetTempFileName(); $stderr=[IO.Path]::GetTempFileName()
  try { $p=Start-Process -FilePath docker -ArgumentList @('restart',$expectedName) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden; if(-not $p.WaitForExit($remaining * 1000)){ & taskkill /PID $p.Id /T /F | Out-Null; throw "Native process timeout during M12 collector in-flight telemetry reset after $remaining seconds." }; if($p.ExitCode -ne 0){throw "Collector restart failed during M12 telemetry reset (exit $($p.ExitCode)): $([IO.File]::ReadAllText($stderr))"} } finally { Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue }
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
  # The Collector owns an in-memory sending queue and retry state.  Quiesce the
  # M12 producer before replacing the provider, then restart the shared Collector
  # so a prior M12 batch cannot cross the fresh-provider boundary.
  Invoke-Compose @('--project-directory',$Root,'stop','m12-burn-demo') 'M12 telemetry producer quiescence'
  Invoke-Compose @('--project-directory',$Root,'rm','-sf','backend','m12-burn-demo','victoriametrics') 'M12 fixture reset preparation'
  Restart-M12Collector
  Wait-Until { (Http-Status 'http://127.0.0.1:13133/') -eq 200 } $script:SmokeDeadline 'Collector did not become ready after M12 telemetry reset.'
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
function Json([string] $Uri, [string] $Method = 'GET', $Body = $null) { $a=@{Uri=$Uri;Method=$Method;TimeoutSec=(Remaining-Seconds);UseBasicParsing=$true}; if($null -ne $Body){$a.ContentType='application/json';$a.Body=$Body|ConvertTo-Json -Compress}; (Invoke-WebRequest @a).Content|ConvertFrom-Json }
function Http-Status([string] $Uri) { (Invoke-WebRequest -Uri $Uri -TimeoutSec (Remaining-Seconds) -UseBasicParsing).StatusCode }
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
if($RunRecoveryBarrierSelfTest) {
  if(Test-CanonicalM12Firing 9 100){throw 'Below-target recovery barrier case incorrectly fired.'}
  if(-not (Test-CanonicalM12Firing 10 100)){throw 'Boundary recovery barrier case did not fire.'}
  if(-not (Test-CanonicalM12Firing 180 272)){throw 'Historical recovery barrier case did not fire.'}
  if(Test-CanonicalM12Firing 1 0){throw 'Zero-denominator recovery barrier case incorrectly fired.'}
  Write-Output 'Recovery barrier self-test PASS.'
  exit 0
}
if($RunFixtureResetOnly) {
  $root=Split-Path -Parent $PSScriptRoot
  $script:SmokeDeadline=(Get-Date).AddSeconds($TimeoutSeconds)
  $env:COMPOSE_FILE=(Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m12.yaml')
  Reset-M12FixtureVolumes $root
  Write-Output 'M12 fixture reset PASS.'
  exit 0
}
try {
  $root=Split-Path -Parent $PSScriptRoot; $deadline=(Get-Date).AddSeconds($TimeoutSeconds); $script:SmokeDeadline=$deadline; $env:COMPOSE_FILE=(Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m12.yaml')
  # Start with scheduling disabled so the fixture can prove the dedicated M12
  # policies have no durable lifecycle or delivery history before enabling it.
  # This avoids treating a STARTED delivery from an interrupted prior run as a
  # delivery produced by this run after the receiver has been reset.
  $env:GEORDI_SCHEDULING_ALERT_ENABLED='false'; $env:GEORDI_SCHEDULING_ALERT_INTERVAL='10s'
  Reset-M12FixtureVolumes $root
  Invoke-Compose @('--project-directory',$root,'up','-d','--force-recreate','backend','m12-burn-demo') 'fixture preparation'
  Wait-Until { (Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200 } $deadline 'Backend did not become ready.'
  Wait-Until { (Http-Status "$BurnDemoBaseUrl/actuator/health") -eq 200 } $deadline 'Burn-demo did not become ready.'
  $initial=State; if($null -ne $initial -and ($initial.initialized -or $null -ne $initial.latestTransition)){throw 'M12 fixture has durable lifecycle history; reset the local alert lifecycle volume before rerunning this smoke.'}
  $initialDisabled=Disabled-State; if($null -ne $initialDisabled -and ($initialDisabled.initialized -or $null -ne $initialDisabled.latestTransition)){throw 'Disabled M12 fixture has durable lifecycle history; reset the local alert lifecycle volume before rerunning this smoke.'}
  if((Metric-Series '{__name__="http.server.request.duration_count","service.name"="geordi-m12-scheduling-service","http.route"=~"/demo/(success|error)"}').Count -ne 0){throw 'M12 fixture has controlled traffic history; reset the local VictoriaMetrics volume before rerunning this smoke.'}
  [void](Json "$ReceiverBaseUrl/control" 'POST' @{mode='success';failures=0;reset=$true})
  $env:GEORDI_SCHEDULING_ALERT_ENABLED='true'
  Invoke-Compose @('--project-directory',$root,'up','-d','--force-recreate','backend') 'scheduler enablement'
  Wait-Until { (Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200 } $deadline 'Backend did not become ready with M12 scheduling enabled.'
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
  Invoke-Compose @('--project-directory',$root,'stop','victoriametrics') 'provider outage'
  Wait-Until { (State).latestEvaluation.status -eq 'UNAVAILABLE' } $deadline 'Scheduler did not expose provider unavailability.'
  if((State).state -ne 'FIRING' -or (State).latestTransition.type -ne 'ALERT_STARTED'){throw 'Provider outage fabricated a lifecycle transition.'}
  Invoke-Compose @('--project-directory',$root,'stop','backend') 'backlog stabilization'
  Invoke-Compose @('--project-directory',$root,'start','victoriametrics') 'provider recovery'
  Wait-Until { Provider-Firing } $deadline 'Recovered provider did not expose queued firing evidence.'
  Invoke-Compose @('--project-directory',$root,'restart','backend') 'backend restart'
  Wait-Until { (Http-Status "$BackendBaseUrl/actuator/health/readiness") -eq 200 } $deadline 'Backend did not recover after restart.'
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
  if((Invoke-WebRequest -Uri "$BackendBaseUrl/api/platform" -UseBasicParsing).Content -match 'local-dev-only-token'){throw 'Secret leaked through public API.'}
  Write-Host 'PASS: automatic M9/M10/M11 alert scheduling and restart recovery verified.'
} catch { Write-Error "Alert scheduling smoke failed: $($_.Exception.Message)"; exit 1 }
