[CmdletBinding()]
param(
    [ValidateRange(120, 360)][int] $TimeoutSeconds = 300,
    [string] $BackendBaseUrl = 'https://geordi.localhost:8443',
    [string] $BurnDemoBaseUrl = 'http://127.0.0.1:8083',
    [string] $ReceiverBaseUrl = 'http://127.0.0.1:18080',
    [string] $VictoriaMetricsBaseUrl = 'http://127.0.0.1:8428',
    [switch] $PreserveFixtureForNextStage
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM11BackendReplacement.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiM11M12FixtureTransfer.ps1')
$PolicyId = 'burn-smoke-alert'
$m11FixtureState = [pscustomobject]@{ FixtureOwned=$false;MutationStarted=$false;TransferCommitted=$false }
$m11CollectorBaselineContainerId = $null

function Json([string] $Uri, [string] $Method = 'GET', $Body = $null) {
    $arguments = @{ Uri = $Uri; Method = $Method; TimeoutSec = 15; UseBasicParsing = $true }
    if ($null -ne $Body) { $arguments.ContentType = 'application/json'; $arguments.Body = ($Body | ConvertTo-Json -Compress) }
    $response = Invoke-GeordiScriptRequest -Uri $Uri -Method $Method -Body $Body -TimeoutSeconds 15
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "Fixture or API request returned HTTP $($response.StatusCode)." }
    return $response.Content | ConvertFrom-Json
}
function Apply-Lifecycle { Json "$BackendBaseUrl/api/alert-policies/$PolicyId/lifecycle-evaluations" 'POST' }
function Evaluation { Json "$BackendBaseUrl/api/alert-policies/$PolicyId/evaluation" }
function Metric-Query([string] $Query) {
    @((Json "$VictoriaMetricsBaseUrl/api/v1/query?query=$([uri]::EscapeDataString($Query))").data.result)
}
function Counter-HasBaseline([string] $Selector) {
    @((Metric-Query "count_over_time($Selector[60s])") | Where-Object { [double]$_.value[1] -ge 2 }).Count -gt 0
}
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

function Invoke-M11Compose([string[]] $Arguments, [string] $Operation) {
    & docker compose @Arguments
    if ($LASTEXITCODE -ne 0) { throw "M11 $Operation failed." }
}

function Get-M11CaptureRoot([string] $Root) {
    $pointerPath = Join-Path (Join-Path $Root '.runtime') 'm19-capture-root.txt'
    if (!(Test-Path -LiteralPath $pointerPath -PathType Leaf)) { throw 'M11 backend generation requires the active M19 capture pointer.' }
    $captureRoot = [IO.Path]::GetFullPath([IO.File]::ReadAllText($pointerPath).Trim())
    $expectedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedTemp -or
            (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$' -or
            !(Test-Path -LiteralPath $captureRoot -PathType Container)) {
        throw 'M11 backend capture pointer failed its ownership validation.'
    }
    return $captureRoot
}

function Get-M11FixtureVolumes([string] $Root, [string[]] $ComposeArgs) {
    $rendered = & docker compose @ComposeArgs config --format json | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0) { throw 'Unable to render M11 Compose configuration.' }
    $expected = [ordered]@{
        'm11-alert-lifecycle-data' = 'geordi_m11-alert-lifecycle-data'
        'm11-victoriametrics-data' = 'geordi_m11-victoriametrics-data'
    }
    foreach ($logicalName in $expected.Keys) {
        if ($rendered.volumes.$logicalName.name -ne $expected[$logicalName]) {
            throw "Refusing M11 reset for unexpected volume '$($rendered.volumes.$logicalName.name)' instead of '$($expected[$logicalName])'."
        }
    }
    return $expected
}

function Remove-M11FixtureVolumes([System.Collections.IDictionary] $Expected) {
    $dockerCommand = {
        param([string[]] $Arguments)
        $output = & docker @Arguments 2>$null
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode=$exitCode;Output=@($output) }
    }.GetNewClosure()
    $inspectVolume = {
        param([string] $Name)
        return Get-GeordiM11DockerVolumeInspection -Name $Name -DockerCommand $dockerCommand
    }.GetNewClosure()
    $removeVolume = {
        param([string] $Name)
        $result = & $dockerCommand @('volume','rm',$Name)
        if ($null -eq $result -or [int]$result.ExitCode -ne 0) { throw "Unable to remove dedicated M11 volume '$Name'." }
    }.GetNewClosure()
    Remove-GeordiM11DedicatedFixtureVolumes -ExpectedVolumes $Expected -InspectVolume $inspectVolume -RemoveVolume $removeVolume
}

function Invoke-M11BackendGenerationReplacement([string] $CaptureRoot, [string] $Root,
    [string] $Reason, [scriptblock] $Replace, [switch] $RequireVictoriaMetricsReplacement) {
    $identityResolver = {
        param([string] $Service)
        Get-GeordiCurrentCaptureContainerIdentity -Service $Service -RepositoryRoot $Root
    }.GetNewClosure()
    $readiness = {
        param($Target)
        if ([string]$Target.service -cne 'backend') { throw 'M11 readiness was requested for an unexpected service.' }
        Wait-Until {
            try { (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200 }
            catch { $false }
        } $deadline 'M11 replacement backend did not become ready while its exact-generation follower was active.'
    }.GetNewClosure()
    return Invoke-GeordiM11BackendGenerationReplacement -CaptureRoot $CaptureRoot -RepositoryRoot $Root `
        -Replace $Replace -ResolveContainerIdentity $identityResolver -WaitReadiness $readiness -Reason $Reason `
        -RequireVictoriaMetricsReplacement:$RequireVictoriaMetricsReplacement -DockerPath (Get-Command docker.exe -ErrorAction Stop).Source `
        -PowerShellPath (Get-Process -Id $PID).Path -WorkerPath (Join-Path $PSScriptRoot 'lib/Start-GeordiLogFollowerWorker.ps1')
}

function Reset-M11Fixture([string] $Root, [string[]] $ComposeArgs, [string[]] $ReplacementComposeArgs, [string] $CaptureRoot, $FixtureState) {
    $volumeNames = Get-M11FixtureVolumes $Root $ComposeArgs
    & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m11-reset -Services backend,victoriametrics -SkipLogSnapshot | Out-Null
    $replace = {
        $FixtureState.MutationStarted = $true
        Invoke-M11Compose ($ReplacementComposeArgs + @('rm', '-sf', 'backend', 'victoriametrics')) 'joint backend/VictoriaMetrics container detach'
        Remove-M11FixtureVolumes $volumeNames
        Invoke-M11Compose ($ReplacementComposeArgs + @('up', '-d', '--no-deps', '--force-recreate', 'victoriametrics', 'backend')) 'joint backend/VictoriaMetrics recreation'
    }.GetNewClosure()
    $null = Invoke-M11BackendGenerationReplacement -CaptureRoot $CaptureRoot -Root $Root `
        -Reason 'm11-initial-joint-reset' -Replace $replace -RequireVictoriaMetricsReplacement
}

function Seal-M11ActiveBackendGeneration([string] $Root, [string] $CaptureRoot) {
    $manifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $records = if ($manifest.captureGenerations.ContainsKey('backend')) { @($manifest.captureGenerations.backend) } else { @() }
    $active = @($records | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
    if ($active.Count -gt 1) { throw 'M11 cleanup found ambiguous active backend capture generations.' }
    if ($active.Count -eq 1) {
        $identity = Get-GeordiCurrentCaptureContainerIdentity -Service backend -RepositoryRoot $Root
        if ([string]$identity.Id -cne [string]$active[0].containerId) { throw 'M11 cleanup backend identity differs from its active capture generation.' }
        Seal-GeordiCaptureGeneration -CaptureRoot $CaptureRoot -Service backend -GenerationId ([string]$active[0].generationId) | Out-Null
    }
}

function Remove-M11Fixture([string] $Root, [string[]] $ReplacementComposeArgs, [string] $CaptureRoot) {
    if (Test-Path -LiteralPath (Join-Path $CaptureRoot 'manifest.json') -PathType Leaf) {
        Seal-M11ActiveBackendGeneration $Root $CaptureRoot
    }
    Invoke-M11Compose ($ReplacementComposeArgs + @('rm', '-sf', 'backend', 'victoriametrics')) 'container cleanup'
    $expected = [ordered]@{
        'm11-alert-lifecycle-data' = 'geordi_m11-alert-lifecycle-data'
        'm11-victoriametrics-data' = 'geordi_m11-victoriametrics-data'
    }
    Remove-M11FixtureVolumes $expected
}

try {
    $root = Split-Path -Parent $PSScriptRoot
    $env:COMPOSE_FILE = (Join-Path $root 'compose.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m19.yaml') + [IO.Path]::PathSeparator + (Join-Path $root 'compose.m11.yaml')
    Initialize-GeordiAuthentication -Identity REGRESSION -RepositoryRoot $root
    $composeArgs = @('--project-directory', $root, '--file', (Join-Path $root 'compose.yaml'), '--file', (Join-Path $root 'compose.m19.yaml'), '--file', (Join-Path $root 'compose.m11.yaml'))
    $replacementComposeArgs = Get-GeordiM11ControlledReplacementComposeArguments -RepositoryRoot $root
    $captureRoot = Get-M11CaptureRoot $root
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Reset-M11Fixture $root $composeArgs $replacementComposeArgs $captureRoot $m11FixtureState
    $m11FixtureState.FixtureOwned = $true
    $collectorAtM11Start = Get-GeordiCurrentCaptureContainerIdentity -Service 'otel-collector' -RepositoryRoot $root
    $m11CollectorBaselineContainerId = [string]$collectorAtM11Start.Id
    Initialize-GeordiAuthentication -Identity REGRESSION -RepositoryRoot $root
    Control 'success' 0 $true

    Send-Traffic '/demo/success' 1
    $baselineSelector = [uri]::EscapeDataString(
        '{__name__="http.server.request.duration_count","service.name"="geordi-burn-smoke-service","http.response.status_code"="200"}')
    Wait-Until {
        @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$baselineSelector").data).Count -gt 0
    } $deadline 'Controlled traffic baseline was not persisted.'
    Wait-Until {
        Counter-HasBaseline '{__name__="http.server.request.duration_count",service.name="geordi-burn-smoke-service",http.response.status_code="200"}'
    } $deadline 'Controlled success baseline did not receive a second sample.'
    Send-Traffic '/demo/error' 1
    $errorBaselineSelector = [uri]::EscapeDataString(
        '{__name__="http.server.request.duration_count","service.name"="geordi-burn-smoke-service","http.response.status_code"="500"}')
    Wait-Until {
        @((Json "$VictoriaMetricsBaseUrl/api/v1/series?match%5B%5D=$errorBaselineSelector").data).Count -gt 0
    } $deadline 'Controlled error baseline was not persisted.'
    Wait-Until {
        Counter-HasBaseline '{__name__="http.server.request.duration_count",service.name="geordi-burn-smoke-service",http.response.status_code="500"}'
    } $deadline 'Controlled error baseline did not receive a second sample.'
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
    $readiness = Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 15
    if ($readiness.StatusCode -ne 200) { throw 'Remote webhook failure degraded platform readiness.' }

    # Remove the old backend before recovering the receiver, then create a new
    # container on the same M11 volume. This keeps the intentional outage while
    # making the log-follower boundary explicit.
    $downtimeReplacement = {
        $m11FixtureState.MutationStarted = $true
        Invoke-M11Compose ($replacementComposeArgs + @('rm', '-sf', 'backend')) 'backend downtime detach'
        Control 'success'
        Invoke-M11Compose ($replacementComposeArgs + @('up', '-d', '--no-deps', 'backend')) 'backend downtime recovery replacement'
    }.GetNewClosure()
    $null = Invoke-M11BackendGenerationReplacement -CaptureRoot $captureRoot -Root $root `
        -Reason 'm11-pending-delivery-downtime' -Replace $downtimeReplacement
    Wait-Until { @((Json "$ReceiverBaseUrl/events").events | Where-Object deliveryId -eq $resolvedId).Count -eq 1 } $deadline 'Pending delivery did not recover after restart.'
    $receiverState = Json "$ReceiverBaseUrl/events"
    $resolvedEvent = @($receiverState.events | Where-Object deliveryId -eq $resolvedId)[0]
    $attemptIds = @($receiverState.attempts | Where-Object { $_.deliveryId -eq $resolvedEvent.deliveryId } | Select-Object -ExpandProperty deliveryId -Unique)
    if ($attemptIds.Count -ne 1) { throw 'Retry did not retain a stable delivery identity.' }
    $confirmedCount = @($receiverState.events | Where-Object { $_.deliveryId -in @($startedId, $resolvedId) }).Count
    $applicationRestartReplacement = {
        $m11FixtureState.MutationStarted = $true
        Invoke-M11Compose ($replacementComposeArgs + @('rm', '-sf', 'backend')) 'terminal-delivery backend detach'
        Invoke-M11Compose ($replacementComposeArgs + @('up', '-d', '--no-deps', '--force-recreate', 'backend')) 'terminal-delivery backend replacement'
    }.GetNewClosure()
    $null = Invoke-M11BackendGenerationReplacement -CaptureRoot $captureRoot -Root $root `
        -Reason 'm11-terminal-delivery-application-restart' -Replace $applicationRestartReplacement
    Wait-Until {
        try {
            (Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 10).StatusCode -eq 200
        } catch [System.Net.WebException] { $false } catch [System.Net.Http.HttpRequestException] { $false }
    } $deadline 'Backend did not recover after terminal-delivery restart.'
    Start-Sleep -Seconds 4
    if (@((Json "$ReceiverBaseUrl/events").events | Where-Object { $_.deliveryId -in @($startedId, $resolvedId) }).Count -ne $confirmedCount) { throw 'Restart redelivered confirmed successful work.' }

    $public = (Invoke-GeordiScriptRequest -Uri "$BackendBaseUrl/api/platform").Content
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
    $runtimeLogs = & docker compose @composeArgs logs --no-color backend webhook-receiver
    if (($runtimeLogs -join "`n") -match 'local-dev-only-token') { throw 'Notification secret leaked through runtime logs.' }
    & (Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1') -Phase m11-final -Services backend,victoriametrics -SkipLogSnapshot | Out-Null
    if ($PreserveFixtureForNextStage) {
        $resolveIdentity = { param([string] $Service) Get-GeordiCurrentCaptureContainerIdentity -Service $Service -RepositoryRoot $root }.GetNewClosure()
        $dockerCommand = {
            param([string[]] $Arguments)
            $output = & docker @Arguments 2>$null
            $exitCode = $LASTEXITCODE
            return [pscustomobject]@{ ExitCode=$exitCode;Output=@($output) }
        }.GetNewClosure()
        $inspectVolume = { param([string] $Name) Get-GeordiM11DockerVolumeInspection -Name $Name -DockerCommand $dockerCommand }.GetNewClosure()
        $testFollower = { param($Record) Test-GeordiM11TransferFollowerProcess -FollowerRecord $Record }.GetNewClosure()
        $expectedVolumes = Get-M11FixtureVolumes $root $composeArgs
        $null = Assert-GeordiM11M12FixtureTransfer -CaptureRoot $captureRoot -RepositoryRoot $root `
            -ResolveIdentity $resolveIdentity -InspectVolume $inspectVolume -TestFollowerProcess $testFollower `
            -ExpectedVolumes $expectedVolumes -ExpectedCollectorContainerId $m11CollectorBaselineContainerId
        $m11FixtureState.TransferCommitted = $true
    }
    Write-Host 'PASS: atomic STARTED/RESOLVED webhook delivery, stable identity, retry/restart recovery, no-transition suppression, terminal success, and secret isolation verified.'
    exit 0
} catch { Write-Error "Notification Delivery smoke failed: $($_.Exception.Message)"; exit 1 }
finally {
    if (Test-GeordiM11FixtureCleanupRequired -FixtureOwned $m11FixtureState.FixtureOwned `
            -MutationStarted $m11FixtureState.MutationStarted -TransferCommitted $m11FixtureState.TransferCommitted) {
        Remove-M11Fixture $root $replacementComposeArgs $captureRoot
    }
}
