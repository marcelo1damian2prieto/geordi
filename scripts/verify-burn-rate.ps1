[CmdletBinding()]
param(
    [ValidateRange(30, 300)]
    [int] $TimeoutSeconds = 180,

    [ValidateRange(2, 50)]
    [int] $RequestCount = 4,

    [switch] $ExerciseProviderFailure,

    [string] $BackendBaseUrl = "http://127.0.0.1:8080",
    [string] $BurnDemoBaseUrl = "http://127.0.0.1:8083",
    [string] $DemoBaseUrl = "http://127.0.0.1:8081",
    [string] $VictoriaMetricsBaseUrl = "http://127.0.0.1:8428",
    [string] $FrontendBaseUrl = "http://127.0.0.1:3000"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$BurnSloId = "burn-smoke-error-rate"
$ZeroBudgetSloId = "demo-error-rate"
$NoTrafficSloId = "no-traffic-availability"
$LegacyAvailabilitySloId = "demo-downstream-availability"
$BurnIdentity = [ordered]@{ name = "geordi-burn-smoke-service"; namespace = "geordi-burn-smoke"; environment = "development" }
$ProviderSyntaxPattern = 'promql|metricsql|victoriametrics|http\.server\.request|__name__|increase\s*\(|rate\s*\('

function Invoke-TextRequest {
    param([Parameter(Mandatory)][string] $Uri, [int] $RequestTimeoutSeconds = 8)
    $response = Invoke-WebRequest -Uri $Uri -TimeoutSec $RequestTimeoutSeconds -UseBasicParsing
    if ($response.StatusCode -ne 200) { throw "GET $Uri returned HTTP $($response.StatusCode)." }
    return [string] $response.Content
}

function Wait-ForHttp200 {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Uri, [Parameter(Mandatory)][datetime] $Deadline)
    while ((Get-Date) -lt $Deadline) {
        try { [void](Invoke-TextRequest $Uri); return } catch { Start-Sleep -Seconds 1 }
    }
    throw "Timed out waiting for $Name at $Uri."
}

function Get-Evaluation {
    param([Parameter(Mandatory)][string] $SloId)
    Invoke-TextRequest "$BackendBaseUrl/api/slos/$SloId/evaluation" -RequestTimeoutSeconds 15 | ConvertFrom-Json
}

function Assert-Identity {
    param([Parameter(Mandatory)] $Actual, [Parameter(Mandatory)] $Expected, [Parameter(Mandatory)][string] $Context)
    if ($Actual.name -ne $Expected.name -or $Actual.namespace -ne $Expected.namespace -or $Actual.environment -ne $Expected.environment) {
        throw "$Context returned '$($Actual.namespace)/$($Actual.name)/$($Actual.environment)', expected '$($Expected.namespace)/$($Expected.name)/$($Expected.environment)'."
    }
}

function Assert-NoProviderSyntax {
    param([Parameter(Mandatory)] $Payload, [Parameter(Mandatory)][string] $Context)
    if (($Payload | ConvertTo-Json -Depth 20 -Compress) -match $ProviderSyntaxPattern) { throw "$Context leaked provider syntax or metric names." }
}

function ConvertTo-ProviderLabelValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n')
}

function ConvertTo-ExclusiveProviderTime {
    param([Parameter(Mandatory)][string] $Timestamp)
    $parsed = [DateTimeOffset]$Timestamp
    $fractionNanoseconds = 0
    if ($Timestamp -match '\.(\d{1,9})(?:Z|[+-]\d{2}:\d{2})$') {
        $fractionNanoseconds = [int]$Matches[1].PadRight(9, '0')
    }
    $epochSeconds = [decimal]$parsed.ToUnixTimeSeconds()
    $exclusive = $epochSeconds + ([decimal]$fractionNanoseconds / [decimal]1000000000) - [decimal]0.000000001
    return $exclusive.ToString('0.000000000', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-VictoriaScalar {
    param([Parameter(Mandatory)][string] $Expression, [Parameter(Mandatory)][string] $EvaluationTime)
    $query = [uri]::EscapeDataString($Expression)
    $time = [uri]::EscapeDataString($EvaluationTime)
    $payload = Invoke-TextRequest "$VictoriaMetricsBaseUrl/api/v1/query?query=$query&time=$time" | ConvertFrom-Json
    if ($payload.status -ne "success") { throw "VictoriaMetrics did not report success for independent burn evidence." }
    $results = @($payload.data.result)
    if ($results.Count -eq 0) { return @{ present = $false; value = $null } }
    if ($results.Count -ne 1) { throw "Independent burn query returned $($results.Count) series, expected exactly one." }
    $value = [double]$results[0].value[1]
    if (-not [double]::IsFinite($value)) { throw "Independent burn query returned a non-finite value." }
    @{ present = $true; value = $value }
}

function Assert-IndependentBurnFormula {
    param([Parameter(Mandatory)] $Evaluation, [Parameter(Mandatory)][double] $ExpectedMinimumBurn)
    Assert-Identity $Evaluation.service $BurnIdentity "Burn evaluation"
    if ($Evaluation.sloId -ne $BurnSloId -or $Evaluation.sliType -ne "ERROR_RATE" -or [double]$Evaluation.target -ne 0.10 -or $Evaluation.window -ne "PT5M") { throw "Burn evaluation did not preserve its finite error-rate definition." }
    $from = ([DateTimeOffset]$Evaluation.range.from).ToUniversalTime()
    $to = ([DateTimeOffset]$Evaluation.range.to).ToUniversalTime()
    $evaluatedAt = ([DateTimeOffset]$Evaluation.evaluatedAt).ToUniversalTime()
    if ($to -ne $evaluatedAt -or ($to - $from) -ne [TimeSpan]::FromMinutes(5)) { throw "Burn evaluation did not return one exact PT5M range ending at evaluatedAt." }
    $burn = $Evaluation.burnRateEvaluation
    if ($burn.status -ne "AVAILABLE" -or $burn.reason -ne $null -or [double]$burn.allowedBadRatio -ne 0.10) { throw "Finite error-rate burn evidence did not expose the canonical allowed bad ratio." }
    foreach ($value in @($burn.observedBadRatio, $burn.burnRate)) { if (-not [double]::IsFinite([double]$value)) { throw "Burn API exposed a non-finite number." } }
    $service = ConvertTo-ProviderLabelValue ([string]$Evaluation.service.name)
    $namespace = ConvertTo-ProviderLabelValue ([string]$Evaluation.service.namespace)
    $environment = ConvertTo-ProviderLabelValue ([string]$Evaluation.service.environment)
    $selectors = '"geordi.telemetry.origin"="monitored","service.name"="' + $service + '","service.namespace"="' + $namespace + '","deployment.environment.name"="' + $environment + '"'
    $windowSeconds = [long](($to - $from).TotalSeconds)
    $all = '{__name__="http.server.request.duration_count",' + $selectors + '}'
    $errors = '{__name__="http.server.request.duration_count",' + $selectors + ',"http.response.status_code"=~"5.."}'
    # Match the adapter's exact `to - 1ns` instant so the independent range is [from,to).
    $queryAt = ConvertTo-ExclusiveProviderTime ([string]$Evaluation.range.to)
    $requestExpression = "sum(increase($all`[$windowSeconds" + "s]))"
    $errorExpression = "sum(increase($errors`[$windowSeconds" + "s]))"
    $requests = Get-VictoriaScalar -Expression $requestExpression -EvaluationTime $queryAt
    $bad = Get-VictoriaScalar -Expression $errorExpression -EvaluationTime $queryAt
    if (-not $requests.present -or $requests.value -le 0) { throw "Independent burn request count was absent or non-positive." }
    $errorCount = if ($bad.present) { [double]$bad.value } else { 0.0 }
    $observed = $errorCount / [double]$requests.value
    $expectedBurn = $observed / 0.10
    $tolerance = 0.000001
    if ([Math]::Abs([double]$burn.observedBadRatio - $observed) -gt $tolerance -or [Math]::Abs([double]$burn.burnRate - $expectedBurn) -gt $tolerance) { throw "Burn API does not match independently recomputed exact-window evidence." }
    if ([double]$burn.burnRate -lt $ExpectedMinimumBurn) { throw "Burn rate $($burn.burnRate) was below required minimum $ExpectedMinimumBurn." }
    Assert-NoProviderSyntax $Evaluation "Burn evaluation"
}

function Wait-ForVerifiedBurn {
    param(
        [Parameter(Mandatory)][scriptblock] $Predicate,
        [Parameter(Mandatory)][double] $ExpectedMinimumBurn,
        [Parameter(Mandatory)][datetime] $Deadline,
        [Parameter(Mandatory)][string] $Expected
    )

    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $evaluation = Get-Evaluation $BurnSloId
            if (-not (& $Predicate $evaluation)) {
                $burn = $evaluation.burnRateEvaluation
                throw "SLO=$($evaluation.status)/$($evaluation.reason), burn=$($burn.status)/$($burn.reason)/$($burn.burnRate)"
            }
            Assert-IndependentBurnFormula $evaluation $ExpectedMinimumBurn
            return $evaluation
        }
        catch {
            $lastFailure = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "Timed out waiting for verified ${Expected}: $lastFailure"
}

function Assert-InvestigationContext {
    param([Parameter(Mandatory)] $Evaluation)
    $query = "serviceName=$([uri]::EscapeDataString($Evaluation.service.name))&serviceNamespace=$([uri]::EscapeDataString($Evaluation.service.namespace))&environment=$([uri]::EscapeDataString($Evaluation.service.environment))&from=$([uri]::EscapeDataString($Evaluation.range.from))&to=$([uri]::EscapeDataString($Evaluation.range.to))"
    $html = Invoke-TextRequest "$FrontendBaseUrl/investigate?$query"
    if ($html -notmatch '<title>Geordi Platform</title>') { throw "Frontend did not accept exact Burn Investigation context." }
    $metrics = Invoke-TextRequest "$FrontendBaseUrl/api/metrics/series?$query&metric=HTTP_REQUEST_COUNT" | ConvertFrom-Json
    Assert-Identity $metrics.service $Evaluation.service "Burn Investigation proxy"
    if ($metrics.range.from -ne $Evaluation.range.from -or $metrics.range.to -ne $Evaluation.range.to) { throw "Burn Investigation proxy did not preserve the exact evaluation range." }
}

function Assert-BurnTelemetry {
    param([Parameter(Mandatory)][datetime] $Deadline)
    $lastFailure = $null
    while ((Get-Date) -lt $Deadline) {
        try {
            $from = [uri]::EscapeDataString((Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o'))
            $to = [uri]::EscapeDataString((Get-Date).ToUniversalTime().ToString('o'))
            $selector = [uri]::EscapeDataString('{__name__="geordi.slo.burn.results"}')
            $series = @((Invoke-TextRequest "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$selector&start=$from&end=$to" | ConvertFrom-Json).data)
            if ($series.Count -eq 0) { throw "Burn self-observability metric is not stored yet." }
            foreach ($item in $series) {
                $custom = @($item.PSObject.Properties.Name | Where-Object { $_ -like 'geordi.slo.*' })
                if (@($custom | Where-Object { $_ -notin @('geordi.slo.burn.status', 'geordi.slo.sli_type', 'geordi.slo.burn.reason') }).Count -gt 0) { throw "Burn self-observability exposed an unsupported custom label." }
                if ($null -eq $item.'geordi.slo.burn.status' -or $null -eq $item.'geordi.slo.sli_type') { throw "Burn self-observability omitted required bounded labels." }
                foreach ($property in $item.PSObject.Properties) {
                    if ([string]$property.Value -in @($BurnSloId, $BurnIdentity.name, $BurnIdentity.namespace) -or [string]$property.Value -match $ProviderSyntaxPattern) { throw "Burn self-observability leaked high-cardinality or provider context." }
                }
            }
            $statuses = @($series | ForEach-Object { [string]$_.'geordi.slo.burn.status' } | Sort-Object -Unique)
            if (@('available', 'unavailable') | Where-Object { $_ -notin $statuses }) { throw "Burn self-observability did not preserve AVAILABLE and UNAVAILABLE outcomes." }
            return
        } catch { $lastFailure = $_.Exception.Message; Start-Sleep -Seconds 2 }
    }
    throw "Timed out waiting for bounded burn self-observability: $lastFailure"
}

function Assert-ProviderFailure {
    $root = Split-Path -Parent $PSScriptRoot; $compose = Join-Path $root 'compose.yaml'; $stopped = $false
    try {
        & docker compose --project-directory $root --file $compose stop victoriametrics
        if ($LASTEXITCODE -ne 0) { throw "Could not stop VictoriaMetrics for burn provider-failure scenario." }
        $stopped = $true
        $burn = Get-Evaluation $BurnSloId; $legacy = Get-Evaluation $LegacyAvailabilitySloId
        if ($burn.status -ne 'UNAVAILABLE' -or $burn.reason -ne 'METRICS_UNAVAILABLE' -or $burn.burnRateEvaluation.status -ne 'UNAVAILABLE' -or $burn.burnRateEvaluation.reason -ne 'METRICS_UNAVAILABLE' -or $null -ne $burn.burnRateEvaluation.burnRate) { throw "Burn provider failure was not explicitly unavailable." }
        if ($legacy.status -ne 'UNAVAILABLE' -or $legacy.reason -ne 'METRICS_UNAVAILABLE' -or $null -ne $legacy.observedValue) { throw "Legacy SLO provider failure regression was not explicitly unavailable." }
    } finally {
        if ($stopped) {
            & docker compose --project-directory $root --file $compose start victoriametrics
            if ($LASTEXITCODE -ne 0) { throw "Could not restart VictoriaMetrics after burn provider-failure scenario." }
            $recoveryDeadline = (Get-Date).AddSeconds(60)
            Wait-ForHttp200 'VictoriaMetrics after burn provider-failure scenario' "$VictoriaMetricsBaseUrl/health" $recoveryDeadline
            $recovered = Wait-ForVerifiedBurn { param($e) $e.burnRateEvaluation.status -eq 'AVAILABLE' -and [double]$e.burnRateEvaluation.burnRate -gt 1.0 } 1.0 $recoveryDeadline 'Burn evaluation recovery after provider restart'
        }
    }
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 'backend readiness' "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 'isolated burn demo readiness' "$BurnDemoBaseUrl/actuator/health/readiness" $deadline
    1..$RequestCount | ForEach-Object { [void](Invoke-TextRequest "$BurnDemoBaseUrl/demo/success") }
    Start-Sleep -Seconds 6
    $zero = Wait-ForVerifiedBurn { param($e) $e.burnRateEvaluation.status -eq 'AVAILABLE' -and [double]$e.burnRateEvaluation.burnRate -eq 0.0 } 0.0 $deadline 'valid zero burn'
    # Span two export cycles so VictoriaMetrics observes a counter increase rather than
    # only the first stored sample of a newly created 5xx series.
    1..$RequestCount | ForEach-Object { $response = Invoke-WebRequest -Uri "$BurnDemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck; if ($response.StatusCode -ne 500) { throw "Controlled burn error returned HTTP $($response.StatusCode), expected 500." } }
    Start-Sleep -Seconds 6
    1..$RequestCount | ForEach-Object { $response = Invoke-WebRequest -Uri "$BurnDemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck; if ($response.StatusCode -ne 500) { throw "Controlled burn error returned HTTP $($response.StatusCode), expected 500." } }
    Start-Sleep -Seconds 6
    $elevated = Wait-ForVerifiedBurn { param($e) $e.burnRateEvaluation.status -eq 'AVAILABLE' -and [double]$e.burnRateEvaluation.burnRate -gt 1.0 } 1.0 $deadline 'controlled burn above one'
    Assert-InvestigationContext $elevated
    [void](Invoke-WebRequest -Uri "$DemoBaseUrl/demo/error" -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck)
    $zeroBudget = $null
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-Evaluation $ZeroBudgetSloId
        if ($candidate.burnRateEvaluation.reason -eq 'ZERO_ALLOWED_BAD_RATIO') { $zeroBudget = $candidate; break }
        Start-Sleep -Seconds 2
    }
    if ($null -eq $zeroBudget) { throw "Timed out waiting for valid zero-budget objective evidence." }
    if ($zeroBudget.burnRateEvaluation.status -ne 'UNAVAILABLE' -or $zeroBudget.burnRateEvaluation.reason -ne 'ZERO_ALLOWED_BAD_RATIO' -or $null -ne $zeroBudget.burnRateEvaluation.burnRate) { throw "Zero-budget objective did not expose safe unavailable burn semantics." }
    $noTraffic = Get-Evaluation $NoTrafficSloId
    if ($noTraffic.burnRateEvaluation.status -ne 'UNAVAILABLE' -or $noTraffic.burnRateEvaluation.reason -notin @('NO_TRAFFIC', 'MISSING_REQUEST_COUNT') -or $null -ne $noTraffic.burnRateEvaluation.burnRate) { throw "No-traffic objective was represented as a burn rate." }
    if ($ExerciseProviderFailure) { Assert-ProviderFailure }
    Assert-BurnTelemetry $deadline
    Write-Host 'PASS: isolated valid-zero and elevated burn evidence, independent exact-window recomputation, unavailable semantics, provider recovery, Investigation context, and bounded burn telemetry verified.'
    exit 0
} catch { Write-Error "Burn Rate smoke verification failed: $($_.Exception.Message)"; exit 1 }
