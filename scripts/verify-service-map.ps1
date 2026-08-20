[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int] $TimeoutSeconds = 180,

    [ValidateRange(1, 100)]
    [int] $RequestCount = 4,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $DemoBaseUrl = "http://127.0.0.1:8081",
    [string] $DownstreamBaseUrl = "http://127.0.0.1:8082",
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Environment = "development"
$Caller = [ordered]@{ name = "geordi-demo-service"; namespace = "geordi-demo"; environment = $Environment }
$Callee = [ordered]@{ name = "geordi-demo-downstream-service"; namespace = "geordi-demo"; environment = $Environment }

function Invoke-TextRequest {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [int] $TimeoutSeconds = 5
    )

    $response = Invoke-WebRequest -Uri $Uri -TimeoutSec $TimeoutSeconds -UseBasicParsing
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

function Test-Identity {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected
    )

    return $Actual.name -eq $Expected.name -and $Actual.namespace -eq $Expected.namespace -and $Actual.environment -eq $Expected.environment
}

function Assert-RangeTimestamp {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][string] $Context
    )

    try {
        $timestamp = ([DateTimeOffset] $Value).ToUniversalTime()
    }
    catch {
        throw "$Context returned an invalid timestamp '$Value'."
    }
    if ($timestamp -lt $From.ToUniversalTime() -or $timestamp -ge $To.ToUniversalTime()) {
        throw "$Context timestamp '$Value' was outside the requested half-open range."
    }
}

function Get-ServiceMap {
    param(
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To
    )

    $fromValue = [uri]::EscapeDataString($From.ToUniversalTime().ToString("o"))
    $toValue = [uri]::EscapeDataString($To.ToUniversalTime().ToString("o"))
    return (Invoke-TextRequest -Uri "$BackendBaseUrl/api/service-map?environment=$Environment&from=$fromValue&to=$toValue" -TimeoutSeconds 12 | ConvertFrom-Json)
}

function Assert-EvidenceTraceHasDirectDependency {
    param(
        [Parameter(Mandatory)][string] $TraceId,
        [Parameter(Mandatory)][string] $ObservedAt
    )

    $detail = Invoke-TextRequest -Uri "$BackendBaseUrl/api/traces/$TraceId" | ConvertFrom-Json
    if ($detail.traceId -ne $TraceId) {
        throw "Trace detail did not resolve Service Map evidence trace '$TraceId'."
    }

    $spansById = @{}
    foreach ($span in @($detail.spans)) {
        if ([string] $span.traceId -ne $TraceId -or [string] $span.spanId -notmatch '^[0-9a-f]{16}$') {
            throw "Evidence trace '$TraceId' returned an invalid span identity."
        }
        $spansById[[string] $span.spanId] = $span
    }

    $hasDirectDependency = $false
    foreach ($serverSpan in @($detail.spans | Where-Object {
                $_.kind -eq "SERVER" -and $_.telemetryOrigin -eq "monitored" -and (Test-Identity -Actual $_.service -Expected $Callee)
            })) {
        $parentId = [string] $serverSpan.parentSpanId
        if ([string]::IsNullOrWhiteSpace($parentId) -or -not $spansById.ContainsKey($parentId)) {
            continue
        }
        $clientSpan = $spansById[$parentId]
        if ($clientSpan.kind -eq "CLIENT" -and $clientSpan.telemetryOrigin -eq "monitored" -and (Test-Identity -Actual $clientSpan.service -Expected $Caller)) {
            $serverStart = ([DateTimeOffset] $serverSpan.startTime).ToUniversalTime()
            if ($serverStart -ne ([DateTimeOffset] $ObservedAt).ToUniversalTime()) {
                throw "Evidence trace '$TraceId' did not preserve the qualifying SERVER start timestamp."
            }
            $hasDirectDependency = $true
            break
        }
    }
    if (-not $hasDirectDependency) {
        throw "Evidence trace '$TraceId' did not contain a direct monitored CLIENT caller parent and SERVER callee child."
    }
}

function Assert-ServiceMap {
    param(
        [Parameter(Mandatory)] $Map,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To
    )

    if ($Map.context.environment -ne $Environment) {
        throw "Service Map returned environment '$($Map.context.environment)', expected '$Environment'."
    }
    $returnedFrom = ([DateTimeOffset] $Map.context.range.from).ToUniversalTime()
    if ($returnedFrom -ne $From.ToUniversalTime()) {
        throw "Service Map did not preserve the requested range start."
    }
    $returnedTo = ([DateTimeOffset] $Map.context.range.to).ToUniversalTime()
    if ($returnedTo -ne $To.ToUniversalTime()) {
        throw "Service Map did not preserve the requested range end."
    }
    if ([bool] $Map.truncated) {
        throw "The deterministic Service Map smoke unexpectedly returned a truncated graph."
    }

    $nodes = @($Map.nodes)
    if ($nodes.Count -ne 2 -or @($nodes | Where-Object { -not (Test-Identity -Actual $_ -Expected $Caller) -and -not (Test-Identity -Actual $_ -Expected $Callee) }).Count -ne 0) {
        throw "Service Map contained nodes other than the exact monitored caller and callee identities."
    }
    if (@($nodes | Where-Object { Test-Identity -Actual $_ -Expected $Caller }).Count -ne 1 -or @($nodes | Where-Object { Test-Identity -Actual $_ -Expected $Callee }).Count -ne 1) {
        throw "Service Map did not contain each expected endpoint identity exactly once."
    }

    $edges = @($Map.edges)
    if ($edges.Count -ne 1) {
        throw "Service Map returned $($edges.Count) edges; expected only the deterministic monitored dependency."
    }
    $edge = $edges[0]
    if (-not (Test-Identity -Actual $edge.caller -Expected $Caller) -or -not (Test-Identity -Actual $edge.callee -Expected $Callee)) {
        throw "Service Map did not return geordi-demo-service -> geordi-demo-downstream-service."
    }
    if (Test-Identity -Actual $edge.caller -Expected $edge.callee) {
        throw "Service Map returned a prohibited self-edge."
    }
    if ([int] $edge.evidenceCount -lt 1) {
        throw "Service Map returned a non-positive evidence count."
    }

    $evidence = @($edge.evidence)
    if ($evidence.Count -lt 1 -or $evidence.Count -gt 3 -or $evidence.Count -gt [int] $edge.evidenceCount) {
        throw "Service Map returned invalid bounded evidence for the observed dependency."
    }
    $traceIds = @{}
    foreach ($item in $evidence) {
        if ([string] $item.traceId -notmatch '^[0-9a-f]{32}$') {
            throw "Service Map returned an invalid OpenTelemetry trace ID '$($item.traceId)'."
        }
        if ($traceIds.ContainsKey([string] $item.traceId)) {
            throw "Service Map returned duplicate representative trace evidence."
        }
        $traceIds[[string] $item.traceId] = $true
        Assert-RangeTimestamp -Value ([string] $item.observedAt) -From $From -To $To -Context "Service Map evidence"
    }
    Assert-EvidenceTraceHasDirectDependency -TraceId ([string] $evidence[0].traceId) -ObservedAt ([string] $evidence[0].observedAt)
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "demo readiness" "$DemoBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "downstream demo readiness" "$DownstreamBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline

    $from = (Get-Date).ToUniversalTime().AddSeconds(-2)
    1..$RequestCount | ForEach-Object {
        $response = Invoke-TextRequest -Uri "$DemoBaseUrl/demo/downstream"
        if ($response -ne "downstream-ok") {
            throw "The deterministic downstream call returned '$response', expected 'downstream-ok'."
        }
    }
    $to = (Get-Date).ToUniversalTime().AddSeconds(10)
    Write-Host "Generated $RequestCount propagated monitored demo-to-downstream requests."

    $lastFailure = $null
    while ((Get-Date) -lt $deadline) {
        try {
            Assert-ServiceMap -Map (Get-ServiceMap -From $from -To $to) -From $from -To $to
            $frontendRoute = Invoke-TextRequest -Uri "$FrontendBaseUrl/service-map?environment=$Environment&from=$([uri]::EscapeDataString($from.ToString('o')))&to=$([uri]::EscapeDataString($to.ToString('o')))"
            if ($frontendRoute -notmatch '<title>Geordi Platform</title>') {
                throw "Frontend /service-map route did not return the Geordi application document."
            }
            $proxiedMap = Invoke-TextRequest -Uri "$FrontendBaseUrl/api/service-map?environment=$Environment&from=$([uri]::EscapeDataString($from.ToString('o')))&to=$([uri]::EscapeDataString($to.ToString('o')))" -TimeoutSeconds 12 | ConvertFrom-Json
            Assert-ServiceMap -Map $proxiedMap -From $from -To $to
            Write-Host "PASS: Service Map returned exact directed monitored evidence with bounded traces and no self, platform, or unrelated edges."
            exit 0
        }
        catch {
            $lastFailure = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "Timed out waiting for deterministic Service Map evidence: $lastFailure"
}
catch {
    Write-Error "Service Map smoke verification failed: $($_.Exception.Message)"
    exit 1
}
