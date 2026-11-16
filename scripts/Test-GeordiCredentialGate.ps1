[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to run the bounded fail-closed gate simulations.' }
. (Join-Path $PSScriptRoot 'lib/GeordiCredentialGateOrchestration.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-capture-selftest-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$requiredGate = Join-Path $PSScriptRoot 'Test-GeordiCredentialGateRequired.ps1'
$channels = @('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo')
$secret = 'gate-sentinel-' + [guid]::NewGuid().ToString('N') + '/+=' 

function Assert-PrivateGateFails {
    param([scriptblock] $Action, [string] $Label, [string] $ForbiddenOutput)
    try { & $Action; throw "Gate accepted controlled failure: $Label" }
    catch {
        if ($_.Exception.Message -like "Gate accepted controlled failure: $Label") { throw }
        if ($ForbiddenOutput -and $_.Exception.Message.Contains($ForbiddenOutput, [StringComparison]::Ordinal)) {
            throw 'A credential value escaped into the test diagnostic.'
        }
    }
}

try {
    $manifest = @{ version=2; root=$root; runId='credential-gate-self-test';
        startedUtc=[DateTimeOffset]::UtcNow.ToString('o'); captureStartedUtc=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o');
        completedUtc=[DateTimeOffset]::UtcNow.ToString('o'); sentinels=@($secret); controls=@{}; captures=@{};
        captureMetadata=@{}; additionalSources=@() }
    foreach ($channel in $channels) {
        $control = 'control-' + $channel + '-' + [guid]::NewGuid().ToString('N')
        $file = Join-Path $root ($channel + '.capture')
        [IO.File]::WriteAllText($file, $control)
        $manifest.controls[$channel] = $control
        $manifest.captures[$channel] = @($file)
    }
    foreach ($channel in @('backend','otel','collector')) {
        $capturePath=[string]$manifest.captures[$channel][0]
        $length=(Get-Item -LiteralPath $capturePath).Length
        $manifest.captureMetadata[$channel]=@{
            version=1;complete=$true;runId=$manifest.runId;captureStartedUtc=$manifest.captureStartedUtc
            captureCompletedUtc=[DateTimeOffset]::UtcNow.ToString('o');logicalByteCount=$length
            maximumLogicalByteCount=(Get-GeordiPrivateCaptureLimit $channel);fileCount=1
            overlapPolicy='all ordered files retained and scanned independently';positiveControlFound=$true
            files=@(@{order=0;identity=[IO.Path]::GetFileName($capturePath);path=$capturePath;startOffset=0L;
                endOffsetExclusive=[long]$length;byteCount=[long]$length;sha256=(Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash.ToLowerInvariant()})
        }
    }

    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $artifactRoots = @(
        'backend/target/surefire-reports','backend/target/pmd.xml',
        'backend/target/spotbugsXml.xml','backend/target/geordi-backend-0.1.0-SNAPSHOT.jar',
        'backend/target/geordi-backend-0.1.0-SNAPSHOT-security-telemetry.jar',
        'backend/.ci-artifact/application.jar','backend/.ci-artifact/security-telemetry.jar',
        'backend/target/verified-artifact.properties','frontend/dist')
    $artifactFiles = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($relative in $artifactRoots) {
        $path = Join-Path $repositoryRoot $relative
        if (!(Test-Path -LiteralPath $path)) {
            if ($relative -in @('backend/.ci-artifact/application.jar','backend/.ci-artifact/security-telemetry.jar')) { continue }
            throw 'Gate self-test requires built publishable artifacts.'
        }
        $item = Get-Item -LiteralPath $path
        if ($item.PSIsContainer) {
            foreach ($file in Get-ChildItem -LiteralPath $path -File -Recurse) { $artifactFiles.Add($file) }
        } else { $artifactFiles.Add($item) }
    }
    $failsafeRoot = Join-Path $repositoryRoot 'backend/target/failsafe-reports'
    if (Test-Path -LiteralPath $failsafeRoot) {
        foreach ($file in Get-ChildItem -LiteralPath $failsafeRoot -File -Recurse) { $artifactFiles.Add($file) }
    }
    $archiveCount = 0; $archiveEntryCount = 0
    foreach ($file in $artifactFiles) {
        if ($file.Extension -in @('.jar','.zip')) {
            $archiveCount++
            $archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
            try { $archiveEntryCount += $archive.Entries.Count } finally { $archive.Dispose() }
        }
    }
    $inventoryPath = Join-Path $root 'publishable-artifact-inventory.json'
    $artifactEntries = @($artifactFiles | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($repositoryRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\','/')
        @{ path=$relative; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -Depth 8 -Compress @{ artifactInventory='complete';
        fileCount=$artifactFiles.Count; archiveCount=$archiveCount; archiveEntryCount=$archiveEntryCount; files=$artifactEntries }))
    $manifest.controls['ci-artifacts'] = 'artifactInventory'
    $manifest.captures['ci-artifacts'] = @($inventoryPath) + @($artifactFiles | ForEach-Object FullName)

    foreach ($channel in @('loki','victoriametrics')) {
        $control = if ($channel -eq 'loki') { 'Security decision' } else { 'geordi.security.authentication.attempts' }
        $file = Join-Path $root ($channel + '.json')
        $payload = if ($channel -eq 'loki') {
            @{ status='success'; data=@{result=@(@{line=$control})} }
        } else { $null }
        $currentMetricTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $persistedCapture = if ($channel -eq 'loki') { ConvertTo-Json $payload -Depth 5 -Compress } else {
            (@{ metric=@{ '__name__'='geordi.security.authentication.attempts'; 'service.name'='geordi-backend'; 'geordi.telemetry.origin'='platform' }; values=@(1); timestamps=@($currentMetricTimestamp) } | ConvertTo-Json -Depth 5 -Compress) + "`n" +
            (@{ metric=@{ '__name__'='geordi.test.unrelated_metric'; service_name='geordi-backend'; geordi_telemetry_origin='platform'; http_request_header_authorization='' }; values=@(0); timestamps=@($currentMetricTimestamp) } | ConvertTo-Json -Depth 5 -Compress)
        }
        [IO.File]::WriteAllText($file, $persistedCapture)
        $manifest.additionalSources += @{ channel=$channel; control=$control; captures=@($file) }
    }
    $initialVictoriaFixture = [string](@($manifest.additionalSources | Where-Object channel -eq 'victoriametrics')[0].captures[0])
    $manifest.persistedMetricEvidenceBytes = [long](Get-Item -LiteralPath $initialVictoriaFixture).Length
    $manifest.completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $manifestPath = Join-Path $root 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json $manifest -Depth 8), [Text.UTF8Encoding]::new($false))

    Assert-PrivateGateFails { & $requiredGate -ManifestPath (Join-Path $root 'missing.json') } 'missing manifest' $secret
    Write-Output 'gate_case=missing_manifest result=FAIL_CLOSED'

    $artifactRan=$false
    $orchestration=Invoke-GeordiM19EvidenceGates -Finalize { throw 'controlled finalize failure' } `
        -CredentialScan { throw 'controlled credential failure' } -ArtifactScan { $script:artifactRan=$true; 'artifact completed' }
    if ($orchestration.Status.finalize -ne 'FAIL' -or $orchestration.Status.credentialScan -ne 'FAIL' -or
            $orchestration.Status.artifactScan -ne 'PASS' -or !$script:artifactRan) {
        throw 'Publishable artifact scan did not run independently after runtime evidence failure.'
    }
    Write-Output 'gate_case=artifact_scan_independent_after_runtime_failure result=PASS'

    $malformedPath = Join-Path $root 'malformed.json'
    [IO.File]::WriteAllText($malformedPath, '{"version":', [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $malformedPath } 'malformed manifest' $secret
    Write-Output 'gate_case=malformed_manifest result=FAIL_CLOSED'

    $broken = $manifest.Clone(); $broken.controls = $manifest.controls.Clone(); $broken.controls.browser = 'missing-control'
    $brokenPath = Join-Path $root 'missing-positive.json'
    [IO.File]::WriteAllText($brokenPath, (ConvertTo-Json $broken -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $brokenPath } 'missing positive control' $secret
    Write-Output 'gate_case=missing_positive_control result=FAIL_CLOSED'

    [IO.File]::AppendAllText($manifest.captures.backend[0], [Uri]::EscapeDataString($secret))
    $backendFixture = [string]$manifest.captures.backend[0]
    $backendFixtureLength = (Get-Item -LiteralPath $backendFixture).Length
    $manifest.captureMetadata.backend.logicalByteCount = [long]$backendFixtureLength
    $manifest.captureMetadata.backend.files[0].endOffsetExclusive = [long]$backendFixtureLength
    $manifest.captureMetadata.backend.files[0].byteCount = [long]$backendFixtureLength
    $manifest.captureMetadata.backend.files[0].sha256 = (Get-FileHash -LiteralPath $backendFixture -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 12), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $manifestPath } 'synthetic leak' $secret
    [IO.File]::WriteAllText($manifest.captures.backend[0], $manifest.controls.backend)
    $backendFixtureLength = (Get-Item -LiteralPath $backendFixture).Length
    $manifest.captureMetadata.backend.logicalByteCount = [long]$backendFixtureLength
    $manifest.captureMetadata.backend.files[0].endOffsetExclusive = [long]$backendFixtureLength
    $manifest.captureMetadata.backend.files[0].byteCount = [long]$backendFixtureLength
    $manifest.captureMetadata.backend.files[0].sha256 = (Get-FileHash -LiteralPath $backendFixture -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 12), [Text.UTF8Encoding]::new($false))
    Write-Output 'gate_case=synthetic_leak result=FAIL_CLOSED diagnostic=sanitized'

    $metricSentinel = 'metric-label-leak-' + [guid]::NewGuid().ToString('N')
    $victoriaFixture = [string](@($manifest.additionalSources | Where-Object channel -eq 'victoriametrics')[0].captures[0])
    $victoriaOriginal = Get-Content -LiteralPath $victoriaFixture -Raw
    $victoriaOriginalLength = [long](Get-Item -LiteralPath $victoriaFixture).Length
    $victoriaPayload = [IO.File]::ReadAllText($victoriaFixture)
    $victoriaPayload += "`n" + (@{ metric=@{ '__name__'='geordi.test.unrelated_metric'; service_name='geordi-backend'; geordi_telemetry_origin='platform'; http_request_header_authorization=$metricSentinel }; values=@(1); timestamps=@([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) } | ConvertTo-Json -Depth 8 -Compress)
    [IO.File]::WriteAllText($victoriaFixture, $victoriaPayload, [Text.UTF8Encoding]::new($false))
    $manifest.sentinels += $metricSentinel
    $manifest.persistedMetricEvidenceBytes = [long](Get-Item -LiteralPath $victoriaFixture).Length
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 12), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $manifestPath } 'unrelated metric label leak' $metricSentinel
    [IO.File]::WriteAllText($victoriaFixture, $victoriaOriginal, [Text.UTF8Encoding]::new($false))
    $manifest.sentinels = @($manifest.sentinels | Where-Object { $_ -cne $metricSentinel })
    $manifest.persistedMetricEvidenceBytes = $victoriaOriginalLength
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 12), [Text.UTF8Encoding]::new($false))
    Write-Output 'gate_case=unrelated_metric_label_leak result=FAIL_CLOSED diagnostic=sanitized'

    $missingTempo = $manifest.Clone(); $missingTempo.captures = $manifest.captures.Clone()
    $missingTempo.captures.tempo = @()
    $missingTempoPath = Join-Path $root 'missing-tempo.json'
    [IO.File]::WriteAllText($missingTempoPath, (ConvertTo-Json $missingTempo -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $missingTempoPath } 'Tempo unavailable' $secret

    $missingLoki = $manifest.Clone(); $missingLoki.additionalSources = @($manifest.additionalSources | Where-Object channel -ne 'loki')
    $missingLokiPath = Join-Path $root 'missing-loki.json'
    [IO.File]::WriteAllText($missingLokiPath, (ConvertTo-Json $missingLoki -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $missingLokiPath } 'Loki unavailable' $secret

    $missingVictoria = $manifest.Clone(); $missingVictoria.additionalSources = @($manifest.additionalSources | Where-Object channel -ne 'victoriametrics')
    $missingVictoriaPath = Join-Path $root 'missing-victoriametrics.json'
    [IO.File]::WriteAllText($missingVictoriaPath, (ConvertTo-Json $missingVictoria -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $missingVictoriaPath } 'VictoriaMetrics unavailable' $secret
    Write-Output 'gate_case=persisted_tempo_loki_victoriametrics_unavailable result=FAIL_CLOSED'

    $badInventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $badInventory.fileCount++
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json $badInventory -Compress))
    $artifactScanner=Join-Path $PSScriptRoot 'Test-GeordiPublishableArtifacts.ps1'
    Assert-PrivateGateFails { & $artifactScanner -ManifestPath $manifestPath } 'artifact scan unavailable' $secret
    $badInventory.fileCount--
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json $badInventory -Compress))
    Write-Output 'gate_case=artifact_inventory_unavailable result=FAIL_CLOSED'

    $independentArtifactOutput=@(& $artifactScanner -Independent)
    if ($independentArtifactOutput.Count -ne 1 -or $independentArtifactOutput[0] -notmatch 'result=PASS') {
        throw 'Independent publishable artifact scan failed.'
    }
    Write-Output 'gate_case=artifact_scan_without_runtime_manifest result=PASS'

    $validGateOutput = @(& $requiredGate -ManifestPath $manifestPath `
        -SummaryPath (Join-Path $root 'gate-summary.txt') -DiagnosticFailure)
    $timing = @($validGateOutput | Where-Object { $_ -match '^required_credential_gate_seconds=' })
    if ($timing.Count -ne 1) { throw 'Clean required gate timing is missing.' }
    Write-Output $timing[0]
    Write-Output 'gate_case=valid_manifest result=PASS'

    $diagnostic = @(& (Join-Path $PSScriptRoot 'Write-GeordiSafeDiagnostics.ps1') `
        -SummaryPath (Join-Path $root 'missing-summary.txt')) -join "`n"
    if ($diagnostic -notmatch '^diagnostics=withheld reason=required-gate-not-passed$' -or
            $diagnostic.Contains($secret, [StringComparison]::Ordinal)) {
        throw 'Failure diagnostics were not bounded and sanitized.'
    }
    Write-Output 'gate_case=failure_diagnostics result=PASS diagnostic=sanitized'
    Write-Output 'Required credential gate self-test passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $expectedParent -or
            (Split-Path $resolved -Leaf) -notmatch '^geordi-m19-capture-selftest-[0-9a-f]{32}$') {
        throw 'Unsafe gate self-test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
