[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to run the bounded fail-closed gate simulations.' }
. (Join-Path $PSScriptRoot 'lib/GeordiCredentialGateOrchestration.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiTempoEvidence.ps1')

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
        $manifest.controls[$channel] = $control
        if ($channel -ceq 'tempo') { continue }
        $file = Join-Path $root ($channel + '.capture')
        [IO.File]::WriteAllText($file, $control)
        $manifest.captures[$channel] = @($file)
    }

    $tempoDirectory = Join-Path $root 'tempo-segments'
    $tempoWriter = [GeordiTempoSegmentWriter]::new($tempoDirectory,33554432L,167772160L,256,67108864L)
    try {
        $tempoBytes = [Text.Encoding]::UTF8.GetBytes('{"resource":{"service.name":"' + $manifest.controls.tempo + '"}}')
        $tempoWriter.BeginRecord(1L)
        $tempoWriter.WriteRecordBytes($tempoBytes,$tempoBytes.Length)
        $tempoWriter.CompleteRecord()
        $tempoMetadata = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $tempoWriter.Complete() -Depth 20 -Compress) -AsHashtable
        $tempoMetadata.runId = [string]$manifest.runId
        $tempoMetadata.captureStartedUtc = [string]$manifest.captureStartedUtc
        $tempoMetadata.captureCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $manifest.captureMetadata.tempo = $tempoMetadata
        $manifest.captures.tempo = @($tempoMetadata.segments | ForEach-Object { [string]$_.path })
    } finally {
        $tempoWriter.Dispose()
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

    $artifactRoot = Join-Path $root 'publishable-artifacts'
    $artifactDirectories = @(
        'backend/target/surefire-reports',
        'backend/target',
        'frontend/dist'
    )
    foreach ($relativeDirectory in $artifactDirectories) {
        [void][IO.Directory]::CreateDirectory((Join-Path $artifactRoot $relativeDirectory))
    }
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'backend/target/surefire-reports/TEST-geordi.xml'), '<testsuite tests="1" failures="0"/>')
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'backend/target/pmd.xml'), '<pmd/>')
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'backend/target/spotbugsXml.xml'), '<BugCollection/>')
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'backend/target/verified-artifact.properties'), 'verified=true')

    foreach ($archiveName in @('geordi-backend-0.1.0-SNAPSHOT.jar','geordi-backend-0.1.0-SNAPSHOT-security-telemetry.jar')) {
        $archivePath = Join-Path $artifactRoot ('backend/target/' + $archiveName)
        $archive = [IO.Compression.ZipFile]::Open($archivePath,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry('META-INF/MANIFEST.MF')
            $writer = [IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
            try { $writer.Write("Manifest-Version: 1.0" + [Environment]::NewLine) } finally { $writer.Dispose() }
        } finally { $archive.Dispose() }
    }
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'frontend/dist/index.html'), '<!doctype html><title>synthetic artifact</title>')

    $artifactModule = Join-Path $PSScriptRoot 'lib/GeordiPublishableArtifacts.psm1'
    Import-Module $artifactModule -Force -ErrorAction Stop
    try {
        $artifactInventory = Get-GeordiPublishableArtifactInventory -RootPath $artifactRoot -Mode SelfTest
        $artifactInventory = Test-GeordiPublishableArtifactInventory -RootPath $artifactRoot -ExpectedInventory $artifactInventory -Mode SelfTest
        $artifactInventory = Test-GeordiPublishableArtifactContent -RootPath $artifactRoot -Inventory $artifactInventory -Mode SelfTest
    } finally {
        Remove-Module GeordiPublishableArtifacts -ErrorAction SilentlyContinue
    }
    $inventoryPath = Join-Path $root 'publishable-artifact-inventory.json'
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject $artifactInventory -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    $manifest.controls['ci-artifacts'] = 'artifactInventory'
    $manifest.captures['ci-artifacts'] = @($inventoryPath) + @($artifactInventory.files | ForEach-Object {
        Join-Path $artifactRoot ([string]$_.path.Replace('/',[IO.Path]::DirectorySeparatorChar))
    })

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

    $attemptId = [guid]::NewGuid().ToString('N')
    $attemptPhases = @{}
    foreach ($phase in @('tempo-search','tempo-detail','loki','victoriametrics','artifact-scan','manifest')) {
        $attemptPhases[$phase] = @{ status='PASS'; recordedUtc=$manifest.completedUtc; details=@{} }
    }
    $manifest.acceptedAttemptId = $attemptId
    $manifest.attempts = @{
        $attemptId = @{
            attemptId=$attemptId
            status='completed'
            completedUtc=$manifest.completedUtc
            root=(Join-Path (Join-Path $root 'finalize-attempts') $attemptId)
            phases=$attemptPhases
            channels=@{
                controls=$manifest.controls
                captures=$manifest.captures
                captureMetadata=$manifest.captureMetadata
            }
            additionalSources=@($manifest.additionalSources)
        }
    }
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

    $broken = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $manifest -Depth 24 -Compress) -AsHashtable
    $broken.controls.browser = 'missing-control'
    $broken.attempts[$attemptId].channels.controls = $broken.controls
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

    $missingTempo = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $manifest -Depth 24 -Compress) -AsHashtable
    $missingTempo.captures.tempo = @()
    $missingTempo.attempts[$attemptId].channels.captures = $missingTempo.captures
    $missingTempoPath = Join-Path $root 'missing-tempo.json'
    [IO.File]::WriteAllText($missingTempoPath, (ConvertTo-Json $missingTempo -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $missingTempoPath } 'Tempo unavailable' $secret

    $missingLoki = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $manifest -Depth 24 -Compress) -AsHashtable
    $missingLoki.additionalSources = @($missingLoki.additionalSources | Where-Object channel -ne 'loki')
    $missingLoki.attempts[$attemptId].additionalSources = @($missingLoki.additionalSources)
    $missingLokiPath = Join-Path $root 'missing-loki.json'
    [IO.File]::WriteAllText($missingLokiPath, (ConvertTo-Json $missingLoki -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $missingLokiPath } 'Loki unavailable' $secret

    $missingVictoria = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $manifest -Depth 24 -Compress) -AsHashtable
    $missingVictoria.additionalSources = @($missingVictoria.additionalSources | Where-Object channel -ne 'victoriametrics')
    $missingVictoria.attempts[$attemptId].additionalSources = @($missingVictoria.additionalSources)
    $missingVictoriaPath = Join-Path $root 'missing-victoriametrics.json'
    [IO.File]::WriteAllText($missingVictoriaPath, (ConvertTo-Json $missingVictoria -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $requiredGate -ManifestPath $missingVictoriaPath } 'VictoriaMetrics unavailable' $secret
    Write-Output 'gate_case=persisted_tempo_loki_victoriametrics_unavailable result=FAIL_CLOSED'

    $badInventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $badInventory.fileCount++
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json $badInventory -Compress))
    $artifactScanner=Join-Path $PSScriptRoot 'Test-GeordiPublishableArtifacts.ps1'
    Assert-PrivateGateFails { & $artifactScanner -ManifestPath $manifestPath -RootPath $artifactRoot } 'artifact scan unavailable' $secret
    $badInventory.fileCount--
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json $badInventory -Compress))
    Write-Output 'gate_case=artifact_inventory_unavailable result=FAIL_CLOSED'

    $originalIndex = [IO.File]::ReadAllText((Join-Path $artifactRoot 'frontend/dist/index.html'))
    [IO.File]::AppendAllText((Join-Path $artifactRoot 'frontend/dist/index.html'), 'changed-after-inventory')
    Assert-PrivateGateFails { & $artifactScanner -ManifestPath $manifestPath -RootPath $artifactRoot } 'artifact digest changed' $secret
    [IO.File]::WriteAllText((Join-Path $artifactRoot 'frontend/dist/index.html'), $originalIndex, [Text.UTF8Encoding]::new($false))
    Write-Output 'gate_case=artifact_digest_mutation result=FAIL_CLOSED'

    $unsafeArchivePath = Join-Path $artifactRoot 'frontend/dist/unsafe.zip'
    $unsafeArchive = [IO.Compression.ZipFile]::Open($unsafeArchivePath,[IO.Compression.ZipArchiveMode]::Create)
    try {
        $unsafeEntry = $unsafeArchive.CreateEntry('oidc-fixture/fixture.txt')
        $unsafeWriter = [IO.StreamWriter]::new($unsafeEntry.Open(),[Text.UTF8Encoding]::new($false))
        try { $unsafeWriter.Write('synthetic forbidden fixture') } finally { $unsafeWriter.Dispose() }
    } finally { $unsafeArchive.Dispose() }
    Import-Module $artifactModule -Force -ErrorAction Stop
    try {
        $artifactInventory = Get-GeordiPublishableArtifactInventory -RootPath $artifactRoot -Mode SelfTest
    } finally {
        Remove-Module GeordiPublishableArtifacts -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject $artifactInventory -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    $manifest.captures['ci-artifacts'] = @($inventoryPath) + @($artifactInventory.files | ForEach-Object {
        Join-Path $artifactRoot ([string]$_.path.Replace('/',[IO.Path]::DirectorySeparatorChar))
    })
    $manifest.attempts[$attemptId].channels.captures = $manifest.captures
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 12), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $artifactScanner -ManifestPath $manifestPath -RootPath $artifactRoot } 'forbidden archive entry' $secret
    Remove-Item -LiteralPath $unsafeArchivePath -Force
    Import-Module $artifactModule -Force -ErrorAction Stop
    try {
        $artifactInventory = Get-GeordiPublishableArtifactInventory -RootPath $artifactRoot -Mode SelfTest
    } finally {
        Remove-Module GeordiPublishableArtifacts -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject $artifactInventory -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    $manifest.captures['ci-artifacts'] = @($inventoryPath) + @($artifactInventory.files | ForEach-Object {
        Join-Path $artifactRoot ([string]$_.path.Replace('/',[IO.Path]::DirectorySeparatorChar))
    })
    $manifest.attempts[$attemptId].channels.captures = $manifest.captures
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 12), [Text.UTF8Encoding]::new($false))
    Write-Output 'gate_case=forbidden_archive_entry result=FAIL_CLOSED'

    $traversalInventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $traversalInventory.files[0].path = '../outside-artifact.txt'
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject $traversalInventory -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $artifactScanner -ManifestPath $manifestPath -RootPath $artifactRoot } 'artifact path traversal' $secret
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject $artifactInventory -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    Write-Output 'gate_case=artifact_path_traversal result=FAIL_CLOSED'

    $requiredArtifactPath = Join-Path $artifactRoot 'backend/target/pmd.xml'
    $requiredArtifactContent = [IO.File]::ReadAllText($requiredArtifactPath)
    Remove-Item -LiteralPath $requiredArtifactPath -Force
    Assert-PrivateGateFails { & $artifactScanner -Independent -RootPath $artifactRoot } 'required artifact missing' $secret
    [IO.File]::WriteAllText($requiredArtifactPath,$requiredArtifactContent,[Text.UTF8Encoding]::new($false))
    Write-Output 'gate_case=required_artifact_missing result=FAIL_CLOSED'

    $invalidArchivePath = Join-Path $artifactRoot 'frontend/dist/invalid.zip'
    [IO.File]::WriteAllText($invalidArchivePath,'not-a-zip-archive',[Text.UTF8Encoding]::new($false))
    Assert-PrivateGateFails { & $artifactScanner -Independent -RootPath $artifactRoot } 'invalid archive' $secret
    Remove-Item -LiteralPath $invalidArchivePath -Force
    Write-Output 'gate_case=invalid_archive result=FAIL_CLOSED'

    $outsideArtifactDirectory = Join-Path $root 'outside-artifact-target'
    [void][IO.Directory]::CreateDirectory($outsideArtifactDirectory)
    $reparsePath = Join-Path $artifactRoot 'frontend/dist/reparse-target'
    $reparseCreated = $false
    try {
        [void][IO.Directory]::CreateSymbolicLink($reparsePath,$outsideArtifactDirectory)
        $reparseCreated = $true
    } catch {
        $reparseCreated = $false
    }
    if ($reparseCreated) {
        Assert-PrivateGateFails { & $artifactScanner -Independent -RootPath $artifactRoot } 'artifact reparse point' $secret
        Remove-Item -LiteralPath $reparsePath -Force
        Write-Output 'gate_case=artifact_reparse_point result=FAIL_CLOSED'
    } else {
        Write-Output 'gate_case=artifact_reparse_point result=SKIP_UNAVAILABLE'
    }

    $independentArtifactOutput=@(& $artifactScanner -Independent -RootPath $artifactRoot)
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
