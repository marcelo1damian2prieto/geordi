[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('m10-reset','m11-reset','m11-final','m12-reset','m12-fixture-start','m12-recovery-start','m12-overlap-reset','m12-overlap-recreate','m13-reset','m14-reset','m14-final','m19-burn-isolate','m19-burn-restore')][string] $Phase,
    [Parameter(Mandatory)][ValidateSet('backend','victoriametrics','frontend','otel-collector','burn-demo','m12-burn-demo','m12-query-gate','webhook-receiver-a','webhook-receiver-b','webhook-receiver')][string[]] $Services,
    [switch] $SkipLogSnapshot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiDiagnosticEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pointerPath = Join-Path (Join-Path $repositoryRoot '.runtime') 'm19-capture-root.txt'
if (!(Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return }
$captureRoot = [IO.Path]::GetFullPath([IO.File]::ReadAllText($pointerPath).Trim())
$expectedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedTemp -or
        (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$' -or
        !(Test-Path -LiteralPath $captureRoot -PathType Container)) {
    throw 'Private M19 evidence capture path failed validation before generation snapshot.'
}
$manifestPath = Join-Path $captureRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
if ($manifest.version -ne 2 -or $manifest.root -cne $captureRoot -or !$manifest.ContainsKey('captureStartedUtc')) {
    throw 'Private M19 evidence manifest is not active before generation snapshot.'
}
. (Join-Path $PSScriptRoot 'lib/GeordiPersistedMetricEvidence.ps1')
$runStart = [DateTimeOffset]$manifest.captureStartedUtc
$snapshotStart = $runStart
$snapshotEnd = [DateTimeOffset]::UtcNow
if ($snapshotEnd -lt $snapshotStart) { throw 'Private metric evidence snapshot clock moved backward.' }
$snapshotDirectory = Join-Path $captureRoot 'victoriametrics-generations'
[void][IO.Directory]::CreateDirectory($snapshotDirectory)
$isM14Event = $Phase -in @('m14-reset','m14-final')
$occurrenceId = [guid]::NewGuid().ToString('N')
$diagnosticInvocationId = [Environment]::GetEnvironmentVariable('GEORDI_M19_DIAGNOSTIC_INVOCATION_ID','Process')
if ($isM14Event -and $diagnosticInvocationId -notmatch '^[0-9a-f]{32}$') { throw 'M14 generation event has no active diagnostic invocation identity.' }
$containerGenerations = [Collections.Generic.List[object]]::new()
$identityServices = @($Services)
if ($isM14Event) {
    $identityServices = @(Get-GeordiM14EventIdentityServices -RequestedLogServices $Services)
    foreach ($service in $identityServices) {
        $ids=@(& docker ps -q --filter 'label=com.docker.compose.project=geordi' --filter "label=com.docker.compose.service=$service")
        if ($LASTEXITCODE -ne 0) { throw 'M14 container generation inventory failed.' }
        $ids=@($ids | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_) })
        if ($ids.Count -gt 1) { throw 'M14 service has ambiguous simultaneous container generations.' }
        if ($ids.Count -eq 0) {
            if ($Phase -ceq 'm14-final') { throw 'M14 final capture is missing an owned service container generation.' }
            continue
        }
        $identity=Get-GeordiDockerCaptureIdentity -ContainerId ([string]$ids[0]) -Service $service -RepositoryRoot $repositoryRoot
        $containerGenerations.Add([ordered]@{service=$service;containerId=[string]$identity.Id;composeProject=[string]$identity.Project;
            workingDirectory=[string]$identity.WorkingDirectory;createdUtc=[string]$identity.CreatedUtc})
    }
    foreach ($requiredService in @('backend','victoriametrics','otel-collector')) {
        if ($requiredService -in $Services -and @($containerGenerations | Where-Object service -ceq $requiredService).Count -ne 1) {
            throw 'M14 captured replacement service has no exact running container identity.'
        }
    }
}
$snapshotPaths = if ($isM14Event) { New-GeordiM14GenerationPaths -CaptureRoot $captureRoot -Phase $Phase -OccurrenceId $occurrenceId } else { $null }
$snapshotKey = if ($isM14Event) { $snapshotPaths.Key } else { $Phase }
$snapshotPath = if ($isM14Event) { $snapshotPaths.SnapshotPath } else { Join-Path $snapshotDirectory "$snapshotKey.jsonl" }
$snapshotTemporary = "$snapshotPath.$([guid]::NewGuid().ToString('N')).tmp"
$snapshotLedgerPath = if ($isM14Event) { $snapshotPaths.LedgerPath } else { Join-Path $snapshotDirectory "$snapshotKey.snapshot.json" }
$ledgerTemporary = "$snapshotLedgerPath.$([guid]::NewGuid().ToString('N')).tmp"
$metricSource = @($manifest.additionalSources | Where-Object { $_.channel -ceq 'victoriametrics' })
if ($metricSource.Count -gt 1) { throw 'Private VictoriaMetrics evidence source is duplicated.' }
$isM11Final = $Phase -ceq 'm11-final'
$isM12Reset = $Phase -ceq 'm12-reset'
$isM12FixtureStart = $Phase -ceq 'm12-fixture-start'
$isM12RecoveryStart = $Phase -ceq 'm12-recovery-start'
$phasePublicationMutex=$null
if ($isM12Reset) {
    $phasePublicationMutex=Enter-GeordiPersistedMetricPhasePublication -SnapshotPath $snapshotPath -LedgerPath $snapshotLedgerPath
}
try {
if ($isM11Final -or $isM12Reset -or $isM12FixtureStart -or $isM12RecoveryStart) {
    Assert-GeordiPersistedMetricPhaseAvailable -Phase $Phase -SnapshotPath $snapshotPath -LedgerPath $snapshotLedgerPath -Manifest $manifest
}
$oldPhaseFiles = if ($isM14Event -or $isM11Final -or $isM12Reset -or $isM12FixtureStart -or $isM12RecoveryStart) { @() } else { @($snapshotPath,$snapshotLedgerPath) }
$usedBytes = 0L
if ($metricSource.Count -eq 1) {
    foreach ($existingPath in @($metricSource[0].captures)) {
        if ($existingPath -notin $oldPhaseFiles -and (Test-Path -LiteralPath $existingPath -PathType Leaf)) {
            $usedBytes += [long](Get-Item -LiteralPath $existingPath).Length
        }
    }
}
$remainingBytes = 67108864L - $usedBytes
if ($remainingBytes -le 0) { throw 'Current-run persisted metric evidence exceeded its aggregate size bound.' }
$snapshotSource = 'victoriametrics-export'
$priorSnapshotReference = $null
$snapshot = $null
if ($Phase -ceq 'm12-reset') {
    $priorLedgerPath = Join-Path $snapshotDirectory 'm11-final.snapshot.json'
    $priorGeneration = @($metricSource | ForEach-Object { $_.captures } | Where-Object { $_ -ceq $priorLedgerPath }).Count -gt 0
    if ($priorGeneration -and (Test-Path -LiteralPath $priorLedgerPath -PathType Leaf)) {
        $priorLedger = Get-Content -LiteralPath $priorLedgerPath -Raw | ConvertFrom-Json -AsHashtable
        if ($priorLedger.source -ceq 'victoriametrics-export' -and $priorLedger.complete -and $priorLedger.runStartBound -and
                $priorLedger.intervalStartUtc -ceq $runStart.ToString('o')) {
            $docker = (Get-Command docker.exe -ErrorAction Stop).Source
            $remainingContainers = & $docker ps -aq --filter 'label=com.docker.compose.project=geordi' --filter 'label=com.docker.compose.service=victoriametrics'
            if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the previous M11 VictoriaMetrics generation removal.' }
            if (@($remainingContainers | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
                $snapshotSource = 'verified-prior-generation-removal'
                $priorSnapshotReference = 'm11-final'
                $snapshot = [pscustomobject]@{ Bytes=0L; Series=0; Samples=0L; PositiveControl=$false; PositiveMetricName=$null }
            }
        }
    }
}
$sourceIdentity = $null
if ($snapshotSource -ceq 'victoriametrics-export') {
    $sourceIdentity = Get-GeordiPersistedMetricSourceIdentity -Phase $Phase -RepositoryRoot $repositoryRoot `
        -ResolvedM14ContainerGenerations $containerGenerations.ToArray()
    if ($isM11Final) {
        [void](Assert-GeordiM11FinalSourceTransition -Manifest $manifest -SnapshotDirectory $snapshotDirectory `
            -FinalSourceIdentity $sourceIdentity -CaptureStartedUtc $runStart)
    }
}
if ($isM14Event) {
    $event = [ordered]@{ candidateId=[string]$manifest.runId; runId=[string]$manifest.runId; diagnosticInvocationId=$diagnosticInvocationId;
        phase=$Phase; occurrenceId=$occurrenceId; services=@($identityServices); requestedLogServices=@($Services);
        containerGenerations=@($containerGenerations.ToArray());
        sourceIdentity=@('victoriametrics-export','docker-container-logs'); capturedUtc=[DateTimeOffset]::UtcNow.ToString('o'); status='in_progress'; files=@() }
    $manifest=Update-GeordiM19ManifestAtomic -ManifestPath $manifestPath -ExpectedRunId ([string]$manifest.runId) -Mutation {
        param($latest)
        if (!$latest.ContainsKey('generationCaptureEvents')) { $latest.generationCaptureEvents=@{} }
        if ($latest.generationCaptureEvents.ContainsKey($occurrenceId)) { throw 'M14 capture occurrence already exists.' }
        $latest.generationCaptureEvents[$occurrenceId]=$event
    }
}
if ($null -eq $snapshot) {
    $snapshot = Export-GeordiPersistedMetricSamples -StartUtc $snapshotStart -EndUtc $snapshotEnd -Path $snapshotTemporary -MaximumBytes $remainingBytes -AllowEmpty
}
$metricFiles = @()
$ledgerValue=@{ intervalStartUtc=$snapshotStart.ToString('o'); intervalEndUtc=$snapshotEnd.ToString('o');
    source=$snapshotSource; complete=$true; runStartBound=$true; series=$snapshot.Series; samples=$snapshot.Samples; bytes=$snapshot.Bytes }
if ($priorSnapshotReference) { $ledgerValue.priorSnapshot=$priorSnapshotReference }
Add-GeordiPersistedMetricArtifactBinding -Ledger $ledgerValue -Source $snapshotSource -SourceIdentity $sourceIdentity `
    -SnapshotTemporaryPath $snapshotTemporary -Bytes ([long]$snapshot.Bytes)
[IO.File]::WriteAllText($ledgerTemporary,(ConvertTo-Json -Compress -Depth 5 $ledgerValue),[Text.UTF8Encoding]::new($false))
$newTotal=$usedBytes+$snapshot.Bytes+(Get-Item -LiteralPath $ledgerTemporary).Length
if ($newTotal -gt 67108864L) {
    Remove-Item -LiteralPath $snapshotTemporary,$ledgerTemporary -Force -ErrorAction SilentlyContinue
    throw 'Current-run persisted metric evidence exceeded its aggregate size bound.'
}
$publishedSnapshot=Complete-GeordiPersistedMetricSnapshotFile -TemporaryPath $snapshotTemporary -SnapshotPath $snapshotPath -Bytes $snapshot.Bytes -CreateNew:($isM14Event -or $isM11Final -or $isM12Reset -or $isM12FixtureStart -or $isM12RecoveryStart)
if ($publishedSnapshot) { $metricFiles += $publishedSnapshot }
if ($isM14Event -or $isM11Final -or $isM12Reset -or $isM12FixtureStart -or $isM12RecoveryStart) { [IO.File]::Move($ledgerTemporary,$snapshotLedgerPath) }
else { [IO.File]::Move($ledgerTemporary,$snapshotLedgerPath,$true) }
$metricFiles += $snapshotLedgerPath
if ($isM14Event) {
    $manifest=Update-GeordiM19ManifestAtomic -ManifestPath $manifestPath -ExpectedRunId ([string]$manifest.runId) -Mutation {
        param($latest)
        $sources=@($latest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
        if ($sources.Count -gt 1) { throw 'Private VictoriaMetrics evidence source is duplicated.' }
        if ($sources.Count -eq 0) {
            $latest.additionalSources+=@{channel='victoriametrics';control='geordi.security.authentication.attempts';captures=@()}
            $sources=@($latest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
        }
        $sources[0].captures=@(@($sources[0].captures)+$metricFiles | Select-Object -Unique)
        if ($snapshot.PositiveControl) { $sources[0].control=$snapshot.PositiveMetricName }
        $total=0L
        foreach($capture in @($sources[0].captures)) {
            if (!(Test-Path -LiteralPath $capture -PathType Leaf)) { throw 'Persisted metric capture disappeared during manifest update.' }
            $total += [long](Get-Item -LiteralPath $capture).Length
        }
        if($total -gt 67108864L){throw 'Current-run persisted metric evidence exceeded its aggregate size bound.'}
        $latest.persistedMetricEvidenceBytes=$total
    }
} else {
    if ($metricSource.Count -eq 1) { $metricSource[0].captures=@(@($metricSource[0].captures | Where-Object { $_ -notin $oldPhaseFiles })+$metricFiles) }
    if ($metricSource.Count -eq 0) {
        $manifest.additionalSources += @{ channel='victoriametrics'; control='geordi.security.authentication.attempts'; captures=@($metricFiles) }
    }
    if ($snapshot.PositiveControl) { $metricSource = @($manifest.additionalSources | Where-Object { $_.channel -ceq 'victoriametrics' }); $metricSource[0].control = $snapshot.PositiveMetricName }
    $manifest.persistedMetricEvidenceBytes=$newTotal
    Write-GeordiM19ManifestAtomic -Path $manifestPath -Manifest $manifest
}
} finally {
    if ($phasePublicationMutex) { Exit-GeordiPersistedMetricPhasePublication -Mutex $phasePublicationMutex }
}
Write-Output ("vm_generation_snapshot=PASS phase={0} duration_source=bounded_export series={1} samples={2} bytes={3} current_run_interval=true" -f
    $Phase,$snapshot.Series,$snapshot.Samples,$snapshot.Bytes)
if($SkipLogSnapshot){
    Write-Output ("generation_snapshot=recorded phase={0} service_log_snapshot=skipped shared_generation_follower=authority" -f $Phase)
    return
}
$generationRoot = Join-Path $captureRoot 'container-generations'
[void][IO.Directory]::CreateDirectory($generationRoot)
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$key = if ($isM14Event) { "$Phase-$stamp-$occurrenceId" } else { "$Phase-$stamp" }
$dockerPath = (Get-Command docker.exe -ErrorAction Stop).Source
$snapshotProcessTimeoutSeconds = 30
$snapshotLimit = if ($Services -contains 'otel-collector') { Get-GeordiPrivateCaptureLimit 'collector' } else { [long](64MB) }
$logCaptureRecords=[Collections.Generic.List[object]]::new()
if ($isM14Event) {
    foreach ($containerIdentity in $containerGenerations) {
        $service=[string]$containerIdentity.service
        if ($service -notin $Services) { continue }
        $serviceDirectory=Join-Path $generationRoot $service
        [void][IO.Directory]::CreateDirectory($serviceDirectory)
        $path=Join-Path $serviceDirectory "$Phase-$occurrenceId-$($containerIdentity.containerId.Substring(0,12)).log"
        $errorPath=Join-Path $serviceDirectory "$Phase-$occurrenceId-$($containerIdentity.containerId.Substring(0,12)).stderr.log"
        foreach ($reserved in @($path,$errorPath)) {
            $stream=[IO.File]::Open($reserved,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$stream.Dispose()
        }
        $process=Start-Process -FilePath $dockerPath -ArgumentList @('logs','--timestamps',[string]$containerIdentity.containerId) `
            -WorkingDirectory $repositoryRoot -RedirectStandardOutput $path -RedirectStandardError $errorPath -WindowStyle Hidden -PassThru
        if (!$process.WaitForExit($snapshotProcessTimeoutSeconds * 1000)) {
            $process.Kill($true);[void]$process.WaitForExit(5000)
            throw 'Private M14 exact-container log snapshot timed out.'
        }
        if ($process.ExitCode -ne 0) { throw 'Private M14 exact-container log snapshot failed.' }
        $stdoutBytes=(Get-Item -LiteralPath $path).Length;$stderrBytes=(Get-Item -LiteralPath $errorPath).Length
        if ($stdoutBytes -gt $snapshotLimit -or $stderrBytes -gt $snapshotLimit -or ($stdoutBytes+$stderrBytes) -gt $snapshotLimit) {
            throw 'Private M14 exact-container log snapshot exceeded its configured size bound.'
        }
        foreach ($capturePath in @($path,$errorPath)) {
            if ((Get-Item -LiteralPath $capturePath).Length -gt 0) {
                $logCaptureRecords.Add([pscustomobject]@{path=$capturePath;service=$service;containerId=[string]$containerIdentity.containerId})
            }
        }
        if ($stdoutBytes -eq 0 -and $stderrBytes -eq 0) { Remove-Item -LiteralPath $path,$errorPath -Force }
    }
} else {
    $path = Join-Path $generationRoot "$key.log"
    $errorPath = Join-Path $generationRoot "$key.stderr.log"
    $outReservation=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$outReservation.Dispose()
    $errorReservation=[IO.File]::Open($errorPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$errorReservation.Dispose()
    $arguments=@('compose','logs','--no-color','--timestamps')+$Services
    $process=Start-Process -FilePath $dockerPath -ArgumentList $arguments -WorkingDirectory $repositoryRoot `
        -RedirectStandardOutput $path -RedirectStandardError $errorPath -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit($snapshotProcessTimeoutSeconds * 1000)) {
        $process.Kill($true);[void]$process.WaitForExit(5000)
        throw "Private M19 container generation log command timed out after $snapshotProcessTimeoutSeconds seconds."
    }
    if ($process.ExitCode -ne 0) { throw 'Private M19 container generation snapshot failed.' }
    $stdoutBytes=(Get-Item -LiteralPath $path).Length;$stderrBytes=(Get-Item -LiteralPath $errorPath).Length
    if ($stdoutBytes -gt $snapshotLimit -or $stderrBytes -gt $snapshotLimit -or ($stdoutBytes+$stderrBytes) -gt $snapshotLimit) {
        throw 'Private M19 container generation snapshot exceeded its configured size bound.'
    }
    foreach ($capturePath in @($path,$errorPath)) {
        if ((Get-Item -LiteralPath $capturePath).Length -gt 0) { $logCaptureRecords.Add([pscustomobject]@{path=$capturePath;service=$null;containerId=$null}) }
    }
    if ($logCaptureRecords.Count -eq 0) { Remove-Item -LiteralPath $path,$errorPath -Force;return }
}
$nonemptyPaths=@($logCaptureRecords | ForEach-Object { [string]$_.path })
$channels = [Collections.Generic.List[string]]::new()
if (@($Services | Where-Object { $_ -eq 'frontend' }).Count) { $channels.Add('nginx-access') }
if (@($Services | Where-Object { $_ -in @('backend','oidc-fixture','webhook-receiver','webhook-receiver-a','webhook-receiver-b') }).Count) { $channels.Add('backend') }
if (@($Services | Where-Object { $_ -eq 'otel-collector' }).Count) { $channels.Add('otel'); $channels.Add('collector') }
$channelPaths=@{}
foreach ($record in $logCaptureRecords) {
    $mappedChannels=@()
    if ([string]$record.service -ceq 'frontend') { $mappedChannels=@('nginx-access') }
    elseif ([string]$record.service -in @('backend','oidc-fixture','webhook-receiver','webhook-receiver-a','webhook-receiver-b')) { $mappedChannels=@('backend') }
    elseif ([string]$record.service -ceq 'otel-collector') { $mappedChannels=@('otel','collector') }
    foreach ($channel in $mappedChannels) {
        if (!$channelPaths.ContainsKey($channel)) { $channelPaths[$channel]=[Collections.Generic.List[string]]::new() }
        $channelPaths[$channel].Add([string]$record.path)
    }
}
foreach ($channel in $channels) {
    if (!$isM14Event) {
        if (!$manifest.ContainsKey('generationCaptures')) { $manifest.generationCaptures = @{} }
        if (!$manifest.generationCaptures.ContainsKey($channel)) { $manifest.generationCaptures[$channel] = @() }
        $manifest.generationCaptures[$channel] += $nonemptyPaths
    }
}
if ($isM14Event) {
    $metricContainer=@($containerGenerations | Where-Object { [string]$_.service -ceq 'victoriametrics' })
    if ($metricContainer.Count -ne 1) { throw 'M14 persisted metrics capture has no exact VictoriaMetrics container identity.' }
    $eventFiles=@(
        @($metricFiles | Select-Object -Unique | ForEach-Object {
            $item=Get-Item -LiteralPath $_ -Force
            [ordered]@{path=[IO.Path]::GetFullPath($_);identity=$item.Name;byteCount=[long]$item.Length;
                sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant();service='victoriametrics';
                containerId=[string]$metricContainer[0].containerId;source='victoriametrics-export'}
        }) + @($logCaptureRecords | ForEach-Object {
            $item=Get-Item -LiteralPath $_.path -Force
            [ordered]@{path=[IO.Path]::GetFullPath([string]$_.path);identity=$item.Name;byteCount=[long]$item.Length;
                sha256=(Get-FileHash -LiteralPath $_.path -Algorithm SHA256).Hash.ToLowerInvariant();service=[string]$_.service;
                containerId=[string]$_.containerId;source='docker-container-logs'}
        })
    )
    $eventFiles=@($eventFiles | Select-Object -Unique)
    if ($eventFiles.Count -eq 0) { throw 'M14 generation event has no immutable capture files.' }
    foreach ($eventFile in $eventFiles) { (Get-Item -LiteralPath ([string]$eventFile.path) -Force).IsReadOnly=$true }
    $manifest=Update-GeordiM19ManifestAtomic -ManifestPath $manifestPath -ExpectedRunId ([string]$manifest.runId) -Mutation {
        param($latest)
        if (!$latest.ContainsKey('generationCaptures')) { $latest.generationCaptures=@{} }
        foreach($channel in $channels) {
            if (!$latest.generationCaptures.ContainsKey($channel)) { $latest.generationCaptures[$channel]=@() }
            $newChannelPaths=if($channelPaths.ContainsKey($channel)){@($channelPaths[$channel].ToArray())}else{@()}
            $latest.generationCaptures[$channel]=@(@($latest.generationCaptures[$channel])+$newChannelPaths | Select-Object -Unique)
        }
        if (!$latest.ContainsKey('generationCaptureEvents') -or !$latest.generationCaptureEvents.ContainsKey($occurrenceId)) { throw 'M14 capture event disappeared before completion.' }
        $currentEvent=$latest.generationCaptureEvents[$occurrenceId]
        if ([string]$currentEvent.status -cne 'in_progress' -or [string]$currentEvent.diagnosticInvocationId -cne $diagnosticInvocationId) {
            throw 'M14 capture event lifecycle conflict.'
        }
        $currentEvent.files=$eventFiles
        $currentEvent.containerGenerations=@($containerGenerations.ToArray())
        $currentEvent.status='complete'
        $currentEvent.completedUtc=[DateTimeOffset]::UtcNow.ToString('o')
        $latest.generationCaptureEvents[$occurrenceId]=$currentEvent
    }
} else {
    Write-GeordiM19ManifestAtomic -Path $manifestPath -Manifest $manifest
}
Write-Output ("generation_snapshot=recorded phase={0} services={1} files={2}" -f $Phase,$Services.Count,$nonemptyPaths.Count)
