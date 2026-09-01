[CmdletBinding()]
param(
    [ValidateRange(180, 480)]
    [int] $TimeoutSeconds = 420,
    [string] $BackendBaseUrl = 'http://127.0.0.1:8080',
    [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8083',
    [string] $ReceiverABaseUrl = 'http://127.0.0.1:18081',
    [string] $ReceiverBBaseUrl = 'http://127.0.0.1:18082',
    [string] $VictoriaMetricsBaseUrl = 'http://127.0.0.1:8428'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Fixture-only credentials are supplied by the invoking environment, never committed
# in routing configuration. Fail before Compose is invoked when either is absent.
if ([string]::IsNullOrWhiteSpace($env:GEORDI_M13_WEBHOOK_TOKEN_A) -or
        [string]::IsNullOrWhiteSpace($env:GEORDI_M13_WEBHOOK_TOKEN_B)) {
    throw 'GEORDI_M13_WEBHOOK_TOKEN_A and GEORDI_M13_WEBHOOK_TOKEN_B must be non-empty environment variables.'
}
$RouteAPolicy = 'm13-route-a-alert'
$RouteBPolicy = 'm13-route-b-alert'
$SuppressedPolicy = 'm13-suppressed-alert'
$UnroutedPolicy = 'm13-unrouted-alert'

function Invoke-Compose([string[]] $Arguments, [string] $Operation) {
    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Compose $Operation failed." }
}

function Json([string] $Uri, [string] $Method = 'GET', $Body = $null) {
    $arguments = @{ Uri = $Uri; Method = $Method; TimeoutSec = 15; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $arguments.ContentType = 'application/json'
        $arguments.Body = $Body | ConvertTo-Json -Compress
    }
    return (Invoke-WebRequest @arguments).Content | ConvertFrom-Json
}

function Wait-Until([scriptblock] $Condition, [datetime] $Deadline, [string] $Message) {
    while ((Get-Date) -lt $Deadline) {
        try { if (& $Condition) { return } } catch [System.Net.WebException] { } catch [System.Net.Http.HttpRequestException] { }
        Start-Sleep -Milliseconds 250
    }
    throw $Message
}

function Send-Traffic([string] $Path, [int] $Count) {
    $uri = "$BurnDemoBaseUrl$Path"
    1..$Count | ForEach-Object -Parallel {
        [void](Invoke-WebRequest -Uri $using:uri -TimeoutSec 10 -UseBasicParsing -SkipHttpErrorCheck)
    } -ThrottleLimit 16
}

function Apply-Lifecycle([string] $PolicyId) {
    return Json "$BackendBaseUrl/api/alert-policies/$PolicyId/lifecycle-evaluations" 'POST'
}

function Delivery-Id([string] $PolicyId, [string] $Type, [string] $OccurredAt) {
    $text = "$PolicyId`n$Type`n$OccurredAt"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Receiver-Control([string] $ReceiverBaseUrl, [string] $Mode, [int] $Failures = 0, [bool] $Reset = $false) {
    [void](Json "$ReceiverBaseUrl/control" 'POST' @{ mode = $Mode; failures = $Failures; reset = $Reset })
}

function Receiver-Events([string] $ReceiverBaseUrl) { return Json "$ReceiverBaseUrl/events" }

function Event-Count([string] $ReceiverBaseUrl, [string] $DeliveryId) {
    return @((Receiver-Events $ReceiverBaseUrl).events | Where-Object deliveryId -eq $DeliveryId).Count
}

function Attempt-Count([string] $ReceiverBaseUrl, [string] $DeliveryId) {
    return @((Receiver-Events $ReceiverBaseUrl).attempts | Where-Object deliveryId -eq $DeliveryId).Count
}

function Metric-Series([string] $Selector) {
    return @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$([uri]::EscapeDataString($Selector))").data)
}

function Reset-M13Fixture([string] $Root) {
    $rendered = & docker compose --project-directory $Root config --format json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to render the M13 Compose configuration for fixture reset.' }
    $expected = @{
        'm13-alert-lifecycle-data' = 'geordi_m13-alert-lifecycle-data'
        'm13-victoriametrics-data' = 'geordi_m13-victoriametrics-data'
    }
    foreach ($logicalName in $expected.Keys) {
        if ($rendered.volumes.$logicalName.name -ne $expected[$logicalName]) {
            throw "Refusing M13 fixture reset for unexpected volume '$($rendered.volumes.$logicalName.name)'."
        }
    }
    Invoke-Compose @('--project-directory', $Root, 'rm', '-sf', 'backend', 'victoriametrics', 'webhook-receiver-a', 'webhook-receiver-b') 'fixture reset preparation'
    foreach ($logicalName in $expected.Keys) {
        $candidate = $expected[$logicalName]
        $inspection = & docker volume inspect $candidate 2>$null
        if ($LASTEXITCODE -eq 0) {
            $volume = @($inspection | ConvertFrom-Json)[0]
            if ($volume.Name -ne $candidate -or $volume.Labels.'com.docker.compose.project' -ne 'geordi' -or $volume.Labels.'com.docker.compose.volume' -ne $logicalName) {
                throw "Refusing M13 fixture reset for non-M13 volume '$candidate'."
            }
            & docker volume rm $candidate | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to remove dedicated M13 volume '$candidate'." }
        }
    }
}

function Outbox-Scalar([string] $Root, [string] $Sql) {
    # The backend is stopped before this read.  H2 is extracted from the already
    # verified application artifact; this does not rebuild or alter the runtime.
    $jar = Join-Path $Root 'backend/target/geordi-backend-0.1.0-SNAPSHOT.jar'
    if (!(Test-Path $jar)) { throw 'Verified backend artifact is required for the read-only M13 outbox inspection.' }
    $output = & docker run --rm --network none `
        -e "M13_SQL=$Sql" `
        -v "$(Join-Path $Root 'backend/target'):/verified:ro" `
        -v 'geordi_m13-alert-lifecycle-data:/var/lib/geordi/alerts' `
        maven:3.9.11-eclipse-temurin-21 sh -c 'mkdir -p /tmp/h2 && cd /tmp/h2 && jar xf /verified/geordi-backend-0.1.0-SNAPSHOT.jar && java -cp "BOOT-INF/lib/*" org.h2.tools.Shell -url "jdbc:h2:file:/var/lib/geordi/alerts/lifecycle;ACCESS_MODE_DATA=r" -user sa -password "" -sql "$M13_SQL"'
    if ($LASTEXITCODE -ne 0) { throw 'Read-only M13 outbox inspection failed.' }
    $matches = [regex]::Matches(($output -join "`n"), '(?m)^\s*(\d+)\s*$')
    if ($matches.Count -ne 1) { throw 'Read-only M13 outbox inspection returned an ambiguous scalar result.' }
    return [int]$matches[0].Groups[1].Value
}

function Assert-OutboxBoundary([string] $Root, [string] $RouteAId, [string] $SuppressedId, [string] $UnroutedId, [string[]] $FixtureTokens) {
    if ((Outbox-Scalar $Root "SELECT COUNT(*) FROM alert_notification_outbox WHERE delivery_id = '$RouteAId' AND destination_id = 'm13-receiver-a'") -ne 1) {
        throw 'MATCHED route A did not persist exactly one destination-A delivery binding.'
    }
    if ((Outbox-Scalar $Root "SELECT COUNT(*) FROM alert_notification_outbox WHERE delivery_id IN ('$SuppressedId', '$UnroutedId')") -ne 0) {
        throw 'SUPPRESSED or UNROUTED transition created durable delivery work.'
    }
    foreach ($token in $FixtureTokens) {
        $sqlLiteral = $token.Replace("'", "''")
        if ((Outbox-Scalar $Root "SELECT COUNT(*) FROM alert_notification_outbox WHERE POSITION('$sqlLiteral' IN payload_json) > 0 OR POSITION('$sqlLiteral' IN destination_fingerprint) > 0") -ne 0) {
            throw 'Fixture credential was persisted in outbox payload or destination fingerprint.'
        }
    }
}

try {
    $root = Split-Path -Parent $PSScriptRoot
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $env:COMPOSE_FILE = (Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m13.yaml')
    Reset-M13Fixture $root
    Invoke-Compose @('--project-directory', $root, 'up', '-d', '--force-recreate', 'victoriametrics', 'otel-collector', 'backend', 'burn-demo', 'webhook-receiver-a', 'webhook-receiver-b') 'M13 fixture startup'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M13 backend did not become ready.'
    Wait-Until { (Invoke-WebRequest -Uri "$ReceiverABaseUrl/health" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M13 receiver A did not become ready.'
    Wait-Until { (Invoke-WebRequest -Uri "$ReceiverBBaseUrl/health" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M13 receiver B did not become ready.'
    Wait-Until { (Invoke-WebRequest -Uri "$BurnDemoBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M13 burn demo did not become ready.'
    Receiver-Control $ReceiverABaseUrl 'success' 0 $true
    Receiver-Control $ReceiverBBaseUrl 'success' 0 $true

    Send-Traffic '/demo/success' 1
    $baseline = '{__name__="http.server.request.duration_count","service.name"="geordi-burn-smoke-service","http.response.status_code"="200"}'
    Wait-Until { (Metric-Series $baseline).Count -gt 0 } $deadline 'M13 controlled success baseline was not persisted.'
    Send-Traffic '/demo/error' 1
    $errorBaseline = '{__name__="http.server.request.duration_count","service.name"="geordi-burn-smoke-service","http.response.status_code"="500"}'
    Wait-Until { (Metric-Series $errorBaseline).Count -gt 0 } $deadline 'M13 controlled error baseline was not persisted.'
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$RouteAPolicy/evaluation").status -eq 'CONDITION_MET' } $deadline 'M13 route A condition did not become met.'

    $routeA = Apply-Lifecycle $RouteAPolicy
    $suppressed = Apply-Lifecycle $SuppressedPolicy
    $unrouted = Apply-Lifecycle $UnroutedPolicy
    foreach ($result in @($routeA, $suppressed, $unrouted)) {
        if ($result.transition.type -ne 'ALERT_STARTED') { throw "Expected an M13 STARTED transition, got '$($result.transition.type)'." }
    }
    $routeAId = Delivery-Id $RouteAPolicy 'ALERT_STARTED' $routeA.transition.occurredAt
    $suppressedId = Delivery-Id $SuppressedPolicy 'ALERT_STARTED' $suppressed.transition.occurredAt
    $unroutedId = Delivery-Id $UnroutedPolicy 'ALERT_STARTED' $unrouted.transition.occurredAt
    Wait-Until { (Event-Count $ReceiverABaseUrl $routeAId) -eq 1 } $deadline 'Route A STARTED delivery did not reach receiver A.'
    if ((Event-Count $ReceiverBBaseUrl $routeAId) -ne 0 -or (Event-Count $ReceiverABaseUrl $suppressedId) -ne 0 -or (Event-Count $ReceiverBBaseUrl $suppressedId) -ne 0 -or (Event-Count $ReceiverABaseUrl $unroutedId) -ne 0 -or (Event-Count $ReceiverBBaseUrl $unroutedId) -ne 0) {
        throw 'M13 receiver isolation failed for route A, SUPPRESS, or UNROUTED.'
    }

    Invoke-Compose @('--project-directory', $root, 'stop', 'backend') 'outbox-boundary inspection stop'
    Assert-OutboxBoundary $root $routeAId $suppressedId $unroutedId @($env:GEORDI_M13_WEBHOOK_TOKEN_A, $env:GEORDI_M13_WEBHOOK_TOKEN_B)
    Invoke-Compose @('--project-directory', $root, 'start', 'backend') 'post-inspection backend start'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'Backend did not recover after outbox inspection.'

    Receiver-Control $ReceiverBBaseUrl 'retry' 100 $false
    Send-Traffic '/demo/error' 179
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$RouteBPolicy/evaluation").status -eq 'CONDITION_MET' } $deadline 'M13 route B condition did not become met.'
    $routeB = Apply-Lifecycle $RouteBPolicy
    if ($routeB.transition.type -ne 'ALERT_STARTED') { throw 'Route B did not create its distinct STARTED transition.' }
    $routeBId = Delivery-Id $RouteBPolicy 'ALERT_STARTED' $routeB.transition.occurredAt
    Wait-Until { (Attempt-Count $ReceiverBBaseUrl $routeBId) -ge 1 } $deadline 'Route B retryable delivery was not attempted.'
    if ((Event-Count $ReceiverABaseUrl $routeBId) -ne 0) { throw 'Route B was delivered to receiver A.' }

    Invoke-Compose @('--project-directory', $root, 'stop', 'backend') 'restart persistence stop'
    if ((Outbox-Scalar $root "SELECT COUNT(*) FROM alert_notification_outbox WHERE delivery_id = '$routeBId' AND destination_id = 'm13-receiver-b'") -ne 1) {
        throw 'Pending route B delivery did not retain its non-secret destination-B binding.'
    }
    $routeBToken = $env:GEORDI_M13_WEBHOOK_TOKEN_B.Replace("'", "''")
    if ((Outbox-Scalar $root "SELECT COUNT(*) FROM alert_notification_outbox WHERE delivery_id = '$routeBId' AND (POSITION('$routeBToken' IN payload_json) > 0 OR POSITION('$routeBToken' IN destination_fingerprint) > 0)") -ne 0) {
        throw 'Pending route B delivery persisted its fixture credential.'
    }
    Invoke-Compose @('--project-directory', $root, 'start', 'backend') 'restart persistence start'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'Backend did not recover for persisted delivery retry.'
    Receiver-Control $ReceiverBBaseUrl 'success'
    Wait-Until { (Event-Count $ReceiverBBaseUrl $routeBId) -eq 1 } $deadline 'Persisted route B delivery did not recover after restart.'
    $retryIds = @((Receiver-Events $ReceiverBBaseUrl).attempts | Where-Object deliveryId -eq $routeBId | Select-Object -ExpandProperty deliveryId -Unique)
    if ($retryIds.Count -ne 1 -or $retryIds[0] -ne $routeBId -or (Event-Count $ReceiverABaseUrl $routeBId) -ne 0) {
        throw 'Retry/restart changed the delivery identity or destination.'
    }

    Send-Traffic '/demo/success' 2000
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$RouteAPolicy/evaluation").status -eq 'CONDITION_NOT_MET' } $deadline 'M13 route A condition did not recover.'
    $routeAResolved = Apply-Lifecycle $RouteAPolicy
    if ($routeAResolved.transition.type -ne 'ALERT_RESOLVED') { throw 'Route A did not produce ALERT_RESOLVED.' }
    $routeAResolvedId = Delivery-Id $RouteAPolicy 'ALERT_RESOLVED' $routeAResolved.transition.occurredAt
    Wait-Until { (Event-Count $ReceiverABaseUrl $routeAResolvedId) -eq 1 } $deadline 'Route A RESOLVED delivery did not reach receiver A.'
    if ((Event-Count $ReceiverBBaseUrl $routeAResolvedId) -ne 0) { throw 'Route A RESOLVED was delivered to receiver B.' }

    $routingMetrics = @(
        'geordi.alert.routing.evaluations',
        'geordi.alert.routing.matched',
        'geordi.alert.routing.suppressed',
        'geordi.alert.routing.unrouted'
    )
    foreach ($metric in $routingMetrics) {
        $selector = "{__name__=`"$metric`"}"
        Wait-Until { (Metric-Series $selector).Count -gt 0 } $deadline "M13 routing telemetry '$metric' was not persisted."
    }
    foreach ($metric in $routingMetrics) {
        $selector = "{__name__=`"$metric`"}"
        foreach ($series in Metric-Series $selector) {
        $customLabels = @($series.PSObject.Properties.Name | Where-Object { $_.StartsWith('geordi.alert.routing.') })
        if (@($customLabels | Where-Object { $_ -notin @('geordi.alert.routing.transition.type') }).Count -ne 0) {
            throw 'Routing telemetry exposed a non-allowlisted custom label.'
        }
        }
    }
    $runtimeLogs = & docker compose --project-directory $root logs --no-color backend webhook-receiver-a webhook-receiver-b
    $logText = $runtimeLogs -join "`n"
    if ($logText.Contains($env:GEORDI_M13_WEBHOOK_TOKEN_A) -or $logText.Contains($env:GEORDI_M13_WEBHOOK_TOKEN_B) -or $logText -match 'webhook-receiver-[ab]:8080/hook') {
        throw 'M13 fixture credential or endpoint leaked to relevant runtime logs.'
    }
    Write-Host 'PASS: M13 isolated route A/B, explicit suppression/unrouted durable boundary, retry/restart binding, security boundary, and bounded routing telemetry verified.'
} catch {
    Write-Error "Alert routing smoke failed: $($_.Exception.Message)"
    exit 1
}
