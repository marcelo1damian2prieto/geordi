[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')

function Assert-GeordiFinalizeTest {
    param([bool] $Condition,[string] $Message)
    if (!$Condition) { throw "Finalize attempt self-test failed: $Message" }
}

if (!$SelfTest) { throw 'Use -SelfTest to run isolated Finalize attempt tests.' }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('geordi-finalize-attempt-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$manifestPath = Join-Path $testRoot 'manifest.json'
$manifest = [ordered]@{
    version=2; runId='self-test-run'; startedUtc=[DateTimeOffset]::UtcNow.ToString('o');
    root=$testRoot; captureStartedUtc=[DateTimeOffset]::UtcNow.ToString('o');
    controls=@{}; captures=@{}; captureMetadata=@{}; additionalSources=@()
}
try {
    Write-GeordiM19ManifestAtomic -Path $manifestPath -Manifest $manifest
    $initialManifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $oversized=[ordered]@{}
    foreach($manifestKey in $manifest.Keys){$oversized[$manifestKey]=$manifest[$manifestKey]}
    $oversized.sizeProbe='x' * 1048577
    $manifestBoundRejected=$false
    try { Write-GeordiM19ManifestAtomic -Path $manifestPath -Manifest $oversized } catch { $manifestBoundRejected=$true }
    Assert-GeordiFinalizeTest $manifestBoundRejected 'manifest over 1 MiB is rejected'
    Assert-GeordiFinalizeTest ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $initialManifestHash) `
        'oversized manifest candidate leaves the published manifest unchanged'
    $first = New-GeordiM19FinalizeAttempt -CaptureRoot $testRoot -Manifest $manifest -ManifestPath $manifestPath
    $firstFile = Join-Path $first.Root 'loki-query.json'
    Write-GeordiM19AttemptFile -Path $firstFile -Content 'secret-sentinel-never-output'
    $beforeHash = (Get-FileHash -LiteralPath $firstFile -Algorithm SHA256).Hash
    $null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath `
        -AttemptId $first.AttemptId -Phase 'loki' -Status PASS -Details @{ entries=1 } `
        -AdditionalSources @([ordered]@{channel='loki';control='positive';captures=@($firstFile)})
    $null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath `
        -AttemptId $first.AttemptId -Phase 'tempo-detail' -Status FAIL -FailureCategory 'transport'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable
    $firstFailedAttempt = $manifest.attempts[$first.AttemptId]
    $firstFailedSnapshot = ConvertTo-Json -InputObject $firstFailedAttempt -Depth 20 -Compress
    Assert-GeordiFinalizeTest ($firstFailedAttempt.status -ceq 'failed' -and $firstFailedAttempt.phases.Contains('loki')) 'failed attempt retains successful phase evidence'

    $second = New-GeordiM19FinalizeAttempt -CaptureRoot $testRoot -Manifest $manifest -ManifestPath $manifestPath
    Assert-GeordiFinalizeTest ($first.AttemptId -cne $second.AttemptId -and $first.Root -cne $second.Root) 'retry gets unique scoped paths'
    $secondFile = Join-Path $second.Root 'loki-query.json'
    Write-GeordiM19AttemptFile -Path $secondFile -Content 'second attempt'
    Assert-GeordiFinalizeTest ((Get-FileHash -LiteralPath $firstFile -Algorithm SHA256).Hash -ceq $beforeHash) 'retry preserves previous file bytes'
    Assert-GeordiFinalizeTest ((Get-Content -LiteralPath $firstFile -Raw) -ceq 'secret-sentinel-never-output') 'failed evidence is immutable'

    $evidenceSource = Join-Path $PSScriptRoot 'New-GeordiCredentialEvidence.ps1'
    $tokens = $null; $parseErrors = $null
    $evidenceAst = [System.Management.Automation.Language.Parser]::ParseFile($evidenceSource,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Finalize channel capture source did not parse.' }
    $captureFunction = $evidenceAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Add-ControlCapture'
    },$true)
    if (!$captureFunction) { throw 'Finalize channel capture function is missing.' }
    . (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')
    . (Join-Path $PSScriptRoot 'lib/GeordiTempoEvidence.ps1')
    . (Join-Path $PSScriptRoot 'lib/GeordiDiagnosticEvidence.ps1')
    . (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')
    Invoke-Expression $captureFunction.Extent.Text
    $channelFile = Join-Path $second.Root 'backend-live.log'
    Write-GeordiM19AttemptFile -Path $channelFile -Content 'Started GeordiApplication'
    $channelEvidence = @{ controls=@{}; captures=@{}; captureMetadata=@{}; generationCaptures=@{};
        runId='self-test-run'; captureStartedUtc=[DateTimeOffset]::UtcNow.ToString('o') }
    Add-ControlCapture $channelEvidence 'backend' @($channelFile) 'Started GeordiApplication'
    Assert-GeordiFinalizeTest ($channelEvidence.captureMetadata.backend.runId -ceq 'self-test-run' -and
        $channelEvidence.captureMetadata.backend.captureStartedUtc -ceq $channelEvidence.captureStartedUtc) `
        'streamed channel metadata carries stable run identity'

    $generationRoot=Join-Path $second.Root 'generation-finalize-integration'
    [void][IO.Directory]::CreateDirectory($generationRoot)
    $generationManifest=[ordered]@{version=2;runId='self-test-run';root=$generationRoot;
        startedUtc=[DateTimeOffset]::UtcNow.ToString('o');captureStartedUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');
        captures=@{};captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};generationCaptureEvents=@{}}
    Write-GeordiM19ManifestAtomic -Path (Join-Path $generationRoot 'manifest.json') -Manifest $generationManifest
    $script:finalizeGenerationPid=41000
    $script:finalizeGenerationAlive=@{}
    $finalizeFollower={
        param($stdout,$stderr,$recordPath,$arguments,$target)
        $script:finalizeGenerationPid++
        $processId=$script:finalizeGenerationPid
        $startUtc=[DateTimeOffset]::UtcNow.ToString('o')
        $processRecord=@{id=$processId;name='synthetic-docker';startUtc=$startUtc;containerId=[string]$target.containerId;
            service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc}
        [IO.File]::WriteAllText($recordPath,(ConvertTo-Json -InputObject $processRecord -Compress))
        [IO.File]::WriteAllText($stdout,'generation-control')
        [IO.File]::WriteAllText($stderr,'')
        $script:finalizeGenerationAlive[[string]$processId]=$true
        return [pscustomobject]@{id=$processId;name='synthetic-docker';startUtc=$startUtc}
    }
    $finalizeProcessCheck={param($record) return [bool]$script:finalizeGenerationAlive[[string]$record.id]}
    $finalizeProcessStop={param($record) $script:finalizeGenerationAlive[[string]$record.id]=$false}
    $generationIdentity={
        param($id)
        return [pscustomobject]@{Id=$id;Project='geordi';Service='backend';WorkingDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));
            CreatedUtc=[DateTimeOffset]::UtcNow;Running=$true}
    }
    $firstGeneration=Start-GeordiCaptureGeneration -CaptureRoot $generationRoot -Service backend `
        -ContainerIdentity (& $generationIdentity ('5'*64)) -DockerPath synthetic -PowerShellPath synthetic -WorkerPath synthetic `
        -WorkingDirectory (Get-Location).Path -StartFollower $finalizeFollower
    $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $generationRoot -Service backend -Reason 'finalize-integration' `
        -TestProcessIdentity $finalizeProcessCheck -StopProcess $finalizeProcessStop
    $restoration=Invoke-GeordiFinalizeCaptureRestoration -CaptureRoot $generationRoot -Service backend `
        -RepositoryRoot (Get-Location).Path -StartFollower $finalizeFollower `
        -GetContainerIdentity { param($service) & $generationIdentity ('6'*64) } `
        -Replace { $script:finalizeReplacementObserved=$true }
    $replacementGeneration=[string]$restoration.GenerationId
    $null=Seal-GeordiCaptureGeneration -CaptureRoot $generationRoot -Service backend -GenerationId $replacementGeneration `
        -TestProcessIdentity $finalizeProcessCheck -StopProcess $finalizeProcessStop
    $eventPath=Join-Path $generationRoot 'm14-backend-event.log'
    [IO.File]::WriteAllText($eventPath,'generation-control')
    (Get-Item -LiteralPath $eventPath -Force).IsReadOnly=$true
    $eventId=[guid]::NewGuid().ToString('N')
    $eventUtc=[DateTimeOffset]::UtcNow.ToString('o')
    $backendIdentity=[pscustomobject]@{service='backend';containerId=('6'*64);composeProject='geordi';workingDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));createdUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    $vmIdentity=[pscustomobject]@{service='victoriametrics';containerId=('7'*64);composeProject='geordi';workingDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));createdUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    $eventIdentityServices=@(Get-GeordiM14EventIdentityServices -RequestedLogServices @('backend'))
    Assert-GeordiFinalizeTest (($eventIdentityServices -join ',') -ceq 'backend,victoriametrics') 'backend-only M14 snapshots still bind the exact VictoriaMetrics source identity'
    $event=[ordered]@{candidateId='self-test-run';runId='self-test-run';diagnosticInvocationId=('8'*32);phase='m14-final';
        occurrenceId=$eventId;services=@('backend','victoriametrics');requestedLogServices=@('backend');
        containerGenerations=@($backendIdentity,$vmIdentity);sourceIdentity=@('victoriametrics-export','docker-container-logs');
        capturedUtc=$eventUtc;status='complete';files=@(@{path=$eventPath;identity=[IO.Path]::GetFileName($eventPath);
            byteCount=(Get-Item -LiteralPath $eventPath).Length;sha256=(Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash.ToLowerInvariant();
            service='backend';containerId=('6'*64);source='docker-container-logs'})}
    Update-GeordiM19ManifestAtomic -ManifestPath (Join-Path $generationRoot 'manifest.json') -ExpectedRunId 'self-test-run' -Mutation {
        param($latest)
        $latest.generationCaptureEvents[$eventId]=$event
    } | Out-Null
    $script:ActiveCaptureRoot=$generationRoot
    $generationManifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $generationRoot
    $generationEvidence=@{controls=@{};captures=@{};captureMetadata=@{};generationCaptures=$generationManifest.generationCaptures;
        captureGenerations=$generationManifest.captureGenerations;captureHandoffs=$generationManifest.captureHandoffs;
        runId='self-test-run';captureStartedUtc=$generationManifest.captureStartedUtc}
    Add-ControlCapture $generationEvidence backend @() 'generation-control'
    Assert-GeordiFinalizeTest ($eventPath -in @($generationEvidence.captures.backend)) 'Finalize omitted the immutable M14 event snapshot from its scanner channel'
    $scanManifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $generationRoot
    $scanManifest.captures=@{backend=@($generationEvidence.captures.backend)}
    Assert-GeordiCaptureHandoffCoverage -Manifest $scanManifest
    $eventOmissionRejected=$false
    $scanManifest.captures.backend=@($generationEvidence.captures.backend | Where-Object { $_ -cne $eventPath })
    try { Assert-GeordiCaptureHandoffCoverage -Manifest $scanManifest } catch { $eventOmissionRejected=$true }
    Assert-GeordiFinalizeTest ($script:finalizeReplacementObserved -and $firstGeneration -cne $replacementGeneration -and
        $generationEvidence.captures.backend.Count -eq 3 -and $generationEvidence.captureMetadata.backend.fileCount -eq 3 -and
        $restoration.HandoffId -ceq $handoff -and @($generationManifest.captureHandoffs.Keys).Count -eq 1 -and $eventOmissionRejected) `
        'Finalize reuses teardown handoff, scans every follower and M14 snapshot exactly once, and keeps one logical backend channel'
    $attemptState=[hashtable]@{generationCaptures=@{};captureGenerations=@{};captureHandoffs=@{}}
    Set-GeordiFinalizeGenerationEvidenceState -Evidence $attemptState -Manifest $scanManifest
    Assert-GeordiFinalizeTest ($attemptState.captureGenerations.backend.Count -eq 2 -and
        $attemptState.captureHandoffs[$handoff].status -ceq 'complete') 'Finalize attempt metadata refreshes all post-handoff generation maps'
    Write-Output 'finalize_generation_coverage=PASS production_handoff=true reused_pending=true ordered_generations=2 event_snapshots=1 logical_channels=1'
    Remove-Variable -Scope Script -Name ActiveCaptureRoot -ErrorAction SilentlyContinue

    # Exercise the exact Finalize Add-ControlCapture -> Tempo validator boundary.
    # A spy records the object passed to the real validator so the test proves that
    # validation and persistence use the same normalized envelope and completion time.
    $script:originalTempoValidator=(Get-Command Test-GeordiTempoSegmentChannel).ScriptBlock
    $script:tempoMetadataSeenByValidator=$null
    function Test-GeordiTempoSegmentChannel {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string[]]$Paths,
            [Parameter(Mandatory)]$Metadata,
            [Parameter(Mandatory)][string[]]$Needles,
            [string]$Control=$Needles[0],
            [string]$ExpectedRunId,
            [string]$ExpectedCaptureStartedUtc,
            [ValidateRange(1,167772160)][long]$MaximumLogicalBytes=167772160L,
            [switch]$AllowTestBounds
        )
        $script:tempoMetadataSeenByValidator=$Metadata
        return & $script:originalTempoValidator @PSBoundParameters
    }
    $tempoSegmentRoot=Join-Path $second.Root 'tempo-integration-segments'
    $tempoWriter=[GeordiTempoSegmentWriter]::new($tempoSegmentRoot,33554432L,167772160L,256,67108864L)
    try {
        $filler=[byte[]]::new(65536)
        [Array]::Fill($filler,[byte]0x78)
        $tempoWriter.BeginRecord(1L)
        for($block=0;$block -lt 512;$block++){$tempoWriter.WriteRecordBytes($filler,$filler.Length)}
        $tempoWriter.CompleteRecord()
        foreach($ordinal in 2L,3L){
            $record=[Text.Encoding]::UTF8.GetBytes('{"record":' + $ordinal + ',"service":"service.name=geordi-backend"}')
            $tempoWriter.BeginRecord($ordinal);$tempoWriter.WriteRecordBytes($record,$record.Length);$tempoWriter.CompleteRecord()
        }
        $rawTempoMetadata=$tempoWriter.Complete()
    } finally { $tempoWriter.Dispose() }
    Assert-GeordiFinalizeTest ($rawTempoMetadata.PSObject.Properties.Name -notcontains 'runId' -and
        $rawTempoMetadata.PSObject.Properties.Name -notcontains 'captureStartedUtc' -and
        $rawTempoMetadata.PSObject.Properties.Name -notcontains 'captureCompletedUtc') `
        'writer metadata does not own capture identity or interval'
    $rawTempoSnapshot=ConvertTo-Json -InputObject $rawTempoMetadata -Depth 20 -Compress
    Assert-GeordiFinalizeTest ($rawTempoMetadata.segmentCount -gt 1 -and $rawTempoMetadata.recordCount -eq 3) `
        'integration fixture has multiple ordered complete framed records'
    $tempoCaptureStart=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
    $tempoCaptureEvidence=@{controls=@{};captures=@{};captureMetadata=@{};generationCaptures=@{};
        runId='tempo-integration-run';captureStartedUtc=$tempoCaptureStart}
    $tempoPaths=@($rawTempoMetadata.segments | ForEach-Object { [string]$_.path })
    Add-ControlCapture $tempoCaptureEvidence 'tempo' $tempoPaths 'service.name=geordi-backend' $rawTempoMetadata
    $persistedTempoMetadata=$tempoCaptureEvidence.captureMetadata.tempo
    Assert-GeordiFinalizeTest ([object]::ReferenceEquals($script:tempoMetadataSeenByValidator,$persistedTempoMetadata)) `
        'the exact normalized metadata object validated is persisted'
    Assert-GeordiFinalizeTest ($persistedTempoMetadata.captureCompletedUtc -ceq $script:tempoMetadataSeenByValidator.captureCompletedUtc) `
        'one capture completion timestamp is shared by validation and persistence'
    Assert-GeordiFinalizeTest ($persistedTempoMetadata.runId -ceq $tempoCaptureEvidence.runId -and
        $persistedTempoMetadata.captureStartedUtc -ceq $tempoCaptureStart -and
        [DateTimeOffset]::Parse($persistedTempoMetadata.captureCompletedUtc) -gt [DateTimeOffset]::Parse($tempoCaptureStart)) `
        'normalized metadata carries exact run identity and valid capture interval'
    Assert-GeordiFinalizeTest ($persistedTempoMetadata.logicalByteCount -eq $rawTempoMetadata.logicalByteCount -and
        $persistedTempoMetadata.recordCount -eq $rawTempoMetadata.recordCount -and
        $persistedTempoMetadata.segmentCount -eq $rawTempoMetadata.segmentCount -and
        (ConvertTo-Json -InputObject $persistedTempoMetadata.segments -Depth 20 -Compress) -ceq
            (ConvertTo-Json -InputObject $rawTempoMetadata.segments -Depth 20 -Compress)) `
        'persisted segment identities, hashes, ordinals, and byte metadata equal writer metadata'
    Assert-GeordiFinalizeTest ($persistedTempoMetadata.positiveControlFound -eq $true -and
        (ConvertTo-Json -InputObject $rawTempoMetadata -Depth 20 -Compress) -ceq $rawTempoSnapshot) `
        'positive control passes and raw writer metadata remains unchanged'

    $tempoInvalidCases=@(
        @{label='wrong runId';change={param($m)$m.runId='historical-run'};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='wrong captureStartedUtc';change={param($m)$m.captureStartedUtc=[DateTimeOffset]::Parse($tempoCaptureStart).AddSeconds(-1).ToString('o')};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='malformed captureCompletedUtc';change={param($m)$m.captureCompletedUtc='not-a-timestamp'};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='capture completion before start';change={param($m)$m.captureCompletedUtc=[DateTimeOffset]::Parse($tempoCaptureStart).AddSeconds(-1).ToString('o')};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='missing runId';change={param($m)$m.Remove('runId')};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='missing capture start';change={param($m)$m.Remove('captureStartedUtc')};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='changed segment hash';change={param($m)$m.segments[0].sha256=('0'*64)};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='changed segment order';change={param($m)[array]::Reverse($m.segments)};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart},
        @{label='changed logical byte total';change={param($m)$m.logicalByteCount++};expectedRun='tempo-integration-run';expectedStart=$tempoCaptureStart})
    $unmodifiedClone=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $persistedTempoMetadata -Depth 20 -Compress) `
        -AsHashtable -DateKind String
    Assert-GeordiFinalizeTest ($unmodifiedClone.captureStartedUtc -is [string] -and
        $unmodifiedClone.captureStartedUtc -ceq $tempoCaptureStart) `
        'JSON clone preserves capture timestamp text and round-trip precision'
    $unmodifiedCloneAccepted=$true
    try {
        [void](Test-GeordiTempoSegmentChannel -Paths $tempoPaths -Metadata $unmodifiedClone `
            -Needles @('service.name=geordi-backend') -Control 'service.name=geordi-backend' `
            -ExpectedRunId 'tempo-integration-run' -ExpectedCaptureStartedUtc $tempoCaptureStart)
    } catch { $unmodifiedCloneAccepted=$false }
    Assert-GeordiFinalizeTest $unmodifiedCloneAccepted 'unmodified cloned metadata passes before mutation cases'
    foreach($invalidCase in $tempoInvalidCases){
        $candidateMetadata=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $persistedTempoMetadata -Depth 20 -Compress) `
            -AsHashtable -DateKind String
        & $invalidCase.change $candidateMetadata
        $rejected=$false
        try {
            [void](Test-GeordiTempoSegmentChannel -Paths $tempoPaths -Metadata $candidateMetadata `
                -Needles @('service.name=geordi-backend') -Control 'service.name=geordi-backend' `
                -ExpectedRunId $invalidCase.expectedRun -ExpectedCaptureStartedUtc $invalidCase.expectedStart)
        } catch { $rejected=$true }
        Assert-GeordiFinalizeTest $rejected ([string]$invalidCase.label + ' fails closed')
    }
    $manifestAfterTempoIntegration=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-GeordiFinalizeTest ((Get-FileHash -LiteralPath $firstFile -Algorithm SHA256).Hash -ceq $beforeHash -and
        (ConvertTo-Json -InputObject $manifestAfterTempoIntegration.attempts[$first.AttemptId] -Depth 20 -Compress) -ceq $firstFailedSnapshot) `
        'Tempo integration regression leaves the prior failed attempt byte-for-byte and metadata unchanged'

    $launchFile = Join-Path $second.Root 'synthetic-live.launch.json'
    Write-GeordiM19AttemptFile -Path $launchFile -Content '{"service":"synthetic"}'
    $processPath = Join-Path $second.Root 'synthetic-live.process.json'
    $stoppedPath = Join-Path $second.Root 'synthetic-live.stopped.json'
    $powershellPath = (Get-Process -Id $PID).Path
    $trackedProcess = Start-Process -FilePath $powershellPath -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30') `
        -WindowStyle Hidden -PassThru
    Write-GeordiM19AttemptFile -Path $processPath -Content 'force CreateNew collision'
    $publicationFailed = $false
    try { Write-GeordiM19AttemptFile -Path $processPath -Content 'process record' }
    catch { $publicationFailed = $true }
    Assert-GeordiFinalizeTest $publicationFailed 'process record publication failure is simulated'
    Stop-GeordiM19TrackedProcess -Process $trackedProcess
    Assert-GeordiFinalizeTest ($trackedProcess.HasExited) 'spawned follower stops after process-record publication failure'
    Remove-Item -LiteralPath $processPath -Force
    Write-GeordiM19AttemptFile -Path $stoppedPath -Content "stopped=true`n"
    Assert-GeordiM19FinalizeLaunchRecordsRecoverable -AttemptRoot $second.Root
    $unownedLaunch = Join-Path $second.Root 'orphan-live.launch.json'
    Write-GeordiM19AttemptFile -Path $unownedLaunch -Content '{"service":"orphan"}'
    $orphanRejected = $false
    try { Assert-GeordiM19FinalizeLaunchRecordsRecoverable -AttemptRoot $second.Root }
    catch { $orphanRejected = $true }
    Assert-GeordiFinalizeTest $orphanRejected 'orphan launch without process identity fails closed'
    Remove-Item -LiteralPath $unownedLaunch -Force

    $originalManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $throwsBeforePublish = $false
    try {
        Write-GeordiM19ManifestAtomic -Path $manifestPath -Manifest $manifest -BeforePublish { throw 'simulated publish interruption' }
    } catch { $throwsBeforePublish = $true }
    Assert-GeordiFinalizeTest $throwsBeforePublish 'pre-rename failure is simulated'
    Assert-GeordiFinalizeTest ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $originalManifestHash) 'pre-rename failure preserves published manifest'
    Assert-GeordiFinalizeTest (@(Get-ChildItem -LiteralPath $testRoot -Filter 'manifest.json.*.tmp').Count -eq 0) 'temporary manifest is removed after interruption'

    $null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath `
        -AttemptId $second.AttemptId -Phase 'loki' -Status PASS -Details @{ entries=1 } `
        -AdditionalSources @([ordered]@{channel='loki';control='positive';captures=@($secondFile)})
    $keyedSources = @{}
    $keyedSources.loki = [ordered]@{channel='loki';control='positive';captures=@($secondFile)}
    $keyedSources.loki = [ordered]@{channel='loki';control='positive';captures=@($secondFile)}
    Assert-GeordiFinalizeTest (@($keyedSources.Values).Count -eq 1) 'keyed Loki metadata cannot duplicate'
    $partial = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable
    Assert-GeordiFinalizeTest (!$partial.Contains('completedUtc') -and !$partial.Contains('acceptedAttemptId')) 'partial channel does not complete manifest'
    Assert-GeordiFinalizeTest ((ConvertTo-Json -InputObject $partial.attempts[$first.AttemptId] -Depth 20 -Compress) -ceq $firstFailedSnapshot) `
        'a prior failed attempt record remains immutable after retry'

    $diagnosticRoot=Join-Path $testRoot 'diagnostic-run'
    [void][IO.Directory]::CreateDirectory($diagnosticRoot)
    $diagnosticManifestPath=Join-Path $diagnosticRoot 'manifest.json'
    $diagnosticManifest=[ordered]@{version=2;runId='diagnostic-run';startedUtc=[DateTimeOffset]::UtcNow.ToString('o');
        root=$diagnosticRoot;captureStartedUtc=[DateTimeOffset]::UtcNow.ToString('o');controls=@{};captures=@{};captureMetadata=@{};additionalSources=@()}
    Write-GeordiM19ManifestAtomic -Path $diagnosticManifestPath -Manifest $diagnosticManifest
    $diagnostic = New-GeordiM19FinalizeAttempt -CaptureRoot $diagnosticRoot -Manifest $diagnosticManifest `
        -ManifestPath $diagnosticManifestPath -DiagnosticOnly
    Assert-GeordiFinalizeTest ($diagnostic.Manifest.diagnosticOnly -eq $true -and
        $diagnostic.Manifest.attempts[$diagnostic.AttemptId].diagnosticOnly -eq $true) `
        'diagnostic identity is persisted at attempt creation'
    $diagnosticFile=Join-Path $diagnostic.Root 'diagnostic-channel.json'
    Write-GeordiM19AttemptFile -Path $diagnosticFile -Content '{"control":"diagnostic"}'
    $diagnosticChannels=@{controls=@{tempo='diagnostic-positive'};captures=@{tempo=@($diagnosticFile)};captureMetadata=@{tempo=@{complete=$true}}}
    $diagnosticSources=@([ordered]@{channel='diagnostic';control='diagnostic-positive';captures=@($diagnosticFile)})
    $deadlinePublicationRejected=$false
    try { Complete-GeordiM19DiagnosticAttempt -Manifest $diagnosticManifest -ManifestPath $diagnosticManifestPath `
        -AttemptId $diagnostic.AttemptId -ChannelState $diagnosticChannels -AdditionalSources $diagnosticSources `
        -BeforePublish { throw 'simulated diagnostic deadline exhaustion' } | Out-Null } catch { $deadlinePublicationRejected=$true }
    $incompleteDiagnostic=Get-Content -LiteralPath $diagnosticManifestPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-GeordiFinalizeTest ($deadlinePublicationRejected -and
        !$incompleteDiagnostic.Contains('completedUtc') -and !$incompleteDiagnostic.Contains('acceptedAttemptId') -and
        $incompleteDiagnostic.attempts[$diagnostic.AttemptId].status -ceq 'running') `
        'deadline exhaustion before atomic rename leaves diagnostic evidence incomplete'
    $diagnosticManifest=Complete-GeordiM19DiagnosticAttempt -Manifest $incompleteDiagnostic -ManifestPath $diagnosticManifestPath `
        -AttemptId $diagnostic.AttemptId -ChannelState $diagnosticChannels -AdditionalSources $diagnosticSources -Timing @{samplePoint='self-test'}
    Assert-GeordiFinalizeTest (!$diagnosticManifest.Contains('completedUtc') -and !$diagnosticManifest.Contains('acceptedAttemptId')) `
        'diagnostic completion retains explicit non-accepted candidate state'
    Assert-GeordiFinalizeTest ($diagnosticManifest.diagnosticOnly -eq $true -and
        $diagnosticManifest.attempts[$diagnostic.AttemptId].status -ceq 'diagnostic-completed') `
        'diagnostic attempt completion is explicitly marked'
    $diagnosticPromotionRejected=$false
    try { Complete-GeordiM19FinalizeAttempt -Manifest $diagnosticManifest -ManifestPath $diagnosticManifestPath -AttemptId $diagnostic.AttemptId `
        -ChannelState $diagnosticChannels -AdditionalSources $diagnosticSources | Out-Null } catch { $diagnosticPromotionRejected=$true }
    Assert-GeordiFinalizeTest $diagnosticPromotionRejected 'diagnostic evidence cannot be promoted to production acceptance'
    $productionRestartRejected=$false
    try { New-GeordiM19FinalizeAttempt -CaptureRoot $diagnosticRoot -Manifest $diagnosticManifest `
        -ManifestPath $diagnosticManifestPath | Out-Null } catch { $productionRestartRejected=$true }
    Assert-GeordiFinalizeTest $productionRestartRejected 'a diagnostic-only root cannot later start a production attempt'

    $channels = @{controls=@{loki='positive'};captures=@{loki=@($secondFile)};captureMetadata=@{}}
    $manifest = Complete-GeordiM19FinalizeAttempt -Manifest $manifest -ManifestPath $manifestPath `
        -AttemptId $second.AttemptId -ChannelState $channels -AdditionalSources @($keyedSources.Values)
    $completedHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $rejected = $false
    try { $null = New-GeordiM19FinalizeAttempt -CaptureRoot $testRoot -Manifest $manifest -ManifestPath $manifestPath }
    catch { $rejected = $true }
    Assert-GeordiFinalizeTest $rejected 'completed manifest rejects retry'
    Assert-GeordiFinalizeTest ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $completedHash) 'rejected retry has no side effects'
    Remove-GeordiM19FinalizeAttempts -CaptureRoot $testRoot
    Assert-GeordiFinalizeTest (!(Test-Path -LiteralPath (Join-Path $testRoot 'finalize-attempts'))) 'cleanup removes every attempt'
    $output = 'M19 Finalize attempt self-test passed; secrets=not-emitted'
    Assert-GeordiFinalizeTest (!$output.Contains('secret-sentinel-never-output',[StringComparison]::Ordinal)) 'test summary does not print secret-bearing evidence'
    Write-Output $output
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
