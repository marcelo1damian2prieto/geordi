[CmdletBinding()]
param(
    [ValidateRange(180, 600)] [int] $TimeoutSeconds = 480,
    [string] $BackendBaseUrl = 'https://geordi.localhost:8443',
    [string] $FrontendBaseUrl = 'https://geordi.localhost:8443',
    [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8083',
    [string] $VictoriaMetricsBaseUrl = 'http://127.0.0.1:8428',
    [switch] $M14Only,
    [switch] $SkipM19Capture
)

if ($SkipM19Capture -and -not $M14Only) {
    throw '-SkipM19Capture requires -M14Only. No fixture operation was started.'
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiSchedulerIsolation.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiDiagnosticEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')
$RouteA = 'm13-route-a-alert'
$Suppressed = 'm13-suppressed-alert'
$Unrouted = 'm13-unrouted-alert'

$script:HistorySecrets = @{}
$script:HistoryTiming = [ordered]@{ waits=0.0; waitPolls=0; compose=0.0; persistence=0.0; traffic=0.0; browser=0.0; m18=0.0; m18Checks=0 }
$fixtureClock = $null
$m14StartClock = $null
$m16Clock = $null
$m14RecoveryClock = $null
$m15Clock = $null
$m17Clock = $null
$root = $null
$captureRoot = $null
$script:M14PendingCaptureHandoffs = @{}
$script:M14CaptureRoot = $null
$script:DiagnosticSentinelSource = $null
$script:DiagnosticInvocationId = $null

function Write-HistoryDuration([string] $Category, [Diagnostics.Stopwatch] $Clock, [string] $Result = 'PASS') {
    $Clock.Stop()
    Write-Host ("history_timing category={0} result={1} seconds={2:N2}" -f $Category,$Result,$Clock.Elapsed.TotalSeconds)
}

function Add-M19PrivateSentinel([string] $Value, [string] $Class = 'browser-cookie') {
	if ($SkipM19Capture) { return }
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if ($script:DiagnosticSentinelSource) {
        Add-GeordiDiagnosticSentinel -Source $script:DiagnosticSentinelSource -Class $Class -Value $Value
        return
    }
    $capturePointer = Join-Path (Split-Path -Parent $PSScriptRoot) '.runtime/m19-capture-root.txt'
    if (!(Test-Path -LiteralPath $capturePointer -PathType Leaf)) { return }
    $captureRoot = [IO.Path]::GetFullPath([IO.File]::ReadAllText($capturePointer).Trim())
    $script:M14CaptureRoot = $captureRoot
    $expectedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedTemp -or
            (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
        throw 'Private evidence path failed validation before browser credential registration.'
    }
    [IO.File]::AppendAllLines((Join-Path $captureRoot 'browser-secret-sentinels.txt'), [string[]]@($Value), [Text.UTF8Encoding]::new($false))
}

function Get-M19QueryValue([uri] $Uri, [string] $Name) {
    foreach ($pair in ($Uri.Query.TrimStart('?') -split '&')) {
        $parts = $pair -split '=', 2
        if ($parts.Count -eq 2 -and [uri]::UnescapeDataString($parts[0]) -ceq $Name) {
            return [uri]::UnescapeDataString($parts[1])
        }
    }
    return $null
}

function Compose([string[]] $Arguments, [string] $Operation) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $category = ($Operation.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
    $result = 'FAIL'
    try {
        & docker compose @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Compose $Operation failed." }
        $result = 'PASS'
    } finally {
        $clock.Stop()
        $script:HistoryTiming.compose += $clock.Elapsed.TotalSeconds
        Write-Host ("history_compose operation={0} result={1} seconds={2:N2}" -f $category,$result,$clock.Elapsed.TotalSeconds)
    }
}
function Send-Backend([string] $Uri, [string] $Method = 'GET', $Body = $null) {
    $result = Invoke-GeordiAuthenticatedRequest -Uri $Uri -Method $Method -Body $Body -TimeoutSeconds 15
    return $result
}
function Send-BrowserRequest([string] $Uri, [string] $Method = 'GET', $Body = $null) {
    $uriValue = [uri]$Uri
    if (($uriValue.Host -cne 'geordi.localhost' -or $uriValue.Port -ne 8443) -and
        ($uriValue.Host -cne 'auth.localhost' -or $uriValue.Port -ne 9445)) {
        throw 'M19 browser request endpoint is outside the ingress and issuer allow-list.'
    }
    $cookie = if ($uriValue.Host -ceq 'geordi.localhost' -and $script:GeordiBrowserCookies.Count -gt 0) {
        (@($script:GeordiBrowserCookies.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
    } else { $null }
    $isIssuer = $uriValue.Host -ceq 'auth.localhost' -and $uriValue.Port -eq 9445
    $response = Invoke-GeordiHttpsRequest -Uri $Uri -Method $Method -Body $Body -TimeoutSeconds 15 `
        -Cookie $cookie -CsrfToken $script:GeordiBrowserCsrfToken -Anonymous -AllowOidcBrowserEndpoint:$isIssuer
    $setCookieValues = [string[]]@()
    [void]$response.Headers.TryGetValues('Set-Cookie', [ref]$setCookieValues)
    $setCookies = @($setCookieValues)
    if ($uriValue.AbsolutePath -eq '/api/auth/csrf' -and $response.StatusCode -eq 200) {
        $csrfPayload = $response.Content | ConvertFrom-Json
        $script:GeordiBrowserCsrfToken = [string]$csrfPayload.token
    }
    foreach ($setCookie in $setCookies) {
        if ($setCookie -match '^([^=;]+)=([^;]*);') {
            $name = $Matches[1]; $value = $Matches[2]
            if ([string]::IsNullOrEmpty($value) -or $setCookie -match '(?i)(?:^|;\s*)Max-Age=0(?:;|$)') { $script:GeordiBrowserCookies.Remove($name) }
            else { $script:GeordiBrowserCookies[$name] = $value }
        }
    }
    $script:GeordiBrowserSessionCookie = if ($script:GeordiBrowserCookies.ContainsKey('__Host-GEORDISESSION')) { '__Host-GEORDISESSION=<present>' } else { $null }
    return $response
}
function Start-BrowserSession {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $script:GeordiBrowserCookies = @{}
    $script:GeordiBrowserSessionCookie = $null
    $script:GeordiBrowserCsrfToken = $null
    $login = Send-BrowserRequest "$FrontendBaseUrl/oauth2/authorization/geordi"
    if ($login.StatusCode -ne 302 -or !$login.Headers.Location) { throw 'M19 session fixture did not start a browser OIDC authorization.' }
    $authorize = Send-BrowserRequest ([string]$login.Headers.Location)
    if ($authorize.StatusCode -ne 302 -or !$authorize.Headers.Location) { throw 'M19 OIDC fixture did not return the callback redirect.' }
    $authorizeUrl = [uri][string]$login.Headers.Location
    foreach ($key in @('state','nonce','code_challenge')) {
        $class = switch ($key) { 'state' { 'browser-state' } 'nonce' { 'browser-nonce' } default { 'browser-pkce' } }
        Add-M19PrivateSentinel (Get-M19QueryValue $authorizeUrl $key) $class
    }
    $callbackUrl = [uri][string]$authorize.Headers.Location
    foreach ($key in @('state','code')) {
        Add-M19PrivateSentinel (Get-M19QueryValue $callbackUrl $key) $(if ($key -ceq 'state') { 'browser-state' } else { 'browser-code' })
    }
    $callback = Send-BrowserRequest ([string]$authorize.Headers.Location)
    if ($callback.StatusCode -ne 302 -or !$callback.Headers.Location -or !$script:GeordiBrowserSessionCookie) {
        throw "M19 OIDC callback/session failed (status=$($callback.StatusCode); redirect=$([bool]$callback.Headers.Location); sessionCookie=$([bool]$script:GeordiBrowserSessionCookie))."
    }
    $csrfResponse = Send-BrowserRequest "$FrontendBaseUrl/api/auth/csrf"
    Add-M19PrivateSentinel $script:GeordiBrowserCsrfToken 'browser-csrf'
    foreach ($value in $script:GeordiBrowserCookies.Values) { Add-M19PrivateSentinel ([string]$value) 'browser-cookie' }
    if ($csrfResponse.StatusCode -ne 200 -or !$script:GeordiBrowserCsrfToken) {
        $cookieNames = @($script:GeordiBrowserCookies.Keys) -join ','
        throw "M19 browser CSRF bootstrap failed (status=$($csrfResponse.StatusCode); cookieNames=$cookieNames; tokenPresent=$([bool]$script:GeordiBrowserCsrfToken))."
    }
    $clock.Stop()
    $script:HistoryTiming.browser += $clock.Elapsed.TotalSeconds
    Write-Host ("history_browser_session result=PASS seconds={0:N2}" -f $clock.Elapsed.TotalSeconds)
}
function Json([string] $Uri, [string] $Method = 'GET') {
    if ($Uri.StartsWith($FrontendBaseUrl, [StringComparison]::OrdinalIgnoreCase)) {
        $response = Send-BrowserRequest $Uri $Method
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            $cookieNames = @($script:GeordiBrowserCookies.Keys) -join ','
            throw "Expected successful browser JSON response, got HTTP $($response.StatusCode); cookieNames=$cookieNames."
        }
        return Read-JsonStrings $response.Content
    }
    if ($Uri.StartsWith($BackendBaseUrl, [StringComparison]::OrdinalIgnoreCase)) {
        $response = Send-Backend $Uri $Method
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "Expected successful JSON response from '$Uri', got HTTP $($response.StatusCode)." }
        return Read-JsonStrings $response.Content
    }
    $uriValue = [uri]$Uri
    if (!$uriValue.IsAbsoluteUri -or $uriValue.Scheme -cne 'http' -or $uriValue.Host -cnotin @('127.0.0.1','localhost') -or $uriValue.Port -notin @(8428,18081,18082)) {
        throw 'M14 history smoke JSON request is outside the local fixture allow-list.'
    }
    $fixtureResponse = Invoke-WebRequest -Uri $Uri -Method $Method -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck
    if ($fixtureResponse.StatusCode -lt 200 -or $fixtureResponse.StatusCode -ge 300) { throw "Expected successful local fixture response, got HTTP $($fixtureResponse.StatusCode)." }
    return Read-JsonStrings $fixtureResponse.Content
}
function Post-Json([string] $Uri, $Body) {
    $isBrowser = $Uri.StartsWith($FrontendBaseUrl, [StringComparison]::OrdinalIgnoreCase)
    $response = if ($isBrowser) { Send-BrowserRequest $Uri 'POST' $Body } else { Send-Backend $Uri 'POST' $Body }
    return [pscustomobject]@{ StatusCode = $response.StatusCode; Body = if ($response.Content) { Read-JsonStrings $response.Content } else { $null }; ContentType = [string]$response.ContentHeaders.ContentType }
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
        foreach ($forbidden in @($script:HistorySecrets.TokenA, $script:HistorySecrets.TokenB,
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
    $m18Clock = [Diagnostics.Stopwatch]::StartNew()
    try {
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
    } finally {
        $m18Clock.Stop()
        $script:HistoryTiming.m18 += $m18Clock.Elapsed.TotalSeconds
        $script:HistoryTiming.m18Checks++
    }
}
function Require-ProxyProblem([string] $Uri) {
    $response = Send-BrowserRequest $Uri
    if ($response.StatusCode -ne 400 -or [string]$response.ContentHeaders.ContentType -notmatch '^application/problem\+json(?:\s*;|$)' -or $response.Content.Length -gt 2048) {
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
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $polls = 0
    $category = if ($Message -match '^(M\d+)') { $Matches[1] } else { 'readiness' }
    while ((Get-Date) -lt $Deadline) {
        $polls++
        try {
            if (& $Condition) {
                $clock.Stop()
                $script:HistoryTiming.waits += $clock.Elapsed.TotalSeconds
                $script:HistoryTiming.waitPolls += $polls
                Write-Host ("history_wait category={0} result=PASS seconds={1:N2} polls={2}" -f $category,$clock.Elapsed.TotalSeconds,$polls)
                return
            }
        } catch { }
        Start-Sleep -Milliseconds 250
    }
    $clock.Stop()
    $script:HistoryTiming.waits += $clock.Elapsed.TotalSeconds
    $script:HistoryTiming.waitPolls += $polls
    Write-Host ("history_wait category={0} result=TIMEOUT seconds={1:N2} polls={2}" -f $category,$clock.Elapsed.TotalSeconds,$polls)
    throw $Message
}
function Send-Traffic([string] $Path, [int] $Count) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $uri = "$BurnDemoBaseUrl$Path"
    try {
        1..$Count | ForEach-Object -Parallel { [void](Invoke-WebRequest -Uri $using:uri -UseBasicParsing -TimeoutSec 10 -SkipHttpErrorCheck) } -ThrottleLimit 16
    } finally {
        $clock.Stop()
        $script:HistoryTiming.traffic += $clock.Elapsed.TotalSeconds
        Write-Host ("history_traffic path={0} requests={1} seconds={2:N2}" -f ($Path.Trim('/').Replace('/','-')),$Count,$clock.Elapsed.TotalSeconds)
    }
}
function Apply([string] $PolicyId) {
    # The OIDC browser fixture represents an operator; use the explicit
    # regression bearer identity for lifecycle evaluation permission.
    $response = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-policies/$PolicyId/lifecycle-evaluations" `
        -Method POST -TimeoutSeconds 15
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Authenticated lifecycle evaluation returned HTTP $($response.StatusCode)."
    }
    $script:RouteALifecycleHttpStatus = [int]$response.StatusCode
    return Read-JsonStrings $response.Content
}
function Episodes([string] $PolicyId) { @(Json "$BackendBaseUrl/api/alert-episodes?policyId=$PolicyId&limit=100").alertEpisodes }
function Transitions([string] $PolicyId) { @(Json "$BackendBaseUrl/api/alert-transitions?policyId=$PolicyId&limit=100").alertTransitions }
function Metric-Series([string] $Selector) {
    # VictoriaMetrics is an isolated local fixture, not the HTTPS Geordi API.
    # Keep provider queries on that fixture's own transport instead of passing
    # them through the bearer-authenticated platform request helper.
    $uri = "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$([uri]::EscapeDataString($Selector))"
    return @((Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15).data)
}
function Metric-Query([string] $Query) {
    $uri = "$VictoriaMetricsBaseUrl/api/v1/query?query=$([uri]::EscapeDataString($Query))"
    return @((Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15).data.result)
}
function Counter-HasBaseline([string] $Selector) { @((Metric-Query "count_over_time($Selector[60s])") | Where-Object { [double]$_.value[1] -ge 2 }).Count -gt 0 }
function Require-Status([string] $Uri, [int] $Expected) {
    $actual = (Send-Backend $Uri).StatusCode
    if ($actual -ne $Expected) { throw "Expected HTTP $Expected from '$Uri', got '$actual'." }
}
function Reset-M14Fixture([string] $Root, [object] $Ownership) {
    $rendered = & docker compose --project-directory $Root config --format json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to render the M14 Compose configuration for fixture reset.' }
    $inventory = Get-GeordiM14DockerResourceInventory
    $plan = Get-GeordiM14MutationPlan -Configuration $rendered
    Assert-GeordiM14MutationPreflight -Plan $plan -ServiceInventory $inventory.Containers
    $script:M14MutationPlan = $plan
    if ($script:M14CaptureRoot) {
        $script:M14PendingCaptureHandoffs = Begin-GeordiCaptureHandoffs -CaptureRoot $script:M14CaptureRoot `
            -Services @('backend','otel-collector') -Reason 'm14-fixture-reset'
    }
    Invoke-GeordiM14FixtureReset -Ownership $Ownership -RenderedVolumes $rendered.volumes `
        -ExistingContainers $inventory.Containers -ExistingVolumes $inventory.Volumes `
        -CaptureGeneration {
            param([string[]] $Services)
            if (-not $SkipM19Capture) {
                & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') `
                    -Phase m14-reset -Services $Services
            }
        } -RemoveContainerIds {
            param([string[]] $Ids)
            & docker rm -sf $Ids | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the exact pre-reset Geordi container identities for M14 fixture acquisition.' }
        } -RemoveVolume {
            param([string] $Name)
            & docker volume rm $Name | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to remove dedicated M14 volume '$Name'." }
        } -GetInventory { Get-GeordiM14DockerResourceInventory }
}

function Remove-M14OwnedFixtureResources([object] $Ownership) {
    if ($script:M14CaptureRoot) {
        $manifest = Get-GeordiCaptureGenerationManifest $script:M14CaptureRoot
        foreach ($service in @('backend','otel-collector')) {
            $active = @($manifest.captureGenerations[$service] | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
            if ($active.Count -eq 1) {
                $script:M14PendingCaptureHandoffs[$service] = Begin-GeordiCaptureHandoff -CaptureRoot $script:M14CaptureRoot `
                    -Service $service -Reason 'm14-fixture-cleanup'
            }
        }
    }
    Invoke-GeordiM14OwnedResourceCleanup -Ownership $Ownership -GetInventory { Get-GeordiM14DockerResourceInventory } `
        -CaptureGeneration {
            param([string[]] $Services)
            if (-not $SkipM19Capture) {
                & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') `
                    -Phase m14-final -Services $Services
            }
        } -RemoveContainerIds {
            param([string[]] $Ids)
            & docker rm -sf $Ids | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Could not remove the exact M14 fixture containers acquired by this invocation.' }
        } -RemoveVolume {
            param([string] $Name)
            & docker volume rm $Name | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not remove owned M14 fixture volume '$Name'." }
        }
}

function Start-M14FixtureServices([string] $Root, [object] $Plan) {
    foreach ($command in $Plan.Commands) {
        $arguments = @('--project-directory',$Root,'up','-d','--no-deps','--wait','--wait-timeout','60')
        if ($command.ForceRecreate) { $arguments += '--force-recreate' }
        $arguments += @($command.Services)
        foreach ($service in @($command.Services)) {
            if ($script:M14CaptureRoot -and $service -in @('backend','otel-collector') -and $command.ForceRecreate) {
                $handoffId = [string]$script:M14PendingCaptureHandoffs[$service]
                if ([string]::IsNullOrWhiteSpace($handoffId)) { throw 'M14 capture handoff identity is missing after replacement.' }
                $serviceArguments = @($arguments | Where-Object { $_ -notin @($command.Services) }) + @($service)
                $null = Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $script:M14CaptureRoot -Service $service `
                    -HandoffId $handoffId -RepositoryRoot $Root -Reason 'm14-fixture-generation' `
                    -Replace { Compose $serviceArguments ("M14 scoped startup {0}" -f $service) } `
                    -GetContainerIdentity { param($name) Get-GeordiCurrentCaptureContainerIdentity -Service $name -RepositoryRoot $Root }
            } else {
                Compose $arguments ("M14 scoped startup {0}" -f ($command.Services -join ','))
                break
            }
        }
    }
}
function H2-Scalar([string] $Root, [string] $Sql) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = 'FAIL'
    try {
        $jar = Join-Path $Root 'backend/target/geordi-backend-0.1.0-SNAPSHOT.jar'
        if (!(Test-Path $jar)) { throw 'Verified backend artifact is required for M14 persistence inspection.' }
        $output = & docker run --rm --network none -e "M14_SQL=$Sql" -v "$(Join-Path $Root 'backend/target'):/verified:ro" -v 'geordi_m14-alert-lifecycle-data:/var/lib/geordi/alerts' maven:3.9.11-eclipse-temurin-21 sh -c 'mkdir -p /tmp/h2 && cd /tmp/h2 && jar xf /verified/geordi-backend-0.1.0-SNAPSHOT.jar && java -cp "BOOT-INF/lib/*" org.h2.tools.Shell -url "jdbc:h2:file:/var/lib/geordi/alerts/lifecycle;ACCESS_MODE_DATA=r" -user sa -password "" -sql "$M14_SQL"'
        if ($LASTEXITCODE -ne 0) { throw 'Read-only M14 persistence inspection failed.' }
        $match = [regex]::Matches(($output -join "`n"), '(?m)^\s*(\d+)\s*$')
        if ($match.Count -ne 1) { throw 'M14 persistence inspection returned an unexpected scalar result.' }
        $result = 'PASS'
        return [int]$match[0].Groups[1].Value
    } finally {
        $clock.Stop()
        $script:HistoryTiming.persistence += $clock.Elapsed.TotalSeconds
        Write-Host ("history_persistence operation=scalar result={0} seconds={1:N2}" -f $result,$clock.Elapsed.TotalSeconds)
    }
}
function H2-Execute([string] $Root, [string] $Sql) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = 'FAIL'
    try {
        $jar = Join-Path $Root 'backend/target/geordi-backend-0.1.0-SNAPSHOT.jar'
        if (!(Test-Path $jar)) { throw 'Verified backend artifact is required for M17 controlled persistence setup.' }
        & docker run --rm --network none -e "M17_SQL=$Sql" -v "$(Join-Path $Root 'backend/target'):/verified:ro" -v 'geordi_m14-alert-lifecycle-data:/var/lib/geordi/alerts' maven:3.9.11-eclipse-temurin-21 sh -c 'mkdir -p /tmp/h2 && cd /tmp/h2 && jar xf /verified/geordi-backend-0.1.0-SNAPSHOT.jar && java -cp "BOOT-INF/lib/*" org.h2.tools.Shell -url "jdbc:h2:file:/var/lib/geordi/alerts/lifecycle" -user sa -password "" -sql "$M17_SQL"' | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'M17 controlled persistence setup failed.' }
        $result = 'PASS'
    } finally {
        $clock.Stop()
        $script:HistoryTiming.persistence += $clock.Elapsed.TotalSeconds
        Write-Host ("history_persistence operation=execute result={0} seconds={1:N2}" -f $result,$clock.Elapsed.TotalSeconds)
    }
}
function Require-SanitizedUnavailable([string] $Uri) {
    $response = Send-Backend $Uri
    if ($response.StatusCode -ne 503 -or [string]$response.ContentHeaders.ContentType -notmatch '^application/problem\+json(?:\s*;|$)' -or $response.Content.Length -gt 2048) {
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

$fixtureOwnership = New-GeordiM14FixtureOwnershipState -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
Invoke-GeordiWithProcessEnvironmentRestore -Names @(
    'COMPOSE_FILE', 'GEORDI_SCHEDULING_ALERT_ENABLED', 'GEORDI_M13_WEBHOOK_TOKEN_A', 'GEORDI_M13_WEBHOOK_TOKEN_B',
    'GEORDI_M19_DIAGNOSTIC_INVOCATION_ID') -Action {
Invoke-GeordiDiagnosticEvidenceLifecycle -SourceProvider { $script:DiagnosticSentinelSource } -Action {
Invoke-GeordiM14FixtureLifecycle -Ownership $fixtureOwnership -Action {
try {
    $root = Split-Path -Parent $PSScriptRoot
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $fixtureClock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($key in @('GEORDI_M13_WEBHOOK_TOKEN_A','GEORDI_M13_WEBHOOK_TOKEN_B')) {
        [Environment]::SetEnvironmentVariable($key, [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)), 'Process')
    }
    $script:HistorySecrets = @{ TokenA = $env:GEORDI_M13_WEBHOOK_TOKEN_A; TokenB = $env:GEORDI_M13_WEBHOOK_TOKEN_B }
    if (-not $SkipM19Capture) {
        $capturePointer = Join-Path $root '.runtime/m19-capture-root.txt'
        if (Test-Path -LiteralPath $capturePointer -PathType Leaf) {
            $captureRoot = [IO.Path]::GetFullPath([IO.File]::ReadAllText($capturePointer).Trim())
            $script:M14CaptureRoot = $captureRoot
            $expectedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
            if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedTemp -or
                    (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
                throw 'Private evidence path failed validation before fixture credential registration.'
            }
        }
    }
    $env:COMPOSE_FILE = (Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m19.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m14.yaml')
    $env:GEORDI_SCHEDULING_ALERT_ENABLED = 'false'
    $null = Get-GeordiM14RenderedComposeConfiguration -RepositoryRoot $root
    if (-not $SkipM19Capture -and $captureRoot) {
        $script:DiagnosticInvocationId = [guid]::NewGuid().ToString('N')
        $script:DiagnosticSentinelSource = New-GeordiDiagnosticSentinelSource -CaptureRoot $captureRoot -DiagnosticInvocationId $script:DiagnosticInvocationId
        $env:GEORDI_M19_DIAGNOSTIC_INVOCATION_ID = $script:DiagnosticInvocationId
        $script:GeordiPrivateTokenSentinelOverride = { param($Token) Add-GeordiDiagnosticSentinel -Source $script:DiagnosticSentinelSource -Class 'runtime-bearer' -Value ([string]$Token) }
        foreach ($token in @($script:HistorySecrets.TokenA,$script:HistorySecrets.TokenB)) { Add-M19PrivateSentinel $token 'webhook-token' }
    }
    $transportPreflight = Test-GeordiAuthenticatedTransport -RepositoryRoot $root
    Reset-M14Fixture $root $fixtureOwnership
    $fixtureOwnership.StartupAttempted = $true
    $fixtureOwnership.StartupStartedUtc = [DateTimeOffset]::UtcNow
    Start-M14FixtureServices $root $script:M14MutationPlan
    Wait-Until { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 } $deadline 'M14 backend did not become ready.'
    Initialize-GeordiAuthentication -Identity REGRESSION -RepositoryRoot $root
    $regressionIdentityResponse = Send-Backend "$BackendBaseUrl/api/me"
    if ($regressionIdentityResponse.StatusCode -ne 200) { throw 'M14 regression identity preflight failed.' }
    $regressionIdentity = Read-JsonStrings $regressionIdentityResponse.Content
    if ('alerts:evaluate' -cnotin @($regressionIdentity.permissions)) {
        throw 'M14 lifecycle evaluation fixture identity is missing alerts:evaluate.'
    }
    Start-BrowserSession
    Write-Host 'PASS: M19 browser OIDC session and CSRF bootstrap completed.'
    Wait-Until { (Invoke-WebRequest -Uri "$BurnDemoBaseUrl/actuator/health/readiness" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } $deadline 'M14 burn demo did not become ready.'
    if (-not $M14Only) {
        Wait-Until { $null -ne (Json "$FrontendBaseUrl/api/alert-episodes?policyId=$RouteA&limit=50").alertEpisodes } $deadline 'M15 frontend history API proxy did not become ready.'
    }
    $fixtureClock.Stop()
    Write-Host ("history_timing category=fixture_startup_readiness result=PASS seconds={0:N2}" -f $fixtureClock.Elapsed.TotalSeconds)

    $m14StartClock = [Diagnostics.Stopwatch]::StartNew()
    Send-Traffic '/demo/error' 1
    $errorSelector = '{__name__="http.server.request.duration_count",service.name="geordi-burn-smoke-service",http.response.status_code="500"}'
    Wait-Until { (Metric-Series $errorSelector).Count -gt 0 } $deadline 'M14 controlled error baseline was not persisted.'
    Wait-Until { Counter-HasBaseline $errorSelector } $deadline 'M14 controlled error baseline did not receive a second sample.'
    Wait-Until { (Json "$BackendBaseUrl/api/alert-policies/$RouteA/evaluation").status -eq 'CONDITION_MET' } $deadline 'M14 route-A condition did not become met.'
    Write-Host 'PASS: M14 controlled telemetry produced a matched route-A condition.'

    $started = Apply $RouteA
    $routeADiagnostic = Get-GeordiRouteADiagnostic -HttpStatus $script:RouteALifecycleHttpStatus -Response $started
    Write-Host $routeADiagnostic.Line
    if ($started.transition.type -ne 'ALERT_STARTED') { throw 'M14 route A did not create ALERT_STARTED.' }
    $episode = Episodes $RouteA
    if ($episode.Count -ne 1 -or $episode[0].origin -ne 'M14' -or [string]::IsNullOrWhiteSpace($episode[0].openedAt) -or $null -ne $episode[0].closedAt) { throw 'M14 normal open episode projection is invalid.' }
    $episodeId = $episode[0].id
    if ((Transitions $RouteA).Count -ne 1) { throw 'M14 normal STARTED transition was not persisted exactly once.' }
    Write-HistoryDuration 'M14_initial_condition_and_episode' $m14StartClock
	
    if ($M14Only) {
        Write-Host 'M14_ONLY result=PASS scope=initial_route_a_lifecycle cleanup=ENABLED'
        return
    }

    $m16Clock = [Diagnostics.Stopwatch]::StartNew()
    $ackActor = 'M19 Operator'
    $ackReason = 'm16 bounded smoke acknowledgement'
    $ack = Post-Json "$FrontendBaseUrl/api/alert-episodes/$episodeId/acknowledgements" @{ reason = $ackReason }
    Write-Host "PASS: M16 acknowledgement POST returned HTTP $($ack.StatusCode)."
    if ($ack.StatusCode -ne 201 -or $ack.Body.actor -cne $ackActor -or $ack.Body.reason -cne $ackReason -or
        $ack.Body.attribution.provenance -cne 'AUTHENTICATED_PRINCIPAL' -or $ack.Body.attribution.identity.issuer -cne 'https://auth.localhost' -or
        $ack.Body.attribution.identity.subject -cne 'm19-operator' -or [string]::IsNullOrWhiteSpace($ack.Body.acknowledgedAt)) { throw 'M16 authenticated acknowledgement did not return HTTP 201 with persisted principal attribution.' }
    $ackAt = $ack.Body.acknowledgedAt
    $ackReplay = Post-Json "$FrontendBaseUrl/api/alert-episodes/$episodeId/acknowledgements" @{ reason = "  $ackReason  " }
    if ($ackReplay.StatusCode -ne 200 -or $ackReplay.Body.actor -cne $ackActor -or $ackReplay.Body.acknowledgedAt -cne $ackAt -or
        $ackReplay.Body.attribution.provenance -cne 'AUTHENTICATED_PRINCIPAL' -or $ackReplay.Body.attribution.identity.subject -cne 'm19-operator') { throw 'M16 exact acknowledgement replay did not preserve immutable authenticated attribution.' }
    $ackDetail = Json "$FrontendBaseUrl/api/alert-episodes/$episodeId"
    Require-Fields $ackDetail @('episode', 'acknowledgement', 'transitions') 'M16 acknowledged detail envelope'
    if ($ackDetail.acknowledgement.actor -cne $ackActor -or $ackDetail.acknowledgement.acknowledgedAt -cne $ackAt) { throw 'M16 acknowledgement detail mismatch.' }
    if (@($ackDetail.transitions).Count -ne 1) { throw 'M17 open episode did not contain its single transition.' }
    Require-Transition $ackDetail.transitions[0] $started.transition $episodeId 'MATCHED' $true
    $startedTransitionId = $ackDetail.transitions[0].id
    Write-HistoryDuration 'M16_acknowledgement_and_projection' $m16Clock

    $m14RecoveryClock = [Diagnostics.Stopwatch]::StartNew()
    $retry = Apply $RouteA
    if ($null -ne $retry.transition -or (Episodes $RouteA).Count -ne 1 -or (Transitions $RouteA).Count -ne 1) { throw 'M14 no-transition reevaluation changed history.' }

    Compose @('--project-directory', $root, 'restart', 'backend') 'backend restart'
    Wait-Until { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 } $deadline 'M14 backend did not recover after restart.'
    Start-BrowserSession
    Write-Host 'PASS: M19 browser session re-established after the bounded backend restart.'
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
    Write-HistoryDuration 'M14_restart_routing_recovery_and_M17_delivery' $m14RecoveryClock

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
    $m15Clock = [Diagnostics.Stopwatch]::StartNew()
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
    Write-HistoryDuration 'M15_bounded_frontend_projection' $m15Clock

    $m17Clock = [Diagnostics.Stopwatch]::StartNew()
    Compose @('--project-directory', $root, 'stop', 'backend') 'history persistence inspection stop'
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_episode WHERE policy_id = '$RouteA' AND opened_at IS NOT NULL AND closed_at IS NOT NULL") -ne 1) { throw 'M14 normal durable episode row is missing.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_transition_history WHERE policy_id = '$RouteA'") -ne 2) { throw 'M14 normal durable transitions are missing.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM `"flyway_schema_history`" WHERE `"version`" = '7' AND `"success`" = TRUE") -ne 1) { throw 'M17 V7 migration was not recorded exactly once.' }
    if ((H2-Scalar $root 'SELECT COUNT(*) FROM alert_notification_disposition') -ne 4) { throw 'M17 clean V1-to-V7 migration or transition commits produced an unexpected disposition backfill.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_disposition WHERE disposition = 'MATCHED'") -ne 2 -or
            (H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_disposition WHERE disposition = 'SUPPRESSED'") -ne 1 -or
            (H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_disposition WHERE disposition = 'UNROUTED'") -ne 1) { throw 'M17 durable disposition rows do not match committed routing outcomes.' }
    if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_notification_outbox WHERE policy_id = '$RouteA'") -ne 2) { throw 'M17 MATCHED transitions did not retain exactly one correlated delivery each.' }
    $secrets = @($script:HistorySecrets.TokenA, $script:HistorySecrets.TokenB)
    foreach ($secret in $secrets) { if ((H2-Scalar $root "SELECT COUNT(*) FROM alert_transition_history WHERE POSITION('$($secret.Replace("'", "''"))' IN transition_json) > 0") -ne 0) { throw 'M14 transition history persisted a fixture secret.' } }
    Compose @('--project-directory', $root, 'start', 'backend') 'post-inspection backend start'
    Wait-Until { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 } $deadline 'M14 backend did not recover after persistence inspection.'
    Start-BrowserSession

    foreach ($metric in @('geordi.alert.history.episodes', 'geordi.alert.history.persistence')) {
        Wait-Until { (Metric-Series "{__name__=`"$metric`"}").Count -gt 0 } $deadline "M14 history metric '$metric' was not persisted."
    }
    $postClose = Post-Json "$FrontendBaseUrl/api/alert-episodes/$episodeId/acknowledgements" @{ reason = $ackReason }
    if ($postClose.StatusCode -ne 409 -or $postClose.ContentType -notmatch 'application/problem\+json') { throw 'M16 post-close acknowledgement did not return RFC9457 409.' }
    $postCloseDetail = Json "$FrontendBaseUrl/api/alert-episodes/$episodeId"
    if ($postCloseDetail.acknowledgement.acknowledgedAt -cne $ackAt) { throw 'M16 post-close conflict changed acknowledgement.' }
    $postCloseNotification = ($postCloseDetail.transitions | Where-Object { $_.id -eq $startedTransitionId })[0].notification | ConvertTo-Json -Depth 8 -Compress
    if ($postCloseNotification -cne $stableNotification) { throw 'M17 acknowledgement changed notification disposition or delivery evidence.' }

    # This existing isolated H2 fixture permits a minimal legacy/corruption setup without a second delivery framework.
    & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m14-final -Services backend
    Compose @('--project-directory', $root, 'stop', 'backend') 'M17 legacy evidence setup stop'
    H2-Execute $root "DELETE FROM alert_notification_disposition WHERE transition_id IN ('$startedTransitionId', '$($suppressedDetail.transitions[0].id)')"
    Compose @('--project-directory', $root, 'start', 'backend') 'M17 legacy evidence setup start'
    Wait-Until { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 } $deadline 'M17 backend did not recover for legacy evidence.'
    Start-BrowserSession
    $legacyCorrelated = Json "$BackendBaseUrl/api/alert-episodes/$episodeId"
    Require-Transition ($legacyCorrelated.transitions | Where-Object { $_.id -eq $startedTransitionId })[0] $started.transition $episodeId 'NOT_RECORDED' $true
    $legacyWithoutDelivery = Json "$BackendBaseUrl/api/alert-episodes/$suppressedEpisodeId"
    Require-Transition $legacyWithoutDelivery.transitions[0] $suppressedStarted.transition $suppressedEpisodeId 'NOT_RECORDED' $false

    & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m14-final -Services backend
    Compose @('--project-directory', $root, 'stop', 'backend') 'M17 integrity evidence setup stop'
    H2-Execute $root "DELETE FROM alert_notification_outbox WHERE delivery_id = '$resolvedTransitionId'"
    Compose @('--project-directory', $root, 'start', 'backend') 'M17 integrity evidence setup start'
    Wait-Until { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 } $deadline 'M17 backend did not recover for integrity evidence.'
    Require-SanitizedUnavailable "$BackendBaseUrl/api/alert-episodes/$episodeId"
    Write-HistoryDuration 'M17_durable_migration_legacy_and_integrity' $m17Clock
    Write-Host 'PASS: M17 clean V7 migration, MATCHED/SUPPRESSED/UNROUTED evidence, deterministic DELIVERED durability, privacy, acknowledgement independence, legacy NOT_RECORDED projection, and sanitized integrity failure verified. Populated V6-to-V7 preservation/no-backfill is covered by the dedicated migration integration suite. FAILED is not asserted because this fixture has no deterministic failing receiver.'
    Write-Host 'PASS: M16 episode acknowledgement creation, replay, restart durability, post-close conflict, and isolation verified.'
    Write-Host 'PASS: M14 isolated normal history, retry/restart stability, routing independence, bounded/privacy-safe API, durable persistence, and history telemetry verified.'
} catch {
    foreach ($entry in @(
            @{Name='fixture_startup_readiness';Clock=$fixtureClock},
            @{Name='M14_initial_condition_and_episode';Clock=$m14StartClock},
            @{Name='M16_acknowledgement_and_projection';Clock=$m16Clock},
            @{Name='M14_restart_routing_recovery_and_M17_delivery';Clock=$m14RecoveryClock},
            @{Name='M15_bounded_frontend_projection';Clock=$m15Clock},
            @{Name='M17_durable_migration_legacy_and_integrity';Clock=$m17Clock})) {
        if ($null -ne $entry.Clock -and $entry.Clock.IsRunning) { Write-HistoryDuration $entry.Name $entry.Clock 'FAIL' }
    }
    Write-Error "Alert history smoke failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -ErrorAction Continue
    throw
}
} -Cleanup {
    $cleanupClock = [Diagnostics.Stopwatch]::StartNew()
    $cleanupStatus = 'PASS'
    try { Remove-M14OwnedFixtureResources $fixtureOwnership }
    catch { $cleanupStatus = 'FAIL'; throw }
    finally {
        Write-HistoryDuration 'fixture_cleanup_restore' $cleanupClock $cleanupStatus
        Write-Host ("history_timing category=aggregate result=RECORDED compose_seconds={0:N2} wait_seconds={1:N2} wait_polls={2} traffic_seconds={3:N2} browser_seconds={4:N2} persistence_seconds={5:N2} M18_projection_seconds={6:N2} M18_checks={7}" -f
            $script:HistoryTiming.compose,$script:HistoryTiming.waits,$script:HistoryTiming.waitPolls,
            $script:HistoryTiming.traffic,$script:HistoryTiming.browser,$script:HistoryTiming.persistence,
            $script:HistoryTiming.m18,$script:HistoryTiming.m18Checks)
    }
}
}
}
