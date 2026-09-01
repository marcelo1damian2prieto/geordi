[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int] $TimeoutSeconds = 180,

    [ValidateRange(1, 100)]
    [int] $RequestCount = 8,

    [switch] $ExerciseProviderFailure,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $DemoBaseUrl = "http://127.0.0.1:8081",
    [string] $DownstreamBaseUrl = "http://127.0.0.1:8082",
    [string] $VictoriaMetricsBaseUrl = "http://127.0.0.1:8428",
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$AvailabilitySloId = "demo-downstream-availability"
$ErrorRateSloId = "demo-error-rate"
$NoTrafficSloId = "no-traffic-availability"
$BurnSmokeSloId = "burn-smoke-error-rate"
$ExpectedM7SloIds = @($AvailabilitySloId, $ErrorRateSloId, $BurnSmokeSloId, $NoTrafficSloId)
$DemoIdentity = [ordered]@{ name = "geordi-demo-service"; namespace = "geordi-demo"; environment = "development" }
$DownstreamIdentity = [ordered]@{ name = "geordi-demo-downstream-service"; namespace = "geordi-demo"; environment = "development" }
$NoTrafficIdentity = [ordered]@{ name = "geordi-slo-no-traffic"; namespace = "geordi-slo-smoke"; environment = "development" }
$BurnSmokeIdentity = [ordered]@{ name = "geordi-burn-smoke-service"; namespace = "geordi-burn-smoke"; environment = "development" }
$ProviderSyntaxPattern = 'promql|metricsql|victoriametrics|http\.server\.request|__name__|increase\s*\(|rate\s*\('

function Invoke-TextRequest {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [int] $RequestTimeoutSeconds = 8
    )

    $response = Invoke-WebRequest -Uri $Uri -TimeoutSec $RequestTimeoutSeconds -UseBasicParsing
    if ($response.StatusCode -ne 200) {
        throw "GET $Uri returned HTTP $($response.StatusCode)."
    }
    return [string] $response.Content
}

function Wait-ForHttp200 {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    while ((Get-Date) -lt $Deadline) {
        try {
            [void] (Invoke-TextRequest -Uri $Uri)
            Write-Host "PASS: $Name is ready at $Uri"
            return
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "Timed out waiting for $Name at $Uri."
}

function Assert-Identity {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Context
    )

    if ($Actual.name -ne $Expected.name -or
        $Actual.namespace -ne $Expected.namespace -or
        $Actual.environment -ne $Expected.environment) {
        throw "$Context returned '$($Actual.namespace)/$($Actual.name)/$($Actual.environment)', expected '$($Expected.namespace)/$($Expected.name)/$($Expected.environment)'."
    }
}

function Assert-NoProviderSyntax {
    param(
        [Parameter(Mandatory)] $Payload,
        [Parameter(Mandatory)][string] $Context
    )

    $serialized = $Payload | ConvertTo-Json -Depth 20 -Compress
    if ($serialized -match $ProviderSyntaxPattern) {
        throw "$Context leaked provider-specific query syntax or stored metric names."
    }
}

function Assert-Definition {
    param(
        [Parameter(Mandatory)] $Definition,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)][string] $SliType,
        [Parameter(Mandatory)][double] $Target
    )

    if ($Definition.id -ne $Id -or $Definition.sliType -ne $SliType -or
        [double] $Definition.target -ne $Target -or $Definition.window -ne "PT5M" -or
        -not [bool] $Definition.enabled) {
        throw "SLO '$Id' did not preserve its configured SLI, ratio target, PT5M window, and enabled state."
    }
    Assert-Identity -Actual $Definition.service -Expected $Identity -Context "SLO '$Id'"
}

function Get-DefinitionsById {
    param(
        [Parameter(Mandatory)][array] $Definitions,
        [Parameter(Mandatory)][string] $Context
    )

    $byId = @{}
    foreach ($definition in $Definitions) {
        $id = [string] $definition.id
        if ($byId.ContainsKey($id)) {
            throw "$Context returned duplicate id '$id'."
        }
        $byId[$id] = $definition
    }
    $missing = @($ExpectedM7SloIds | Where-Object { -not $byId.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "$Context did not expose expected M7 SLO definitions: $($missing -join ', ')."
    }
    return $byId
}

function Get-Evaluation {
    param([Parameter(Mandatory)][string] $SloId)

    return (Invoke-TextRequest -Uri "$BackendBaseUrl/api/slos/$SloId/evaluation" | ConvertFrom-Json)
}

function Wait-ForEvaluationStatus {
    param(
        [Parameter(Mandatory)][string] $SloId,
        [Parameter(Mandatory)][string] $ExpectedStatus,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $evaluation = Get-Evaluation -SloId $SloId
            if ($evaluation.status -eq $ExpectedStatus) {
                return $evaluation
            }
            $lastFailure = "status was '$($evaluation.status)' with reason '$($evaluation.reason)'"
        }
        catch {
            $lastFailure = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for SLO '$SloId' to become $ExpectedStatus`: $lastFailure"
}

function Assert-EvaluationContext {
    param(
        [Parameter(Mandatory)] $Evaluation,
        [Parameter(Mandatory)][string] $SloId,
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)][string] $SliType,
        [Parameter(Mandatory)][double] $Target,
        [Parameter(Mandatory)][string] $Status
    )

    if ($Evaluation.sloId -ne $SloId -or $Evaluation.sliType -ne $SliType -or
        [double] $Evaluation.target -ne $Target -or $Evaluation.window -ne "PT5M" -or
        $Evaluation.status -ne $Status) {
        throw "Evaluation '$SloId' did not preserve its definition and expected '$Status' status."
    }
    Assert-Identity -Actual $Evaluation.service -Expected $Identity -Context "Evaluation '$SloId'"

    $from = ([DateTimeOffset] $Evaluation.range.from).ToUniversalTime()
    $to = ([DateTimeOffset] $Evaluation.range.to).ToUniversalTime()
    $evaluatedAt = ([DateTimeOffset] $Evaluation.evaluatedAt).ToUniversalTime()
    if ($to -ne $evaluatedAt -or ($to - $from) -ne [TimeSpan]::FromMinutes(5)) {
        throw "Evaluation '$SloId' did not return one exact PT5M range ending at evaluatedAt."
    }
    Assert-NoProviderSyntax -Payload $Evaluation -Context "Evaluation '$SloId'"
}

function ConvertTo-ProviderLabelValue {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Value
    )

    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n')
}

function ConvertTo-ExclusiveProviderTime {
    param([Parameter(Mandatory)][string] $Timestamp)

    $parsed = [DateTimeOffset] $Timestamp
    $fractionNanoseconds = 0
    if ($Timestamp -match '\.(\d{1,9})(?:Z|[+-]\d{2}:\d{2})$') {
        $fractionNanoseconds = [int] $Matches[1].PadRight(9, '0')
    }
    $epochSeconds = [decimal] $parsed.ToUnixTimeSeconds()
    $exclusive = $epochSeconds + ([decimal] $fractionNanoseconds / [decimal] 1000000000) - [decimal] 0.000000001
    return $exclusive.ToString('0.000000000', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-VictoriaScalar {
    param(
        [Parameter(Mandatory)][string] $Expression,
        [Parameter(Mandatory)][string] $EvaluatedAt
    )

    $query = [uri]::EscapeDataString($Expression)
    $time = [uri]::EscapeDataString($EvaluatedAt)
    $payload = Invoke-TextRequest -Uri "$VictoriaMetricsBaseUrl/api/v1/query?query=$query&time=$time" | ConvertFrom-Json
    if ($payload.status -ne "success") {
        throw "VictoriaMetrics did not report success for an independent SLO formula query."
    }
    $results = @($payload.data.result)
    if ($results.Count -eq 0) {
        return @{ present = $false; value = $null }
    }
    if ($results.Count -ne 1) {
        throw "Independent SLO formula query returned $($results.Count) scalar series, expected one."
    }
    $value = [double] $results[0].value[1]
    if (-not [double]::IsFinite($value)) {
        throw "Independent SLO formula query returned a non-finite value."
    }
    return @{ present = $true; value = $value }
}

function Get-IndependentProviderCounts {
    param([Parameter(Mandatory)] $Evaluation)

    $serviceName = ConvertTo-ProviderLabelValue -Value ([string] $Evaluation.service.name)
    $serviceNamespace = ConvertTo-ProviderLabelValue -Value ([string] $Evaluation.service.namespace)
    $environment = ConvertTo-ProviderLabelValue -Value ([string] $Evaluation.service.environment)
    $selectors = '"geordi.telemetry.origin"="monitored"' +
        ',"service.name"="' + $serviceName + '"' +
        ',"deployment.environment.name"="' + $environment + '"' +
        ',"service.namespace"="' + $serviceNamespace + '"'
    $duration = ([DateTimeOffset] $Evaluation.range.to) - ([DateTimeOffset] $Evaluation.range.from)
    $windowSeconds = [long] $duration.TotalSeconds
    $allVector = '{__name__="http.server.request.duration_count",' + $selectors + '}'
    $errorVector = '{__name__="http.server.request.duration_count",' + $selectors +
        ',"http.response.status_code"=~"5.."}'
    $requestExpression = "sum(increase($allVector`[$windowSeconds" + "s]))"
    $errorExpression = "sum(increase($errorVector`[$windowSeconds" + "s]))"
    return @{
        requests = Get-VictoriaScalar -Expression $requestExpression -EvaluatedAt (ConvertTo-ExclusiveProviderTime ([string] $Evaluation.range.to))
        errors = Get-VictoriaScalar -Expression $errorExpression -EvaluatedAt (ConvertTo-ExclusiveProviderTime ([string] $Evaluation.range.to))
    }
}

function Assert-Formula {
    param(
        [Parameter(Mandatory)] $Evaluation,
        [Parameter(Mandatory)][string] $SliType
    )

    $observed = [double] $Evaluation.observedValue
    $reportedRequests = [double] $Evaluation.requestCount
    if (-not [double]::IsFinite($observed) -or $observed -lt 0 -or $observed -gt 1 -or
        -not [double]::IsFinite($reportedRequests) -or $reportedRequests -le 0) {
        throw "Evaluation '$($Evaluation.sloId)' did not return finite bounded evidence with positive request traffic."
    }

    $counts = Get-IndependentProviderCounts -Evaluation $Evaluation
    if (-not $counts.requests.present -or [double] $counts.requests.value -le 0) {
        throw "Independent provider request count was absent or non-positive for '$($Evaluation.sloId)'."
    }
    $errors = if ($counts.errors.present) { [double] $counts.errors.value } else { 0.0 }
    $requests = [double] $counts.requests.value
    $expected = if ($SliType -eq "AVAILABILITY") { 1.0 - ($errors / $requests) } else { $errors / $requests }
    $tolerance = 0.000001
    if ([Math]::Abs($reportedRequests - $requests) -gt $tolerance -or
        [Math]::Abs($observed - $expected) -gt $tolerance) {
        throw "Evaluation '$($Evaluation.sloId)' observed=$observed/requestCount=$reportedRequests but exact-time provider counts require observed=$expected/requestCount=$requests."
    }
}

function Wait-ForStableFormula {
    param(
        [Parameter(Mandatory)][string] $SloId,
        [Parameter(Mandatory)][string] $ExpectedStatus,
        [Parameter(Mandatory)][string] $SliType,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $evaluation = Get-Evaluation -SloId $SloId
            if ($evaluation.status -ne $ExpectedStatus) {
                throw "status was '$($evaluation.status)' with reason '$($evaluation.reason)'"
            }
            Assert-Formula -Evaluation $evaluation -SliType $SliType
            return $evaluation
        }
        catch {
            $lastFailure = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "Timed out waiting for SLO '$SloId' to expose stable exact-window evidence: $lastFailure"
}

function Assert-InvestigationContext {
    param([Parameter(Mandatory)] $Evaluation)

    $parameters = [ordered]@{
        serviceName = [string] $Evaluation.service.name
        serviceNamespace = [string] $Evaluation.service.namespace
        environment = [string] $Evaluation.service.environment
        from = [string] $Evaluation.range.from
        to = [string] $Evaluation.range.to
    }
    $query = ($parameters.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([uri]::EscapeDataString([string] $_.Value))"
    }) -join "&"
    $html = Invoke-TextRequest -Uri "$FrontendBaseUrl/investigate?$query"
    if ($html -notmatch '<title>Geordi Platform</title>') {
        throw "Frontend did not accept the exact SLO Service Investigation context."
    }
    $proxiedMetrics = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/metrics/series?$query&metric=HTTP_REQUEST_COUNT" | ConvertFrom-Json
    Assert-Identity -Actual $proxiedMetrics.service -Expected $Evaluation.service -Context "Investigation proxy"
    if ($proxiedMetrics.range.from -ne $Evaluation.range.from -or $proxiedMetrics.range.to -ne $Evaluation.range.to) {
        throw "Investigation proxy did not preserve the exact SLO evaluation range."
    }
}

function Get-SloSelfTelemetrySeries {
    $from = [uri]::EscapeDataString((Get-Date).ToUniversalTime().AddMinutes(-10).ToString("o"))
    $to = [uri]::EscapeDataString((Get-Date).ToUniversalTime().ToString("o"))
    $selector = [uri]::EscapeDataString(
        '{__name__=~"geordi[.]slo[.].*|geordi[.]metrics[.]request_outcomes[.].*"}')
    $payload = Invoke-TextRequest -Uri "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$selector&start=$from&end=$to" |
        ConvertFrom-Json
    if ($payload.status -ne "success") {
        throw "VictoriaMetrics did not report success while reading SLO self-observability series."
    }
    return @($payload.data)
}

function Assert-SloSelfTelemetrySeries {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array] $Series,
        [switch] $RequireRequestOutcomeFailure
    )

    $requiredNames = @(
        "geordi.slo.evaluations",
        "geordi.slo.results",
        "geordi.slo.duration_count",
        "geordi.metrics.request_outcomes.requests",
        "geordi.metrics.request_outcomes.duration_count"
    )
    if ($RequireRequestOutcomeFailure) {
        $requiredNames += "geordi.metrics.request_outcomes.failures"
    }
    $names = @($Series | ForEach-Object { [string] $_.'__name__' } | Sort-Object -Unique)
    $missing = @($requiredNames | Where-Object { $_ -notin $names })
    if ($missing.Count -gt 0) {
        throw "SLO self-observability is missing stored metric families: $($missing -join ', ')."
    }

    $allowedSloLabels = @(
        "geordi.slo.status",
        "geordi.slo.sli_type",
        "geordi.slo.reason",
        "geordi.slo.burn.status",
        "geordi.slo.burn.reason"
    )
    $forbiddenValues = @(
        $AvailabilitySloId,
        $ErrorRateSloId,
        $NoTrafficSloId,
        $DemoIdentity.name,
        $DownstreamIdentity.name,
        $NoTrafficIdentity.name,
        $DemoIdentity.namespace,
        $NoTrafficIdentity.namespace
    )
    foreach ($item in $Series) {
        $metricName = [string] $item.'__name__'
        $properties = @($item.PSObject.Properties)
        $unexpectedCustomLabels = @($properties.Name | Where-Object {
                $_ -like "geordi.slo.*" -and $_ -notin $allowedSloLabels
            })
        if ($unexpectedCustomLabels.Count -gt 0) {
            throw "Self-observability metric '$metricName' exposed unexpected SLO labels: $($unexpectedCustomLabels -join ', ')."
        }
        if ($metricName -like "geordi.metrics.request_outcomes.*" -and
            @($properties.Name | Where-Object { $_ -like "geordi.metrics.request_outcomes.*" }).Count -gt 0) {
            throw "Request-outcome metric '$metricName' exposed query-specific custom labels."
        }

        if ($null -ne $item.'service.name' -and $item.'service.name' -ne "geordi-backend") {
            throw "Self-observability metric '$metricName' did not retain the platform backend resource identity."
        }
        if ($null -ne $item.'geordi.telemetry.origin' -and $item.'geordi.telemetry.origin' -ne "platform") {
            throw "Self-observability metric '$metricName' was not classified as platform telemetry."
        }

        foreach ($property in $properties | Where-Object { $_.Name -ne "__name__" }) {
            $value = [string] $property.Value
            if ($value -in $forbiddenValues -or
                $value -match 'http\.server\.request\.duration|increase\s*\(|promql|metricsql|victoriametrics' -or
                $property.Name -match '(?i)(slo[._-]?(id|name|target)|evaluated[._-]?at|range[._-]?(from|to)|query|expression)') {
                throw "Self-observability metric '$metricName' leaked high-cardinality objective, identity, time, target, or provider-query context through '$($property.Name)'."
            }
        }
    }

    $results = @($Series | Where-Object { $_.'__name__' -eq "geordi.slo.results" })
    $statuses = @($results | ForEach-Object { [string] $_.'geordi.slo.status' } | Sort-Object -Unique)
    $sliTypes = @($results | ForEach-Object { [string] $_.'geordi.slo.sli_type' } | Sort-Object -Unique)
    $reasons = @($results | ForEach-Object { [string] $_.'geordi.slo.reason' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if (@("met", "breached", "unavailable") | Where-Object { $_ -notin $statuses }) {
        throw "SLO result telemetry did not preserve the bounded MET/BREACHED/UNAVAILABLE outcomes."
    }
    if (@("availability", "error_rate") | Where-Object { $_ -notin $sliTypes }) {
        throw "SLO result telemetry did not preserve both bounded SLI types."
    }
    if ("missing_request_count" -notin $reasons) {
        throw "SLO result telemetry did not preserve the bounded missing-request-count reason."
    }
    if ($RequireRequestOutcomeFailure -and "metrics_unavailable" -notin $reasons) {
        throw "SLO result telemetry did not preserve the bounded provider-unavailable reason after the outage scenario."
    }
    if (@($statuses | Where-Object { $_ -notin @("met", "breached", "unavailable") }).Count -gt 0 -or
        @($sliTypes | Where-Object { $_ -notin @("availability", "error_rate") }).Count -gt 0 -or
        @($reasons | Where-Object { $_ -notin @("missing_request_count", "metrics_unavailable") }).Count -gt 0) {
        throw "SLO result telemetry contained an out-of-catalog status, SLI type, or reason label."
    }
}

function Wait-ForSloSelfTelemetry {
    param(
        [Parameter(Mandatory)][datetime] $Deadline,
        [switch] $RequireRequestOutcomeFailure
    )

    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $series = Get-SloSelfTelemetrySeries
            Assert-SloSelfTelemetrySeries -Series $series -RequireRequestOutcomeFailure:$RequireRequestOutcomeFailure
            Write-Host "PASS: SLO evaluation and Metrics request-outcome self-observability is stored with bounded, low-cardinality labels."
            return
        }
        catch {
            $lastFailure = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for bounded SLO self-observability telemetry: $lastFailure"
}

function Assert-ProviderFailureUnavailable {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $composeFile = Join-Path $repositoryRoot "compose.yaml"
    $providerStopped = $false
    try {
        & docker compose --project-directory $repositoryRoot --file $composeFile stop victoriametrics
        if ($LASTEXITCODE -ne 0) {
            throw "Could not stop VictoriaMetrics for the provider-failure scenario."
        }
        $providerStopped = $true
        $evaluation = Get-Evaluation -SloId $AvailabilitySloId
        if ($evaluation.status -ne "UNAVAILABLE" -or $evaluation.reason -ne "METRICS_UNAVAILABLE" -or
            $null -ne $evaluation.observedValue) {
            throw "Provider failure became '$($evaluation.status)/$($evaluation.reason)' instead of UNAVAILABLE/METRICS_UNAVAILABLE."
        }
        Write-Host "PASS: provider failure remained UNAVAILABLE and was never reported as MET."
    }
    finally {
        if ($providerStopped) {
            & docker compose --project-directory $repositoryRoot --file $composeFile start victoriametrics
            if ($LASTEXITCODE -ne 0) {
                throw "Could not restart VictoriaMetrics after the provider-failure scenario."
            }
            $restartDeadline = (Get-Date).AddSeconds(60)
            Wait-ForHttp200 "VictoriaMetrics after provider-failure scenario" "$VictoriaMetricsBaseUrl/health" $restartDeadline
            Wait-ForSloSelfTelemetry -Deadline $restartDeadline -RequireRequestOutcomeFailure
        }
    }
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "demo readiness" "$DemoBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "downstream demo readiness" "$DownstreamBaseUrl/actuator/health/readiness" $deadline

    $catalog = Invoke-TextRequest -Uri "$BackendBaseUrl/api/slos" | ConvertFrom-Json
    $definitions = @($catalog.slos)
    $byId = Get-DefinitionsById -Definitions $definitions -Context "SLO catalog"
    Assert-Definition -Definition $byId[$AvailabilitySloId] -Id $AvailabilitySloId -Identity $DownstreamIdentity -SliType "AVAILABILITY" -Target 0.99
    Assert-Definition -Definition $byId[$ErrorRateSloId] -Id $ErrorRateSloId -Identity $DemoIdentity -SliType "ERROR_RATE" -Target 0.0
    Assert-Definition -Definition $byId[$BurnSmokeSloId] -Id $BurnSmokeSloId -Identity $BurnSmokeIdentity -SliType "ERROR_RATE" -Target 0.10
    Assert-Definition -Definition $byId[$NoTrafficSloId] -Id $NoTrafficSloId -Identity $NoTrafficIdentity -SliType "AVAILABILITY" -Target 0.99
    Assert-NoProviderSyntax -Payload $catalog -Context "SLO catalog"

    1..$RequestCount | ForEach-Object {
        $downstreamResponse = Invoke-TextRequest -Uri "$DownstreamBaseUrl/downstream/respond"
        if ($downstreamResponse -ne "downstream-ok") {
            throw "Downstream success scenario returned '$downstreamResponse'."
        }
        $errorResponse = Invoke-WebRequest -Uri "$DemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
        if ($errorResponse.StatusCode -ne 500) {
            throw "Controlled error scenario returned HTTP $($errorResponse.StatusCode), expected 500."
        }
    }
    Write-Host "Generated $RequestCount isolated downstream successes and $RequestCount controlled demo errors."
    # Let the SDK and Collector finish the current metric export before capturing the
    # immutable evaluation timestamp used by the independent provider assertion.
    Start-Sleep -Seconds 6

    $availability = Wait-ForStableFormula -SloId $AvailabilitySloId -ExpectedStatus "MET" -SliType "AVAILABILITY" -Deadline $deadline
    $errorRate = Wait-ForStableFormula -SloId $ErrorRateSloId -ExpectedStatus "BREACHED" -SliType "ERROR_RATE" -Deadline $deadline
    $noTraffic = Wait-ForEvaluationStatus -SloId $NoTrafficSloId -ExpectedStatus "UNAVAILABLE" -Deadline $deadline

    Assert-EvaluationContext -Evaluation $availability -SloId $AvailabilitySloId -Identity $DownstreamIdentity -SliType "AVAILABILITY" -Target 0.99 -Status "MET"
    Assert-EvaluationContext -Evaluation $errorRate -SloId $ErrorRateSloId -Identity $DemoIdentity -SliType "ERROR_RATE" -Target 0.0 -Status "BREACHED"
    Assert-EvaluationContext -Evaluation $noTraffic -SloId $NoTrafficSloId -Identity $NoTrafficIdentity -SliType "AVAILABILITY" -Target 0.99 -Status "UNAVAILABLE"
    if ($null -ne $noTraffic.observedValue -or $null -ne $noTraffic.requestCount -or
        $noTraffic.reason -ne "MISSING_REQUEST_COUNT") {
        throw "No-traffic identity must remain UNAVAILABLE/MISSING_REQUEST_COUNT with null observed evidence; absence must not become zero or MET."
    }

    $frontendHtml = Invoke-TextRequest -Uri "$FrontendBaseUrl/slos"
    if ($frontendHtml -notmatch '<title>Geordi Platform</title>') {
        throw "Frontend /slos route did not return the Geordi application document."
    }
    $proxiedCatalog = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/slos" | ConvertFrom-Json
    [void] (Get-DefinitionsById -Definitions @($proxiedCatalog.slos) -Context "Frontend SLO proxy")
    $proxiedEvaluation = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/slos/$ErrorRateSloId/evaluation" | ConvertFrom-Json
    if ($proxiedEvaluation.status -ne "BREACHED") {
        throw "Frontend proxy did not preserve the deterministic breached SLO result."
    }
    Assert-NoProviderSyntax -Payload $proxiedEvaluation -Context "Frontend SLO proxy"
    Assert-InvestigationContext -Evaluation $errorRate
    Wait-ForSloSelfTelemetry -Deadline $deadline

    if ($ExerciseProviderFailure) {
        Assert-ProviderFailureUnavailable
    }

    Write-Host "PASS: SLO catalog, exact identities, whole-window formulas, MET/BREACHED/UNAVAILABLE semantics, provider-neutral API, frontend proxy, and Investigation context verified."
    exit 0
}
catch {
    Write-Error "SLO smoke verification failed: $($_.Exception.Message)"
    exit 1
}
