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
function Require-Episode($Actual, $Expected) {
    $fields = @('id', 'policyId', 'openedAt', 'closedAt', 'origin', 'durationSeconds')
    Require-Fields $Actual $fields 'episode'
    foreach ($field in $fields) {
        if ($Actual.$field -cne $Expected.$field) { throw "M15 proxy episode mismatch in $field." }
    }
}
function Require-Transition($Actual, $Expected, [string] $ExpectedEpisodeId) {
    Require-Fields $Actual @('id', 'episodeId', 'policyId', 'type', 'previousState', 'currentState', 'occurredAt', 'evaluation') 'transition'
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
    if ($match.Count -ne 1) { throw 'M14 persistence inspection returned an ambiguous scalar result.' }
    return [int]$match[0].Groups[1].Value
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
    $retry = Apply $RouteA
    if ($null -ne $retry.transition -or (Episodes $RouteA).Count -ne 1 -or (Transitions $RouteA).Count -ne 1) { throw 'M14 no-transition reevaluation changed history.' }

    Compose @('--project-directory', $root, 'restart', 'backend') 'backend restart'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M14 backend did not recover after restart.'
    if ((Episodes $RouteA)[0].id -ne $episodeId -or (Transitions $RouteA).Count -ne 1) { throw 'M14 restart changed normal history identity.' }

    $suppressedStarted = Apply $Suppressed
    $unroutedStarted = Apply $Unrouted
    if ($suppressedStarted.transition.type -ne 'ALERT_STARTED' -or $unroutedStarted.transition.type -ne 'ALERT_STARTED') { throw 'M14 suppressed or unrouted lifecycle did not start.' }
    if ((Episodes $Suppressed).Count -ne 1 -or (Episodes $Unrouted).Count -ne 1) { throw 'M14 routing outcome incorrectly prevented history persistence.' }

    Send-Traffic '/demo/success' 2000
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$RouteA/evaluation").status -eq 'CONDITION_NOT_MET' } $deadline 'M14 route-A condition did not recover.'
    $resolved = Apply $RouteA
    if ($resolved.transition.type -ne 'ALERT_RESOLVED') { throw 'M14 route A did not create ALERT_RESOLVED.' }
    $closed = (Episodes $RouteA)
    if ($closed.Count -ne 1 -or $closed[0].id -ne $episodeId -or [string]::IsNullOrWhiteSpace($closed[0].closedAt) -or (Transitions $RouteA).Count -ne 2) { throw 'M14 normal resolution did not close the same episode exactly once.' }
    if ((Apply $RouteA).transition) { throw 'M14 repeated resolution created a transition.' }

    # Scope the limit checks so a 400 proves the limit boundary, not an unbounded-query error.
    if ((Episodes $RouteA).Count -gt 100) { throw 'M14 episode default result bound was exceeded.' }
    if ((Transitions $RouteA).Count -gt 200) { throw 'M14 transition default result bound was exceeded.' }
    Require-Status "$BackendBaseUrl/api/alert-episodes?policyId=$RouteA&limit=101" 400
    Require-Status "$BackendBaseUrl/api/alert-transitions?policyId=$RouteA&limit=201" 400
    Require-Status "$BackendBaseUrl/api/alert-episodes?policyId=$RouteA&from=2026-01-01T00:00:00Z" 400
    Require-Status "$BackendBaseUrl/api/alert-transitions?policyId=$RouteA&from=2026-01-01T00:00:00Z&to=2026-01-01T00:00:00Z" 400
    $detail = Json "$BackendBaseUrl/api/alert-episodes/$episodeId"
    $serialized = $detail | ConvertTo-Json -Depth 20 -Compress
    if ($serialized -match 'destination|delivery|token|secret|endpoint|url') { throw 'M14 history API exposed routing or delivery fields.' }

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
    Require-Fields $proxyDetail @('episode', 'transitions') 'detail envelope'
    Require-Private $proxyDetail
    Require-Episode $proxyDetail.episode $closed[0]
    if (@($proxyDetail.transitions).Count -ne 2) { throw 'M15 proxy detail did not contain both fixture transitions.' }
    Require-Transition $proxyDetail.transitions[0] $resolved.transition $episodeId
    Require-Transition $proxyDetail.transitions[1] $started.transition $episodeId
    for ($index = 0; $index -lt 2; $index++) {
        if ($proxyDetail.transitions[$index].id -cne $detail.transitions[$index].id) { throw 'M15 proxy transition ID differs from canonical history.' }
    }
    Require-ProxyProblem "$FrontendBaseUrl/api/alert-episodes?policyId=$RouteA&from=$([uri]::EscapeDataString($from))&to=$([uri]::EscapeDataString($from))&limit=50"
    Require-ProxyProblem "$FrontendBaseUrl/api/alert-episodes?policyId=$RouteA&from=$([uri]::EscapeDataString($to))&to=$([uri]::EscapeDataString($from))&limit=50"
    Write-Host 'PASS: M15 deployed frontend/API proxy verified bounded real M14 episode list/detail, exact canonical evidence, schema privacy, and RFC9457 range errors.'

    Compose @('--project-directory', $root, 'stop', 'backend') 'history persistence inspection stop'
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_episode WHERE policy_id = '$RouteA' AND opened_at IS NOT NULL AND closed_at IS NOT NULL") -ne 1) { throw 'M14 normal durable episode row is missing.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_transition_history WHERE policy_id = '$RouteA'") -ne 2) { throw 'M14 normal durable transitions are missing.' }
    $secrets = @($env:GEORDI_M13_WEBHOOK_TOKEN_A, $env:GEORDI_M13_WEBHOOK_TOKEN_B)
    foreach ($secret in $secrets) { if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_transition_history WHERE POSITION('$($secret.Replace("'", "''"))' IN transition_json) > 0") -ne 0) { throw 'M14 transition history persisted a fixture secret.' } }
    Compose @('--project-directory', $root, 'start', 'backend') 'post-inspection backend start'
    Wait-Until { (Invoke-WebRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M14 backend did not recover after persistence inspection.'

    foreach ($metric in @('geordi.alert.history.episodes', 'geordi.alert.history.persistence')) {
        Wait-Until { (Metric-Series "{__name__=`"$metric`"}").Count -gt 0 } $deadline "M14 history metric '$metric' was not persisted."
    }
    Write-Host 'PASS: M14 isolated normal history, retry/restart stability, routing independence, bounded/privacy-safe API, durable persistence, and history telemetry verified.'
} catch {
    Write-Error "Alert history smoke failed: $($_.Exception.Message)"
    exit 1
} finally {
    if ($root) {
        & docker compose --project-directory $root down --volumes --remove-orphans | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not clean up the isolated M14 Compose fixture.' }
    }
}
