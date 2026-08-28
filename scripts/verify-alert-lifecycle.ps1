[CmdletBinding()]
param(
    [ValidateRange(90, 300)]
    [int] $TimeoutSeconds = 240,

    [string] $BackendBaseUrl = 'http://127.0.0.1:8080',
    [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8083',
    [string] $VictoriaMetricsBaseUrl = 'http://127.0.0.1:8428',
    [string] $FrontendBaseUrl = 'http://127.0.0.1:3000'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PolicyId = 'burn-smoke-alert'
$BaselinePolicyId = 'demo-downstream-burn-alert'
$DisabledPolicyId = 'disabled-burn-alert'
$NoTrafficPolicyId = 'no-traffic-burn-alert'
$SloId = 'burn-smoke-error-rate'
$BaselineSloId = 'demo-downstream-availability'
$Identity = [ordered]@{ name = 'geordi-burn-smoke-service'; namespace = 'geordi-burn-smoke'; environment = 'development' }
$BaselineIdentity = [ordered]@{ name = 'geordi-demo-downstream-service'; namespace = 'geordi-demo'; environment = 'development' }
$ProviderSyntaxPattern = 'promql|metricsql|victoriametrics|http\.server\.request|__name__|increase\s*\(|rate\s*\('
$DeliverySyntaxPattern = 'smtp|slack|teams|pagerduty|opsgenie|alertmanager|webhook|notification|incident|page|acknowledg|silenc|escalat'

function Invoke-TextRequest {
    param([Parameter(Mandatory)][string] $Uri, [int] $RequestTimeoutSeconds = 15, [string] $Method = 'GET')
    $response = Invoke-WebRequest -Uri $Uri -Method $Method -TimeoutSec $RequestTimeoutSeconds -UseBasicParsing
    if ($response.StatusCode -ne 200) { throw "$Method $Uri returned HTTP $($response.StatusCode)." }
    return [string] $response.Content
}

function Invoke-JsonRequest {
    param([Parameter(Mandatory)][string] $Uri, [string] $Method = 'GET')
    return Invoke-TextRequest -Uri $Uri -Method $Method | ConvertFrom-Json
}

function Wait-ForHttp200 {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Uri, [Parameter(Mandatory)][datetime] $Deadline)
    while ((Get-Date) -lt $Deadline) {
        try { [void](Invoke-TextRequest $Uri); return } catch { Start-Sleep -Seconds 1 }
    }
    throw "Timed out waiting for $Name at $Uri."
}

function Get-States { (Invoke-JsonRequest "$BackendBaseUrl/api/alert-states").alertStates }
function Get-State { param([string] $Id) @((Get-States) | Where-Object { $_.policy.id -eq $Id }) }
function Get-Evaluation { param([string] $Id) Invoke-JsonRequest "$BackendBaseUrl/api/alert-policies/$([uri]::EscapeDataString($Id))/evaluation" }
function Apply-Lifecycle { param([string] $Id) Invoke-JsonRequest "$BackendBaseUrl/api/alert-policies/$([uri]::EscapeDataString($Id))/lifecycle-evaluations" 'POST' }

function Assert-Identity {
    param([Parameter(Mandatory)] $Actual, [Parameter(Mandatory)] $Expected, [Parameter(Mandatory)][string] $Context)
    if ($Actual.name -ne $Expected.name -or $Actual.namespace -ne $Expected.namespace -or $Actual.environment -ne $Expected.environment) {
        throw "$Context returned '$($Actual.namespace)/$($Actual.name)/$($Actual.environment)', expected '$($Expected.namespace)/$($Expected.name)/$($Expected.environment)'."
    }
}

function Assert-NoForbiddenSyntax {
    param([Parameter(Mandatory)] $Payload, [Parameter(Mandatory)][string] $Context)
    $json = $Payload | ConvertTo-Json -Depth 30 -Compress
    if ($json -match $ProviderSyntaxPattern) { throw "$Context leaked provider query syntax." }
    if ($json -match $DeliverySyntaxPattern) { throw "$Context leaked notification or incident semantics." }
}

function ConvertTo-ProviderLabelValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n')
}

function ConvertTo-ExclusiveProviderTime {
    param([Parameter(Mandatory)][string] $Timestamp)
    $parsed = [DateTimeOffset]$Timestamp; $fractionNanoseconds = 0
    if ($Timestamp -match '\.(\d{1,9})(?:Z|[+-]\d{2}:\d{2})$') { $fractionNanoseconds = [int]$Matches[1].PadRight(9, '0') }
    $exclusive = [decimal]$parsed.ToUnixTimeSeconds() + ([decimal]$fractionNanoseconds / [decimal]1000000000) - [decimal]0.000000001
    $exclusive.ToString('0.000000000', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-VictoriaScalar {
    param([Parameter(Mandatory)][string] $Expression, [Parameter(Mandatory)][string] $EvaluationTime)
    $payload = Invoke-JsonRequest "$VictoriaMetricsBaseUrl/api/v1/query?query=$([uri]::EscapeDataString($Expression))&time=$([uri]::EscapeDataString($EvaluationTime))"
    if ($payload.status -ne 'success') { throw 'VictoriaMetrics did not report success for independent lifecycle evidence.' }
    $results = @($payload.data.result)
    if ($results.Count -eq 0) { return @{ present = $false; value = $null } }
    if ($results.Count -ne 1) { throw "Independent lifecycle query returned $($results.Count) series, expected one." }
    $value = [double]$results[0].value[1]
    if (-not [double]::IsFinite($value)) { throw 'Independent lifecycle query returned a non-finite value.' }
    @{ present = $true; value = $value }
}

function Assert-IndependentEvaluation {
    param(
        [Parameter(Mandatory)] $Evaluation,
        [Parameter(Mandatory)][string] $ExpectedStatus,
        [Parameter(Mandatory)][string] $ExpectedPolicyId,
        [Parameter(Mandatory)][string] $ExpectedSloId,
        [Parameter(Mandatory)] $ExpectedIdentity
    )
    if ($Evaluation.policyId -ne $ExpectedPolicyId -or $Evaluation.sloId -ne $ExpectedSloId -or $Evaluation.condition.type -ne 'BURN_RATE_ABOVE' -or [double]$Evaluation.condition.threshold -ne 1.0) { throw 'Lifecycle evaluation did not preserve policy and condition identity.' }
    if ($null -eq $Evaluation.evidence -or $null -ne $Evaluation.reason) { throw 'Available lifecycle evaluation omitted canonical evidence.' }
    Assert-Identity $Evaluation.evidence.service $ExpectedIdentity 'Lifecycle evaluation'
    $from = ([DateTimeOffset]$Evaluation.evidence.range.from).ToUniversalTime(); $to = ([DateTimeOffset]$Evaluation.evidence.range.to).ToUniversalTime()
    if ($Evaluation.evidence.evaluatedAt -ne $Evaluation.evidence.range.to -or ($to - $from) -ne [TimeSpan]::FromMinutes(5)) { throw 'Lifecycle evaluation did not preserve its exact canonical [from,to) range.' }
    $labels = '"geordi.telemetry.origin"="monitored","service.name"="' + (ConvertTo-ProviderLabelValue $ExpectedIdentity.name) + '","service.namespace"="' + (ConvertTo-ProviderLabelValue $ExpectedIdentity.namespace) + '","deployment.environment.name"="' + (ConvertTo-ProviderLabelValue $ExpectedIdentity.environment) + '"'
    $seconds = [long](($to - $from).TotalSeconds); $at = ConvertTo-ExclusiveProviderTime $Evaluation.evidence.range.to
    $all = Get-VictoriaScalar ('sum(increase({__name__="http.server.request.duration_count",' + $labels + "}[$seconds" + 's]))') $at
    $bad = Get-VictoriaScalar ('sum(increase({__name__="http.server.request.duration_count",' + $labels + ',"http.response.status_code"=~"5.."}' + "[$seconds" + 's]))') $at
    if (-not $all.present -or $all.value -le 0) { throw 'Independent lifecycle request count was absent or non-positive.' }
    $errorCount = if ($bad.present) { [double]$bad.value } else { 0.0 }
    $burn = ($errorCount / [double]$all.value) / 0.10
    $oracle = if ($burn -ge 1.0) { 'CONDITION_MET' } else { 'CONDITION_NOT_MET' }
    if ($oracle -ne $ExpectedStatus -or $Evaluation.status -ne $oracle -or [Math]::Abs([double]$Evaluation.evidence.observedBurnRate - $burn) -gt 0.000001) { throw "Independent lifecycle oracle expected $ExpectedStatus (burn $burn), got $($Evaluation.status)." }
    Assert-NoForbiddenSyntax $Evaluation 'Lifecycle evaluation'
}

function Assert-Transition {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)][string] $Type, [Parameter(Mandatory)][string] $Previous, [Parameter(Mandatory)][string] $Current)
    $transition = $Result.transition
    if ($Result.outcome -ne 'APPLIED' -or $null -eq $transition -or $transition.type -ne $Type -or $transition.previousState -ne $Previous -or $transition.currentState -ne $Current -or $transition.policyId -ne $PolicyId) { throw "Expected exactly one $Type transition from $Previous to $Current." }
    if ($transition.occurredAt -ne $Result.triggeringEvaluation.evidence.evaluatedAt -or $transition.evaluation.evidence.range.from -ne $Result.triggeringEvaluation.evidence.range.from -or $transition.evaluation.evidence.range.to -ne $Result.triggeringEvaluation.evidence.range.to) { throw 'Transition did not retain its exact canonical evaluation time and range.' }
    Assert-Identity $transition.evaluation.evidence.service $Identity 'Lifecycle transition'
}

function Assert-NoTransition {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)][string] $ExpectedState, [Parameter(Mandatory)][string] $Context)
    if ($null -ne $Result.transition -or $Result.current.state -ne $ExpectedState -or $Result.outcome -notin @('APPLIED', 'DUPLICATE_IGNORED', 'STALE_IGNORED')) { throw "$Context fabricated a lifecycle transition." }
}

function Wait-ForCanonicalStatus {
    param(
        [Parameter(Mandatory)][string] $Policy,
        [Parameter(Mandatory)][string] $ExpectedStatus,
        [Parameter(Mandatory)][string] $ExpectedSloId,
        [Parameter(Mandatory)] $ExpectedIdentity,
        [Parameter(Mandatory)][datetime] $Deadline
    )
    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try { $evaluation = Get-Evaluation $Policy; Assert-IndependentEvaluation $evaluation $ExpectedStatus $Policy $ExpectedSloId $ExpectedIdentity; return $evaluation } catch { $lastFailure = $_.Exception.Message; Start-Sleep -Seconds 2 }
    }
    throw "Timed out waiting for independently verified $ExpectedStatus lifecycle evidence: $lastFailure"
}

function Send-Requests {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][int] $Count, [switch] $ExpectError)
    $expectedStatus = if ($ExpectError) { 500 } else { 200 }
    $baseUrl = $BurnDemoBaseUrl
    $failures = @(1..$Count | ForEach-Object -Parallel {
        try {
            $response = Invoke-WebRequest -Uri "$using:baseUrl$using:Path" -TimeoutSec 10 -UseBasicParsing -SkipHttpErrorCheck
            if ($response.StatusCode -ne $using:expectedStatus) {
                "Controlled workload request '$using:Path' returned HTTP $($response.StatusCode)."
            }
        } catch {
            "Controlled workload request '$using:Path' failed: $($_.Exception.Message)"
        }
    } -ThrottleLimit 16)
    if ($failures.Count -gt 0) { throw $failures[0] }
}

function Assert-LifecycleTelemetry {
    param([Parameter(Mandatory)][datetime] $Deadline)
    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $from = [uri]::EscapeDataString((Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')); $to = [uri]::EscapeDataString((Get-Date).ToUniversalTime().ToString('o'))
            $series = @((Invoke-JsonRequest "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$([uri]::EscapeDataString('{__name__=~"geordi.alert.lifecycle.(results|transitions)"}') )&start=$from&end=$to").data)
            if ($series.Count -eq 0) { throw 'Lifecycle self-observability is not persisted yet.' }
            foreach ($item in $series) {
                $metric = [string]$item.__name__
                $allowed = if ($metric -eq 'geordi.alert.lifecycle.results') {
                    @('geordi.alert.lifecycle.outcome', 'geordi.alert.lifecycle.state', 'geordi.alert.lifecycle.evaluation.status', 'geordi.alert.lifecycle.evaluation.reason')
                } elseif ($metric -eq 'geordi.alert.lifecycle.transitions') {
                    @('geordi.alert.lifecycle.transition.type')
                } else { throw "Unexpected lifecycle telemetry metric '$metric'." }
                $custom = @($item.PSObject.Properties.Name | Where-Object { $_.StartsWith('geordi.alert.lifecycle.') })
                if (@($custom | Where-Object { $_ -notin $allowed }).Count -gt 0) { throw "Lifecycle telemetry exposed unsupported custom labels on '$metric'." }
                if ($item.'geordi.telemetry.origin' -ne 'platform' -or $item.'service.name' -ne 'geordi-backend' -or $item.'service.namespace' -ne 'geordi') { throw 'Lifecycle telemetry did not retain the platform resource identity.' }
                foreach ($property in $item.PSObject.Properties) {
                    $value = [string]$property.Value
                    if ($value -match $ProviderSyntaxPattern -or $value -match $DeliverySyntaxPattern) { throw 'Lifecycle telemetry leaked provider or delivery syntax.' }
                    if ($property.Name.StartsWith('geordi.alert.lifecycle.') -and $value -in @($PolicyId, $SloId, $Identity.name, $Identity.namespace, $Identity.environment)) { throw 'Lifecycle telemetry leaked high-cardinality context in lifecycle-owned labels.' }
                }
            }
            return
        } catch { $lastFailure = $_.Exception.Message; Start-Sleep -Seconds 2 }
    }
    throw "Timed out waiting for bounded lifecycle self-observability: $lastFailure"
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 'backend readiness' "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 'VictoriaMetrics' "$VictoriaMetricsBaseUrl/health" $deadline
    Wait-ForHttp200 'isolated burn demo readiness' "$BurnDemoBaseUrl/actuator/health/readiness" $deadline

    $initial = Get-State $PolicyId
    if ($initial.Count -ne 1 -or $initial[0].initialized -or $initial[0].state -ne 'INACTIVE' -or $null -ne $initial[0].latestEvaluation) { throw 'Fresh Compose lifecycle volume did not expose an uninitialized INACTIVE state.' }

    # M9 generates success-only downstream traffic. Use its separate policy to prove
    # first/repeated INACTIVE semantics without contaminating the burn policy's window.
    [void](Wait-ForCanonicalStatus $BaselinePolicyId 'CONDITION_NOT_MET' $BaselineSloId $BaselineIdentity $deadline)
    $initialNotMet = Apply-Lifecycle $BaselinePolicyId
    Assert-IndependentEvaluation $initialNotMet.triggeringEvaluation 'CONDITION_NOT_MET' $BaselinePolicyId $BaselineSloId $BaselineIdentity
    Assert-NoTransition $initialNotMet 'INACTIVE' 'First CONDITION_NOT_MET'
    $repeatedBaselineNotMet = Apply-Lifecycle $BaselinePolicyId
    Assert-NoTransition $repeatedBaselineNotMet 'INACTIVE' 'Repeated CONDITION_NOT_MET'

    # M9 deliberately leaves isolated burn evidence met. Consume it before adding any
    # recovery traffic, preserving a fresh lifecycle record for this policy.
    [void](Wait-ForCanonicalStatus $PolicyId 'CONDITION_MET' $SloId $Identity $deadline)
    $started = Apply-Lifecycle $PolicyId
    Assert-IndependentEvaluation $started.triggeringEvaluation 'CONDITION_MET' $PolicyId $SloId $Identity
    Assert-Transition $started 'ALERT_STARTED' 'INACTIVE' 'FIRING'
    $startedAt = $started.current.startedAt
    if ($startedAt -ne $started.triggeringEvaluation.evidence.evaluatedAt -or $null -eq $started.current.activeEvidence) { throw 'FIRING state did not retain canonical start time and active evidence.' }
    $repeatedMet = Apply-Lifecycle $PolicyId
    Assert-NoTransition $repeatedMet 'FIRING' 'Repeated CONDITION_MET'
    if ($repeatedMet.current.startedAt -ne $startedAt) { throw 'Repeated CONDITION_MET changed the active episode start time.' }

    $root = Split-Path -Parent $PSScriptRoot; $compose = Join-Path $root 'compose.yaml'
    & docker compose --project-directory $root --file $compose restart backend
    if ($LASTEXITCODE -ne 0) { throw 'Could not restart backend for lifecycle durability verification.' }
    Wait-ForHttp200 'backend after lifecycle restart' "$BackendBaseUrl/actuator/health/readiness" $deadline
    $afterRestart = Get-State $PolicyId
    if ($afterRestart.Count -ne 1 -or $afterRestart[0].state -ne 'FIRING' -or $afterRestart[0].startedAt -ne $startedAt) { throw 'Durable lifecycle state did not survive backend restart.' }
    $afterRestartMet = Apply-Lifecycle $PolicyId
    Assert-NoTransition $afterRestartMet 'FIRING' 'CONDITION_MET after backend restart'

    $stopped = $false
    try {
        & docker compose --project-directory $root --file $compose stop victoriametrics
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop VictoriaMetrics for lifecycle unavailable verification.' }
        $stopped = $true
        $unavailable = Apply-Lifecycle $PolicyId
        if ($unavailable.triggeringEvaluation.status -ne 'UNAVAILABLE' -or $unavailable.triggeringEvaluation.reason -ne 'METRICS_UNAVAILABLE') { throw 'Provider outage did not produce canonical UNAVAILABLE evidence.' }
        Assert-NoTransition $unavailable 'FIRING' 'FIRING + UNAVAILABLE'
        if ($unavailable.current.startedAt -ne $startedAt) { throw 'FIRING + UNAVAILABLE changed lifecycle start time.' }
    } finally {
        if ($stopped) {
            & docker compose --project-directory $root --file $compose start victoriametrics
            if ($LASTEXITCODE -ne 0) { throw 'Could not restart VictoriaMetrics after lifecycle unavailable verification.' }
            Wait-ForHttp200 'VictoriaMetrics after lifecycle unavailable verification' "$VictoriaMetricsBaseUrl/health" $deadline
        }
    }

    # The preceding M8/M9 smokes intentionally leave a small bounded error sample.
    # A large local success batch makes recovery evidence independent of that history.
    Send-Requests '/demo/success' 800
    [void](Wait-ForCanonicalStatus $PolicyId 'CONDITION_NOT_MET' $SloId $Identity $deadline)
    $resolved = Apply-Lifecycle $PolicyId
    Assert-IndependentEvaluation $resolved.triggeringEvaluation 'CONDITION_NOT_MET' $PolicyId $SloId $Identity
    Assert-Transition $resolved 'ALERT_RESOLVED' 'FIRING' 'INACTIVE'
    if ($resolved.current.resolvedAt -ne $resolved.triggeringEvaluation.evidence.evaluatedAt -or $resolved.current.activeEvidence -ne $null) { throw 'Resolution did not retain canonical time or clear active evidence.' }
    $repeatedNotMet = Apply-Lifecycle $PolicyId
    Assert-NoTransition $repeatedNotMet 'INACTIVE' 'Repeated CONDITION_NOT_MET'

    $inactiveUnavailable = Apply-Lifecycle $NoTrafficPolicyId
    if ($inactiveUnavailable.triggeringEvaluation.status -ne 'UNAVAILABLE' -or $inactiveUnavailable.triggeringEvaluation.reason -notin @('NO_TRAFFIC', 'MISSING_REQUEST_COUNT')) { throw 'No-traffic policy did not return canonical unavailable evidence.' }
    Assert-NoTransition $inactiveUnavailable 'INACTIVE' 'INACTIVE + UNAVAILABLE'
    $disabled = Apply-Lifecycle $DisabledPolicyId
    if ($disabled.triggeringEvaluation.status -ne 'UNAVAILABLE' -or $disabled.triggeringEvaluation.reason -ne 'DISABLED') { throw 'Disabled policy did not remain explicitly unavailable.' }
    Assert-NoTransition $disabled 'INACTIVE' 'Disabled policy'

    $evidence = $resolved.transition.evaluation.evidence
    $query = "serviceName=$([uri]::EscapeDataString($evidence.service.name))&serviceNamespace=$([uri]::EscapeDataString($evidence.service.namespace))&environment=$([uri]::EscapeDataString($evidence.service.environment))&from=$([uri]::EscapeDataString($evidence.range.from))&to=$([uri]::EscapeDataString($evidence.range.to))"
    if ((Invoke-TextRequest "$FrontendBaseUrl/investigate?$query") -notmatch '<title>Geordi Platform</title>') { throw 'Frontend did not accept exact lifecycle Investigation context.' }
    Assert-LifecycleTelemetry $deadline
    Write-Host 'PASS: durable alert lifecycle transitions, exact canonical evidence, restart survival, firing-state unavailable freeze, disabled unavailability, independent provider oracle, Investigation context, and bounded telemetry verified.'
    exit 0
} catch { Write-Error "Alert Lifecycle smoke verification failed: $($_.Exception.Message)"; exit 1 }
