[CmdletBinding()]
param(
    [string] $BackendBaseUrl = 'https://geordi.localhost:8443',
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')

function Assert-Status {
    param([int] $Actual, [int] $Expected, [string] $Label)
    if ($Actual -ne $Expected) { throw "M19 security smoke: $Label expected HTTP $Expected, got $Actual." }
}

function Read-JsonBody($Response) {
    if (!$Response.Content) { return $null }
    return $Response.Content | ConvertFrom-Json
}

try {
    $composeArgs = @('-f', (Join-Path $RepositoryRoot 'compose.yaml'), '-f', (Join-Path $RepositoryRoot 'compose.m19.yaml'))
    & docker compose @composeArgs up -d demo-downstream burn-demo
    if ($LASTEXITCODE -ne 0) { throw 'M19 security smoke could not start its isolated telemetry fixture.' }

    $startupDeadline = (Get-Date).AddSeconds(45)
    do {
        try {
            $ready = Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/health/readiness" -TimeoutSeconds 3
            if ($ready.StatusCode -eq 200) { break }
        } catch { }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $startupDeadline)
    if (!$ready -or $ready.StatusCode -ne 200) { throw 'M19 security smoke backend did not become ready through trusted TLS ingress.' }

    # Liveness/readiness are intentionally anonymous and expose no details.
    $probes = @(
        @{ Path = '/actuator/health/liveness'; Method = 'GET' },
        @{ Path = '/actuator/health/liveness'; Method = 'HEAD' },
        @{ Path = '/actuator/health/readiness'; Method = 'GET' },
        @{ Path = '/actuator/health/readiness'; Method = 'HEAD' }
    )
    foreach ($probe in $probes) {
        $response = Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl$($probe.Path)" -Method $probe.Method -TimeoutSeconds 10
        Assert-Status $response.StatusCode 200 "$($probe.Method) $($probe.Path)"
        if ($probe.Method -eq 'HEAD' -and $response.Content) { throw 'M19 security smoke: HEAD probe returned a body.' }
        if ($probe.Method -eq 'GET') {
            $body = Read-JsonBody $response
            $fields = @()
            if ($body) { $fields = @($body.PSObject.Properties | ForEach-Object { $_.Name }) }
            if ($fields.Count -ne 1 -or $fields[0] -cne 'status') {
                throw 'M19 security smoke: probe response was not exactly status-only.'
            }
        }
    }

    $anonymous = Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/api/platform" -TimeoutSeconds 10
    Assert-Status $anonymous.StatusCode 401 'anonymous protected read'
    $unlistedMethod = Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/api/platform" -Method POST -TimeoutSeconds 10
    Assert-Status $unlistedMethod.StatusCode 401 'unlisted application method without credentials'
    $unlistedActuator = Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator/metrics" -TimeoutSeconds 10
    Assert-Status $unlistedActuator.StatusCode 404 'broader actuator denial'
    $actuatorRoot = Invoke-GeordiAnonymousRequest -Uri "$BackendBaseUrl/actuator" -TimeoutSeconds 10
    Assert-Status $actuatorRoot.StatusCode 404 'actuator root denial'

    Initialize-GeordiAuthentication -Identity VIEWER -RepositoryRoot $RepositoryRoot
    $viewer = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/platform"
    Assert-Status $viewer.StatusCode 200 'VIEWER protected read'
    $invalidSignature = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/platform" -SecurityCase INVALID_SIGNATURE
    Assert-Status $invalidSignature.StatusCode 401 'invalid JWT signature'
    $duplicateAuthorization = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/platform" -SecurityCase DUPLICATE_AUTHORIZATION
    Assert-Status $duplicateAuthorization.StatusCode 400 'duplicate Authorization headers'
    $duplicateSession = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/platform" -SecurityCase DUPLICATE_SESSION_COOKIE
    Assert-Status $duplicateSession.StatusCode 400 'duplicate session cookies'
    $unknownSessionBearer = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/platform" -SecurityCase UNKNOWN_SESSION_WITH_BEARER
    Assert-Status $unknownSessionBearer.StatusCode 200 'unknown session cookie with valid bearer'
    Initialize-GeordiAuthentication -Identity VIEWER -WrongAudience -RepositoryRoot $RepositoryRoot
    $wrongAudience = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/platform"
    Assert-Status $wrongAudience.StatusCode 401 'wrong JWT audience'
    Initialize-GeordiAuthentication -Identity VIEWER -IdToken -RepositoryRoot $RepositoryRoot
    $idToken = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/platform"
    Assert-Status $idToken.StatusCode 401 'ID token used as API token'
    Initialize-GeordiAuthentication -Identity VIEWER -RepositoryRoot $RepositoryRoot
    $episodes = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-episodes?policyId=burn-smoke-alert&state=OPEN&limit=1"
    $episodePayload = Read-JsonBody $episodes
    $episode = @($episodePayload.alertEpisodes)[0]
    if (!$episode -or !$episode.id) {
        # Seed only the M19 database from a controlled error workload and require
        # provider evidence before applying lifecycle work.
        $deadline = (Get-Date).AddSeconds(90)
        do {
            try {
                $ready = Invoke-WebRequest -Uri 'http://127.0.0.1:8083/actuator/health/readiness' -UseBasicParsing -TimeoutSec 3 -SkipHttpErrorCheck
                if ($ready.StatusCode -eq 200) { break }
            } catch { }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
        do {
            try { $traffic = Invoke-WebRequest -Uri 'http://127.0.0.1:8083/demo/error' -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck }
            catch { Start-Sleep -Seconds 2; continue }
            if ($traffic.StatusCode -ne 500) { throw 'M19 security smoke error fixture did not return its expected 500 positive control.' }
            Start-Sleep -Seconds 2
            $catalog = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-policies/burn-smoke-alert/evaluation"
            $catalogPayload = Read-JsonBody $catalog
        } while ($catalog.StatusCode -ne 200 -or $catalogPayload.status -ne 'CONDITION_MET' -and (Get-Date) -lt $deadline)
        if ($catalog.StatusCode -ne 200 -or $catalogPayload.status -ne 'CONDITION_MET') {
            throw 'M19 security smoke could not produce independently observable burn evidence.'
        }
        Initialize-GeordiAuthentication -Identity EVALUATOR -RepositoryRoot $RepositoryRoot
        $seed = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-policies/burn-smoke-alert/lifecycle-evaluations" -Method POST
        Assert-Status $seed.StatusCode 200 'isolated lifecycle fixture creation'
        Initialize-GeordiAuthentication -Identity VIEWER -RepositoryRoot $RepositoryRoot
        $episodes = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-episodes?policyId=burn-smoke-alert&state=OPEN&limit=1"
        $episodePayload = Read-JsonBody $episodes
        $episode = @($episodePayload.alertEpisodes)[0]
        if (!$episode -or !$episode.id) { throw 'M19 security smoke could not seed its dedicated acknowledgement episode.' }
    }
    $ackPath = "$BackendBaseUrl/api/alert-episodes/$([uri]::EscapeDataString([string]$episode.id))/acknowledgements"
    $episodeDetailResponse = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-episodes/$([uri]::EscapeDataString([string]$episode.id))"
    Assert-Status $episodeDetailResponse.StatusCode 200 'isolated episode detail'
    $existingAcknowledgement = (Read-JsonBody $episodeDetailResponse).acknowledgement
    $ackBody = if ($existingAcknowledgement) { @{ reason = $existingAcknowledgement.reason } } else { @{ reason = 'M19 isolated authorization smoke' } }
    $viewerAck = Invoke-GeordiAuthenticatedRequest -Uri $ackPath -Method POST -Body $ackBody
    Assert-Status $viewerAck.StatusCode 403 'VIEWER ACK'

    Initialize-GeordiAuthentication -Identity OPERATOR -RepositoryRoot $RepositoryRoot
    $actorAck = Invoke-GeordiAuthenticatedRequest -Uri $ackPath -Method POST -Body @{ actor = 'spoof'; reason = 'M19 actor rejection' }
    Assert-Status $actorAck.StatusCode 400 'actor-bearing ACK'
    $created = Invoke-GeordiAuthenticatedRequest -Uri $ackPath -Method POST -Body $ackBody
    $expectedAckStatus = if ($existingAcknowledgement) { 200 } else { 201 }
    Assert-Status $created.StatusCode $expectedAckStatus 'OPERATOR reason-only ACK or persisted idempotent replay'
    $createdBody = Read-JsonBody $created
    if ($createdBody.attribution.provenance -cne 'AUTHENTICATED_PRINCIPAL' -or
        $createdBody.attribution.identity.issuer -cne 'https://auth.localhost' -or
        $createdBody.attribution.identity.subject -cne 'm19-operator') {
        throw 'M19 security smoke: persisted ACK principal provenance did not match the signed OPERATOR token.'
    }
    $replay = Invoke-GeordiAuthenticatedRequest -Uri $ackPath -Method POST -Body $ackBody
    Assert-Status $replay.StatusCode 200 'identical OPERATOR ACK replay'
    $replayedBody = Read-JsonBody $replay
    if ($replayedBody.acknowledgedAt -cne $createdBody.acknowledgedAt -or
        $replayedBody.actor -cne $createdBody.actor -or $replayedBody.reason -cne $createdBody.reason -or
        $replayedBody.attribution.displayName -cne $createdBody.attribution.displayName) {
        throw 'M19 security smoke: idempotent ACK replay changed the original snapshot.'
    }
    Initialize-GeordiAuthentication -Identity OPERATOR -AlternateOperator -RepositoryRoot $RepositoryRoot
    $identityConflict = Invoke-GeordiAuthenticatedRequest -Uri $ackPath -Method POST -Body $ackBody
    Assert-Status $identityConflict.StatusCode 409 'conflicting ACK identity'
    Initialize-GeordiAuthentication -Identity OPERATOR -RepositoryRoot $RepositoryRoot
    $reasonConflict = Invoke-GeordiAuthenticatedRequest -Uri $ackPath -Method POST -Body @{ reason = 'different M19 reason' }
    Assert-Status $reasonConflict.StatusCode 409 'conflicting normalized ACK reason'

    $policiesResponse = Invoke-GeordiAuthenticatedRequest -Uri "$BackendBaseUrl/api/alert-policies"
    Assert-Status $policiesResponse.StatusCode 200 'VIEWER policy catalog'
    $policy = @((Read-JsonBody $policiesResponse).alertPolicies)[0]
    if (!$policy -or !$policy.id) { throw 'M19 security smoke requires an existing lifecycle policy.' }
    Initialize-GeordiAuthentication -Identity EVALUATOR -RepositoryRoot $RepositoryRoot
    $lifecyclePath = "$BackendBaseUrl/api/alert-policies/$([uri]::EscapeDataString([string]$policy.id))/lifecycle-evaluations"
    $evaluation = Invoke-GeordiAuthenticatedRequest -Uri $lifecyclePath -Method POST
    Assert-Status $evaluation.StatusCode 200 'EVALUATOR manual lifecycle evaluation'
    Initialize-GeordiAuthentication -Identity OPERATOR -RepositoryRoot $RepositoryRoot
    $operatorEvaluation = Invoke-GeordiAuthenticatedRequest -Uri $lifecyclePath -Method POST
    Assert-Status $operatorEvaluation.StatusCode 403 'OPERATOR lifecycle evaluation denial'

    Write-Output 'M19 security smoke passed: probes, anonymous denial, signed VIEWER/OPERATOR/EVALUATOR permissions, and authenticated ACK provenance/idempotency/conflicts.'
} finally {
    Clear-GeordiAuthentication
}
