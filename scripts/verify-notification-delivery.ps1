[CmdletBinding()]
param(
    [ValidateRange(120, 360)][int] $TimeoutSeconds = 300,
    [string] $BackendBaseUrl = 'http://127.0.0.1:8080',
    [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8083',
    [string] $ReceiverBaseUrl = 'http://127.0.0.1:18080',
    [string] $VictoriaMetricsBaseUrl = 'http://127.0.0.1:8428'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PolicyId = 'burn-smoke-alert'

function Json([string] $Uri, [string] $Method = 'GET', $Body = $null) {
    $arguments = @{ Uri = $Uri; Method = $Method; TimeoutSec = 15; UseBasicParsing = $true }
    if ($null -ne $Body) { $arguments.ContentType = 'application/json'; $arguments.Body = ($Body | ConvertTo-Json -Compress) }
    (Invoke-WebRequest @arguments).Content | ConvertFrom-Json
}
function Apply-Lifecycle { Json "$BackendBaseUrl/api/alert-policies/$PolicyId/lifecycle-evaluations" 'POST' }
function Evaluation { Json "$BackendBaseUrl/api/alert-policies/$PolicyId/evaluation" }
function Delivery-Id([string] $Type, [string] $OccurredAt) {
    $text = "$PolicyId`n$Type`n$OccurredAt"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Control([string] $Mode, [int] $Failures = 0, [bool] $Reset = $false) {
    [void](Json "$ReceiverBaseUrl/control" 'POST' @{ mode = $Mode; failures = $Failures; reset = $Reset })
}
function Send-Traffic([string] $Path, [int] $Count) {
    $url = "$BurnDemoBaseUrl$Path"
    1..$Count | ForEach-Object -Parallel {
        [void](Invoke-WebRequest -Uri $using:url -TimeoutSec 10 -UseBasicParsing -SkipHttpErrorCheck)
    } -ThrottleLimit 16
}
function Wait-Until([scriptblock] $Condition, [datetime] $Deadline, [string] $Message) {
    while ((Get-Date) -lt $Deadline) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 250
    }
    throw $Message
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Control 'success' 0 $true

    Send-Traffic '/demo/success' 1
    $baselineSelector = [uri]::EscapeDataString(
        '{__name__="http.server.request.duration_count","service.name"="geordi-burn-smoke-service","http.response.status_code"="200"}')
    Wait-Until {
        @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$baselineSelector").data).Count -gt 0
    } $deadline 'Controlled traffic baseline was not persisted.'
    Send-Traffic '/demo/error' 1
    $errorBaselineSelector = [uri]::EscapeDataString(
        '{__name__="http.server.request.duration_count","service.name"="geordi-burn-smoke-service","http.response.status_code"="500"}')
    Wait-Until {
        @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$errorBaselineSelector").data).Count -gt 0
    } $deadline 'Controlled error baseline was not persisted.'
    Send-Traffic '/demo/error' 179
    Wait-Until { (Evaluation).status -eq 'CONDITION_MET' } $deadline 'Condition did not become met.'
    $started = Apply-Lifecycle
    if ($started.transition.type -ne 'ALERT_STARTED') { throw 'M11 did not create a STARTED transition.' }
    $startedId = Delivery-Id 'ALERT_STARTED' $started.transition.occurredAt
    Wait-Until { @((Json "$ReceiverBaseUrl/events").events | Where-Object deliveryId -eq $startedId).Count -eq 1 } $deadline 'STARTED webhook was not delivered.'
    $startedEvents = Json "$ReceiverBaseUrl/events"
    $startedEvent = @($startedEvents.events | Where-Object deliveryId -eq $startedId)[0]
    if ($startedEvent.deliveryId -ne $startedEvent.payload.deliveryId -or $startedEvent.payload.schemaVersion -ne 'geordi.notification.v1') { throw 'STARTED delivery identity/payload is invalid.' }
    [void](Apply-Lifecycle)
    Start-Sleep -Seconds 2
    if (@((Json "$ReceiverBaseUrl/events").events | Where-Object deliveryId -eq $startedId).Count -ne 1) { throw 'No-transition processing created delivery work.' }

    Control 'retry' 100 $false
    Send-Traffic '/demo/success' 2000
    Wait-Until { (Evaluation).status -eq 'CONDITION_NOT_MET' } $deadline 'Condition did not recover.'
    $resolved = Apply-Lifecycle
    if ($resolved.transition.type -ne 'ALERT_RESOLVED') { throw 'M11 did not create a RESOLVED transition.' }
    $resolvedId = Delivery-Id 'ALERT_RESOLVED' $resolved.transition.occurredAt
    Wait-Until { @((Json "$ReceiverBaseUrl/events").attempts | Where-Object deliveryId -eq $resolvedId).Count -ge 1 } $deadline 'Retryable webhook failure was not attempted.'
    $readiness = Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSec 15 -UseBasicParsing
    if ($readiness.StatusCode -ne 200) { throw 'Remote webhook failure degraded platform readiness.' }

    $root = Split-Path -Parent $PSScriptRoot
    & docker compose --project-directory $root --file (Join-Path $root 'compose.yaml') restart backend
    if ($LASTEXITCODE -ne 0) { throw 'Backend restart failed.' }
    Control 'success'
    Wait-Until { @((Json "$ReceiverBaseUrl/events").events | Where-Object deliveryId -eq $resolvedId).Count -eq 1 } $deadline 'Pending delivery did not recover after restart.'
    $receiverState = Json "$ReceiverBaseUrl/events"
    $resolvedEvent = @($receiverState.events | Where-Object deliveryId -eq $resolvedId)[0]
    $attemptIds = @($receiverState.attempts | Where-Object { $_.deliveryId -eq $resolvedEvent.deliveryId } | Select-Object -ExpandProperty deliveryId -Unique)
    if ($attemptIds.Count -ne 1) { throw 'Retry did not retain a stable delivery identity.' }
    $confirmedCount = @($receiverState.events | Where-Object { $_.deliveryId -in @($startedId, $resolvedId) }).Count
    & docker compose --project-directory $root --file (Join-Path $root 'compose.yaml') restart backend
    Start-Sleep -Seconds 4
    if (@((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.deliveryId -in @($startedId, $resolvedId) }).Count -ne $confirmedCount) { throw 'Restart redelivered confirmed successful work.' }

    $public = (Invoke-WebRequest -Uri "$BackendBaseUrl/api/platform" -UseBasicParsing).Content
    if ($public -match 'local-dev-only-token') { throw 'Notification secret leaked through public API.' }
    $selector = [uri]::EscapeDataString('{__name__="geordi.alert.delivery.results"}')
    Wait-Until {
        $series = @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$selector").data)
        $series.Count -gt 0
    } $deadline 'Delivery self-observability was not persisted.'
    foreach ($item in @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$selector").data)) {
        $custom = @($item.PSObject.Properties.Name | Where-Object { $_.StartsWith('geordi.alert.delivery.') })
        if (@($custom | Where-Object { $_ -notin @('geordi.alert.delivery.outcome', 'geordi.alert.delivery.transition.type') }).Count -gt 0) {
            throw 'Delivery telemetry exposed an unsupported custom label.'
        }
        if ($item.'geordi.telemetry.origin' -ne 'platform' -or $item.'service.name' -ne 'geordi-backend') { throw 'Delivery telemetry lost platform identity.' }
    }
    $runtimeLogs = & docker compose --project-directory $root --file (Join-Path $root 'compose.yaml') logs --no-color backend webhook-receiver
    if (($runtimeLogs -join "`n") -match 'local-dev-only-token') { throw 'Notification secret leaked through runtime logs.' }
    Write-Host 'PASS: atomic STARTED/RESOLVED webhook delivery, stable identity, retry/restart recovery, no-transition suppression, terminal success, and secret isolation verified.'
    exit 0
} catch { Write-Error "Notification Delivery smoke failed: $($_.Exception.Message)"; exit 1 }
