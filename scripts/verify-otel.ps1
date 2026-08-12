[CmdletBinding()]
param(
    [ValidateRange(10, 300)]
    [int] $TimeoutSeconds = 90,

    [ValidateRange(1, 100)]
    [int] $RequestCount = 10,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $CollectorHealthUrl = "http://127.0.0.1:13133/",
    [string] $CollectorMetricsUrl = "http://127.0.0.1:8888/metrics"
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
    $matched = $false
    foreach ($line in ($Metrics -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#") -or $trimmed.Length -eq 0) {
            continue
        }
        if ($trimmed -notmatch "^$([regex]::Escape($Name))(?:\{(?<labels>[^}]*)\})?\s+(?<value>[-+0-9.eE]+)(?:\s+\d+)?$") {
            continue
        }
        $sum += [double]::Parse($Matches.value, [Globalization.CultureInfo]::InvariantCulture)
        $matched = $true
    }
    # OpenTelemetry counters with a zero value may be absent until their first update.
    # Treating absence as zero permits a clean baseline while positive flow counters
    # are still required to appear and increase below.
    return $sum
}

function Get-Snapshot {
    $metrics = Invoke-TextRequest -Uri $CollectorMetricsUrl

    return @{
        # This milestone topology contains one receiver (otlp) and one exporter
        # (debug), so summing all series is independent of Collector label naming.
        AcceptedSpans = Get-CounterTotal $metrics "otelcol_receiver_accepted_spans"
        AcceptedMetricPoints = Get-CounterTotal $metrics "otelcol_receiver_accepted_metric_points"
        RefusedSpans = Get-CounterTotal $metrics "otelcol_receiver_refused_spans"
        RefusedMetricPoints = Get-CounterTotal $metrics "otelcol_receiver_refused_metric_points"
        SentSpans = Get-CounterTotal $metrics "otelcol_exporter_sent_spans"
        SentMetricPoints = Get-CounterTotal $metrics "otelcol_exporter_sent_metric_points"
        FailedSpans = Get-CounterTotal $metrics "otelcol_exporter_send_failed_spans"
        FailedMetricPoints = Get-CounterTotal $metrics "otelcol_exporter_send_failed_metric_points"
    }
}

function Get-CollectorLogs {
    $output = & docker compose logs --no-color otel-collector 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read logs for Compose service 'otel-collector': $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

function Get-PlatformVersion {
    $platformJson = Invoke-TextRequest -Uri "$BackendBaseUrl/api/platform"
    $platform = $platformJson | ConvertFrom-Json
    $version = [string] $platform.version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "GET /api/platform did not return a non-blank version."
    }
    return $version
}

function Assert-NoIncrease {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][double] $Before,
        [Parameter(Mandatory)][double] $After
    )

    if ($After -ne $Before) {
        throw "$Name increased from $Before to $After."
    }
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is required to inspect the otel-collector Compose service."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "Collector readiness" $CollectorHealthUrl $deadline

    $platformVersion = Get-PlatformVersion
    $before = Get-Snapshot

    1..$RequestCount | ForEach-Object {
        [void] (Invoke-TextRequest -Uri "$BackendBaseUrl/api/platform")
    }
    Write-Host "Generated $RequestCount backend requests."

    $after = $null
    do {
        Start-Sleep -Seconds 2
        $after = Get-Snapshot
        $spanFlow = $after.AcceptedSpans -gt $before.AcceptedSpans -and
            $after.SentSpans -gt $before.SentSpans
        $metricFlow = $after.AcceptedMetricPoints -gt $before.AcceptedMetricPoints -and
            $after.SentMetricPoints -gt $before.SentMetricPoints
    } while ((-not ($spanFlow -and $metricFlow)) -and (Get-Date) -lt $deadline)

    if (-not $spanFlow) {
        throw "Collector span acceptance/export did not increase before timeout."
    }
    if (-not $metricFlow) {
        throw "Collector metric-point acceptance/export did not increase before timeout."
    }

    Assert-NoIncrease "refused spans" $before.RefusedSpans $after.RefusedSpans
    Assert-NoIncrease "refused metric points" $before.RefusedMetricPoints $after.RefusedMetricPoints
    Assert-NoIncrease "failed span exports" $before.FailedSpans $after.FailedSpans
    Assert-NoIncrease "failed metric-point exports" $before.FailedMetricPoints $after.FailedMetricPoints

    $logs = Get-CollectorLogs
    $requiredPatterns = [ordered]@{
        "backend service.name" = 'service\.name:\s+Str\(geordi-backend\)'
        "service namespace" = 'service\.namespace:\s+Str\(geordi\)'
        "service version matching the platform API" =
            'service\.version:\s+Str\(' + [regex]::Escape($platformVersion) + '\)'
        "platform origin" = 'geordi\.telemetry\.origin:\s+Str\(platform\)'
        "backend component" = 'geordi\.platform\.component:\s+Str\(backend\)'
        "deployment environment" = 'deployment\.environment\.name:\s+Str\(development\)'
        "service instance id" = 'service\.instance\.id:\s+Str\([^\r\n)]+\)'
        "JVM metric" = 'Name:\s+jvm\.'
    }
    foreach ($entry in $requiredPatterns.GetEnumerator()) {
        if ($logs -notmatch $entry.Value) {
            throw "Collector debug output did not contain $($entry.Key)."
        }
    }

    Write-Host "PASS: spans accepted/exported increased by $($after.AcceptedSpans - $before.AcceptedSpans)/$($after.SentSpans - $before.SentSpans)."
    Write-Host "PASS: metric points accepted/exported increased by $($after.AcceptedMetricPoints - $before.AcceptedMetricPoints)/$($after.SentMetricPoints - $before.SentMetricPoints)."
    Write-Host "PASS: refused and send-failed counters did not increase."
    Write-Host "PASS: backend Resource identity and JVM telemetry are present in Collector output."
    Write-Host "PASS: OpenTelemetry service.version matches API version $platformVersion."
    exit 0
}
catch {
    Write-Error "OpenTelemetry smoke verification failed: $($_.Exception.Message)"
    exit 1
}
