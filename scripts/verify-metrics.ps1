[CmdletBinding()]
param(
    [ValidateRange(20, 300)]
    [int] $TimeoutSeconds = 150,

    [ValidateRange(1, 100)]
    [int] $RequestCount = 8,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $DemoBaseUrl = "http://127.0.0.1:8081",
    [string] $VictoriaMetricsBaseUrl = "http://127.0.0.1:8428",
    [string] $CollectorMetricsUrl = "http://127.0.0.1:8888/metrics",
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-TextRequest {
    param([Parameter(Mandatory)][string] $Uri)

    $response = Invoke-WebRequest -Uri $Uri -TimeoutSec 5 -UseBasicParsing
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

function Get-CounterTotal {
    param(
        [Parameter(Mandatory)][string] $Metrics,
        [Parameter(Mandatory)][string] $Name
    )

    $sum = 0.0
    foreach ($line in ($Metrics -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#") -or $trimmed.Length -eq 0) {
            continue
        }
        if ($trimmed -match "^$([regex]::Escape($Name))(?:\{[^}]*\})?\s+(?<value>[-+0-9.eE]+)(?:\s+\d+)?$") {
            $sum += [double]::Parse($Matches.value, [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    return $sum
}

function Get-CollectorSnapshot {
    $metrics = Invoke-TextRequest -Uri $CollectorMetricsUrl
    return @{
        SentMetricPoints = Get-CounterTotal $metrics "otelcol_exporter_sent_metric_points"
        RefusedMetricPoints = Get-CounterTotal $metrics "otelcol_receiver_refused_metric_points"
        FailedMetricPoints = Get-CounterTotal $metrics "otelcol_exporter_send_failed_metric_points"
        EnqueueFailedMetricPoints = Get-CounterTotal $metrics "otelcol_exporter_enqueue_failed_metric_points"
    }
}

function Get-VictoriaQueryResult {
    param([Parameter(Mandatory)][string] $Query)

    $escapedQuery = [uri]::EscapeDataString($Query)
    $response = Invoke-TextRequest -Uri "$VictoriaMetricsBaseUrl/api/v1/query?query=$escapedQuery"
    $payload = $response | ConvertFrom-Json
    if ($payload.status -ne "success") {
        throw "VictoriaMetrics did not report a successful query for '$Query'."
    }
    return @($payload.data.result)
}

function Wait-ForVictoriaMetric {
    param(
        [Parameter(Mandatory)][string] $Query,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    while ((Get-Date) -lt $Deadline) {
        if ((Get-VictoriaQueryResult -Query $Query).Count -gt 0) {
            Write-Host "PASS: VictoriaMetrics returned '$Query'."
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for persisted metric matching '$Query'."
}

function Assert-GeordiMetricsApiSnapshot {
    param([Parameter(Mandatory)][datetime] $Deadline)

    $expected = [ordered]@{
        JVM_MEMORY_USED = "By"
        JVM_CPU_UTILIZATION = "1"
        JVM_THREAD_COUNT = "{thread}"
        JVM_GC_DURATION = "s"
        HTTP_REQUEST_RATE = "{request}/s"
        HTTP_REQUEST_COUNT = "{request}"
        HTTP_REQUEST_LATENCY_P95 = "s"
        HTTP_ERROR_RATE = "1"
        HTTP_ERROR_COUNT = "{request}"
    }
    $fromValue = $Deadline.AddMinutes(-15).ToUniversalTime().ToString("o")
    $toValue = (Get-Date).ToUniversalTime().ToString("o")
    $from = [uri]::EscapeDataString($fromValue)
    $to = [uri]::EscapeDataString($toValue)
    $services = (Invoke-TextRequest -Uri "$BackendBaseUrl/api/metrics/services?from=$from&to=$to" | ConvertFrom-Json)
    $demoService = @($services.services | Where-Object {
        $_.name -eq "geordi-demo-service" -and $_.namespace -eq "geordi-demo" -and $_.environment -eq "development"
    })
    if ($demoService.Count -ne 1) {
        throw "Geordi metrics services API did not expose the expected demo service identity."
    }

    $identity = "serviceName=geordi-demo-service&serviceNamespace=geordi-demo&environment=development&from=$from&to=$to"
    $metricParameters = ($expected.Keys | ForEach-Object { "metric=$_" }) -join "&"
    $overview = Invoke-TextRequest -Uri "$BackendBaseUrl/api/metrics/overview?$identity" | ConvertFrom-Json
    $series = Invoke-TextRequest -Uri "$BackendBaseUrl/api/metrics/series?$identity&$metricParameters" | ConvertFrom-Json

    $overviewByMetric = @{}
    foreach ($value in @($overview.values)) {
        $metric = [string] $value.metric
        if (-not $expected.Contains($metric)) {
            throw "Geordi overview returned unsupported metric '$metric'."
        }
        if ($overviewByMetric.ContainsKey($metric)) {
            throw "Geordi overview returned duplicate metric '$metric'."
        }
        if ([string] $value.unit -ne $expected[$metric]) {
            throw "Geordi overview unit for '$metric' was '$($value.unit)', expected '$($expected[$metric])'."
        }
        if (-not [double]::IsFinite([double] $value.value)) {
            throw "Geordi overview value for '$metric' was not finite."
        }
        $overviewByMetric[$metric] = $value
    }
    if ($overviewByMetric.Count -ne $expected.Count) {
        throw "Geordi overview returned $($overviewByMetric.Count) supported metrics, expected all $($expected.Count)."
    }

    $seriesByMetric = @{}
    foreach ($item in @($series.series)) {
        $metric = [string] $item.metric
        if (-not $expected.Contains($metric)) {
            throw "Geordi series returned unsupported metric '$metric'."
        }
        if ($seriesByMetric.ContainsKey($metric)) {
            throw "Geordi series returned duplicate metric '$metric'."
        }
        if ([string] $item.unit -ne $expected[$metric]) {
            throw "Geordi series unit for '$metric' was '$($item.unit)', expected '$($expected[$metric])'."
        }
        $points = @($item.points)
        if ($points.Count -eq 0) {
            throw "Geordi series for '$metric' did not contain points."
        }
        foreach ($point in $points) {
            if (-not [double]::IsFinite([double] $point.value)) {
                throw "Geordi series point for '$metric' was not finite."
            }
        }
        $seriesByMetric[$metric] = $points
    }
    if ($seriesByMetric.Count -ne $expected.Count) {
        throw "Geordi series returned $($seriesByMetric.Count) supported metrics, expected all $($expected.Count)."
    }

    foreach ($ratio in @("JVM_CPU_UTILIZATION", "HTTP_ERROR_RATE")) {
        foreach ($value in @($seriesByMetric[$ratio])) {
            if ([double] $value.value -lt 0 -or [double] $value.value -gt 1) {
                throw "Geordi ratio '$ratio' was outside [0,1]: $($value.value)."
            }
        }
    }
    foreach ($trafficMetric in @("HTTP_REQUEST_RATE", "HTTP_REQUEST_COUNT", "HTTP_ERROR_RATE", "HTTP_ERROR_COUNT")) {
        if (-not (@($seriesByMetric[$trafficMetric]) | Where-Object { [double] $_.value -gt 0 })) {
            throw "Geordi '$trafficMetric' did not contain positive generated traffic data."
        }
    }

    $frontendHtml = Invoke-TextRequest -Uri "$FrontendBaseUrl/metrics"
    if ($frontendHtml -notmatch '<title>Geordi Platform</title>') {
        throw "Frontend /metrics route did not return the Geordi application document."
    }
    $proxiedServices = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/metrics/services?from=$from&to=$to" | ConvertFrom-Json
    if (@($proxiedServices.services | Where-Object { $_.name -eq "geordi-demo-service" }).Count -ne 1) {
        throw "Frontend proxy did not return the demo service from /api/metrics/services."
    }
    Write-Host "PASS: Geordi APIs returned all supported metric IDs, units, finite values/points and generated HTTP traffic through backend and frontend proxy."
}

function Assert-GeordiMetricsApi {
    param([Parameter(Mandatory)][datetime] $Deadline)

    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            Assert-GeordiMetricsApiSnapshot $Deadline
            return
        }
        catch {
            $lastFailure = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "Timed out waiting for complete Geordi metrics API data: $lastFailure"
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "VictoriaMetrics" "$VictoriaMetricsBaseUrl/health" $deadline
    Wait-ForHttp200 "demo readiness" "$DemoBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline

    $before = Get-CollectorSnapshot
    1..$RequestCount | ForEach-Object {
        [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/success")
        [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/slow")
        [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/cpu")
        $errorResponse = Invoke-WebRequest -Uri "$DemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
        if ($errorResponse.StatusCode -ne 500) {
            throw "The controlled demo error endpoint returned HTTP $($errorResponse.StatusCode), expected 500."
        }
    }
    Write-Host "Generated success, error, latency and CPU traffic for the demo service."

    do {
        Start-Sleep -Seconds 2
        $after = Get-CollectorSnapshot
    } while ($after.SentMetricPoints -le $before.SentMetricPoints -and (Get-Date) -lt $deadline)
    if ($after.SentMetricPoints -le $before.SentMetricPoints) {
        throw "Collector did not export additional metric points after demo traffic."
    }
    foreach ($counter in @("RefusedMetricPoints", "FailedMetricPoints", "EnqueueFailedMetricPoints")) {
        if ($after[$counter] -ne $before[$counter]) {
            throw "Collector $counter increased from $($before[$counter]) to $($after[$counter]) during demo traffic."
        }
    }
    Write-Host "PASS: Collector exported $($after.SentMetricPoints - $before.SentMetricPoints) additional metric points with no refused, failed or enqueue-failed points."

    # The Java agent's runtime metric names and the stable HTTP semantic-convention name
    # are intentionally asserted at the storage boundary, not only in Collector logs.
    Wait-ForVictoriaMetric 'jvm.memory.used{service.name="geordi-demo-service"}' $deadline
    Wait-ForVictoriaMetric 'jvm.cpu.recent_utilization{service.name="geordi-demo-service"}' $deadline
    Wait-ForVictoriaMetric 'jvm.thread.count{service.name="geordi-demo-service"}' $deadline
    Wait-ForVictoriaMetric 'jvm.gc.duration_sum{service.name="geordi-demo-service"}' $deadline
    Wait-ForVictoriaMetric 'http.server.request.duration_count{service.name="geordi-demo-service"}' $deadline
    Wait-ForVictoriaMetric 'http.server.request.duration_count{service.name="geordi-demo-service",http.response.status_code="500"}' $deadline
    Assert-GeordiMetricsApi $deadline
    Write-Host "PASS: metrics ingestion, persistence and Geordi query API verification completed."
    exit 0
}
catch {
    Write-Error "Metrics smoke verification failed: $($_.Exception.Message)"
    exit 1
}
