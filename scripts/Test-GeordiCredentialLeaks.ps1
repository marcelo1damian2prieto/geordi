[CmdletBinding()]
param(
    [string] $ManifestPath,
    [string] $DiagnosticAttemptId,
    [switch] $SelfTest,
    [switch] $LargeCaptureSelfTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiTempoEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiDiagnosticEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')

function Inspect-PrivateBytes {
    param([byte[]] $Bytes, [hashtable] $State, [int] $Depth = 0)
    if ($Bytes.Length -gt 64MB -or $Depth -gt 4) { throw 'Capture expansion bound exceeded.' }
    $State.Expanded += $Bytes.Length
    if ($State.Expanded -gt 512MB) { throw 'Capture expansion bound exceeded.' }
    foreach ($content in @([Text.Encoding]::UTF8.GetString($Bytes), [Text.Encoding]::Latin1.GetString($Bytes),
            [Text.Encoding]::Unicode.GetString($Bytes))) {
        if ($content.Contains($State.Control, [StringComparison]::Ordinal)) { $State.ObservedControl = $true }
        foreach ($pattern in $State.RawPatterns) {
            if ($content.Contains($pattern, [StringComparison]::Ordinal)) { $State.RawMatches++ }
        }
        foreach ($pattern in $State.EncodedPatterns) {
            if ($content.Contains($pattern, [StringComparison]::Ordinal)) { $State.EncodedMatches++ }
        }
    }
    if ($Bytes.Length -lt 4 -or $Bytes[0] -ne 0x50 -or $Bytes[1] -ne 0x4b) { return }
    $inputStream = [IO.MemoryStream]::new($Bytes, $false)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new($inputStream, [IO.Compression.ZipArchiveMode]::Read, $false)
        foreach ($entry in $archive.Entries) {
            $State.Entries++
            if ($State.Entries -gt 131072 -or $entry.Length -gt 64MB) { throw 'Capture expansion bound exceeded.' }
            Inspect-PrivateBytes ([Text.Encoding]::UTF8.GetBytes($entry.FullName)) $State ($Depth + 1)
            if ($entry.FullName.EndsWith('/')) { continue }
            $entryStream = $entry.Open()
            $expandedStream = [IO.MemoryStream]::new()
            try {
                $buffer = [byte[]]::new(8192)
                while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($expandedStream.Length + $read -gt 64MB) { throw 'Capture expansion bound exceeded.' }
                    $expandedStream.Write($buffer, 0, $read)
                }
                Inspect-PrivateBytes $expandedStream.ToArray() $State ($Depth + 1)
            } finally {
                $expandedStream.Dispose()
                $entryStream.Dispose()
            }
        }
    } finally {
        if ($archive) { $archive.Dispose() }
        $inputStream.Dispose()
    }
}

function Test-StreamedCaptureChannel {
    param([hashtable] $Manifest, [string] $Channel, [string] $Control,
        [Collections.Generic.HashSet[string]] $RawPatterns,
        [Collections.Generic.HashSet[string]] $EncodedPatterns)
    $files = @($Manifest.captures[$Channel])
    $metadata = $Manifest.captureMetadata[$Channel]
    $maximumBytes = Get-GeordiPrivateCaptureLimit $Channel
    $metadataFiles = @($metadata.files)
    if (!$metadata -or $metadata.version -ne 1 -or $metadata.complete -ne $true -or
            [string]$metadata.runId -cne [string]$Manifest.runId -or
            !$metadata.captureCompletedUtc -or $metadata.maximumLogicalByteCount -ne $maximumBytes -or
            [string]$metadata.overlapPolicy -cne 'all ordered files retained and scanned independently' -or
            $metadata.positiveControlFound -ne $true -or $files.Count -eq 0 -or
            $metadataFiles.Count -ne $files.Count -or $metadata.fileCount -ne $files.Count) {
        throw 'Streamed evidence manifest is incomplete or malformed.'
    }
    $captureStarted = ConvertTo-GeordiEvidenceTimestamp $metadata.captureStartedUtc
    $manifestStarted = ConvertTo-GeordiEvidenceTimestamp $Manifest.captureStartedUtc
    $captureCompleted = ConvertTo-GeordiEvidenceTimestamp $metadata.captureCompletedUtc
    if ($captureStarted.UtcTicks -ne $manifestStarted.UtcTicks -or $captureCompleted -le $captureStarted) {
        throw 'Streamed evidence interval is invalid.'
    }

    $needles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$needles.Add($Control)
    foreach ($pattern in $RawPatterns) { [void]$needles.Add($pattern) }
    foreach ($pattern in $EncodedPatterns) { [void]$needles.Add($pattern) }
    $rawMatches = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $encodedMatches = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $controlFound = $false
    $logicalBytes = 0L
    for ($index = 0; $index -lt $files.Count; $index++) {
        $path = [IO.Path]::GetFullPath([string]$files[$index])
        $entry = $metadataFiles[$index]
        if ($entry.order -ne $index -or [string]$entry.path -cne $path -or
                [string]$entry.identity -cne [IO.Path]::GetFileName($path) -or
                $entry.startOffset -ne 0 -or $entry.byteCount -le 0 -or
                $entry.endOffsetExclusive -ne $entry.byteCount -or
                [string]$entry.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Streamed evidence file metadata is malformed or reordered.'
        }
        $scan = Invoke-GeordiPrivateCaptureScan -Path $path -Needles ([string[]]@($needles)) -MaximumBytes $maximumBytes
        if ($scan.ByteCount -ne [long]$entry.byteCount -or $scan.Sha256 -cne [string]$entry.sha256) {
            throw 'Streamed evidence file changed after capture.'
        }
        $logicalBytes += $scan.ByteCount
        if ($logicalBytes -gt $maximumBytes) { throw 'Streamed evidence channel exceeded its bound.' }
        if (@($scan.Matches | Where-Object { $_ -ceq $Control }).Count -gt 0) { $controlFound = $true }
        foreach ($pattern in $RawPatterns) {
            if (@($scan.Matches | Where-Object { $_ -ceq $pattern }).Count -gt 0) { [void]$rawMatches.Add($pattern) }
        }
        foreach ($pattern in $EncodedPatterns) {
            if (@($scan.Matches | Where-Object { $_ -ceq $pattern }).Count -gt 0) { [void]$encodedMatches.Add($pattern) }
        }
    }
    if ($logicalBytes -ne [long]$metadata.logicalByteCount -or !$controlFound) {
        throw 'Streamed evidence byte coverage or positive control is incomplete.'
    }
    return [pscustomobject]@{ RawMatches=$rawMatches.Count; EncodedMatches=$encodedMatches.Count; PositiveControl=$true }
}

function ConvertTo-GeordiEvidenceTimestamp {
    param([Parameter(Mandatory)] $Value)
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new($Value) }
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
}

function Update-TestCaptureMetadata {
    param([hashtable] $Manifest, [string] $Channel)
    $paths = @($Manifest.captures[$Channel])
    $files = [Collections.Generic.List[object]]::new()
    $logicalBytes = 0L
    for ($index = 0; $index -lt $paths.Count; $index++) {
        $path = [IO.Path]::GetFullPath([string]$paths[$index])
        $length = (Get-Item -LiteralPath $path).Length
        $logicalBytes += $length
        $files.Add([ordered]@{
            order=$index;identity=[IO.Path]::GetFileName($path);path=$path;startOffset=0L
            endOffsetExclusive=[long]$length;byteCount=[long]$length
            sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    $Manifest.captureMetadata[$Channel] = [ordered]@{
        version=1;complete=$true;runId=$Manifest.runId;captureStartedUtc=$Manifest.captureStartedUtc
        captureCompletedUtc=[DateTimeOffset]::UtcNow.ToString('o');logicalByteCount=$logicalBytes
        maximumLogicalByteCount=(Get-GeordiPrivateCaptureLimit $Channel);fileCount=$files.Count
        overlapPolicy='all ordered files retained and scanned independently';positiveControlFound=$true
        files=@($files.ToArray())
    }
}

function New-TestTempoSegmentCapture {
    param([string] $Directory,[string] $Control,[hashtable] $Manifest)
    $segmentDirectory=Join-Path $Directory 'tempo-segments'
    $writer=[GeordiTempoSegmentWriter]::new($segmentDirectory,33554432L,167772160L,256,67108864L)
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes('{"resource":{"service.name":"' + $Control + '"}}')
        $writer.BeginRecord(1L);$writer.WriteRecordBytes($bytes,$bytes.Length);$writer.CompleteRecord()
        $metadata=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $writer.Complete() -Depth 20 -Compress) -AsHashtable
        $metadata.runId=[string]$Manifest.runId
        $metadata.captureStartedUtc=[string]$Manifest.captureStartedUtc
        $metadata.captureCompletedUtc=[DateTimeOffset]::UtcNow.ToString('o')
        return $metadata
    } finally { $writer.Dispose() }
}

function Test-PrivateCaptures {
    param([hashtable] $Manifest)
    Assert-GeordiM14GenerationEvents -Manifest $Manifest -RequireSealedGenerations
    $channels = @('browser', 'nginx-access', 'nginx-error', 'backend', 'problems', 'otel', 'collector', 'tempo', 'ci-artifacts')
    if (!$Manifest.ContainsKey('sentinels') -or @($Manifest.sentinels).Count -eq 0) { throw 'Missing private sentinel inventory.' }
    $rawPatterns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $encodedPatterns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sentinelCharacters = 0L
    foreach ($sentinel in $Manifest.sentinels) {
        if ($sentinel -isnot [string] -or $sentinel.Length -lt 8 -or $sentinel.Length -gt 16384) { throw 'Invalid private sentinel inventory.' }
        $sentinelCharacters += $sentinel.Length
        if ($sentinelCharacters -gt 256KB) { throw 'Private sentinel inventory exceeded its bound.' }
        [void] $rawPatterns.Add($sentinel)
        [void] $encodedPatterns.Add([Uri]::EscapeDataString($sentinel))
        [void] $encodedPatterns.Add([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel)))
        [void] $encodedPatterns.Add([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel)).TrimEnd('=').Replace('+','-').Replace('/','_'))
        $jsonSentinel = ConvertTo-Json -InputObject $sentinel -Compress
        if ($jsonSentinel.Length -ge 2) { [void] $encodedPatterns.Add($jsonSentinel.Substring(1, $jsonSentinel.Length - 2)) }
    }
    foreach ($sentinel in @(Get-GeordiDiagnosticSentinelValues -Manifest $Manifest)) {
        if ($sentinel.Length -lt 8 -or $sentinel.Length -gt 16384) { throw 'Invalid diagnostic private sentinel inventory.' }
        $sentinelCharacters += $sentinel.Length
        if ($sentinelCharacters -gt 256KB) { throw 'Private sentinel inventory exceeded its bound.' }
        [void]$rawPatterns.Add($sentinel)
        [void]$encodedPatterns.Add([Uri]::EscapeDataString($sentinel))
        $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel))
        [void]$encodedPatterns.Add($base64)
        [void]$encodedPatterns.Add($base64.TrimEnd('=').Replace('+','-').Replace('/','_'))
        $jsonSentinel = ConvertTo-Json -InputObject $sentinel -Compress
        if ($jsonSentinel.Length -ge 2) { [void]$encodedPatterns.Add($jsonSentinel.Substring(1,$jsonSentinel.Length-2)) }
    }
    $results = @()
    foreach ($channel in $channels) {
        if (!$Manifest.captures.ContainsKey($channel) -or !$Manifest.controls.ContainsKey($channel)) { throw 'Required capture unavailable.' }
        $control = [string] $Manifest.controls[$channel]
        if ($control.Length -lt 8) { throw 'Invalid positive control.' }
        $files = @($Manifest.captures[$channel])
        if ($files.Count -eq 0) { throw 'Required capture unavailable.' }
        if ($channel -in @('backend','otel','collector')) {
            if (!$Manifest.ContainsKey('captureMetadata') -or !$Manifest.captureMetadata.ContainsKey($channel)) {
                throw 'Streamed evidence metadata unavailable.'
            }
            $streamed = Test-StreamedCaptureChannel $Manifest $channel $control $rawPatterns $encodedPatterns
            if ($streamed.RawMatches -ne 0 -or $streamed.EncodedMatches -ne 0) {
                throw 'Credential material detected.'
            }
            $results += [pscustomobject] @{ Channel = $channel; PositiveControl = $true;
                RawMatches = $streamed.RawMatches; EncodedMatches = $streamed.EncodedMatches }
            continue
        }
        if ($channel -ceq 'tempo') {
            if (!$Manifest.ContainsKey('captureMetadata') -or !$Manifest.captureMetadata.ContainsKey('tempo')) {
                throw 'Segmented Tempo evidence metadata unavailable.'
            }
            $streamed=Test-GeordiTempoSegmentChannel -Paths $files -Metadata $Manifest.captureMetadata.tempo `
                -Needles ([string[]]@($rawPatterns) + [string[]]@($encodedPatterns) + @($control)) `
                -Control $control -MaximumLogicalBytes (Get-GeordiPrivateCaptureLimit 'tempo') `
                -ExpectedRunId ([string]$Manifest.runId) -ExpectedCaptureStartedUtc ([string]$Manifest.captureStartedUtc)
            $rawMatches=@($streamed.Matches | Where-Object { $rawPatterns.Contains([string]$_) }).Count
            $encodedMatches=@($streamed.Matches | Where-Object { $encodedPatterns.Contains([string]$_) }).Count
            if ($rawMatches -ne 0 -or $encodedMatches -ne 0) { throw 'Credential material detected.' }
            $results += [pscustomobject]@{ Channel=$channel;PositiveControl=$true;RawMatches=$rawMatches;EncodedMatches=$encodedMatches }
            continue
        }
        $state = @{ Control = $control; RawPatterns = $rawPatterns; EncodedPatterns = $encodedPatterns;
            ObservedControl = $false; RawMatches = 0L; EncodedMatches = 0L; Expanded = 0L; Entries = 0L }
        foreach ($file in $files) {
            if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Required capture unavailable.' }
            if ((Get-Item -LiteralPath $file).Length -gt 64MB) { throw 'Capture size bound exceeded.' }
            $bytes = [IO.File]::ReadAllBytes($file)
            if ($bytes.Length -eq 0) { throw 'Required capture empty.' }
            Inspect-PrivateBytes $bytes $state
        }
        if (!$state.ObservedControl) { throw ('Positive control unavailable in channel=' + $channel + '.') }
        $results += [pscustomobject] @{ Channel = $channel; PositiveControl = $true;
            RawMatches = $state.RawMatches; EncodedMatches = $state.EncodedMatches }
    }
    $additionalSources = if ($Manifest.ContainsKey('additionalSources')) { @($Manifest.additionalSources) } else { @() }
    foreach ($requiredSource in @('loki', 'victoriametrics')) {
        if (@($additionalSources | Where-Object { [string]$_.channel -ceq $requiredSource }).Count -ne 1) {
            throw 'Required persisted-source capture unavailable.'
        }
    }
    foreach ($source in $additionalSources) {
        if ([string]::IsNullOrWhiteSpace([string]$source.channel) -or
                [string]::IsNullOrWhiteSpace([string]$source.control) -or @($source.captures).Count -eq 0) {
            throw 'Additional persistence capture unavailable.'
        }
        $state = @{ Control = [string]$source.control; RawPatterns = $rawPatterns; EncodedPatterns = $encodedPatterns;
            ObservedControl = $false; RawMatches = 0L; EncodedMatches = 0L; Expanded = 0L; Entries = 0L }
        foreach ($file in @($source.captures)) {
            if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Additional persistence capture unavailable.' }
            if ((Get-Item -LiteralPath $file).Length -gt 64MB) { throw 'Capture size bound exceeded.' }
            Inspect-PrivateBytes ([IO.File]::ReadAllBytes($file)) $state
        }
        if (!$state.ObservedControl) { throw 'Additional persistence positive control unavailable.' }
        $results += [pscustomobject] @{ Channel = [string]$source.channel; PositiveControl = $true;
            RawMatches = $state.RawMatches; EncodedMatches = $state.EncodedMatches }
    }
    return $results
}

function Assert-PrivateScanClean {
    param([object[]] $Results)
    if (@($Results | Where-Object { $_.RawMatches -gt 0 -or $_.EncodedMatches -gt 0 }).Count -ne 0) {
        throw 'Credential material detected.'
    }
}

if ($SelfTest) {
    $privateRoot = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-capture-scanner-selftest-' + [guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($privateRoot)
    try {
        $manifest = @{ sentinels = @([guid]::NewGuid().ToString('N') + '/+='); controls = @{}; captures = @{};
            runId='scanner-self-test'; root=$privateRoot; version=2; startedUtc=[DateTimeOffset]::UtcNow.ToString('o');
            captureStartedUtc=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o'); captureMetadata=@{} }
        foreach ($channel in @('browser', 'nginx-access', 'nginx-error', 'backend', 'problems', 'otel', 'collector', 'tempo', 'ci-artifacts')) {
            $control = 'positive-' + $channel + '-' + [guid]::NewGuid().ToString('N')
            $manifest.controls[$channel] = $control
            if ($channel -ceq 'tempo') {
                $tempo=New-TestTempoSegmentCapture $privateRoot $control $manifest
                $manifest.captures[$channel]=@($tempo.segments | ForEach-Object path)
                $manifest.captureMetadata.tempo=$tempo
            } else {
                $file = Join-Path $privateRoot ($channel + '.capture')
                [IO.File]::WriteAllText($file, $control)
                $manifest.captures[$channel] = @($file)
            }
        }
        $manifest.additionalSources = @()
        foreach ($channel in @('loki', 'victoriametrics')) {
            $control = 'positive-' + $channel + '-' + [guid]::NewGuid().ToString('N')
            $file = Join-Path $privateRoot ($channel + '.capture')
            [IO.File]::WriteAllText($file, $control)
            $manifest.additionalSources += @{ channel = $channel; control = $control; captures = @($file) }
        }
        foreach ($channel in @('backend','otel','collector')) {
            $capturePath=[string]$manifest.captures[$channel][0]
            $length=(Get-Item -LiteralPath $capturePath).Length
            $manifest.captureMetadata[$channel]=@{
                version=1;complete=$true;runId=$manifest.runId;captureStartedUtc=$manifest.captureStartedUtc
                captureCompletedUtc=[DateTimeOffset]::UtcNow.ToString('o');logicalByteCount=$length
                maximumLogicalByteCount=(Get-GeordiPrivateCaptureLimit $channel);fileCount=1
                overlapPolicy='all ordered files retained and scanned independently';positiveControlFound=$true
                files=@(@{order=0;identity=[IO.Path]::GetFileName($capturePath);path=[IO.Path]::GetFullPath($capturePath);startOffset=0L;
                    endOffsetExclusive=[long]$length;byteCount=[long]$length;sha256=(Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash.ToLowerInvariant()})
            }
        }
        $backendFirst=[string]$manifest.captures.backend[0]
        $backendSecond=Join-Path $privateRoot 'backend.generation-two.capture'
        [IO.File]::WriteAllText($backendSecond,[string]$manifest.controls.backend)
        $backendFirstError=Join-Path $privateRoot 'backend.generation-one.stderr'
        $backendSecondError=Join-Path $privateRoot 'backend.generation-two.stderr'
        [IO.File]::WriteAllText($backendFirstError,'')
        [IO.File]::WriteAllText($backendSecondError,'')
        $oldProcessPath=Join-Path $privateRoot 'old.process.json';$newProcessPath=Join-Path $privateRoot 'new.process.json'
        [IO.File]::WriteAllText($oldProcessPath,(ConvertTo-Json -InputObject @{id=31001;name='docker';startUtc=([DateTimeOffset]$manifest.captureStartedUtc).ToString('o');containerId=('3'*64);service='backend';project='geordi'} -Compress))
        [IO.File]::WriteAllText($newProcessPath,(ConvertTo-Json -InputObject @{id=31002;name='docker';startUtc=([DateTimeOffset]$manifest.captureStartedUtc).AddSeconds(22).ToString('o');containerId=('4'*64);service='backend';project='geordi'} -Compress))
        $manifest.captures.backend=@($backendFirst,$backendSecond)
        Update-TestCaptureMetadata $manifest 'backend'
        $generationStart=[DateTimeOffset]$manifest.captureStartedUtc
        $generationEnd=$generationStart.AddSeconds(20)
        $secondStart=$generationEnd.AddSeconds(2)
        $backendOldId='3'*64;$backendNewId='4'*64
        $oldGeneration=[ordered]@{generationId='11111111111111111111111111111111';candidateId=$manifest.runId;runId=$manifest.runId;
            logicalService='backend';containerId=$backendOldId;composeProject='geordi';workingDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));
            containerCreatedUtc=$generationStart.AddSeconds(-5).ToString('o');capturePath=$backendFirst;captureFileIdentity=[IO.Path]::GetFileName($backendFirst);
            stderrCapturePath=$backendFirstError;stderrFileIdentity=[IO.Path]::GetFileName($backendFirstError);stderrByteCount=0L;stderrSha256=$null;
            processRecordPath=$oldProcessPath;followerProcess=@{id=31001;name='docker';startUtc=$generationStart.ToString('o')};
            captureStartedUtc=$generationStart.ToString('o');captureEndedUtc=$generationEnd.ToString('o');byteCount=(Get-Item $backendFirst).Length;
            sha256=(Get-FileHash $backendFirst -Algorithm SHA256).Hash.ToLowerInvariant();terminalStatus='sealed';handoffId=$null;replacementReason='initial'}
        $newGeneration=[ordered]@{generationId='22222222222222222222222222222222';candidateId=$manifest.runId;runId=$manifest.runId;
            logicalService='backend';containerId=$backendNewId;composeProject='geordi';workingDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));
            containerCreatedUtc=$secondStart.AddSeconds(-1).ToString('o');capturePath=$backendSecond;captureFileIdentity=[IO.Path]::GetFileName($backendSecond);
            stderrCapturePath=$backendSecondError;stderrFileIdentity=[IO.Path]::GetFileName($backendSecondError);stderrByteCount=0L;stderrSha256=$null;
            processRecordPath=$newProcessPath;followerProcess=@{id=31002;name='docker';startUtc=$secondStart.ToString('o')};
            captureStartedUtc=$secondStart.ToString('o');captureEndedUtc=$secondStart.AddSeconds(10).ToString('o');byteCount=(Get-Item $backendSecond).Length;
            sha256=(Get-FileHash $backendSecond -Algorithm SHA256).Hash.ToLowerInvariant();terminalStatus='sealed';handoffId='33333333333333333333333333333333';replacementReason='synthetic-replacement'}
        $manifest.captureGenerations=@{backend=@($oldGeneration,$newGeneration)}
        $manifest.captureHandoffs=@{'33333333333333333333333333333333'=@{handoffId='33333333333333333333333333333333';logicalService='backend';
            oldGenerationId=$oldGeneration.generationId;newGenerationId=$newGeneration.generationId;oldContainerId=$backendOldId;newContainerId=$backendNewId;
            status='complete';gapState='bounded-transition';gapDurationMilliseconds=2000;maximumGapMilliseconds=10000}}
        $manifest.generationCaptures=@{backend=@($backendFirst,$backendSecond)}
        $backendEventPath=Join-Path $privateRoot 'backend.m14-event.capture'
        [IO.File]::WriteAllText($backendEventPath,[string]$manifest.controls.backend)
        (Get-Item -LiteralPath $backendEventPath -Force).IsReadOnly=$true
        $eventId='44444444444444444444444444444444'
        $eventServices=@(Get-GeordiM14EventIdentityServices -RequestedLogServices @('backend'))
        $repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $event=[ordered]@{candidateId=$manifest.runId;runId=$manifest.runId;diagnosticInvocationId='5'*32;phase='m14-final';
            occurrenceId=$eventId;services=$eventServices;requestedLogServices=@('backend');
            containerGenerations=@(
                @{service='backend';containerId=$backendNewId;composeProject='geordi';workingDirectory=$repoRoot;createdUtc=$generationEnd.ToString('o')},
                @{service='victoriametrics';containerId=('6'*64);composeProject='geordi';workingDirectory=$repoRoot;createdUtc=$generationEnd.ToString('o')});
            sourceIdentity=@('victoriametrics-export','docker-container-logs');capturedUtc=$generationEnd.ToString('o');status='complete';
            files=@(@{path=$backendEventPath;identity=[IO.Path]::GetFileName($backendEventPath);byteCount=(Get-Item $backendEventPath).Length;
                sha256=(Get-FileHash $backendEventPath -Algorithm SHA256).Hash.ToLowerInvariant();service='backend';containerId=$backendNewId;source='docker-container-logs'})}
        $manifest.generationCaptureEvents=@{$eventId=$event}
        $manifest.captures.backend=@($manifest.captures.backend)+$backendEventPath
        Update-TestCaptureMetadata $manifest 'backend'
        if ($manifest.captureMetadata.backend.fileCount -ne 3) { throw 'Multi-generation backend scanner fixture did not contain both follower generations and its M14 event snapshot.' }
        $manifestPath=Join-Path $privateRoot 'manifest.json'
        Write-GeordiM19ManifestAtomic -Path $manifestPath -Manifest $manifest
        $diagnostic=New-GeordiDiagnosticSentinelSource -CaptureRoot $privateRoot
        $diagnosticSecret='????????'
        Add-GeordiDiagnosticSentinel -Source $diagnostic -Class runtime-bearer -Value $diagnosticSecret
        $jsonDiagnosticSecret='synthetic-"diagnostic-credential-0002'
        Add-GeordiDiagnosticSentinel -Source $diagnostic -Class webhook-token -Value $jsonDiagnosticSecret
        $null=Seal-GeordiDiagnosticSentinelSource -Source $diagnostic
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($channel in @('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo','ci-artifacts')) {
            if ($manifest.captures[$channel] -isnot [array]) { $manifest.captures[$channel]=@($manifest.captures[$channel]) }
        }
        foreach ($channel in @('loki','victoriametrics')) {
            $manifest.additionalSources | ForEach-Object { if ($_.channel -ceq $channel) { $_.captures=@($_.captures) } }
        }
        $clean = @(Test-PrivateCaptures $manifest)
        if (@($clean | Where-Object { $_.RawMatches -ne 0 -or $_.EncodedMatches -ne 0 }).Count -ne 0 -or
            @($clean | Where-Object { $_.Channel -in @('loki','victoriametrics') }).Count -ne 2) { throw 'Scanner positive-control failure.' }
        if (@($clean).Count -ne 11 -or !$manifest.diagnosticSentinelSources.ContainsKey($diagnostic.Source.diagnosticInvocationId) -or
                $manifest.ContainsKey('acceptedAttemptId') -or $manifest.ContainsKey('attempts')) { throw 'Diagnostic sentinel inventory changed scanner or Finalize acceptance state.' }
        Write-Output 'scanner_generation_coverage=PASS follower_generations=2 m14_event_snapshots=1 physical_files=3 logical_backend_channels=1 generation_order=validated'
        $diagnosticRepresentations=@($diagnosticSecret,[Uri]::EscapeDataString($diagnosticSecret),
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($diagnosticSecret)),
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($diagnosticSecret)).TrimEnd('=').Replace('+','-').Replace('/','_'))
        if (@($diagnosticRepresentations | Select-Object -Unique).Count -ne 4) { throw 'Diagnostic scanner encodings are not distinct.' }
        foreach ($representation in $diagnosticRepresentations) {
            [IO.File]::WriteAllText($manifest.captures.backend[0],$manifest.controls.backend + $representation)
            Update-TestCaptureMetadata $manifest 'backend'
            $found=$false
            try { [void](Test-PrivateCaptures $manifest) } catch { $found=$true }
            if (!$found) { throw 'Diagnostic credential representation was not detected by the real scanner.' }
        }
        $jsonValue=ConvertTo-Json -InputObject $jsonDiagnosticSecret -Compress
        $jsonRepresentation=$jsonValue.Substring(1,$jsonValue.Length-2)
        [IO.File]::WriteAllText($manifest.captures.backend[0],$manifest.controls.backend + $jsonRepresentation)
        Update-TestCaptureMetadata $manifest 'backend'
        $jsonFound=$false
        try { [void](Test-PrivateCaptures $manifest) } catch { $jsonFound=$true }
        if (!$jsonFound) { throw 'Diagnostic JSON-encoded credential was not detected by the real scanner.' }
        [IO.File]::WriteAllText($manifest.captures.backend[0],$manifest.controls.backend)
        Update-TestCaptureMetadata $manifest 'backend'
        $diagnosticPath=[string]$manifest.diagnosticSentinelSources[$diagnostic.Source.diagnosticInvocationId].path
        $savedDiagnosticBytes=[IO.File]::ReadAllBytes($diagnosticPath)
        $diagnosticRecord=$manifest.diagnosticSentinelSources[$diagnostic.Source.diagnosticInvocationId]
        $savedPath=[string]$diagnosticRecord.path
        $savedIdentity=[string]$diagnosticRecord.sourceIdentity
        $diagnosticRecord.path=Join-Path $privateRoot 'diagnostic-evidence/sentinels/missing.jsonl'
        $diagnosticRecord.sourceIdentity='missing.jsonl'
        $missingRejected=$false
        try { [void](Test-PrivateCaptures $manifest) } catch { $missingRejected=$true }
        if (!$missingRejected) { throw 'Missing diagnostic source was accepted.' }
        $diagnosticRecord.path=$savedPath;$diagnosticRecord.sourceIdentity=$savedIdentity
        $diagnosticRecord.byteCount++
        $sizeRejected=$false
        try { [void](Test-PrivateCaptures $manifest) } catch { $sizeRejected=$true }
        if (!$sizeRejected) { throw 'Diagnostic source byte-count mismatch was accepted.' }
        $diagnosticRecord.byteCount--
        $diagnosticRecord.state='open'
        $incompleteRejected=$false
        try { [void](Test-PrivateCaptures $manifest) } catch { $incompleteRejected=$true }
        if (!$incompleteRejected) { throw 'Incomplete diagnostic source was accepted.' }
        $diagnosticRecord.state='failed-sealed'
        $failedRejected=$false
        try { [void](Test-PrivateCaptures $manifest) } catch { $failedRejected=$true }
        if (!$failedRejected) { throw 'Failed diagnostic source was accepted.' }
        $diagnosticRecord.state='sealed'
        $diagnosticRecord.sha256='0000000000000000000000000000000000000000000000000000000000000000'
        $hashRejected=$false
        try { [void](Test-PrivateCaptures $manifest) } catch { $hashRejected=$true }
        if (!$hashRejected) { throw 'Diagnostic source hash mismatch was accepted.' }
        $diagnosticRecord.sha256=(Get-FileHash -LiteralPath $diagnosticPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $truncatedPath=Join-Path (Split-Path -Parent $diagnosticPath) 'truncated.jsonl'
        $truncated=$savedDiagnosticBytes[0..([Math]::Floor($savedDiagnosticBytes.Length/2)-1)]
        [IO.File]::WriteAllBytes($truncatedPath,$truncated)
        $diagnosticRecord.path=$truncatedPath;$diagnosticRecord.sourceIdentity='truncated.jsonl'
        $diagnosticRecord.byteCount=[long]$truncated.Length
        $diagnosticRecord.sha256=(Get-FileHash -LiteralPath $truncatedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $truncatedRejected=$false
        try { [void](Test-PrivateCaptures $manifest) } catch { $truncatedRejected=$true }
        if (!$truncatedRejected) { throw 'Truncated diagnostic evidence was accepted.' }
        Remove-Item -LiteralPath $truncatedPath -Force
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        foreach($requiredChannel in @('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo','ci-artifacts')) {
            $missingChannel=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $manifest -Depth 32 -Compress) -AsHashtable
            [void]$missingChannel.captures.Remove($requiredChannel)
            $missingRejected=$false
            try { [void](Test-PrivateCaptures $missingChannel) } catch { $missingRejected=$true }
            if(!$missingRejected){throw 'A required runtime-channel positive control was not mandatory.'}
        }
        [IO.File]::AppendAllText($manifest.captures.backend[0], [Uri]::EscapeDataString($manifest.sentinels[0]))
        Update-TestCaptureMetadata $manifest 'backend'
        $dirtyRejected = $false
        try { [void] @(Test-PrivateCaptures $manifest) } catch { $dirtyRejected = $true }
        if (!$dirtyRejected) { throw 'Scanner negative-control failure.' }
        [IO.File]::WriteAllText($manifest.captures.backend[0], $manifest.controls.backend)
        Update-TestCaptureMetadata $manifest 'backend'
        $archivePath = Join-Path $privateRoot 'negative.jar'
        $archiveFile = [IO.File]::Create($archivePath)
        $archive = [IO.Compression.ZipArchive]::new($archiveFile, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $archive.CreateEntry('private.txt', [IO.Compression.CompressionLevel]::Optimal)
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write(('padding-' * 1000) + $manifest.sentinels[0]) } finally { $writer.Dispose() }
        } finally { $archive.Dispose(); $archiveFile.Dispose() }
        $manifest.captures['ci-artifacts'] += $archivePath
        $compressed = @(Test-PrivateCaptures $manifest)
        if (@($compressed | Where-Object { $_.Channel -eq 'ci-artifacts' -and $_.RawMatches + $_.EncodedMatches -gt 0 }).Count -ne 1) {
            throw 'Scanner compressed negative-control failure.'
        }
        $missingPersistence = $manifest.Clone()
        $missingPersistence.additionalSources = @($manifest.additionalSources | Where-Object { $_.channel -ne 'loki' })
        try { [void] @(Test-PrivateCaptures $missingPersistence); throw 'Missing persistence source was accepted.' }
        catch { if ($_.Exception.Message -eq 'Missing persistence source was accepted.') { throw } }
        Write-Output 'Credential scanner self-test passed: diagnostic sentinels, 9 runtime channels, Loki/VictoriaMetrics persistence, and text/compressed leak rejection.'
    } finally {
        $resolvedRoot = [IO.Path]::GetFullPath($privateRoot)
        $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::GetDirectoryName($resolvedRoot) -ne $expectedParent -or !(Split-Path $resolvedRoot -Leaf).StartsWith('geordi-m19-capture-scanner-selftest-')) {
            throw 'Unsafe private capture cleanup path.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
    return
}

if ($LargeCaptureSelfTest) {
    $privateRoot = Join-Path ([IO.Path]::GetTempPath()) ('geordi-large-leak-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($privateRoot)
    $manifest = $null
    try {
        $largePath = Join-Path $privateRoot 'collector-large.log'
        $largeBytes = [long](64MB + 4096)
        $stream = [IO.File]::Open($largePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try {
            $buffer = [byte[]]::new(65536)
            $remaining = $largeBytes
            while ($remaining -gt 0) {
                $count = [int][Math]::Min($buffer.Length,$remaining)
                $stream.Write($buffer,0,$count)
                $remaining -= $count
            }
        } finally { $stream.Dispose() }

        $sentinel = 'm19-large-' + [guid]::NewGuid().ToString('N') + '/+="probe'
        $backendControl = 'backend-control-' + [guid]::NewGuid().ToString('N')
        $controlBefore = 'collector-control-before-' + [guid]::NewGuid().ToString('N')
        $controlAfter = 'collector-control-after-' + [guid]::NewGuid().ToString('N')
        $writeAt = {
            param([string] $Path,[long] $Offset,[string] $Text)
            $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
            $file = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try { $file.Position=$Offset; $file.Write($bytes,0,$bytes.Length) } finally { $file.Dispose() }
        }
        & $writeAt $largePath 1024L $controlBefore
        & $writeAt $largePath 8192L $backendControl
        & $writeAt $largePath ([long](64MB + 512)) $controlAfter

        $manifest = @{
            runId = 'large-capture-self-test'
            captureStartedUtc = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
            sentinels = @($sentinel)
            controls = @{}
            captures = @{}
            captureMetadata = @{}
            additionalSources = @()
        }
        foreach ($channel in @('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo','ci-artifacts')) {
            if ($channel -in @('backend','otel','collector')) { continue }
            $control = 'positive-' + $channel + '-' + [guid]::NewGuid().ToString('N')
            if ($channel -ceq 'tempo') {
                $manifest.controls[$channel]=$control
                continue
            }
            $path = Join-Path $privateRoot ($channel + '.capture')
            [IO.File]::WriteAllText($path,$control,[Text.UTF8Encoding]::new($false))
            $manifest.controls[$channel]=$control
            $manifest.captures[$channel]=@($path)
        }
        $otelPath = Join-Path $privateRoot 'otel.capture'
        $manifest.controls.backend = $backendControl
        $manifest.captures.backend = @($largePath)
        $manifest.controls.otel = 'positive-otel-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($otelPath,$manifest.controls.otel,[Text.UTF8Encoding]::new($false))
        $manifest.captures.otel=@($otelPath)
        $manifest.controls.collector=$controlBefore
        $manifest.captures.collector=@($largePath)
        $manifest.captureMetadata=@{}
        $tempo=New-TestTempoSegmentCapture $privateRoot $manifest.controls.tempo $manifest
        $manifest.captures.tempo=@($tempo.segments | ForEach-Object path)
        $manifest.captureMetadata.tempo=$tempo
        $manifest.additionalSources=@()
        foreach ($channel in @('loki','victoriametrics')) {
            $control=if ($channel -eq 'victoriametrics') { 'geordi.security.authentication.attempts' } else { 'positive-' + $channel + '-' + [guid]::NewGuid().ToString('N') }
            $path=Join-Path $privateRoot ($channel + '.json')
            if ($channel -eq 'loki') {
                $persistedCapture = ConvertTo-Json -InputObject @{status='success';data=@{result=@(@{line=$control})}} -Depth 6 -Compress
            } else {
                $persistedCapture = ConvertTo-Json -InputObject @{metric=@{ '__name__'='geordi.security.authentication.attempts' };values=@('1');timestamps=@(1700000000000)} -Depth 6 -Compress
            }
            [IO.File]::WriteAllText($path,$persistedCapture,[Text.UTF8Encoding]::new($false))
            $manifest.additionalSources += @{channel=$channel;control=$control;captures=@($path)}
        }

        $refreshMetadata = {
            param([string] $Channel)
            Update-TestCaptureMetadata $manifest $Channel
        }
        & $refreshMetadata 'backend'
        & $refreshMetadata 'otel'
        & $refreshMetadata 'collector'

        $raw=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $encoded=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$raw.Add($sentinel)
        [void]$encoded.Add([Uri]::EscapeDataString($sentinel))
        [void]$encoded.Add([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel)))
        [void]$encoded.Add([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel)).TrimEnd('=').Replace('+','-').Replace('/','_'))
        $jsonSentinel=ConvertTo-Json -InputObject $sentinel -Compress
        [void]$encoded.Add($jsonSentinel.Substring(1,$jsonSentinel.Length-2))

        $clean=@(Test-PrivateCaptures $manifest)
        Assert-PrivateScanClean $clean
        $collectorResult=@($clean | Where-Object Channel -eq 'collector')[0]
        $backendResult=@($clean | Where-Object Channel -eq 'backend')[0]
        if ((Get-Item -LiteralPath $largePath).Length -le 64MB -or !$collectorResult.PositiveControl -or
                !$backendResult.PositiveControl -or $manifest.captureMetadata.backend.logicalByteCount -le 64MB) {
            throw 'Large clean backend/collector capture or positive control was not accepted.'
        }
        Write-Output 'large_capture_case=clean_backend_and_collector_over_64MiB result=PASS'

        $backendMutationOffset=[long](64MB + 2048)
        & $writeAt $largePath $backendMutationOffset $sentinel
        & $refreshMetadata 'backend'
        $backendLeak=Test-StreamedCaptureChannel $manifest 'backend' $backendControl $raw $encoded
        if ($backendLeak.RawMatches -eq 0) { throw 'Backend capture missed a raw credential after 64 MiB.' }
        Write-Output 'large_capture_case=backend_raw_credential_after_64MiB result=PASS'
        & $writeAt $largePath $backendMutationOffset ([string]::new([char]0,512))
        & $refreshMetadata 'backend'

        $manifest.controls.collector=$controlAfter
        & $refreshMetadata 'collector'
        $afterResult=Test-StreamedCaptureChannel $manifest 'collector' $controlAfter $raw $encoded
        if (!$afterResult.PositiveControl) { throw 'After-64-MiB positive control was not found.' }
        Write-Output 'large_capture_case=positive_after_64MiB result=PASS'
        $manifest.controls.collector=$controlBefore

        $mutationOffset=[long](64MB + 2048)
        $resetMutation={ & $writeAt $largePath $mutationOffset ([string]::new([char]0,512)) }
        $expectLeak={
            param([string] $Label)
            & $refreshMetadata 'collector'
            $result=Test-StreamedCaptureChannel $manifest 'collector' $controlBefore $raw $encoded
            if (($result.RawMatches + $result.EncodedMatches) -eq 0) { throw "Large capture missed $Label." }
            try { Assert-PrivateScanClean @($result); throw "Large capture accepted $Label." }
            catch { if ($_.Exception.Message -eq "Large capture accepted $Label.") { throw } }
            Write-Output ("large_capture_case={0} result=PASS" -f $Label)
        }
        $encodedCases=@(
            @{label='raw_after_64MiB';value=$sentinel;kind='raw'},
            @{label='url_encoded_after_64MiB';value=[Uri]::EscapeDataString($sentinel);kind='encoded'},
            @{label='json_escaped_after_64MiB';value=$jsonSentinel.Substring(1,$jsonSentinel.Length-2);kind='encoded'},
            @{label='base64_after_64MiB';value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel));kind='encoded'},
            @{label='base64url_after_64MiB';value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel)).TrimEnd('=').Replace('+','-').Replace('/','_');kind='encoded'}
        )
        foreach($case in $encodedCases) {
            & $resetMutation
            & $writeAt $largePath $mutationOffset ([string]$case.value)
            & $expectLeak ([string]$case.label)
        }

        & $resetMutation
        $boundaryOffset=[long](65536 - 3)
        & $writeAt $largePath $boundaryOffset $sentinel
        & $expectLeak 'sentinel_crossing_processing_boundary'

        $validFileList=$manifest.captures.collector
        $validMetadata=$manifest.captureMetadata.collector
        $validOrder=$manifest.captureMetadata.collector.files[0].order
        $manifest.captureMetadata.collector.files[0].order=1
        $reorderedRejected=$false
        try { [void](Test-StreamedCaptureChannel $manifest 'collector' $controlBefore $raw $encoded) } catch { $reorderedRejected=$true }
        if (!$reorderedRejected) { throw 'Reordered capture metadata was accepted.' }
        Write-Output 'large_capture_case=reordered_metadata_rejected result=PASS'
        $manifest.captureMetadata.collector.files[0].order=$validOrder

        $missingPath=Join-Path $privateRoot 'missing-source.log'
        $manifest.captures.collector=@($missingPath)
        $manifest.captureMetadata.collector.files[0].path=[IO.Path]::GetFullPath($missingPath)
        $manifest.captureMetadata.collector.files[0].identity=[IO.Path]::GetFileName($missingPath)
        $missingRejected=$false
        try { [void](Test-StreamedCaptureChannel $manifest 'collector' $controlBefore $raw $encoded) } catch { $missingRejected=$true }
        if (!$missingRejected) { throw 'Missing capture source was accepted.' }
        Write-Output 'large_capture_case=missing_source_rejected result=PASS'
        $manifest.captures.collector=$validFileList
        $manifest.captureMetadata.collector=$validMetadata

        $manifest.captures.collector=@()
        $emptyRejected=$false
        try { [void](Test-StreamedCaptureChannel $manifest 'collector' $controlBefore $raw $encoded) } catch { $emptyRejected=$true }
        if (!$emptyRejected) { throw 'Empty logical capture channel was accepted.' }
        Write-Output 'large_capture_case=empty_channel_rejected result=PASS'
    } finally {
        $resolvedRoot=[IO.Path]::GetFullPath($privateRoot)
        $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::GetDirectoryName($resolvedRoot) -ne $expectedParent -or
                !(Split-Path $resolvedRoot -Leaf).StartsWith('geordi-large-leak-test-')) {
            throw 'Unsafe large-capture self-test cleanup path.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        if (Test-Path -LiteralPath $resolvedRoot) { throw 'Large-capture self-test material remained after cleanup.' }
    }
    Write-Output 'large_capture_case=private_test_cleanup result=PASS'
    return
}

try {
    if (!$ManifestPath) { throw 'Private capture manifest required.' }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($DiagnosticAttemptId) {
        if (!$manifest.attempts -or !$manifest.attempts.ContainsKey($DiagnosticAttemptId)) {
            throw 'Diagnostic Finalize attempt is unavailable.'
        }
        $diagnosticAttempt=$manifest.attempts[$DiagnosticAttemptId]
        if ($diagnosticAttempt.diagnosticOnly -ne $true -or $diagnosticAttempt.status -notin @('running','diagnostic-completed') -or
                !$diagnosticAttempt.channels.controls -or !$diagnosticAttempt.channels.captures -or
                !$diagnosticAttempt.channels.captureMetadata) {
            throw 'Diagnostic Finalize attempt is not complete for scanning.'
        }
        $manifest.controls=$diagnosticAttempt.channels.controls
        $manifest.captures=$diagnosticAttempt.channels.captures
        $manifest.captureMetadata=$diagnosticAttempt.channels.captureMetadata
        $manifest.generationCaptures=$diagnosticAttempt.channels.generationCaptures
        $manifest.captureGenerations=$diagnosticAttempt.channels.captureGenerations
        $manifest.captureHandoffs=$diagnosticAttempt.channels.captureHandoffs
        $manifest.additionalSources=@($diagnosticAttempt.additionalSources)
    }
    $results = @(Test-PrivateCaptures $manifest)
    foreach ($result in $results) {
        $status = if ($result.RawMatches -eq 0 -and $result.EncodedMatches -eq 0) { 'PASS' } else { 'FAIL' }
        Write-Output ('channel={0} positive_control={1} raw_matches={2} encoded_matches={3} result={4}' -f
            $result.Channel, $result.PositiveControl, $result.RawMatches, $result.EncodedMatches, $status)
    }
    Assert-PrivateScanClean $results
} catch {
    # Never forward parser, file, provider or matching-content exceptions to CI.
    throw 'Credential leak validation failed; private captures withheld.'
}
