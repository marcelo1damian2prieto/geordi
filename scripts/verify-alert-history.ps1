[CmdletBinding()]
param(
    [ValidateRange(180, 600)] [int] $TimeoutSeconds = 480,
    [string] $BackendBaseUrl = 'http://127.0.0.1:8080',
    [string] $FrontendBaseUrl = 'http://127.0.0.1:3000',
    [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8083',
    [string] $VictoriaMetricsBaseUrl = 'http://127.0.0.1:8428'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$RouteA = 'm13-route-a-alert'
$Suppressed = 'm13-suppressed-alert'
$Unrouted = 'm13-unrouted-alert'

if ([string]::IsNullOrWhiteSpace($env:GEORDI_M13_WEBHOOK_TOKEN_A) -or [string]::IsNullOrWhiteSpace($env:GEORDI_M13_WEBHOOK_TOKEN_B)) {
    throw 'GEORDI_M13_WEBHOOK_TOKEN_A and GEORDI_M13_WEBHOOK_TOKEN_B must be non-empty environment variables.'
}

function Compose([string[]] $Arguments, [string] $Operation) {
    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Compose $Operation failed." }
}
function Json([string] $Uri, [string] $Method = 'GET') {
    $response = Invoke-WebRequest -Uri $Uri -Method $Method -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "Expected successful JSON response from '$Uri', got HTTP $($response.StatusCode)." }
    return Read-JsonStrings $response.Content
}
function Post-Json([string] $Uri, $Body) {
    $response = Invoke-WebRequest -Uri $Uri -Method POST -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress) -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck
    return [pscustomobject]@{ StatusCode = $response.StatusCode; Body = if ($response.Content) { Read-JsonStrings $response.Content } else { $null }; ContentType = [string]$response.Headers['Content-Type'] }
}
function Read-JsonStrings($Content) {
    # Invoke-WebRequest can return bytes for application/problem+json without charset.
    if ($Content -is [byte[]]) { $Content = [Text.Encoding]::UTF8.GetString($Content) }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Content -DateKind String
    }
    # PowerShell before 7.5 converts ISO strings to DateTime; preserve all nine digits.
    $document = [System.Text.Json.JsonDocument]::Parse($Content)
    try { return Read-JsonElement $document.RootElement } finally { $document.Dispose() }
}
function Read-JsonElement($Element) {
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $properties = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) { $properties[$property.Name] = Read-JsonElement $property.Value }
            return [pscustomobject]$properties
        }
        'Array' {
            $items = @(foreach ($item in $Element.EnumerateArray()) { Read-JsonElement $item })
            return ,$items
        }
        'String' { return $Element.GetString() }
        'Number' { return $Element.GetDecimal() }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw 'Unexpected JSON value kind.' }
    }
}
function Require-Fields($Value, [string[]] $Allowed, [string] $Label) {
    if ($null -eq $Value) { throw "M15 $Label is missing." }
    $names = @($Value.PSObject.Properties.Name)
    if ($names.Count -ne $Allowed.Count -or @($names | Where-Object { $_ -cnotin $Allowed }).Count -gt 0) {
        throw "M15 $Label does not match its allowed schema fields."
    }
}
function Require-Private($Value) {
    if ($Value -is [string]) {
        foreach ($forbidden in @($env:GEORDI_M13_WEBHOOK_TOKEN_A, $env:GEORDI_M13_WEBHOOK_TOKEN_B,
                'm13-receiver-a', 'm13-receiver-b', 'http://webhook-receiver-a:8080/hook', 'http://webhook-receiver-b:8080/hook')) {
            if ($Value.Contains($forbidden)) { throw 'M15 proxy history exposed a private fixture value.' }
        }
    } elseif ($Value -is [array]) {
        foreach ($item in $Value) { Require-Private $item }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { Require-Private $property.Value }
    }
}
function Require-NoNotificationInternals($Value) {
    $forbiddenFields = @(
        'deliveryId', 'destinationId', 'destinationFingerprint', 'url', 'headers',
        'credentials', 'token', 'claimToken', 'leaseExpiresAt', 'payload', 'payloadJson',
        'responseBody', 'failure', 'error', 'exception'
    )
    if ($Value -is [array]) {
        foreach ($item in $Value) { Require-NoNotificationInternals $item }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -iin $forbiddenFields) { throw "M17 history API exposed notification internal field '$($property.Name)'." }
            Require-NoNotificationInternals $property.Value
        }
    }
}
function Require-Episode($Actual, $Expected) {
    $fields = @('id', 'policyId', 'openedAt', 'closedAt', 'origin', 'durationSeconds')
    Require-Fields $Actual $fields 'episode'
    foreach ($field in $fields) {
        if ($Actual.$field -cne $Expected.$field) { throw "M15 proxy episode mismatch in $field." }
    }
}
function Require-Notification($Actual, [string] $ExpectedDisposition, [bool] $ExpectedDelivery) {
    Require-Fields $Actual @('disposition', 'delivery') 'M17 notification'
    if ($Actual.disposition -cne $ExpectedDisposition) { throw "M17 notification disposition is '$($Actual.disposition)', expected '$ExpectedDisposition'." }
    if (!$ExpectedDelivery) {
        if ($null -ne $Actual.delivery) { throw "M17 $ExpectedDisposition notification unexpectedly exposes a delivery." }
        return
    }
    if ($null -eq $Actual.delivery) { throw 'M17 MATCHED notification does not expose its correlated delivery.' }
    Require-Fields $Actual.delivery @('state', 'attempts', 'createdAt', 'nextAttemptAt', 'completedAt') 'M17 delivery'
    if ($Actual.delivery.state -cnotin @('PENDING', 'LEASED', 'DELIVERED', 'FAILED') -or $Actual.delivery.attempts -lt 0 -or
            [string]::IsNullOrWhiteSpace($Actual.delivery.createdAt)) {
        throw 'M17 delivery projection has an invalid state, attempts, or durable timestamp.'
    }
    $terminal = $Actual.delivery.state -in @('DELIVERED', 'FAILED')
    if (($Actual.delivery.state -eq 'PENDING') -ne ($null -ne $Actual.delivery.nextAttemptAt)) {
        throw 'M17 delivery next-attempt timestamp does not match pending state.'
    }
    if ($terminal -ne ($null -ne $Actual.delivery.completedAt)) { throw 'M17 delivery completion timestamp does not match terminal state.' }
    if ($Actual.delivery.state -eq 'LEASED' -and $Actual.delivery.attempts -lt 1) { throw 'M17 leased delivery did not consume a claim.' }
    Require-Private $Actual.delivery
}
function Require-Transition($Actual, $Expected, [string] $ExpectedEpisodeId, [string] $ExpectedDisposition, [bool] $ExpectedDelivery) {
    Require-Fields $Actual @('id', 'episodeId', 'policyId', 'type', 'previousState', 'currentState', 'occurredAt', 'evaluation', 'notification') 'transition'
    if ($Actual.id -cnotmatch '^[0-9a-f]{64}$' -or $Actual.episodeId -cne $ExpectedEpisodeId) { throw 'M15 proxy transition identity is invalid.' }
    foreach ($field in @('policyId', 'type', 'previousState', 'currentState', 'occurredAt')) {
        if ($Actual.$field -cne $Expected.$field) { throw "M15 proxy transition mismatch in $field." }
    }
    $evaluationFields = @('policyId', 'policyName', 'sloId', 'condition', 'status', 'reason', 'evidence')
    Require-Fields $Actual.evaluation $evaluationFields 'evaluation'
    Require-Fields $Actual.evaluation.condition @('type', 'threshold') 'condition'
    Require-Fields $Actual.evaluation.evidence @('service', 'window', 'range', 'evaluatedAt', 'observedBurnRate') 'evidence'
    Require-Fields $Actual.evaluation.evidence.service @('namespace', 'name', 'environment') 'service'
    Require-Fields $Actual.evaluation.evidence.range @('from', 'to') 'evidence range'
    foreach ($field in @('policyId', 'policyName', 'sloId', 'status', 'reason')) {
        if ($Actual.evaluation.$field -cne $Expected.evaluation.$field) { throw "M15 proxy evaluation mismatch in $field." }
    }
    foreach ($part in @('condition', 'evidence')) {
        $fields = if ($part -eq 'condition') { @('type', 'threshold') } else { @('window', 'evaluatedAt', 'observedBurnRate') }
        foreach ($field in $fields) {
            if ($Actual.evaluation.$part.$field -cne $Expected.evaluation.$part.$field) { throw "M15 proxy $part mismatch in $field." }
        }
    }
    foreach ($part in @('service', 'range')) {
        $fields = if ($part -eq 'service') { @('namespace', 'name', 'environment') } else { @('from', 'to') }
        foreach ($field in $fields) {
            if ($Actual.evaluation.evidence.$part.$field -cne $Expected.evaluation.evidence.$part.$field) { throw "M15 proxy evidence $part mismatch in $field." }
        }
    }
    Require-Notification $Actual.notification $ExpectedDisposition $ExpectedDelivery
}
function Require-ProxyProblem([string] $Uri) {
    $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck
    if ($response.StatusCode -ne 400 -or [string]$response.Headers['Content-Type'] -notmatch '^application/problem\+json(?:\s*;|$)' -or $response.Content.Length -gt 2048) {
        throw 'M15 invalid proxy range did not return a bounded HTTP 400 Problem response.'
    }
    $problem = Read-JsonStrings $response.Content
    Require-Fields $problem @('type', 'title', 'status', 'detail', 'instance') 'Problem'
    if ($problem.status -ne 400 -or $problem.type -cne 'about:blank' -or $problem.title -cne 'Invalid alert history request' -or
            $problem.detail -cne 'Invalid alert history request' -or $problem.instance -cne '/api/alert-episodes') {
        throw 'M15 invalid proxy range returned unexpected Problem fields.'
    }
    Require-Private $problem
}
function Wait-Until([scriptblock] $Condition, [datetime] $Deadline, [string] $Message) {
    while ((Get-Date) -lt $Deadline) {
        try { if (& $Condition) { return } } catch { }
        Start-Sleep -Milliseconds 250
    }
    throw $Message
}
function Send-Traffic([string] $Path, [int] $Count) {
    $uri = "$BurnDemoBaseUrl$Path"
    1..$Count | ForEach-Object -Parallel { [void](Invoke-WebRequest -Uri $using:uri -UseBasicParsing -TimeoutSec 10 -SkipHttpErrorCheck) } -ThrottleLimit 16
}
function Apply([string] $PolicyId) { Json "$BackendBaseUrl/api/alert-policies/$PolicyId/lifecycle-evaluations" 'POST' }
function Episodes([string] $PolicyId) { @(Json "$BackendBaseUrl/api/alert-episodes?policyId=$PolicyId&limit=100").alertEpisodes }
function Transitions([string] $PolicyId) { @(Json "$BackendBaseUrl/api/alert-transitions?policyId=$PolicyId&limit=100").alertTransitions }
function Metric-Series([string] $Selector) { @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$([uri]::EscapeDataString($Selector))").data) }
function Require-Status([string] $Uri, [int] $Expected) {
    $actual = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck).StatusCode
    if ($actual -ne $Expected) { throw "Expected HTTP $Expected from '$Uri', got '$actual'." }
}
function Reset-M14Fixture([string] $Root) {
    $rendered = & docker compose --project-directory $Root config --format json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to render the M14 Compose configuration for fixture reset.' }
    $expected = @{ 'm14-alert-lifecycle-data' = 'geordi_m14-alert-lifecycle-data'; 'm14-victoriametrics-data' = 'geordi_m14-victoriametrics-data' }
    foreach ($logical in $expected.Keys) {
        if ($rendered.volumes.$logical.name -ne $expected[$logical]) { throw "Refusing reset for unexpected volume '$($rendered.volumes.$logical.name)'." }
    }
    Compose @('--project-directory', $Root, 'rm', '-sf', 'backend', 'victoriametrics', 'webhook-receiver-a', 'webhook-receiver-b') 'fixture reset preparation'
    foreach ($logical in $expected.Keys) {
        $name = $expected[$logical]; $inspection = & docker volume inspect $name 2>$null
        if ($LASTEXITCODE -eq 0) {
            $volume = @($inspection | ConvertFrom-Json)[0]
            if ($volume.Name -ne $name -or $volume.Labels.'com.docker.compose.project' -ne 'geordi' -or $volume.Labels.'com.docker.compose.volume' -ne $logical) { throw "Refusing reset for non-M14 volume '$name'." }
            & docker volume rm $name | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to remove dedicated M14 volume '$name'." }
        }
    }
}
function H2-Scalar([string] $Root, [string] $Sql) {
    $jar = Join-Path $Root 'backend/target/geordi-backend-0.1.0-SNAPSHOT.jar'
    if (!(Test-Path $jar)) { throw 'Verified backend artifact is required for M14 persistence inspection.' }
    $output = & docker run --rm --network none -e "M14_SQL=$Sql" -v "$(Join-Path $Root 'backend/target'):/verified:ro" -v 'geordi_m14-alert-lifecycle-data:/var/lib/geordi/alerts' maven:3.9.11-eclipse-temurin-21 sh -c 'mkdir -p /tmp/h2 && cd /tmp/h2 && jar xf /verified/geordi-backend-0.1.0-SNAPSHOT.jar && java -cp "BOOT-INF/lib/*" org.h2.tools.Shell -url "jdbc:h2:file:/var/lib/geordi/alerts/lifecycle;ACCESS_MODE_DATA=r" -user sa -password "" -sql "$M14_SQL"'
    if ($LASTEXITCODE -ne 0) { throw 'Read-only M14 persistence inspection failed.' }
    $match = [regex]::Matches(($output -join "`n"), '(?m)^\s*(\d+)\s*$')
    if ($match.Count -ne 1) {
        throw "M14 persistence inspection returned $($match.Count) scalar candidates for '$Sql': $($output -join ' | ')"
    }
    return [int]$match[0].Groups[1].Value
}
function H2-Execute([string] $Root, [string] $Sql) {
    $jar = Join-Path $Root 'backend/target/geordi-backend-0.1.0-SNAPSHOT.jar'
    if (!(Test-Path $jar)) { throw 'Verified backend artifact is required for M17 controlled persistence setup.' }
    & docker run --rm --network none -e "M17_SQL=$Sql" -v "$(Join-Path $Root 'backend/target'):/verified:ro" -v 'geordi_m14-alert-lifecycle-data:/var/lib/geordi/alerts' maven:3.9.11-eclipse-temurin-21 sh -c 'mkdir -p /tmp/h2 && cd /tmp/h2 && jar xf /verified/geordi-backend-0.1.0-SNAPSHOT.jar && java -cp "BOOT-INF/lib/*" org.h2.tools.Shell -url "jdbc:h2:file:/var/lib/geordi/alerts/lifecycle" -user sa -password "" -sql "$M17_SQL"' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'M17 controlled persistence setup failed.' }
}
function Require-SanitizedUnavailable([string] $Uri) {
    $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck
    if ($response.StatusCode -ne 503 -or [string]$response.Headers['Content-Type'] -notmatch '^application/problem\+json(?:\s*;|$)' -or $response.Content.Length -gt 2048) {
        throw 'M17 corrupted notification evidence did not return bounded RFC9457 HTTP 503.'
    }
    $problem = Read-JsonStrings $response.Content
    Require-Fields $problem @('type', 'title', 'status', 'detail', 'instance') 'M17 unavailable Problem'
    if ($problem.status -ne 503) { throw 'M17 unavailable Problem returned an incorrect status body.' }
    Require-Private $problem
    if (($problem | ConvertTo-Json -Compress) -match 'exception|stack|sql|payload|destination|delivery|claim|lease|token|secret|endpoint|url|error') {
        throw 'M17 unavailable Problem leaked persistence or delivery internals.'
    }
}

try {
    $root = Split-Path -Parent $PSScriptRoot
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $env:COMPOSE_FILE = (Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m14.yaml')
    Reset-M14Fixture $root
    Compose @('--project-directory', $root, 'up', '-d', '--force-recreate', 'victoriametrics', 'otel-collector', 'backend', 'frontend', 'burn-demo', 'webhook-receiver-a', 'webhook-receiver-b') 'M14 fixture startup'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M14 backend did not become ready.'
    Wait-Until { (Invoke-WebRequest -Uri "$BurnDemoBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M14 burn demo did not become ready.'
    Wait-Until { $null -ne (Json "$FrontendBaseUrl/api/alert-episodes?policyId=$RouteA&limit=50").alertEpisodes } $deadline 'M15 frontend history API proxy did not become ready.'

    Send-Traffic '/demo/error' 1
    $errorSelector = '{__name__="http.server.request.duration_count",service.name="geordi-burn-smoke-service",http.response.status_code="500"}'
    Wait-Until { (Metric-Series $errorSelector).Count -gt 0 } $deadline 'M14 controlled error baseline was not persisted.'
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$RouteA/evaluation").status -eq 'CONDITION_MET' } $deadline 'M14 route-A condition did not become met.'

    $started = Apply $RouteA
    if ($started.transition.type -ne 'ALERT_STARTED') { throw 'M14 route A did not create ALERT_STARTED.' }
    $episode = Episodes $RouteA
    if ($episode.Count -ne 1 -or $episode[0].origin -ne 'M14' -or [string]::IsNullOrWhiteSpace($episode[0].openedAt) -or $null -ne $episode[0].closedAt) { throw 'M14 normal open episode projection is invalid.' }
    $episodeId = $episode[0].id
    if ((Transitions $RouteA).Count -ne 1) { throw 'M14 normal STARTED transition was not persisted exactly once.' }
    $ackActor = 'm16-smoke-actor'
    $ackReason = 'm16 bounded smoke acknowledgement'
    $ack = Post-Json "$FrontendBaseUrl/api/alert-episodes/$episodeId/acknowledgements" @{ actor = $ackActor; reason = $ackReason }
    if ($ack.StatusCode -ne 201 -or $ack.Body.actor -cne $ackActor -or $ack.Body.reason -cne $ackReason -or [string]::IsNullOrWhiteSpace($ack.Body.acknowledgedAt)) { throw 'M16 acknowledgement did not return HTTP 201 with persisted fields.' }
    $ackAt = $ack.Body.acknowledgedAt
    $ackReplay = Post-Json "$FrontendBaseUrl/api/alert-episodes/$episodeId/acknowledgements" @{ actor = "  $ackActor  "; reason = "  $ackReason  " }
    if ($ackReplay.StatusCode -ne 200 -or $ackReplay.Body.acknowledgedAt -cne $ackAt) { throw 'M16 exact acknowledgement replay did not preserve acknowledgedAt.' }
    $ackDetail = Json "$FrontendBaseUrl/api/alert-episodes/$episodeId"
    Require-Fields $ackDetail @('episode', 'acknowledgement', 'transitions') 'M16 acknowledged detail envelope'
    if ($ackDetail.acknowledgement.actor -cne $ackActor -or $ackDetail.acknowledgement.acknowledgedAt -cne $ackAt) { throw 'M16 acknowledgement detail mismatch.' }
    if (@($ackDetail.transitions).Count -ne 1) { throw 'M17 open episode did not contain its single transition.' }
    Require-Transition $ackDetail.transitions[0] $started.transition $episodeId 'MATCHED' $true
    $startedTransitionId = $ackDetail.transitions[0].id
    $retry = Apply $RouteA
    if ($null -ne $retry.transition -or (Episodes $RouteA).Count -ne 1 -or (Transitions $RouteA).Count -ne 1) { throw 'M14 no-transition reevaluation changed history.' }

    Compose @('--project-directory', $root, 'restart', 'backend') 'backend restart'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M14 backend did not recover after restart.'
    if ((Episodes $RouteA)[0].id -ne $episodeId -or (Transitions $RouteA).Count -ne 1) { throw 'M14 restart changed normal history identity.' }
    $restartOpenDetail = Json "$BackendBaseUrl/api/alert-episodes/$episodeId"
    Require-Transition $restartOpenDetail.transitions[0] $started.transition $episodeId 'MATCHED' $true

    $suppressedStarted = Apply $Suppressed
    $unroutedStarted = Apply $Unrouted
    if ($suppressedStarted.transition.type -ne 'ALERT_STARTED' -or $unroutedStarted.transition.type -ne 'ALERT_STARTED') { throw 'M14 suppressed or unrouted lifecycle did not start.' }
    if ((Episodes $Suppressed).Count -ne 1 -or (Episodes $Unrouted).Count -ne 1) { throw 'M14 routing outcome incorrectly prevented history persistence.' }
    $suppressedEpisodeId = (Episodes $Suppressed)[0].id
    $unroutedEpisodeId = (Episodes $Unrouted)[0].id
    $suppressedDetail = Json "$BackendBaseUrl/api/alert-episodes/$suppressedEpisodeId"
    $unroutedDetail = Json "$BackendBaseUrl/api/alert-episodes/$unroutedEpisodeId"
    Require-Transition $suppressedDetail.transitions[0] $suppressedStarted.transition $suppressedEpisodeId 'SUPPRESSED' $false
    Require-Transition $unroutedDetail.transitions[0] $unroutedStarted.transition $unroutedEpisodeId 'UNROUTED' $false

    Send-Traffic '/demo/success' 2000
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$RouteA/evaluation").status -eq 'CONDITION_NOT_MET' } $deadline 'M14 route-A condition did not recover.'
    $resolved = Apply $RouteA
    if ($resolved.transition.type -ne 'ALERT_RESOLVED') { throw 'M14 route A did not create ALERT_RESOLVED.' }
    $closed = (Episodes $RouteA)
    if ($closed.Count -ne 1 -or $closed[0].id -ne $episodeId -or [string]::IsNullOrWhiteSpace($closed[0].closedAt) -or (Transitions $RouteA).Count -ne 2) { throw 'M14 normal resolution did not close the same episode exactly once.' }
    if ((Apply $RouteA).transition) { throw 'M14 repeated resolution created a transition.' }

    Wait-Until {
        $deliveryDetail = Json "$BackendBaseUrl/api/alert-episodes/$episodeId"
        @($deliveryDetail.transitions | Where-Object { $_.notification.disposition -eq 'MATCHED' -and $_.notification.delivery.state -eq 'DELIVERED' }).Count -eq 2
    } $deadline 'M17 deterministic receiver did not persist both matched deliveries as DELIVERED.'

    # Scope the limit checks so a 400 proves the limit boundary, not an unbounded-query error.
    if ((Episodes $RouteA).Count -gt 100) { throw 'M14 episode default result bound was exceeded.' }
    if ((Transitions $RouteA).Count -gt 200) { throw 'M14 transition default result bound was exceeded.' }
    Require-Status "$BackendBaseUrl/api/alert-episodes?policyId=$RouteA&limit=101" 400
    Require-Status "$BackendBaseUrl/api/alert-transitions?policyId=$RouteA&limit=201" 400
    Require-Status "$BackendBaseUrl/api/alert-episodes?policyId=$RouteA&from=2026-01-01T00:00:00Z" 400
    Require-Status "$BackendBaseUrl/api/alert-transitions?policyId=$RouteA&from=2026-01-01T00:00:00Z&to=2026-01-01T00:00:00Z" 400
    $detail = Json "$BackendBaseUrl/api/alert-episodes/$episodeId"
    Require-NoNotificationInternals $detail
    $startedNotificationTransitions = @($detail.transitions | Where-Object { $_.id -eq $startedTransitionId })
    if ($startedNotificationTransitions.Count -ne 1) {
        $actualTransitionIds = @($detail.transitions | ForEach-Object { $_.id }) -join ', '
        throw "M17 canonical detail did not contain exactly one started transition '$startedTransitionId'; found '$actualTransitionIds'."
    }
    $stableNotification = $startedNotificationTransitions[0].notification | ConvertTo-Json -Depth 8 -Compress
    $resolvedNotificationTransitions = @($detail.transitions | Where-Object { $_.type -eq 'ALERT_RESOLVED' })
    if ($resolvedNotificationTransitions.Count -ne 1) { throw 'M17 canonical detail did not contain exactly one resolved transition.' }
    $resolvedTransitionId = $resolvedNotificationTransitions[0].id

    # Round only separately derived enclosing bounds, never the canonical expected timestamps.
    $from = ([datetimeoffset]::Parse($closed[0].openedAt)).AddMinutes(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $to = ([datetimeoffset]::Parse($closed[0].closedAt)).AddMinutes(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $query = "policyId=$([uri]::EscapeDataString($RouteA))&from=$([uri]::EscapeDataString($from))&to=$([uri]::EscapeDataString($to))&limit=50"
    $proxyList = Json "$FrontendBaseUrl/api/alert-episodes?$query"
    Require-Fields $proxyList @('alertEpisodes') 'list envelope'
    Require-Private $proxyList
    if (@($proxyList.alertEpisodes).Count -ne 1) { throw 'M15 bounded proxy list did not contain the single fixture episode.' }
    Require-Episode $proxyList.alertEpisodes[0] $closed[0]
    $proxyDetail = Json "$FrontendBaseUrl/api/alert-episodes/$episodeId"
    Require-Fields $proxyDetail @('episode', 'acknowledgement', 'transitions') 'detail envelope'
    Require-Private $proxyDetail
    Require-Episode $proxyDetail.episode $closed[0]
    if (@($proxyDetail.transitions).Count -ne 2) { throw 'M15 proxy detail did not contain both fixture transitions.' }
    Require-Transition $proxyDetail.transitions[0] $resolved.transition $episodeId 'MATCHED' $true
    Require-Transition $proxyDetail.transitions[1] $started.transition $episodeId 'MATCHED' $true
    if ($proxyDetail.acknowledgement.acknowledgedAt -cne $ackAt) { throw 'M16 acknowledgement was not durable through proxy.' }
    for ($index = 0; $index -lt 2; $index++) {
        if ($proxyDetail.transitions[$index].id -cne $detail.transitions[$index].id) { throw 'M15 proxy transition ID differs from canonical history.' }
    }
    Require-ProxyProblem "$FrontendBaseUrl/api/alert-episodes?policyId=$RouteA&from=$([uri]::EscapeDataString($from))&to=$([uri]::EscapeDataString($from))&limit=50"
    Require-ProxyProblem "$FrontendBaseUrl/api/alert-episodes?policyId=$RouteA&from=$([uri]::EscapeDataString($to))&to=$([uri]::EscapeDataString($from))&limit=50"
    Write-Host 'PASS: M15 deployed frontend/API proxy verified bounded real M14 episode list/detail, exact canonical evidence, schema privacy, and RFC9457 range errors.'

    Compose @('--project-directory', $root, 'stop', 'backend') 'history persistence inspection stop'
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_episode WHERE policy_id = '$RouteA' AND opened_at IS NOT NULL AND closed_at IS NOT NULL") -ne 1) { throw 'M14 normal durable episode row is missing.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_transition_history WHERE policy_id = '$RouteA'") -ne 2) { throw 'M14 normal durable transitions are missing.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM `"flyway_schema_history`" WHERE `"version`" = '7' AND `"success`" = TRUE") -ne 1) { throw 'M17 V7 migration was not recorded exactly once.' }
    if ((H2-Scalar $root 'SELECT COUNT(*) FROM alert_notification_disposition') -ne 4) { throw 'M17 clean V1-to-V7 migration or transition commits produced an unexpected disposition backfill.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_disposition WHERE disposition = 'MATCHED'") -ne 2 -or
            (H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_disposition WHERE disposition = 'SUPPRESSED'") -ne 1 -or
            (H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_disposition WHERE disposition = 'UNROUTED'") -ne 1) { throw 'M17 durable disposition rows do not match committed routing outcomes.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_outbox WHERE policy_id = '$RouteA'") -ne 2) { throw 'M17 MATCHED transitions did not retain exactly one correlated delivery each.' }
    $secrets = @($env:GEORDI_M13_WEBHOOK_TOKEN_A, $env:GEORDI_M13_WEBHOOK_TOKEN_B)
    foreach ($secret in $secrets) { if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_transition_history WHERE POSITION('$($secret.Replace("'", "''"))' IN transition_json) > 0") -ne 0) { throw 'M14 transition history persisted a fixture secret.' } }
    Compose @('--project-directory', $root, 'start', 'backend') 'post-inspection backend start'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M14 backend did not recover after persistence inspection.'

    foreach ($metric in @('geordi.alert.history.episodes', 'geordi.alert.history.persistence')) {
        Wait-Until { (Metric-Series "{__name__=`"$metric`"}").Count -gt 0 } $deadline "M14 history metric '$metric' was not persisted."
    }
    $postClose = Post-Json "$FrontendBaseUrl/api/alert-episodes/$episodeId/acknowledgements" @{ actor = $ackActor; reason = $ackReason }
    if ($postClose.StatusCode -ne 409 -or $postClose.ContentType -notmatch 'application/problem\+json') { throw 'M16 post-close acknowledgement did not return RFC9457 409.' }
    $postCloseDetail = Json "$FrontendBaseUrl/api/alert-episodes/$episodeId"
    if ($postCloseDetail.acknowledgement.acknowledgedAt -cne $ackAt) { throw 'M16 post-close conflict changed acknowledgement.' }
    $postCloseNotification = ($postCloseDetail.transitions | Where-Object { $_.id -eq $startedTransitionId })[0].notification | ConvertTo-Json -Depth 8 -Compress
    if ($postCloseNotification -cne $stableNotification) { throw 'M17 acknowledgement changed notification disposition or delivery evidence.' }

    # This existing isolated H2 fixture permits a minimal legacy/corruption setup without a second delivery framework.
    Compose @('--project-directory', $root, 'stop', 'backend') 'M17 legacy evidence setup stop'
    H2-Execute $root "DELETE FROM alert_notification_disposition WHERE transition_id IN ('$startedTransitionId', '$($suppressedDetail.transitions[0].id)')"
    Compose @('--project-directory', $root, 'start', 'backend') 'M17 legacy evidence setup start'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M17 backend did not recover for legacy evidence.'
    $legacyCorrelated = Json "$BackendBaseUrl/api/alert-episodes/$episodeId"
    Require-Transition ($legacyCorrelated.transitions | Where-Object { $_.id -eq $startedTransitionId })[0] $started.transition $episodeId 'NOT_RECORDED' $true
    $legacyWithoutDelivery = Json "$BackendBaseUrl/api/alert-episodes/$suppressedEpisodeId"
    Require-Transition $legacyWithoutDelivery.transitions[0] $suppressedStarted.transition $suppressedEpisodeId 'NOT_RECORDED' $false

    Compose @('--project-directory', $root, 'stop', 'backend') 'M17 integrity evidence setup stop'
    H2-Execute $root "DELETE FROM alert_notification_outbox WHERE delivery_id = '$resolvedTransitionId'"
    Compose @('--project-directory', $root, 'start', 'backend') 'M17 integrity evidence setup start'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M17 backend did not recover for integrity evidence.'
    Require-SanitizedUnavailable "$BackendBaseUrl/api/alert-episodes/$episodeId"
    Write-Host 'PASS: M17 clean V7 migration, MATCHED/SUPPRESSED/UNROUTED evidence, deterministic DELIVERED durability, privacy, acknowledgement independence, legacy NOT_RECORDED projection, and sanitized integrity failure verified. Populated V6-to-V7 preservation/no-backfill is covered by the dedicated migration integration suite. FAILED is not asserted because this fixture has no deterministic failing receiver.'
    Write-Host 'PASS: M16 episode acknowledgement creation, replay, restart durability, post-close conflict, and isolation verified.'
    Write-Host 'PASS: M14 isolated normal history, retry/restart stability, routing independence, bounded/privacy-safe API, durable persistence, and history telemetry verified.'
} catch {
    Write-Error "Alert history smoke failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    exit 1
} finally {
    if ($root) {
        & docker compose --project-directory $root down --volumes --remove-orphans | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not clean up the isolated M14 Compose fixture.' }
    }
}
