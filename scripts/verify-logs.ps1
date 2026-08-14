[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int] $TimeoutSeconds = 180,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $DemoBaseUrl = "http://127.0.0.1:8081",
    [string] $LokiBaseUrl = "http://127.0.0.1:3100",
    [string] $CollectorMetricsUrl = "http://127.0.0.1:8888/metrics",
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ServiceName = "geordi-demo-service"
$ServiceNamespace = "geordi-demo"
$Environment = "development"
$Origin = "monitored"
$ExpectedLabels = @("deployment_environment_name", "geordi_telemetry_origin", "service_name", "service_namespace")
$Markers = [ordered]@{
    "geordi.demo.log.info" = "INFO"
    "geordi.demo.log.warn" = "WARN"
    "geordi.demo.log.error" = "ERROR"
    "geordi.demo.log.nested-span" = "INFO"
}

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
        [Parameter(Mandatory)][string] $Name,
        [string] $RequiredLabels
    )

    $sum = 0.0
    foreach ($line in ($Metrics -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#") -or $trimmed.Length -eq 0) {
            continue
        }
        if ($trimmed -match "^$([regex]::Escape($Name))(?:\{(?<labels>[^}]*)\})?\s+(?<value>[-+0-9.eE]+)(?:\s+\d+)?$") {
            $labels = $Matches.labels
            $value = $Matches.value
            if (-not [string]::IsNullOrEmpty($RequiredLabels) -and $labels -notmatch $RequiredLabels) {
                continue
            }
            $sum += [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    return $sum
}

function Get-CollectorSnapshot {
    $metrics = Invoke-TextRequest -Uri $CollectorMetricsUrl
    return @{
        Accepted = Get-CounterTotal $metrics "otelcol_receiver_accepted_log_records"
        Refused = Get-CounterTotal $metrics "otelcol_receiver_refused_log_records"
        Sent = Get-CounterTotal $metrics "otelcol_exporter_sent_log_records" 'exporter="otlphttp/loki"'
        Failed = Get-CounterTotal $metrics "otelcol_exporter_send_failed_log_records" 'exporter="otlphttp/loki"'
        EnqueueFailed = Get-CounterTotal $metrics "otelcol_exporter_enqueue_failed_log_records" 'exporter="otlphttp/loki"'
    }
}

function Get-LokiQuery {
    param(
        [Parameter(Mandatory)][string] $Query,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To
    )

    $uri = "$LokiBaseUrl/loki/api/v1/query_range?query=$([uri]::EscapeDataString($Query))&start=$([uri]::EscapeDataString($From.ToUniversalTime().ToString('o')))&end=$([uri]::EscapeDataString($To.ToUniversalTime().ToString('o')))&limit=200&direction=forward"
    $payload = Invoke-TextRequest -Uri $uri | ConvertFrom-Json
    if ($payload.status -ne "success" -or $payload.data.resultType -ne "streams") {
        throw "Loki did not return a successful stream query."
    }
    return @($payload.data.result)
}

function Get-LokiEntries {
    param([Parameter(Mandatory)] $Streams)

    $entries = @()
    foreach ($stream in $Streams) {
        foreach ($value in @($stream.values)) {
            $metadata = @{}
            # Loki may merge structured metadata into the per-result stream object.
            # The /series assertion below is the authoritative index-label proof.
            foreach ($property in $stream.stream.PSObject.Properties) {
                if ($property.Name -notin $ExpectedLabels) {
                    $metadata[$property.Name] = [string] $property.Value
                }
            }
            if ($value.Count -ge 3 -and $null -ne $value[2]) {
                foreach ($property in $value[2].PSObject.Properties) {
                    $metadata[$property.Name] = [string] $property.Value
                }
            }
            $entries += [pscustomobject]@{
                Labels = $stream.stream
                TimestampNanos = [string] $value[0]
                Body = [string] $value[1]
                Metadata = $metadata
            }
        }
    }
    return $entries
}

function Assert-LokiLabels {
    param([Parameter(Mandatory)] $Streams)

    foreach ($stream in $Streams) {
        $actual = @($stream.stream.PSObject.Properties.Name | Sort-Object)
        $expected = @($ExpectedLabels | Sort-Object)
        $missing = @($expected | Where-Object { $_ -notin $actual })
        if ($missing.Count -ne 0) {
            throw "Loki query result omitted canonical stream labels: '$($missing -join ',')'."
        }
        if ($stream.stream.service_name -ne $ServiceName -or $stream.stream.service_namespace -ne $ServiceNamespace -or
            $stream.stream.deployment_environment_name -ne $Environment -or $stream.stream.geordi_telemetry_origin -ne $Origin) {
            throw "Loki stream did not retain the exact monitored service identity."
        }
    }
}

function Assert-LokiSeriesAllowlist {
    param(
        [Parameter(Mandatory)][string] $Selector,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To
    )

    $uri = "$LokiBaseUrl/loki/api/v1/series?match%5B%5D=$([uri]::EscapeDataString($Selector))&start=$([uri]::EscapeDataString($From.ToUniversalTime().ToString('o')))&end=$([uri]::EscapeDataString($To.ToUniversalTime().ToString('o')))"
    $payload = Invoke-TextRequest -Uri $uri | ConvertFrom-Json
    if ($payload.status -ne "success" -or @($payload.data).Count -eq 0) {
        throw "Loki series API did not return the demo log stream."
    }
    foreach ($series in @($payload.data)) {
        $actual = @($series.PSObject.Properties.Name | Sort-Object)
        if ((Compare-Object $actual @($ExpectedLabels | Sort-Object)).Count -ne 0) {
            throw "Loki /series exposed labels outside the four-label allowlist: '$($actual -join ',')'."
        }
    }
}

function Assert-GeordiLogsApi {
    param(
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][datetime] $Deadline,
        [Parameter(Mandatory)][string] $NestedTraceId,
        [Parameter(Mandatory)][string] $NestedSpanId
    )

    $fromValue = [uri]::EscapeDataString($From.ToUniversalTime().ToString("o"))
    $toValue = [uri]::EscapeDataString($To.ToUniversalTime().ToString("o"))
    $identity = "serviceName=$ServiceName&serviceNamespace=$ServiceNamespace&environment=$Environment&from=$fromValue&to=$toValue"
    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $services = Invoke-TextRequest -Uri "$BackendBaseUrl/api/logs/services?from=$fromValue&to=$toValue" | ConvertFrom-Json
            if (@($services.services | Where-Object { $_.name -eq $ServiceName -and $_.namespace -eq $ServiceNamespace -and $_.environment -eq $Environment }).Count -ne 1) {
                throw "Geordi logs services API did not expose the exact demo identity."
            }
            $logs = Invoke-TextRequest -Uri "$BackendBaseUrl/api/logs?$identity&limit=200" | ConvertFrom-Json
            if ($logs.service.name -ne $ServiceName -or $logs.service.namespace -ne $ServiceNamespace -or $logs.service.environment -ne $Environment) {
                throw "Geordi logs API did not preserve the requested identity."
            }
            if (([DateTimeOffset] $logs.range.from).ToUniversalTime() -ne $From.ToUniversalTime() -or
                ([DateTimeOffset] $logs.range.to).ToUniversalTime() -ne $To.ToUniversalTime()) {
                throw "Geordi logs API did not preserve the requested absolute time range."
            }
            foreach ($marker in $Markers.GetEnumerator()) {
                $matches = @($logs.logs | Where-Object {
                        $_.body -eq $marker.Key -and
                            ([string] $_.severity).ToUpperInvariant() -eq $marker.Value -and
                            ([string] $_.severityText).ToUpperInvariant() -eq $marker.Value
                    })
                if ($matches.Count -eq 0) {
                    throw "Geordi logs API did not return marker '$($marker.Key)' with severity '$($marker.Value)'."
                }
            }
            $nested = @($logs.logs | Where-Object { $_.body -eq "geordi.demo.log.nested-span" }) | Select-Object -First 1
            if ($nested.traceId -ne $NestedTraceId -or $nested.spanId -ne $NestedSpanId) {
                throw "Geordi logs API did not retain nested-span trace and span correlation."
            }
            $traceSearch = Invoke-TextRequest -Uri "$BackendBaseUrl/api/traces?$identity" | ConvertFrom-Json
            if (@($traceSearch.traces | Where-Object { $_.traceId -eq $NestedTraceId }).Count -ne 1) {
                throw "Geordi Trace Search did not return the nested log trace '$NestedTraceId'."
            }
            $traceDetail = Invoke-TextRequest -Uri "$BackendBaseUrl/api/traces/$NestedTraceId" | ConvertFrom-Json
            if (@($traceDetail.spans | Where-Object { $_.spanId -eq $NestedSpanId }).Count -ne 1) {
                throw "Geordi Trace Detail did not contain the nested log span '$NestedSpanId'."
            }
            $orderedTimestamps = @($logs.logs | ForEach-Object { [DateTimeOffset] $_.timestamp })
            for ($index = 1; $index -lt $orderedTimestamps.Count; $index++) {
                if ($orderedTimestamps[$index] -gt $orderedTimestamps[$index - 1]) {
                    throw "Geordi logs API did not return records newest-first."
                }
            }
            $warnLogs = Invoke-TextRequest -Uri "$BackendBaseUrl/api/logs?$identity&severity=WARN&limit=100" | ConvertFrom-Json
            if (@($warnLogs.logs).Count -eq 0 -or @($warnLogs.logs | Where-Object { $_.severity -ne "WARN" }).Count -ne 0) {
                throw "Geordi severity filtering did not return only WARN records."
            }
            $textLogs = Invoke-TextRequest -Uri "$BackendBaseUrl/api/logs?$identity&text=$([uri]::EscapeDataString('geordi.demo.log.error'))&limit=100" | ConvertFrom-Json
            if (@($textLogs.logs).Count -eq 0 -or @($textLogs.logs | Where-Object { $_.body -notlike '*geordi.demo.log.error*' }).Count -ne 0) {
                throw "Geordi literal text filtering did not preserve body semantics."
            }
            $traceLogs = Invoke-TextRequest -Uri "$BackendBaseUrl/api/logs?$identity&traceId=$NestedTraceId&limit=100" | ConvertFrom-Json
            if (@($traceLogs.logs | Where-Object { $_.body -eq "geordi.demo.log.nested-span" }).Count -eq 0) {
                throw "Geordi trace-correlated search did not return the nested-span log."
            }
            $spanLogs = Invoke-TextRequest -Uri "$BackendBaseUrl/api/logs?$identity&traceId=$NestedTraceId&spanId=$NestedSpanId&limit=100" | ConvertFrom-Json
            if (@($spanLogs.logs | Where-Object { $_.body -eq "geordi.demo.log.nested-span" -and $_.traceId -eq $NestedTraceId -and $_.spanId -eq $NestedSpanId }).Count -ne 1) {
                throw "Geordi span-correlated search did not return the nested-span log."
            }
            $limited = Invoke-TextRequest -Uri "$BackendBaseUrl/api/logs?$identity&limit=1" | ConvertFrom-Json
            if (@($limited.logs).Count -gt 1) {
                throw "Geordi logs API exceeded the requested record limit."
            }
            $frontendRoute = Invoke-TextRequest -Uri "$FrontendBaseUrl/logs?$identity"
            if ($frontendRoute -notmatch '<title>Geordi Platform</title>') {
                throw "Frontend /logs route did not return the Geordi application document."
            }
            $proxiedServices = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/logs/services?from=$fromValue&to=$toValue" | ConvertFrom-Json
            if (@($proxiedServices.services | Where-Object { $_.name -eq $ServiceName -and $_.namespace -eq $ServiceNamespace -and $_.environment -eq $Environment }).Count -ne 1) {
                throw "Frontend proxy did not expose the demo log service."
            }
            $proxiedLogs = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/logs?$identity&limit=200" | ConvertFrom-Json
            if (@($proxiedLogs.logs | Where-Object { $_.body -eq "geordi.demo.log.nested-span" }).Count -eq 0) {
                throw "Frontend proxy did not return the correlated nested log."
            }
            return
        }
        catch {
            $lastFailure = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "Timed out waiting for Geordi Logs API and frontend verification: $lastFailure"
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "Loki readiness" "$LokiBaseUrl/ready" $deadline
    Wait-ForHttp200 "Collector readiness" "http://127.0.0.1:13133/" $deadline
    Wait-ForHttp200 "demo readiness" "$DemoBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline

    $from = (Get-Date).ToUniversalTime().AddSeconds(-5)
    $before = Get-CollectorSnapshot
    [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/success")
    [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/warn")
    $errorResponse = Invoke-WebRequest -Uri "$DemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
    if ($errorResponse.StatusCode -ne 500) {
        throw "The controlled demo error endpoint returned HTTP $($errorResponse.StatusCode), expected 500."
    }
    [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/slow")
    $to = (Get-Date).ToUniversalTime().AddSeconds(10)

    do {
        Start-Sleep -Seconds 2
        $after = Get-CollectorSnapshot
    } while (($after.Accepted -le $before.Accepted -or $after.Sent -le $before.Sent) -and (Get-Date) -lt $deadline)
    if ($after.Accepted -le $before.Accepted -or $after.Sent -le $before.Sent) {
        throw "Collector did not accept and export additional log records."
    }
    foreach ($counter in @("Refused", "Failed", "EnqueueFailed")) {
        if ($after[$counter] -ne $before[$counter]) {
            throw "Collector log $counter counter increased from $($before[$counter]) to $($after[$counter])."
        }
    }

    $selector = '{service_name="geordi-demo-service",service_namespace="geordi-demo",deployment_environment_name="development",geordi_telemetry_origin="monitored"}'
    $streams = @()
    do {
        Start-Sleep -Seconds 2
        $streams = Get-LokiQuery -Query "$selector |= `"geordi.demo.log`"" -From $from -To $to
        $entries = Get-LokiEntries -Streams $streams
        $missing = @()
        foreach ($marker in $Markers.Keys) {
            if (@($entries | Where-Object { $_.Body -eq $marker }).Count -eq 0) {
                $missing += $marker
            }
        }
    } while ($missing.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($missing.Count -gt 0) {
        throw "Timed out waiting for persisted Loki semantic log markers: $($missing -join ', ')."
    }

    Assert-LokiLabels -Streams $streams
    Assert-LokiSeriesAllowlist -Selector $selector -From $from -To $to
    $entries = Get-LokiEntries -Streams $streams
    foreach ($marker in $Markers.GetEnumerator()) {
        $entry = @($entries | Where-Object { $_.Body -eq $marker.Key }) | Select-Object -First 1
        $severity = [string] $entry.Metadata["severity_text"]
        if ($severity.ToUpperInvariant() -ne $marker.Value) {
            throw "Loki structured metadata severity for '$($marker.Key)' was '$severity', expected '$($marker.Value)'."
        }
    }
    $nested = @($entries | Where-Object { $_.Body -eq "geordi.demo.log.nested-span" }) | Select-Object -First 1
    if ([string] $nested.Metadata["trace_id"] -notmatch '^[0-9a-f]{32}$' -or [string] $nested.Metadata["span_id"] -notmatch '^[0-9a-f]{16}$') {
        throw "Loki did not retain trace_id and span_id structured metadata for the nested-span log."
    }
    if ($nested.Metadata["request_id"] -ne "geordi-demo-log-request" -or $nested.Metadata["url_full"] -ne "http://geordi-demo:8081/demo/slow") {
        throw "Loki did not retain the narrowly captured request_id and url_full structured metadata."
    }
    Assert-GeordiLogsApi -From $from -To $to -Deadline $deadline -NestedTraceId ([string] $nested.Metadata["trace_id"]) -NestedSpanId ([string] $nested.Metadata["span_id"])

    Write-Host "PASS: OTLP logs were accepted, persisted in Loki with four index labels and structured correlation metadata, and returned by Geordi and the frontend proxy."
    exit 0
}
catch {
    Write-Error "Logs smoke verification failed: $($_.Exception.Message)"
    exit 1
}
