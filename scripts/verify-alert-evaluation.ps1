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
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000",
    [string] $WebhookReceiverBaseUrl = "http://127.0.0.1:18080"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ZeroPolicyId = "demo-downstream-burn-alert"
$MetPolicyId = "burn-smoke-alert"
$NoTrafficPolicyId = "no-traffic-burn-alert"
$ZeroBudgetPolicyId = "zero-budget-burn-alert"
$DisabledPolicyId = "disabled-burn-alert"
$M18PolicyId = "m18-multiwindow-burn-alert"
$ZeroSloId = "demo-downstream-availability"
$MetSloId = "burn-smoke-error-rate"
$NoTrafficSloId = "no-traffic-availability"
$ZeroBudgetSloId = "demo-error-rate"
$M18SloId = "m18-multiwindow-error-rate"
$ZeroIdentity = [ordered]@{ name = "geordi-demo-downstream-service"; namespace = "geordi-demo"; environment = "development" }
$MetIdentity = [ordered]@{ name = "geordi-burn-smoke-service"; namespace = "geordi-burn-smoke"; environment = "development" }
$M18Identity = [ordered]@{ name = "geordi-m18-multiwindow-service"; namespace = "geordi-m18-smoke"; environment = "development" }
$M18FutureMargin = [TimeSpan]::FromMinutes(10)
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
    param([Parameter(Mandatory)][string] $Expression, [Parameter(Mandatory)][string] $EvaluationTime, [switch] $NoCache)
    $cacheParameter = if ($NoCache) { '&nocache=1' } else { '' }
    $payload = Invoke-TextRequest "$VictoriaMetricsBaseUrl/api/v1/query?query=$([uri]::EscapeDataString($Expression))&time=$([uri]::EscapeDataString($EvaluationTime))$cacheParameter" | ConvertFrom-Json
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

function Assert-M18VictoriaMetricsPin {
    $compose = Join-Path (Split-Path -Parent $PSScriptRoot) 'compose.yaml'
    $matches = @(Select-String -Path $compose -Pattern '^\s*image:\s*victoriametrics/victoria-metrics:v1\.148\.0\s*$')
    if ($matches.Count -ne 1) { throw 'M18 semantic fixture requires the approved VictoriaMetrics pin victoriametrics/victoria-metrics:v1.148.0.' }
}

function New-M18HistoricalCounterFixture {
    # Feasibility PASS against the Compose-pinned VictoriaMetrics v1.148.0 established
    # that /api/v1/import accepts explicitly timestamped samples, including this bounded
    # future margin. Samples are one minute apart from E-6h-5m through E+10m. Request
    # rate is 100/minute. Error rate is 0 except on intervals (E-55m,E-10m], where it is
    # 20/minute; the 200 series carries the remaining successful requests. Thus at E:
    # PT5M = 0/500 / 0.10 = 0; PT30M = 400/3000 / 0.10 = 1.333...;
    # PT1H = 900/6000 / 0.10 = 1.5; PT6H = 900/36000 / 0.10 = 0.25.
    # The strict margins against 1.2 and 0.2 avoid threshold-equality dependence. The
    # raw query uses VictoriaMetrics instant-query lookback/increase semantics before
    # Geordi is called, and the returned evaluatedAt is checked to remain in E..E+10m.
    $now = [DateTimeOffset]::UtcNow
    $nominal = [DateTimeOffset]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, 0, [TimeSpan]::Zero)
    $start = $nominal.AddHours(-6).AddMinutes(-5)
    $end = $nominal.Add($M18FutureMargin)
    $timestamps = @(); $successValues = @(); $errorValues = @()
    [long] $success = 0; [long] $errorTotal = 0
    $cursor = $start
    while ($cursor -le $end) {
        if ($cursor -gt $start) {
            [long] $errorIncrement = if ($cursor -gt $nominal.AddMinutes(-55) -and $cursor -le $nominal.AddMinutes(-10)) { 20 } else { 0 }
            $success += 100 - $errorIncrement
            $errorTotal += $errorIncrement
        }
        $timestamps += [long]$cursor.ToUnixTimeMilliseconds()
        $successValues += $success
        $errorValues += $errorTotal
        $cursor = $cursor.AddMinutes(1)
    }
    $baseLabels = [ordered]@{
        '__name__' = 'http.server.request.duration_count'
        'geordi.telemetry.origin' = 'monitored'
        'service.name' = $M18Identity.name
        'service.namespace' = $M18Identity.namespace
        'deployment.environment.name' = $M18Identity.environment
    }
    $successLabels = [ordered]@{}; $errorLabels = [ordered]@{}
    foreach ($entry in $baseLabels.GetEnumerator()) { $successLabels[$entry.Key] = $entry.Value; $errorLabels[$entry.Key] = $entry.Value }
    $successLabels['http.response.status_code'] = '200'; $errorLabels['http.response.status_code'] = '500'
    $lines = @(
        ([ordered]@{ metric = $successLabels; values = $successValues; timestamps = $timestamps } | ConvertTo-Json -Depth 6 -Compress),
        ([ordered]@{ metric = $errorLabels; values = $errorValues; timestamps = $timestamps } | ConvertTo-Json -Depth 6 -Compress)
    ) -join "`n"
    $response = Invoke-WebRequest -Uri "$VictoriaMetricsBaseUrl/api/v1/import" -Method Post -ContentType 'application/stream+json' -Body $lines -TimeoutSec 20 -UseBasicParsing
    if ($response.StatusCode -notin @(200, 204)) { throw "M18 historical counter import returned HTTP $($response.StatusCode)." }
    [pscustomobject]@{ nominal = $nominal; start = $start; end = $end }
}

function Get-M18IndependentBurn {
    param([Parameter(Mandatory)] $Identity, [Parameter(Mandatory)][DateTimeOffset] $EvaluationTime, [Parameter(Mandatory)][int] $WindowSeconds)
    $service = ConvertTo-ProviderLabelValue ([string]$Identity.name)
    $namespace = ConvertTo-ProviderLabelValue ([string]$Identity.namespace)
    $environment = ConvertTo-ProviderLabelValue ([string]$Identity.environment)
    $selectors = '"geordi.telemetry.origin"="monitored","service.name"="' + $service + '","service.namespace"="' + $namespace + '","deployment.environment.name"="' + $environment + '"'
    $all = 'sum(increase({__name__="http.server.request.duration_count",' + $selectors + "}[$WindowSeconds" + 's]))'
    $bad = 'sum(increase({__name__="http.server.request.duration_count",' + $selectors + ',"http.response.status_code"=~"5.."}' + "[$WindowSeconds" + 's]))'
    $at = ConvertTo-ExclusiveProviderTime $EvaluationTime.ToString('o')
    $requests = Get-VictoriaScalar $all $at -NoCache; $badSeries = Get-VictoriaScalar $bad $at -NoCache
    if (-not $requests.present -or $requests.value -le 0) { throw "M18 independent $WindowSeconds-second request count was absent or non-positive." }
    $badCount = if ($badSeries.present) { [double]$badSeries.value } else { 0.0 }
    [pscustomobject]@{ requests = [double]$requests.value; errors = $badCount; burn = ($badCount / [double]$requests.value) / 0.10 }
}

function Assert-M18RawFixture {
    param([Parameter(Mandatory)] $Fixture, [Parameter(Mandatory)][datetime] $Deadline)
    $sampleSelector = '{__name__="http.server.request.duration_count","geordi.telemetry.origin"="monitored","service.name"="' + $M18Identity.name + '","service.namespace"="' + $M18Identity.namespace + '","deployment.environment.name"="' + $M18Identity.environment + '"}'
    $sampleCount = $null
    while ((Get-Date) -lt $Deadline) {
        $sampleCount = Get-VictoriaScalar ('sum(count_over_time(' + $sampleSelector + '[390m]))') (ConvertTo-ExclusiveProviderTime $Fixture.nominal.ToString('o')) -NoCache
        if ($sampleCount.present -and $sampleCount.value -ge 700) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($null -eq $sampleCount -or -not $sampleCount.present -or $sampleCount.value -lt 700) { throw 'M18 raw VictoriaMetrics query did not return both complete imported counter series.' }
    $expected = [ordered]@{ PT5M = 0.0; PT30M = 1.3333333333333333; PT1H = 1.5; PT6H = 0.25 }
    $actual = [ordered]@{
        PT5M = Get-M18IndependentBurn $M18Identity $Fixture.nominal 300
        PT30M = Get-M18IndependentBurn $M18Identity $Fixture.nominal 1800
        PT1H = Get-M18IndependentBurn $M18Identity $Fixture.nominal 3600
        PT6H = Get-M18IndependentBurn $M18Identity $Fixture.nominal 21600
    }
    foreach ($window in $expected.Keys) {
        if ([Math]::Abs($actual[$window].burn - $expected[$window]) -gt 0.03) { throw "M18 raw $window burn $($actual[$window].burn) did not match the independently calculated fixture value $($expected[$window])." }
    }
    if ($actual.PT1H.burn -lt 1.35 -or $actual.PT5M.burn -gt 0.20 -or $actual.PT6H.burn -lt 0.23 -or $actual.PT30M.burn -lt 1.10) {
        throw 'M18 raw fixture did not preserve the required not-met first band and met second band margins.'
    }
}

function Assert-M18Observation {
    param([Parameter(Mandatory)] $Observation, [Parameter(Mandatory)][string] $Window, [Parameter(Mandatory)][DateTimeOffset] $EvaluatedAt)
    if ($Observation.observationWindow -ne $Window -or $null -eq $Observation.observedBurnRate -or $null -ne $Observation.reason) { throw "M18 $Window observation was not available canonical evidence." }
    $from = ([DateTimeOffset]$Observation.range.from).ToUniversalTime(); $to = ([DateTimeOffset]$Observation.range.to).ToUniversalTime()
    $expectedDuration = @{ PT5M = 5; PT30M = 30; PT1H = 60; PT6H = 360 }[$Window]
    if ($to -ne $EvaluatedAt -or ($to - $from) -ne [TimeSpan]::FromMinutes($expectedDuration)) { throw "M18 $Window observation did not preserve its exact canonical range." }
}

function Assert-M18Evaluation {
    param([Parameter(Mandatory)] $Policy, [Parameter(Mandatory)] $Fixture)
    $evaluation = Get-Evaluation $Policy.id
    if ($evaluation.policyId -ne $M18PolicyId -or $evaluation.sloId -ne $M18SloId -or $evaluation.condition.type -ne 'MULTIWINDOW_BURN_RATE' -or $evaluation.status -ne 'CONDITION_MET' -or $null -ne $evaluation.reason) { throw 'M18 evaluation did not preserve its configured identity, condition, or decisive MET status.' }
    $bands = @($evaluation.condition.bands)
    if ($bands.Count -ne 2 -or $bands[0].longWindow -ne 'PT1H' -or $bands[0].shortWindow -ne 'PT5M' -or [double]$bands[0].threshold -ne 1.2 -or $bands[1].longWindow -ne 'PT6H' -or $bands[1].shortWindow -ne 'PT30M' -or [double]$bands[1].threshold -ne 0.2) { throw 'M18 evaluation did not return the two canonical configured bands.' }
    $evidence = $evaluation.evidence
    if ($null -eq $evidence -or $evidence.configuredSloWindow -ne 'PT5M') { throw 'M18 evaluation omitted aggregate evidence or configured-SLO provenance.' }
    Assert-Identity $evidence.service $M18Identity 'M18 evaluation'
    $evaluatedAt = ([DateTimeOffset]$evidence.evaluatedAt).ToUniversalTime()
    if ($evaluatedAt -lt $Fixture.nominal -or $evaluatedAt -gt $Fixture.end) { throw "M18 evaluatedAt '$($evidence.evaluatedAt)' was outside the prevalidated historical-import margin." }
    $observations = @{}
    foreach ($observation in @($evidence.observations)) {
        if ($observations.ContainsKey([string]$observation.observationWindow)) { throw 'M18 aggregate evidence contained a duplicate observation window.' }
        $observations[[string]$observation.observationWindow] = $observation
    }
    $canonicalWindows = @('PT5M', 'PT30M', 'PT1H', 'PT6H')
    if ($observations.Count -ne 4 -or @($evidence.observations | ForEach-Object { $_.observationWindow }) -join ',' -ne ($canonicalWindows -join ',')) { throw 'M18 aggregate evidence did not return the complete canonical window union.' }
    foreach ($window in $canonicalWindows) {
        Assert-M18Observation $observations[$window] $window $evaluatedAt
        $seconds = @{ PT5M = 300; PT30M = 1800; PT1H = 3600; PT6H = 21600 }[$window]
        $independent = Get-M18IndependentBurn $M18Identity $evaluatedAt $seconds
        if ([Math]::Abs([double]$observations[$window].observedBurnRate - $independent.burn) -gt 0.00001) { throw "M18 $window evidence did not match independently recomputed burn evidence." }
    }
    if ([double]$observations.PT1H.observedBurnRate -lt 1.2 -or [double]$observations.PT5M.observedBurnRate -ge 1.2 -or [double]$observations.PT6H.observedBurnRate -lt 0.2 -or [double]$observations.PT30M.observedBurnRate -lt 0.2) { throw 'M18 observations did not retain the required threshold relationship for the two bands.' }
    $results = @($evaluation.bandResults)
    if ($results.Count -ne 2 -or $results[0].outcome -ne 'NOT_MET' -or $results[1].outcome -ne 'MET') { throw 'M18 band results did not preserve required NOT_MET then MET outcomes.' }
    $expectedResults = @(
        @{ long = 'PT1H'; short = 'PT5M'; threshold = 1.2; outcome = 'NOT_MET' },
        @{ long = 'PT6H'; short = 'PT30M'; threshold = 0.2; outcome = 'MET' }
    )
    for ($index = 0; $index -lt $expectedResults.Count; $index++) {
        $result = $results[$index]; $expected = $expectedResults[$index]
        if ($result.band.longWindow -ne $expected.long -or $result.band.shortWindow -ne $expected.short -or [double]$result.band.threshold -ne $expected.threshold -or $result.longObservation.observationWindow -ne $expected.long -or $result.shortObservation.observationWindow -ne $expected.short -or $result.outcome -ne $expected.outcome) { throw "M18 band result $index did not retain canonical band/observation evidence." }
        foreach ($side in @(@{ name = 'longObservation'; window = $expected.long }, @{ name = 'shortObservation'; window = $expected.short })) {
            $actualObservation = $result.($side.name); $canonicalObservation = $observations[$side.window]
            if ($actualObservation.range.from -ne $canonicalObservation.range.from -or $actualObservation.range.to -ne $canonicalObservation.range.to -or [double]$actualObservation.observedBurnRate -ne [double]$canonicalObservation.observedBurnRate -or $actualObservation.reason -ne $canonicalObservation.reason) { throw "M18 band result $index did not reference its canonical $($side.window) observation." }
        }
    }
    Assert-NoForbiddenSyntax $evaluation 'M18 multiwindow alert evaluation'
    return $evaluation
}

function Invoke-JsonRequest {
    param([Parameter(Mandatory)][string] $Uri, [string] $Method = 'GET')
    $response = Invoke-WebRequest -Uri $Uri -Method $Method -TimeoutSec 15 -UseBasicParsing
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "$Method $Uri returned HTTP $($response.StatusCode)." }
    return $response.Content | ConvertFrom-Json
}

function Assert-M18LifecycleHistoryAndWebhook {
    param([Parameter(Mandatory)][datetime] $Deadline)
    $lifecycle = Invoke-JsonRequest "$BackendBaseUrl/api/alert-policies/$([uri]::EscapeDataString($M18PolicyId))/lifecycle-evaluations" 'POST'
    if ($lifecycle.triggeringEvaluation.condition.type -ne 'MULTIWINDOW_BURN_RATE' -or $lifecycle.triggeringEvaluation.status -ne 'CONDITION_MET' -or $lifecycle.current.state -ne 'FIRING') { throw 'M18 lifecycle did not retain the decisive multiwindow evaluation.' }
    $history = Invoke-JsonRequest "$BackendBaseUrl/api/alert-transitions?policyId=$([uri]::EscapeDataString($M18PolicyId))&limit=10"
    $transition = @($history.alertTransitions | Where-Object { $_.type -eq 'ALERT_STARTED' -and $_.evaluation.condition.type -eq 'MULTIWINDOW_BURN_RATE' })
    if ($transition.Count -lt 1) { throw 'M18 history did not retain its multiwindow ALERT_STARTED transition.' }
    while ((Get-Date) -lt $Deadline) {
        try {
            $receiver = Invoke-JsonRequest "$WebhookReceiverBaseUrl/events"
            $events = @($receiver.events | Where-Object { $_.payload.schemaVersion -eq 'geordi.notification.v2' -and $_.payload.policy.id -eq $M18PolicyId })
            if ($events.Count -gt 0) {
                $payload = $events[-1].payload
                if ($payload.condition.type -ne 'MULTIWINDOW_BURN_RATE' -or $payload.evaluationStatus -ne 'CONDITION_MET' -or @($payload.observations).Count -ne 4 -or @($payload.bandResults).Count -ne 2 -or $payload.bandResults[0].outcome -ne 'NOT_MET' -or $payload.bandResults[1].outcome -ne 'MET') { throw 'M18 webhook v2 payload did not retain complete canonical aggregate evidence.' }
                return
            }
        } catch { }
        Start-Sleep -Seconds 1
    }
    throw 'Timed out waiting for the M18 webhook v2 delivery.'
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
    Assert-M18VictoriaMetricsPin
    $m18Fixture = New-M18HistoricalCounterFixture
    Assert-M18RawFixture $m18Fixture $deadline
    $policies = @(Get-Policies)
    $zeroPolicy = @($policies | Where-Object { $_.id -eq $ZeroPolicyId -and $_.enabled -and $_.sloId -eq $ZeroSloId })
    $metPolicy = @($policies | Where-Object { $_.id -eq $MetPolicyId -and $_.enabled -and $_.sloId -eq $MetSloId })
    $noTrafficPolicy = @($policies | Where-Object { $_.id -eq $NoTrafficPolicyId -and $_.enabled -and $_.sloId -eq $NoTrafficSloId })
    $zeroBudgetPolicy = @($policies | Where-Object { $_.id -eq $ZeroBudgetPolicyId -and $_.enabled -and $_.sloId -eq $ZeroBudgetSloId })
    $disabledPolicy = @($policies | Where-Object { $_.id -eq $DisabledPolicyId -and -not $_.enabled -and $_.sloId -eq $MetSloId })
    $m18Policy = @($policies | Where-Object { $_.id -eq $M18PolicyId -and $_.enabled -and $_.sloId -eq $M18SloId })
    if ($zeroPolicy.Count -ne 1 -or $metPolicy.Count -ne 1 -or $noTrafficPolicy.Count -ne 1 -or $zeroBudgetPolicy.Count -ne 1 -or $disabledPolicy.Count -ne 1 -or $m18Policy.Count -ne 1) { throw 'The required deterministic M9/M18 alert policies were absent, enabled incorrectly, duplicated, or referenced the wrong SLO.' }
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
    $m18 = Assert-M18Evaluation $m18Policy[0] $m18Fixture
    Assert-M18LifecycleHistoryAndWebhook $deadline
    Assert-UnavailableEvaluation $noTrafficPolicy[0] $NoTrafficSloId @('NO_TRAFFIC', 'MISSING_REQUEST_COUNT') ([ordered]@{ name = 'geordi-slo-no-traffic'; namespace = 'geordi-slo-smoke'; environment = 'development' })
    Assert-UnavailableEvaluation $zeroBudgetPolicy[0] $ZeroBudgetSloId @('ZERO_ALLOWED_BAD_RATIO') ([ordered]@{ name = 'geordi-demo-service'; namespace = 'geordi-demo'; environment = 'development' })
    Assert-UnavailableEvaluation $disabledPolicy[0] $MetSloId @('DISABLED') -Disabled
    Assert-InvestigationContext $met
    Assert-AlertTelemetry $deadline
    Write-Host 'PASS: Alert policy catalog, self-contained traffic generation, independent exact-window zero/not-met and elevated/met comparator evidence, deterministic raw-imported M18 four-window evidence (band 1 NOT_MET, band 2 MET, overall MET), v2 lifecycle/history/webhook retention, disabled/no-traffic/zero-budget semantics, identity/range/threshold preservation, provider-neutral API, frontend Investigation context, and bounded self-observability verified. Provider outage/recovery remains authoritatively covered once by the preceding M8 burn smoke.'
    exit 0
} catch { Write-Error "Alert Evaluation smoke verification failed: $($_.Exception.Message)"; exit 1 }
