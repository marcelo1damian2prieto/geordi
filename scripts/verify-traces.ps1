[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int] $TimeoutSeconds = 180,

    [ValidateRange(1, 100)]
    [int] $RequestCount = 4,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $DemoBaseUrl = "http://127.0.0.1:8081",
    [string] $TempoBaseUrl = "http://127.0.0.1:3200",
    [string] $CollectorMetricsUrl = "http://127.0.0.1:8888/metrics",
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ServiceName = "geordi-demo-service"
$ServiceNamespace = "geordi-demo"
$Environment = "development"

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
        AcceptedSpans = Get-CounterTotal $metrics "otelcol_receiver_accepted_spans"
        RefusedSpans = Get-CounterTotal $metrics "otelcol_receiver_refused_spans"
        SentSpans = Get-CounterTotal $metrics "otelcol_exporter_sent_spans" 'exporter="otlphttp/tempo"'
        FailedSpans = Get-CounterTotal $metrics "otelcol_exporter_send_failed_spans" 'exporter="otlphttp/tempo"'
        EnqueueFailedSpans = Get-CounterTotal $metrics "otelcol_exporter_enqueue_failed_spans" 'exporter="otlphttp/tempo"'
    }
}

function Get-TraceUri {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [string] $Namespace = $ServiceNamespace
    )

    $parameters = [ordered]@{
        serviceName = $ServiceName
        serviceNamespace = $Namespace
        environment = $Environment
        from = $From.ToUniversalTime().ToString("o")
        to = $To.ToUniversalTime().ToString("o")
    }
    $query = ($parameters.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string] $_.Value)
    }) -join "&"
    return "${BackendBaseUrl}${Path}?$query"
}

function Assert-TraceIdentity {
    param(
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)][string] $Context
    )

    if ($Identity.name -ne $ServiceName -or $Identity.namespace -ne $ServiceNamespace -or $Identity.environment -ne $Environment) {
        throw "$Context returned identity '$($Identity.namespace)/$($Identity.name)/$($Identity.environment)', expected '$ServiceNamespace/$ServiceName/$Environment'."
    }
}

function Assert-TraceRange {
    param(
        [Parameter(Mandatory)] $Range,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][string] $Context
    )

    if (([DateTimeOffset] $Range.from).ToUniversalTime() -ne $From.ToUniversalTime() -or
        ([DateTimeOffset] $Range.to).ToUniversalTime() -ne $To.ToUniversalTime()) {
        throw "$Context did not preserve the requested time range."
    }
}

function Assert-TraceId {
    param([Parameter(Mandatory)][string] $TraceId, [Parameter(Mandatory)][string] $Context)
    if ($TraceId -notmatch '^[0-9a-f]{32}$') {
        throw "$Context trace ID '$TraceId' is not a lowercase 32-hex OpenTelemetry trace ID."
    }
}

function Get-TraceSearch {
    param(
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $payload = Invoke-TextRequest -Uri (Get-TraceUri -Path "/api/traces" -From $From -To $To) | ConvertFrom-Json
            Assert-TraceIdentity -Identity $payload.service -Context "Trace search"
            Assert-TraceRange -Range $payload.range -From $From -To $To -Context "Trace search"
            $traces = @($payload.traces)
            $hasSuccess = @($traces | Where-Object { [string] $_.rootSpanName -match '/demo/success' }).Count -gt 0
            $hasError = @($traces | Where-Object { [string] $_.rootSpanName -match '/demo/error' }).Count -gt 0
            $hasSlow = @($traces | Where-Object { [string] $_.rootSpanName -match '/demo/slow' }).Count -gt 0
            if ($hasSuccess -and $hasError -and $hasSlow) {
                return $payload
            }
            $lastFailure = "not all deterministic trace scenarios are persisted yet"
        }
        catch {
            $lastFailure = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for Geordi trace search results: $lastFailure"
}

function Get-TraceServices {
    param(
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    $uri = "$BackendBaseUrl/api/traces/services?from=$([uri]::EscapeDataString($From.ToUniversalTime().ToString('o')))&to=$([uri]::EscapeDataString($To.ToUniversalTime().ToString('o')))"
    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $payload = Invoke-TextRequest -Uri $uri | ConvertFrom-Json
            if (@($payload.services | Where-Object {
                        $_.name -eq $ServiceName -and $_.namespace -eq $ServiceNamespace -and $_.environment -eq $Environment
                    }).Count -eq 1) {
                return $payload
            }
            $lastFailure = "the exact monitored service identity tuple was not discovered"
        }
        catch {
            $lastFailure = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for trace service discovery: $lastFailure"
}

function Find-TraceForOperation {
    param(
        [Parameter(Mandatory)] $Traces,
        [Parameter(Mandatory)][string] $Operation
    )

    return @($Traces | Where-Object { [string] $_.rootSpanName -match [regex]::Escape($Operation) })
}

function Assert-TraceSummary {
    param(
        [Parameter(Mandatory)] $Trace,
        [Parameter(Mandatory)][string] $Context,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To
    )

    Assert-TraceId -TraceId ([string] $Trace.traceId) -Context $Context
    if ([string]::IsNullOrWhiteSpace([string] $Trace.rootSpanName)) {
        throw "$Context returned a blank root span name."
    }
    $startTime = ([DateTimeOffset] $Trace.startTime).ToUniversalTime()
    if ($startTime -eq [DateTimeOffset]::MinValue) {
        throw "$Context returned an invalid start time."
    }
    $rangeStart = ([DateTimeOffset] $From).ToUniversalTime()
    $rangeEnd = ([DateTimeOffset] $To).ToUniversalTime()
    if ($startTime -lt $rangeStart -or $startTime -ge $rangeEnd) {
        throw "$Context returned trace '$($Trace.traceId)' outside the requested half-open time range."
    }
    if ([double] $Trace.durationNanos -lt 0 -or [int] $Trace.spanCount -le 0) {
        throw "$Context returned invalid duration or span count."
    }
}

function Get-TraceDetail {
    param([Parameter(Mandatory)][string] $TraceId)
    return (Invoke-TextRequest -Uri "$BackendBaseUrl/api/traces/$TraceId" | ConvertFrom-Json)
}

function Assert-TraceDetail {
    param(
        [Parameter(Mandatory)] $Detail,
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)][string] $ExpectedOperation,
        [switch] $RequireError,
        [switch] $RequireNested,
        [switch] $RequireSlow
    )

    if ($Detail.traceId -ne $Summary.traceId) {
        throw "Trace detail ID '$($Detail.traceId)' did not match requested trace '$($Summary.traceId)'."
    }
    Assert-TraceId -TraceId ([string] $Detail.traceId) -Context "Trace detail"
    if ([double] $Detail.durationNanos -lt 0 -or [int] $Detail.spanCount -le 0) {
        throw "Trace detail returned invalid duration or span count."
    }

    $spans = @($Detail.spans)
    if ($spans.Count -ne [int] $Detail.spanCount) {
        throw "Trace detail spanCount did not match the returned span collection."
    }
    $spanIds = @{}
    $matchingServiceSpanCount = 0
    foreach ($span in $spans) {
        if ($span.traceId -ne $Detail.traceId) {
            throw "Trace detail returned a span from a different trace."
        }
        if ([string] $span.spanId -notmatch '^[0-9a-f]{16}$') {
            throw "Trace detail span ID '$($span.spanId)' is not a lowercase 16-hex OpenTelemetry span ID."
        }
        if ($spanIds.ContainsKey([string] $span.spanId)) {
            throw "Trace detail returned duplicate span ID '$($span.spanId)'."
        }
        $spanIds[[string] $span.spanId] = $true
        if ([string]::IsNullOrWhiteSpace([string] $span.service.name) -or [string]::IsNullOrWhiteSpace([string] $span.telemetryOrigin)) {
            throw "Trace span '$($span.spanId)' did not retain a service identity and telemetry origin."
        }
        if ($span.service.name -eq $ServiceName -and $span.service.namespace -eq $ServiceNamespace -and $span.service.environment -eq $Environment -and $span.telemetryOrigin -eq "monitored") {
            $matchingServiceSpanCount++
        }
        if ([double] $span.durationNanos -lt 0) {
            throw "Trace detail returned a negative span duration."
        }
    }
    if ($matchingServiceSpanCount -eq 0) {
        throw "Trace detail did not contain a monitored span with the requested service identity tuple."
    }
    foreach ($span in $spans) {
        if (-not [string]::IsNullOrWhiteSpace([string] $span.parentSpanId) -and -not $spanIds.ContainsKey([string] $span.parentSpanId)) {
            throw "Trace detail parent span '$($span.parentSpanId)' is absent from the same trace."
        }
    }
    if (@($spans | Where-Object { [string] $_.name -match [regex]::Escape($ExpectedOperation) }).Count -eq 0) {
        throw "Trace detail did not contain expected operation '$ExpectedOperation'."
    }
    if ($RequireError -and -not ($Detail.error -and @($spans | Where-Object {
                    $_.status -eq "ERROR" -or ($null -ne $_.http -and [int] $_.http.responseStatusCode -ge 500)
                }).Count -gt 0)) {
        throw "Controlled error trace did not retain error status or HTTP 5xx semantics."
    }
    if ($RequireSlow -and [double] $Detail.durationNanos -lt 125000000) {
        throw "Latency trace duration $($Detail.durationNanos)ns was shorter than the deterministic 150ms scenario."
    }
    if ($RequireNested -and @($spans | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_.parentSpanId) }).Count -eq 0) {
        throw "Nested demo trace did not contain a parent/child relationship."
    }
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "Tempo readiness" "$TempoBaseUrl/ready" $deadline
    Wait-ForHttp200 "demo readiness" "$DemoBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline

    $from = (Get-Date).ToUniversalTime().AddSeconds(-5)
    $before = Get-CollectorSnapshot
    1..$RequestCount | ForEach-Object {
        [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/success")
        [void] (Invoke-TextRequest -Uri "$DemoBaseUrl/demo/slow")
        $errorResponse = Invoke-WebRequest -Uri "$DemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
        if ($errorResponse.StatusCode -ne 500) {
            throw "The controlled demo error endpoint returned HTTP $($errorResponse.StatusCode), expected 500."
        }
    }
    $to = (Get-Date).ToUniversalTime().AddSeconds(10)
    Write-Host "Generated deterministic success, error and latency traffic; the latency scenario includes a nested internal span."

    do {
        Start-Sleep -Seconds 2
        $after = Get-CollectorSnapshot
    } while (($after.AcceptedSpans -le $before.AcceptedSpans -or $after.SentSpans -le $before.SentSpans) -and (Get-Date) -lt $deadline)
    if ($after.AcceptedSpans -le $before.AcceptedSpans -or $after.SentSpans -le $before.SentSpans) {
        throw "Collector did not accept and export additional spans after demo traffic."
    }
    foreach ($counter in @("RefusedSpans", "FailedSpans", "EnqueueFailedSpans")) {
        if ($after[$counter] -ne $before[$counter]) {
            throw "Collector $counter increased from $($before[$counter]) to $($after[$counter]) during trace traffic."
        }
    }

    [void] (Get-TraceServices -From $from -To $to -Deadline $deadline)

    $search = Get-TraceSearch -From $from -To $to -Deadline $deadline
    foreach ($trace in @($search.traces)) {
        Assert-TraceSummary -Trace $trace -Context "Trace search" -From $from -To $to
    }
    $success = Find-TraceForOperation -Traces $search.traces -Operation "/demo/success" | Select-Object -First 1
    $errorTrace = Find-TraceForOperation -Traces $search.traces -Operation "/demo/error" | Select-Object -First 1
    $slow = Find-TraceForOperation -Traces $search.traces -Operation "/demo/slow" | Select-Object -First 1
    if ($null -eq $success -or $null -eq $errorTrace -or $null -eq $slow) {
        throw "Trace search did not return all deterministic success, error and latency scenarios."
    }
    if (-not $errorTrace.error) {
        throw "Trace search did not identify the controlled error trace."
    }
    $errorOnlySearch = Invoke-TextRequest -Uri "$((Get-TraceUri -Path '/api/traces' -From $from -To $to))&errorOnly=true" | ConvertFrom-Json
    if (@($errorOnlySearch.traces).Count -eq 0 -or @($errorOnlySearch.traces | Where-Object { -not $_.error }).Count -gt 0) {
        throw "Trace error-only search did not return only error traces."
    }

    Assert-TraceDetail -Detail (Get-TraceDetail -TraceId $success.traceId) -Summary $success -ExpectedOperation "/demo/success"
    Assert-TraceDetail -Detail (Get-TraceDetail -TraceId $errorTrace.traceId) -Summary $errorTrace -ExpectedOperation "/demo/error" -RequireError
    Assert-TraceDetail -Detail (Get-TraceDetail -TraceId $slow.traceId) -Summary $slow -ExpectedOperation "/demo/slow" -RequireSlow -RequireNested

    $wrongNamespace = Invoke-TextRequest -Uri (Get-TraceUri -Path "/api/traces" -From $from -To $to -Namespace "other-namespace") | ConvertFrom-Json
    if (@($wrongNamespace.traces).Count -ne 0) {
        throw "Trace search returned monitored service traces for a different namespace."
    }

    $frontendRoute = Invoke-TextRequest -Uri "$FrontendBaseUrl/traces?serviceName=$ServiceName&serviceNamespace=$ServiceNamespace&environment=$Environment&from=$([uri]::EscapeDataString($from.ToString('o')))&to=$([uri]::EscapeDataString($to.ToString('o')))"
    if ($frontendRoute -notmatch '<title>Geordi Platform</title>') {
        throw "Frontend /traces route did not return the Geordi application document."
    }
    $proxiedSearch = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/traces?serviceName=$ServiceName&serviceNamespace=$ServiceNamespace&environment=$Environment&from=$([uri]::EscapeDataString($from.ToString('o')))&to=$([uri]::EscapeDataString($to.ToString('o')))" | ConvertFrom-Json
    if (@($proxiedSearch.traces).Count -eq 0) {
        throw "Frontend proxy did not return persisted traces."
    }
    $frontendDetailRoute = Invoke-TextRequest -Uri "$FrontendBaseUrl/traces/$($success.traceId)?serviceName=$ServiceName&serviceNamespace=$ServiceNamespace&environment=$Environment&from=$([uri]::EscapeDataString($from.ToString('o')))&to=$([uri]::EscapeDataString($to.ToString('o')))"
    if ($frontendDetailRoute -notmatch '<title>Geordi Platform</title>') {
        throw "Frontend trace-detail route did not return the Geordi application document."
    }
    $proxiedDetail = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/traces/$($success.traceId)" | ConvertFrom-Json
    if ($proxiedDetail.traceId -ne $success.traceId) {
        throw "Frontend proxy did not return the requested trace detail."
    }

    Write-Host "PASS: trace ingestion, Tempo persistence, exact identity/time/error-only search, trace detail, error/latency/nested semantics, service isolation and frontend routes/proxy verification completed."
    exit 0
}
catch {
    Write-Error "Trace smoke verification failed: $($_.Exception.Message)"
    exit 1
}
