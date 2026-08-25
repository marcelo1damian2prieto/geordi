[CmdletBinding()]
param(
    [ValidateRange(30, 180)]
    [int] $TimeoutSeconds = 150,

    [ValidateRange(2, 50)]
    [int] $RequestCount = 4,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $BurnDemoBaseUrl = "http://127.0.0.1:8083",
    [string] $DownstreamBaseUrl = "http://127.0.0.1:8082",
    [string] $VictoriaMetricsBaseUrl = "http://127.0.0.1:8428",
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ZeroPolicyId = "demo-downstream-burn-alert"
$MetPolicyId = "burn-smoke-alert"
$NoTrafficPolicyId = "no-traffic-burn-alert"
$ZeroBudgetPolicyId = "zero-budget-burn-alert"
$DisabledPolicyId = "disabled-burn-alert"
$ZeroSloId = "demo-downstream-availability"
$MetSloId = "burn-smoke-error-rate"
$NoTrafficSloId = "no-traffic-availability"
$ZeroBudgetSloId = "demo-error-rate"
$ZeroIdentity = [ordered]@{ name = "geordi-demo-downstream-service"; namespace = "geordi-demo"; environment = "development" }
$MetIdentity = [ordered]@{ name = "geordi-burn-smoke-service"; namespace = "geordi-burn-smoke"; environment = "development" }
$ProviderSyntaxPattern = 'promql|metricsql|victoriametrics|http\.server\.request|__name__|increase\s*\(|rate\s*\('
$DeliverySyntaxPattern = 'smtp|slack|teams|pagerduty|opsgenie|alertmanager|webhook|notification|incident|page|firing|resolved|acknowledg|silenc|escalat'

function Invoke-TextRequest {
    param([Parameter(Mandatory)][string] $Uri, [int] $RequestTimeoutSeconds = 8)
    $response = Invoke-WebRequest -Uri $Uri -TimeoutSec $RequestTimeoutSeconds -UseBasicParsing
    if ($response.StatusCode -ne 200) { throw "GET $Uri returned HTTP $($response.StatusCode)." }
    return [string]$response.Content
}

function Wait-ForHttp200 {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Uri, [Parameter(Mandatory)][datetime] $Deadline)
    while ((Get-Date) -lt $Deadline) {
        try { [void](Invoke-TextRequest $Uri); return } catch { Start-Sleep -Seconds 1 }
    }
    throw "Timed out waiting for $Name at $Uri."
}

function Get-Policies { (Invoke-TextRequest "$BackendBaseUrl/api/alert-policies" -RequestTimeoutSeconds 15 | ConvertFrom-Json).alertPolicies }
function Get-Evaluation { param([Parameter(Mandatory)][string] $PolicyId) Invoke-TextRequest "$BackendBaseUrl/api/alert-policies/$([uri]::EscapeDataString($PolicyId))/evaluation" -RequestTimeoutSeconds 15 | ConvertFrom-Json }
function Get-SloDefinition { param([Parameter(Mandatory)][string] $SloId) Invoke-TextRequest "$BackendBaseUrl/api/slos/$([uri]::EscapeDataString($SloId))" -RequestTimeoutSeconds 15 | ConvertFrom-Json }

function Get-AllowedBadRatio {
    param([Parameter(Mandatory)] $Definition)
    $target = [double]$Definition.target
    if (-not [double]::IsFinite($target) -or $target -lt 0 -or $target -gt 1) { throw "SLO '$($Definition.id)' returned an invalid target for independent alert evidence." }
    $allowed = switch ([string]$Definition.sliType) {
        'AVAILABILITY' { 1.0 - $target; break }
        'ERROR_RATE' { $target; break }
        default { throw "SLO '$($Definition.id)' returned unsupported SLI type '$($Definition.sliType)' for independent alert evidence." }
    }
    if ($allowed -le 0 -or -not [double]::IsFinite($allowed)) { throw "SLO '$($Definition.id)' does not provide a positive finite allowed bad ratio for an available alert assertion." }
    return $allowed
}

function Assert-Identity {
    param([Parameter(Mandatory)] $Actual, [Parameter(Mandatory)] $Expected, [Parameter(Mandatory)][string] $Context)
    if ($Actual.name -ne $Expected.name -or $Actual.namespace -ne $Expected.namespace -or $Actual.environment -ne $Expected.environment) {
        throw "$Context returned '$($Actual.namespace)/$($Actual.name)/$($Actual.environment)', expected '$($Expected.namespace)/$($Expected.name)/$($Expected.environment)'."
    }
}

function Assert-NoForbiddenSyntax {
    param([Parameter(Mandatory)] $Payload, [Parameter(Mandatory)][string] $Context)
    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    if ($json -match $ProviderSyntaxPattern) { throw "$Context leaked provider syntax or metric names." }
    if ($json -match $DeliverySyntaxPattern) { throw "$Context leaked notification, incident, or lifecycle semantics." }
}

function ConvertTo-ProviderLabelValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n')
}

function ConvertTo-ExclusiveProviderTime {
    param([Parameter(Mandatory)][string] $Timestamp)
    $parsed = [DateTimeOffset]$Timestamp
    $fractionNanoseconds = 0
    if ($Timestamp -match '\.(\d{1,9})(?:Z|[+-]\d{2}:\d{2})$') { $fractionNanoseconds = [int]$Matches[1].PadRight(9, '0') }
    $exclusive = [decimal]$parsed.ToUnixTimeSeconds() + ([decimal]$fractionNanoseconds / [decimal]1000000000) - [decimal]0.000000001
    $exclusive.ToString('0.000000000', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-VictoriaScalar {
    param([Parameter(Mandatory)][string] $Expression, [Parameter(Mandatory)][string] $EvaluationTime)
    $payload = Invoke-TextRequest "$VictoriaMetricsBaseUrl/api/v1/query?query=$([uri]::EscapeDataString($Expression))&time=$([uri]::EscapeDataString($EvaluationTime))" | ConvertFrom-Json
    if ($payload.status -ne 'success') { throw 'VictoriaMetrics did not report success for independent alert evidence.' }
    $results = @($payload.data.result)
    if ($results.Count -eq 0) { return @{ present = $false; value = $null } }
    if ($results.Count -ne 1) { throw "Independent alert query returned $($results.Count) series, expected exactly one." }
    $value = [double]$results[0].value[1]
    if (-not [double]::IsFinite($value)) { throw 'Independent alert query returned a non-finite value.' }
    @{ present = $true; value = $value }
}

function Get-IndependentBurn {
    param([Parameter(Mandatory)] $Evidence, [Parameter(Mandatory)][double] $AllowedBadRatio)
    $from = ([DateTimeOffset]$Evidence.range.from).ToUniversalTime(); $to = ([DateTimeOffset]$Evidence.range.to).ToUniversalTime()
    if ($Evidence.evaluatedAt -ne $Evidence.range.to -or ($to - $from) -le [TimeSpan]::Zero) { throw 'Alert evidence did not preserve one exact positive range ending at evaluatedAt.' }
    $service = ConvertTo-ProviderLabelValue ([string]$Evidence.service.name)
    $namespace = ConvertTo-ProviderLabelValue ([string]$Evidence.service.namespace)
    $environment = ConvertTo-ProviderLabelValue ([string]$Evidence.service.environment)
    $selectors = '"geordi.telemetry.origin"="monitored","service.name"="' + $service + '","service.namespace"="' + $namespace + '","deployment.environment.name"="' + $environment + '"'
    $seconds = [long](($to - $from).TotalSeconds)
    $all = 'sum(increase({__name__="http.server.request.duration_count",' + $selectors + "}[$seconds" + 's]))'
    $errors = 'sum(increase({__name__="http.server.request.duration_count",' + $selectors + ',"http.response.status_code"=~"5.."}' + "[$seconds" + 's]))'
    $time = ConvertTo-ExclusiveProviderTime ([string]$Evidence.range.to)
    $requests = Get-VictoriaScalar $all $time; $bad = Get-VictoriaScalar $errors $time
    if (-not $requests.present -or $requests.value -le 0) { throw 'Independent alert request count was absent or non-positive.' }
    $badCount = if ($bad.present) { [double]$bad.value } else { 0.0 }
    @{ observed = $badCount / [double]$requests.value; burn = ($badCount / [double]$requests.value) / $AllowedBadRatio }
}

function Assert-Evaluation {
    param([Parameter(Mandatory)] $Policy, [Parameter(Mandatory)] $ExpectedIdentity, [Parameter(Mandatory)][string] $ExpectedSloId, [Parameter(Mandatory)][double] $AllowedBadRatio, [Parameter(Mandatory)][string] $ExpectedStatus)
    $evaluation = Get-Evaluation $Policy.id
    if ($evaluation.policyId -ne $Policy.id -or $evaluation.policyName -ne $Policy.name -or $evaluation.sloId -ne $ExpectedSloId) { throw "Alert evaluation did not preserve catalog policy identity for '$($Policy.id)'." }
    if ($evaluation.condition.type -ne 'BURN_RATE_ABOVE' -or [double]$evaluation.condition.threshold -ne [double]$Policy.condition.threshold) { throw "Alert evaluation did not preserve the configured canonical condition for '$($Policy.id)'." }
    if ($evaluation.reason -ne $null -or $null -eq $evaluation.evidence) { throw "Available alert evaluation '$($Policy.id)' unexpectedly omitted evidence or reported a reason." }
    Assert-Identity $evaluation.evidence.service $ExpectedIdentity "Alert evaluation '$($Policy.id)'"
    $independent = Get-IndependentBurn $evaluation.evidence $AllowedBadRatio
    $tolerance = 0.000001
    if ([Math]::Abs([double]$evaluation.evidence.observedBurnRate - $independent.burn) -gt $tolerance) { throw "Alert evaluation '$($Policy.id)' does not match independently recomputed exact-window burn evidence." }
    $oracle = if ($independent.burn -ge [double]$Policy.condition.threshold) { 'CONDITION_MET' } else { 'CONDITION_NOT_MET' }
    if ($oracle -ne $ExpectedStatus -or $evaluation.status -ne $oracle) { throw "Alert comparator mismatch for '$($Policy.id)': independent burn $($independent.burn), threshold $($Policy.condition.threshold), expected $ExpectedStatus, got $($evaluation.status)." }
    Assert-NoForbiddenSyntax $evaluation "Alert evaluation '$($Policy.id)'"
    return $evaluation
}

function Wait-ForEvaluation {
    param([Parameter(Mandatory)] $Policy, [Parameter(Mandatory)] $Identity, [Parameter(Mandatory)][string] $SloId, [Parameter(Mandatory)][double] $AllowedBadRatio, [Parameter(Mandatory)][string] $Status, [Parameter(Mandatory)][datetime] $Deadline)
    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try { return Assert-Evaluation $Policy $Identity $SloId $AllowedBadRatio $Status } catch { $lastFailure = $_.Exception.Message; Start-Sleep -Seconds 2 }
    }
    throw "Timed out waiting for independently verified $Status alert '$($Policy.id)': $lastFailure"
}

function Assert-UnavailableEvaluation {
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)][string] $ExpectedSloId,
        [Parameter(Mandatory)][string[]] $ExpectedReasons,
        $ExpectedIdentity,
        [switch] $Disabled
    )
    $evaluation = Get-Evaluation $Policy.id
    if ($evaluation.policyId -ne $Policy.id -or $evaluation.policyName -ne $Policy.name -or $evaluation.sloId -ne $ExpectedSloId) { throw "Unavailable alert evaluation did not preserve catalog policy identity for '$($Policy.id)'." }
    if ($evaluation.status -ne 'UNAVAILABLE' -or $evaluation.reason -notin $ExpectedReasons) { throw "Alert '$($Policy.id)' was '$($evaluation.status)/$($evaluation.reason)', expected UNAVAILABLE with one of '$($ExpectedReasons -join ', ')'." }
    if ($Disabled) {
        if ($null -ne $evaluation.evidence) { throw "Disabled alert '$($Policy.id)' fabricated evidence instead of returning null evidence." }
    } else {
        if ($null -eq $evaluation.evidence -or $null -ne $evaluation.evidence.observedBurnRate) { throw "Unavailable alert '$($Policy.id)' did not preserve context with a null observed burn rate." }
        Assert-Identity $evaluation.evidence.service $ExpectedIdentity "Unavailable alert '$($Policy.id)'"
        $from = ([DateTimeOffset]$evaluation.evidence.range.from).ToUniversalTime(); $to = ([DateTimeOffset]$evaluation.evidence.range.to).ToUniversalTime()
        if ($evaluation.evidence.evaluatedAt -ne $evaluation.evidence.range.to -or ($to - $from) -le [TimeSpan]::Zero) { throw "Unavailable alert '$($Policy.id)' did not preserve its exact canonical evidence range." }
    }
    Assert-NoForbiddenSyntax $evaluation "Unavailable alert '$($Policy.id)'"
}

function Assert-InvestigationContext {
    param([Parameter(Mandatory)] $Evaluation)
    $evidence = $Evaluation.evidence
    $query = "serviceName=$([uri]::EscapeDataString($evidence.service.name))&serviceNamespace=$([uri]::EscapeDataString($evidence.service.namespace))&environment=$([uri]::EscapeDataString($evidence.service.environment))&from=$([uri]::EscapeDataString($evidence.range.from))&to=$([uri]::EscapeDataString($evidence.range.to))"
    if ((Invoke-TextRequest "$FrontendBaseUrl/alert-evaluations") -notmatch '<title>Geordi Platform</title>') { throw 'Frontend did not serve the Alert Evaluation route.' }
    if ((Invoke-TextRequest "$FrontendBaseUrl/investigate?$query") -notmatch '<title>Geordi Platform</title>') { throw 'Frontend did not accept exact Alert Evaluation Investigation context.' }
    $metrics = Invoke-TextRequest "$FrontendBaseUrl/api/metrics/series?$query&metric=HTTP_REQUEST_COUNT" | ConvertFrom-Json
    Assert-Identity $metrics.service $evidence.service 'Alert Investigation proxy'
    if ($metrics.range.from -ne $evidence.range.from -or $metrics.range.to -ne $evidence.range.to) { throw 'Alert Investigation proxy did not preserve the exact evidence range.' }
}

function Assert-AlertTelemetry {
    param([Parameter(Mandatory)][datetime] $Deadline)
    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $from = [uri]::EscapeDataString((Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')); $to = [uri]::EscapeDataString((Get-Date).ToUniversalTime().ToString('o'))
            $series = @((Invoke-TextRequest "$VictoriaMetricsBaseUrl/api/v1/query_range?query=$([uri]::EscapeDataString('{__name__="geordi.alert.results"}') )&start=$from&end=$to&step=15" | ConvertFrom-Json).data.result)
            if ($series.Count -eq 0) { throw 'Alert self-observability has no result series.' }
            foreach ($item in $series) {
                $custom = @($item.metric.PSObject.Properties.Name | Where-Object { $_.StartsWith('geordi.alert.') })
                if (@($custom | Where-Object { $_ -notin @('geordi.alert.condition.type', 'geordi.alert.status', 'geordi.alert.reason') }).Count -gt 0) { throw 'Alert self-observability exposed an unsupported custom label.' }
                if ($null -eq $item.metric.'geordi.alert.condition.type' -or $null -eq $item.metric.'geordi.alert.status') { throw 'Alert self-observability omitted required bounded labels.' }
                foreach ($property in $item.metric.PSObject.Properties) { if ([string]$property.Value -match $ProviderSyntaxPattern -or [string]$property.Value -match $DeliverySyntaxPattern -or [string]$property.Value -in @($ZeroPolicyId, $MetPolicyId, $ZeroSloId, $MetSloId, $ZeroIdentity.name, $MetIdentity.name)) { throw 'Alert self-observability leaked forbidden or high-cardinality context.' } }
            }
            return
        } catch { $lastFailure = $_.Exception.Message; Start-Sleep -Seconds 2 }
    }
    throw "Timed out waiting for bounded alert self-observability: $lastFailure"
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 'backend readiness' "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 'VictoriaMetrics' "$VictoriaMetricsBaseUrl/health" $deadline
    Wait-ForHttp200 'isolated burn demo readiness' "$BurnDemoBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 'downstream demo readiness' "$DownstreamBaseUrl/actuator/health/readiness" $deadline
    $policies = @(Get-Policies)
    $zeroPolicy = @($policies | Where-Object { $_.id -eq $ZeroPolicyId -and $_.enabled -and $_.sloId -eq $ZeroSloId })
    $metPolicy = @($policies | Where-Object { $_.id -eq $MetPolicyId -and $_.enabled -and $_.sloId -eq $MetSloId })
    $noTrafficPolicy = @($policies | Where-Object { $_.id -eq $NoTrafficPolicyId -and $_.enabled -and $_.sloId -eq $NoTrafficSloId })
    $zeroBudgetPolicy = @($policies | Where-Object { $_.id -eq $ZeroBudgetPolicyId -and $_.enabled -and $_.sloId -eq $ZeroBudgetSloId })
    $disabledPolicy = @($policies | Where-Object { $_.id -eq $DisabledPolicyId -and -not $_.enabled -and $_.sloId -eq $MetSloId })
    if ($zeroPolicy.Count -ne 1 -or $metPolicy.Count -ne 1 -or $noTrafficPolicy.Count -ne 1 -or $zeroBudgetPolicy.Count -ne 1 -or $disabledPolicy.Count -ne 1) { throw 'The required deterministic M9 alert policies were absent, enabled incorrectly, duplicated, or referenced the wrong SLO.' }
    if ($zeroPolicy[0].condition.type -ne 'BURN_RATE_ABOVE' -or [double]$zeroPolicy[0].condition.threshold -le 0 -or $metPolicy[0].condition.type -ne 'BURN_RATE_ABOVE' -or [double]$metPolicy[0].condition.threshold -ne 1.0) { throw 'M9 smoke policy catalog does not provide the required positive zero policy and threshold-one elevated policy.' }
    Assert-NoForbiddenSyntax @{ alertPolicies = $policies } 'Alert policy catalog'
    1..$RequestCount | ForEach-Object { [void](Invoke-TextRequest "$DownstreamBaseUrl/downstream/respond") }
    # Keep this smoke independently reproducible on a fresh stack. Two separated 5xx
    # batches ensure VictoriaMetrics observes a counter increase, even when this script
    # is not preceded by the M8 burn smoke in the authoritative CI chain.
    1..$RequestCount | ForEach-Object { [void](Invoke-TextRequest "$BurnDemoBaseUrl/demo/success") }
    Start-Sleep -Seconds 6
    1..$RequestCount | ForEach-Object {
        $response = Invoke-WebRequest -Uri "$BurnDemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
        if ($response.StatusCode -ne 500) { throw "Controlled alert burn error returned HTTP $($response.StatusCode), expected 500." }
    }
    Start-Sleep -Seconds 6
    1..$RequestCount | ForEach-Object {
        $response = Invoke-WebRequest -Uri "$BurnDemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
        if ($response.StatusCode -ne 500) { throw "Controlled alert burn error returned HTTP $($response.StatusCode), expected 500." }
    }
    Start-Sleep -Seconds 6
    $zeroDefinition = Get-SloDefinition $ZeroSloId
    $metDefinition = Get-SloDefinition $MetSloId
    if ($zeroDefinition.id -ne $ZeroSloId -or $metDefinition.id -ne $MetSloId) { throw 'SLO definition lookup did not preserve the alert policy reference.' }
    $zero = Wait-ForEvaluation $zeroPolicy[0] $ZeroIdentity $ZeroSloId (Get-AllowedBadRatio $zeroDefinition) 'CONDITION_NOT_MET' $deadline
    $met = Wait-ForEvaluation $metPolicy[0] $MetIdentity $MetSloId (Get-AllowedBadRatio $metDefinition) 'CONDITION_MET' $deadline
    Assert-UnavailableEvaluation $noTrafficPolicy[0] $NoTrafficSloId @('NO_TRAFFIC', 'MISSING_REQUEST_COUNT') ([ordered]@{ name = 'geordi-slo-no-traffic'; namespace = 'geordi-slo-smoke'; environment = 'development' })
    Assert-UnavailableEvaluation $zeroBudgetPolicy[0] $ZeroBudgetSloId @('ZERO_ALLOWED_BAD_RATIO') ([ordered]@{ name = 'geordi-demo-service'; namespace = 'geordi-demo'; environment = 'development' })
    Assert-UnavailableEvaluation $disabledPolicy[0] $MetSloId @('DISABLED') -Disabled
    Assert-InvestigationContext $met
    Assert-AlertTelemetry $deadline
    Write-Host 'PASS: Alert policy catalog, self-contained traffic generation, independent exact-window zero/not-met and elevated/met comparator evidence, disabled/no-traffic/zero-budget semantics, identity/range/threshold preservation, provider-neutral API, frontend Investigation context, and bounded self-observability verified. Provider outage/recovery remains authoritatively covered once by the preceding M8 burn smoke.'
    exit 0
} catch { Write-Error "Alert Evaluation smoke verification failed: $($_.Exception.Message)"; exit 1 }
