[CmdletBinding()]
param(
    [ValidateSet('Start', 'Begin', 'Finalize')][string] $Action,
    [switch] $DiagnosticOnly,
    [string] $DiagnosticTempoTraceSetPath,
    [string] $DiagnosticTempoTraceSetSha256,
    [ValidateRange(1,1000000)][int] $DiagnosticTempoTraceCount = 19752,
    [ValidateRange(150,300)][int] $DiagnosticTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiDiagnosticEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureStart.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiTempoEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiLokiEvidence.ps1')
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeRoot = Join-Path $repositoryRoot '.runtime/m19'
$pointerPath = Join-Path (Join-Path $repositoryRoot '.runtime') 'm19-capture-root.txt'
$tokenSentinelPath = $null
$browserSentinelPath = $null
if ($DiagnosticOnly -and $Action -cne 'Finalize') { throw 'Diagnostic mode is available only for Finalize.' }
if ($DiagnosticOnly -and $DiagnosticTimeoutSeconds -ne 300) { throw 'Diagnostic mode requires its separate 300-second ceiling.' }
if (!$DiagnosticOnly -and ($DiagnosticTempoTraceSetPath -or $DiagnosticTempoTraceSetSha256)) {
    throw 'A frozen Tempo trace set is accepted only in diagnostic-only mode.'
}
if ($DiagnosticOnly -and $DiagnosticTempoTraceSetPath -and
        ($DiagnosticTempoTraceSetSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $DiagnosticTempoTraceCount -lt 1)) {
    throw 'Diagnostic frozen Tempo trace-set identity is invalid.'
}

function Write-PrivateJson {
    param([string] $Path, [object] $Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Read-SharedTextFile {
    param([string] $Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Stop-EvidenceProcessTree {
    param([Parameter(Mandatory)][System.Diagnostics.Process] $Process)
    $taskkillPath = Join-Path $env:SystemRoot 'System32/taskkill.exe'
    & $taskkillPath /PID $Process.Id /T /F *> $null
    $taskkillExitCode = $LASTEXITCODE
    Wait-Process -Id $Process.Id -Timeout 5 -ErrorAction SilentlyContinue
    if ((Get-Process -Id $Process.Id -ErrorAction SilentlyContinue) -and $taskkillExitCode -ne 0) {
        throw 'A runtime log follower process tree could not be stopped.'
    }
}

function Stop-GeordiFinalizeAttemptFollowers {
    param([Parameter(Mandatory)][string] $AttemptRoot,[object[]] $StartedProcesses = @())
    foreach ($process in $StartedProcesses) { Stop-GeordiM19TrackedProcess -Process $process }
    if (!(Test-Path -LiteralPath $AttemptRoot -PathType Container)) { return }
    foreach ($processPath in Get-ChildItem -LiteralPath $AttemptRoot -File -Filter '*.process.json' -Recurse) {
        $processInfo = Get-Content -LiteralPath $processPath.FullName -Raw | ConvertFrom-Json
        $captureProcess = Get-Process -Id ([int]$processInfo.id) -ErrorAction SilentlyContinue
        if (!$captureProcess) { continue }
        if ($captureProcess.ProcessName -cne [string]$processInfo.name -or
                $captureProcess.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$processInfo.startUtc).UtcTicks) {
            throw 'Finalize capture process identity changed.'
        }
        Stop-GeordiM19TrackedProcess -Process $captureProcess
    }
}

function Save-GeordiFinalizePhase {
    param(
        [System.Collections.IDictionary] $Manifest,
        [string] $ManifestPath,
        [string] $AttemptId,
        [string] $Phase,
        [hashtable] $Evidence,
        [object[]] $Sources,
        [hashtable] $Details = @{}
    )
    $channelState = @{
        controls = $Evidence.controls
        captures = $Evidence.captures
        captureMetadata = $Evidence.captureMetadata
        generationCaptures = $Evidence.generationCaptures
        captureGenerations = $Evidence.captureGenerations
        captureHandoffs = $Evidence.captureHandoffs
    }
    $null = Set-GeordiM19FinalizeAttemptState -Manifest $Manifest -ManifestPath $ManifestPath `
        -AttemptId $AttemptId -Phase $Phase -Status PASS -Details $Details `
        -ChannelState $channelState -AdditionalSources $Sources
}

function Write-GeordiFinalizeTiming {
    param([string] $Phase,[System.Collections.IDictionary] $Timing)
    Write-Output ("finalize_timing phase={0} phase_elapsed_ms={1} cumulative_elapsed_ms={2} remaining_deadline_ms={3}" -f
        $Phase,$Timing.phaseElapsedMs,$Timing.cumulativeElapsedMs,$Timing.remainingDeadlineMs)
}

function Get-GeordiFinalizeFailureCategory {
    param([Parameter(Mandatory)][System.Exception] $Exception)
    if ($Exception.Message -match 'failure_class=(timeout|transport|size-bound|http-status)') { return $Matches[1] }
    if ($Exception.Message -match '(?i)configured size bound|exceeded its size bound|size bound') { return 'size-bound' }
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Threading.Tasks.TaskCanceledException] -or $current -is [TimeoutException]) { return 'timeout' }
        if ($current -is [Net.Http.HttpRequestException] -or $current -is [Net.Sockets.SocketException]) { return 'transport' }
        if ($current -is [IO.IOException]) { return 'io' }
        $current = $current.InnerException
    }
    return 'validation'
}

function Invoke-WindowsGeordiHttpsRequest {
    param([string] $Uri, [string] $BearerToken, [ValidateRange(1,30)][int] $TimeoutSeconds = 12,
        [ValidateRange(1,30000)][int] $TimeoutMilliseconds = 0)
    if (-not ('GeordiCredentialEvidenceLoopback' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public static class GeordiCredentialEvidenceLoopback {
    public static ValueTask<Stream> Connect(SocketsHttpConnectionContext context, CancellationToken token) {
        if (!String.Equals(context.DnsEndPoint.Host, "geordi.localhost", StringComparison.OrdinalIgnoreCase)
                || context.DnsEndPoint.Port != 8443) throw new InvalidOperationException("Unexpected TLS probe target.");
        return ConnectLoopback(context.DnsEndPoint.Port, token);
    }
    private static async ValueTask<Stream> ConnectLoopback(int port, CancellationToken token) {
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp);
        try { await socket.ConnectAsync(new IPEndPoint(IPAddress.Loopback, port), token).ConfigureAwait(false); return new NetworkStream(socket, true); }
        catch { socket.Dispose(); throw; }
    }
}
'@
    }
    $handler = [Net.Http.SocketsHttpHandler]::new()
    $handler.ConnectCallback = [Func[Net.Http.SocketsHttpConnectionContext,Threading.CancellationToken,Threading.Tasks.ValueTask[IO.Stream]]] [GeordiCredentialEvidenceLoopback]::Connect
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $requestTimeout = if ($TimeoutMilliseconds -gt 0) { [TimeSpan]::FromMilliseconds($TimeoutMilliseconds) } else { [TimeSpan]::FromSeconds($TimeoutSeconds) }
    $cancellation = [Threading.CancellationTokenSource]::new($requestTimeout)
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
        [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $BearerToken")
        $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancellation.Token).GetAwaiter().GetResult()
        try {
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                ContentType = [string]$response.Content.Headers.ContentType
                Content = $response.Content.ReadAsStringAsync($cancellation.Token).GetAwaiter().GetResult()
            }
        } finally { $response.Dispose(); $request.Dispose() }
    } finally { $cancellation.Dispose(); $client.Dispose() }
}

function Add-ControlCapture {
    param([hashtable] $Manifest, [string] $Channel, [string[]] $Paths, [string] $Control,
        [object] $TempoMetadata)
    $captureRootVariable = Get-Variable -Scope Script -Name ActiveCaptureRoot -ErrorAction SilentlyContinue
    $hasRootCaptureManifest = $null -ne $captureRootVariable
    $evidenceManifest = if ($hasRootCaptureManifest) {
        Get-GeordiCaptureGenerationManifest -CaptureRoot ([string]$captureRootVariable.Value)
    } else { $Manifest }
    if ($Channel -in @('nginx-access','backend','otel','collector')) {
        Assert-GeordiM14GenerationEvents -Manifest $evidenceManifest -RequireSealedGenerations
    } else {
        Assert-GeordiM14GenerationEvents -Manifest $evidenceManifest
    }
    if ($hasRootCaptureManifest -and $Channel -in @('nginx-access','backend','otel','collector')) {
        $Paths = @(Get-GeordiCaptureChannelPaths -Manifest $evidenceManifest -Channel $Channel)
        if (!$Paths.Count) { throw 'Required logical generation channel is absent.' }
    }
    if (!$Paths.Count) { throw 'A required runtime capture is missing.' }
    $normalizedPaths=@($Paths | ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
    if (@($normalizedPaths | Select-Object -Unique).Count -ne $normalizedPaths.Count) { throw 'A physical runtime generation was listed more than once in a logical channel.' }
    $captureMetadata = [Collections.Generic.List[object]]::new()
    $parts = [Collections.Generic.List[string]]::new()
    $totalBytes = 0L
    $maximumBytes = Get-GeordiPrivateCaptureLimit $Channel
    $streamedChannel = $Channel -in @('backend','otel','collector')
    $controlFound = $false
    for ($index = 0; $index -lt $Paths.Count; $index++) {
        $path = [string]$Paths[$index]
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            throw 'A required runtime capture is missing or empty.'
        }
        $length = (Get-Item -LiteralPath $path).Length
        if ($Channel -ceq 'tempo') {
            if ($length -le 0 -or $length -gt ($maximumBytes + 16MB)) { throw 'A Tempo segment exceeded its physical size bound.' }
            continue
        }
        if ($length -gt $maximumBytes -or $totalBytes + $length -gt $maximumBytes) { throw 'A required runtime capture exceeded its size bound.' }
        $totalBytes += $length
        if ($streamedChannel) {
            $evidence = Invoke-GeordiPrivateCaptureScan -Path $path -Needles @($Control) -MaximumBytes $maximumBytes
            if (@($evidence.Matches | Where-Object { $_ -ceq $Control }).Count -gt 0) { $controlFound = $true }
            $captureMetadata.Add([ordered]@{
                order = $index
                identity = [IO.Path]::GetFileName($path)
                path = [IO.Path]::GetFullPath($path)
                startOffset = 0L
                endOffsetExclusive = [long]$evidence.ByteCount
                byteCount = [long]$evidence.ByteCount
                sha256 = [string]$evidence.Sha256
            })
        } else {
            $parts.Add((Read-SharedTextFile $path))
        }
    }
    if ($Channel -ceq 'tempo') {
        if (!$TempoMetadata) { throw 'Tempo segment metadata is missing.' }
        if ([string]::IsNullOrWhiteSpace([string]$Manifest.runId) -or
                [string]::IsNullOrWhiteSpace([string]$Manifest.captureStartedUtc)) {
            throw 'Tempo capture run identity or start time is missing.'
        }
        $normalizedTempoMetadata = [ordered]@{
            version = [int]$TempoMetadata.version
            complete = [bool]$TempoMetadata.complete
            completionMarker = [string]$TempoMetadata.completionMarker
            framing = [string]$TempoMetadata.framing
            overlapPolicy = [string]$TempoMetadata.overlapPolicy
            runId = [string]$Manifest.runId
            captureStartedUtc = [string]$Manifest.captureStartedUtc
            captureCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            logicalByteCount = [long]$TempoMetadata.logicalByteCount
            maximumLogicalByteCount = [long]$maximumBytes
            segmentTargetBytes = [long]$TempoMetadata.segmentTargetBytes
            maximumSegmentCount = [int]$TempoMetadata.maximumSegmentCount
            maximumResponseBytes = [long]$TempoMetadata.maximumResponseBytes
            segmentCount = [int]$TempoMetadata.segmentCount
            recordCount = [long]$TempoMetadata.recordCount
            segments = @($TempoMetadata.segments)
        }
        $scan = Test-GeordiTempoSegmentChannel -Paths $Paths -Metadata $normalizedTempoMetadata `
            -Needles @($Control) -Control $Control -MaximumLogicalBytes $maximumBytes `
            -ExpectedRunId ([string]$Manifest.runId) -ExpectedCaptureStartedUtc ([string]$Manifest.captureStartedUtc)
        $normalizedTempoMetadata.positiveControlFound = [bool]$scan.PositiveControl
        $segments = @($normalizedTempoMetadata.segments)
        for ($index=0; $index -lt $segments.Count; $index++) {
            $segment = $segments[$index]
            if ([IO.Path]::GetFullPath([string]$segment.path) -cne [IO.Path]::GetFullPath([string]$Paths[$index])) {
                throw 'Tempo segment ordering changed during capture finalization.'
            }
        }
        if (!$Manifest.captureMetadata) { $Manifest.captureMetadata = @{} }
        $Manifest.captureMetadata[$Channel] = $normalizedTempoMetadata
    } elseif ($streamedChannel) {
        if (!$controlFound) { throw 'A required channel positive control is missing.' }
        if (!$Manifest.captureMetadata) { $Manifest.captureMetadata = @{} }
        $Manifest.captureMetadata[$Channel] = [ordered]@{
            version = 1
            complete = $true
            runId = [string]$Manifest.runId
            captureStartedUtc = ([DateTimeOffset]$Manifest.captureStartedUtc).ToString('o')
            captureCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            logicalByteCount = $totalBytes
            maximumLogicalByteCount = $maximumBytes
            fileCount = $captureMetadata.Count
            overlapPolicy = 'all ordered files retained and scanned independently'
            positiveControlFound = $controlFound
            files = @($captureMetadata.ToArray())
        }
    } else {
        $text = $parts -join "`n"
        if (!$text.Contains($Control, [StringComparison]::Ordinal)) { throw 'A required channel positive control is missing.' }
    }
    $Manifest.controls[$Channel] = $Control
    $Manifest.captures[$Channel] = @($Paths)
}

if ($Action -eq 'Start') {
    if (!(Test-Path -LiteralPath $runtimeRoot -PathType Container)) { throw 'M19 TLS runtime root is missing.' }
    if (Test-Path -LiteralPath $pointerPath) { throw 'An M19 evidence run is already active.' }
    $oldSummary = Join-Path $repositoryRoot 'backend/target/.m19-evidence-gate-summary.txt'
    if (Test-Path -LiteralPath $oldSummary) { Remove-Item -LiteralPath $oldSummary -Force }
    $runId = if ($env:CI_JOB_ID) { $env:CI_JOB_ID } else { [guid]::NewGuid().ToString('N') }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $captureRoot = Join-Path $tempRoot "geordi-m19-capture-$runId-$([guid]::NewGuid().ToString('N'))"
    foreach ($name in @('client-secret','control-secret','auth.password','geordi.password','truststore.password',
            'auth-key.pem','auth-localhost-key.pem','geordi-key.pem')) {
        if (!(Test-Path -LiteralPath (Join-Path $runtimeRoot $name) -PathType Leaf)) {
            throw 'Required ephemeral credential material is missing.'
        }
    }
    [void][IO.Directory]::CreateDirectory($captureRoot)
    $tokenSentinelPath = Join-Path $captureRoot 'runtime-token-sentinels.txt'
    $browserSentinelPath = Join-Path $captureRoot 'browser-secret-sentinels.txt'
    $pointerTemporary = $null
    try {
        [IO.File]::WriteAllText($tokenSentinelPath, '', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($browserSentinelPath, '', [Text.UTF8Encoding]::new($false))
        $rootItem = Get-Item -LiteralPath $captureRoot -Force
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Private capture root must not be a reparse point.' }

        $sentinels = [Collections.Generic.List[string]]::new()
        foreach ($name in @('client-secret','control-secret','auth.password','geordi.password','truststore.password',
                'auth-key.pem','auth-localhost-key.pem','geordi-key.pem')) {
            $path = Join-Path $runtimeRoot $name
            $value = Read-GeordiCaptureStartFile -Path $path -MaximumBytes 1048576
            $value = $value.Trim()
            if ($value.Length -ge 8) { $sentinels.Add($value) }
            if ($name.EndsWith('.pem')) {
                foreach ($match in [regex]::Matches($value, '(?s)-----BEGIN [^-]+-----\s*(.*?)\s*-----END [^-]+-----')) {
                    $encoded = $match.Groups[1].Value -replace '\s', ''
                    if ($encoded.Length -ge 8) { $sentinels.Add($encoded) }
                }
            }
        }
        foreach ($name in @('GEORDI_M13_WEBHOOK_TOKEN_A','GEORDI_M13_WEBHOOK_TOKEN_B')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if ([string]::IsNullOrWhiteSpace($value)) { throw 'Synthetic fixture credentials are unavailable.' }
            $sentinels.Add($value)
        }
        foreach ($value in @('private-code-sentinel','private-state-sentinel')) { $sentinels.Add($value) }
        $probe = 'm19-probe-' + [guid]::NewGuid().ToString('N') + '/+='
        $sentinels.Add($probe)

        $manifest = [ordered]@{
            version = 2
            runId = $runId
            startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            root = $captureRoot
            sentinels = @($sentinels | Select-Object -Unique)
            controls = @{}
            captures = @{}
            captureMetadata = @{}
            additionalSources = @()
            captureGenerations = @{}
            captureHandoffs = @{}
            probe = $probe
        }
        Write-GeordiM19ManifestAtomic -Path (Join-Path $captureRoot 'manifest.json') -Manifest $manifest
        $pointerTemporary = "$pointerPath.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($pointerTemporary,$captureRoot,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($pointerTemporary,$pointerPath)
        Write-Output 'Private M19 evidence root initialized.'
    } catch {
        if (Test-Path -LiteralPath $captureRoot) { Remove-Item -LiteralPath $captureRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($pointerTemporary -and (Test-Path -LiteralPath $pointerTemporary)) { Remove-Item -LiteralPath $pointerTemporary -Force -ErrorAction SilentlyContinue }
        throw 'Private M19 evidence root initialization failed; no credential-channel capture was started.'
    }
    return
}

if (!(Test-Path -LiteralPath $pointerPath -PathType Leaf)) { throw 'Private M19 evidence manifest pointer is missing.' }
$captureRoot = [IO.Path]::GetFullPath((Read-GeordiCaptureStartFile -Path $pointerPath).Trim())
$script:ActiveCaptureRoot = $captureRoot
$expectedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedTemp -or
        (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
    throw 'Private M19 evidence root failed path validation.'
}
$tokenSentinelPath = Join-Path $captureRoot 'runtime-token-sentinels.txt'
$browserSentinelPath = Join-Path $captureRoot 'browser-secret-sentinels.txt'
$manifestPath = Join-Path $captureRoot 'manifest.json'
$manifest = (Read-GeordiCaptureStartFile -Path $manifestPath -MaximumBytes 1048576) | ConvertFrom-Json -AsHashtable
if ($manifest.version -ne 2 -or $manifest.root -cne $captureRoot -or !$manifest.probe) { throw 'Private M19 evidence manifest is malformed.' }

if ($Action -eq 'Begin') {
    if ($manifest.ContainsKey('captureStartedUtc')) { throw 'M19 evidence capture already started.' }
    $beginClock = [Diagnostics.Stopwatch]::StartNew()
    $startedGenerations = [Collections.Generic.List[object]]::new()
    $manifest.captureStartedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-GeordiM19ManifestAtomic -Path $manifestPath -Manifest $manifest
    try {
        foreach ($service in @('frontend','backend','otel-collector','oidc-fixture')) {
            $generationId = Start-GeordiCurrentCaptureGeneration -CaptureRoot $captureRoot -Service $service -RepositoryRoot $repositoryRoot
            $startedGenerations.Add([pscustomobject]@{ Service=$service;GenerationId=$generationId })
        }
        $beginClock.Stop()
        Write-Output ("capture_begin=PASS duration_seconds={0:N2} generations={1} container_id_bound=true" -f
            $beginClock.Elapsed.TotalSeconds,$startedGenerations.Count)
    } catch {
        $cleanupVerified = $true
        foreach ($started in $startedGenerations) {
            try { $null=Seal-GeordiCaptureGeneration -CaptureRoot $captureRoot -Service $started.Service -GenerationId $started.GenerationId }
            catch { $cleanupVerified = $false }
        }
        $beginClock.Stop()
        $cleanupResult = if ($cleanupVerified) { 'PASS' } else { 'FAIL' }
        Write-Output ("capture_begin=FAIL duration_seconds={0:N2} generations_started={1} seal={2}" -f
            $beginClock.Elapsed.TotalSeconds,$startedGenerations.Count,$cleanupResult)
        if (-not $cleanupVerified) { throw 'Private M19 capture start failed and generation sealing could not be confirmed.' }
        throw 'Private M19 log follower startup failed its bounded readiness gate.'
    }
    return
}

$finalizationTimeoutSeconds = if ($DiagnosticOnly) { $DiagnosticTimeoutSeconds } else { 150 }
$finalizationClock = [Diagnostics.Stopwatch]::StartNew()
$finalizationDeadlineMilliseconds = [long]$finalizationTimeoutSeconds * 1000L
if (Test-GeordiM19ManifestCompleted $manifest) { throw 'Completed M19 manifest is immutable.' }
$finalizeLock = Open-GeordiM19FinalizeLock -CaptureRoot $captureRoot
$attemptId = $null
$attemptRoot = $null
$currentPhase = 'attempt-initialization'
try {
    $manifest = (Read-GeordiCaptureStartFile -Path $manifestPath -MaximumBytes 1048576) | ConvertFrom-Json -AsHashtable
    if ($manifest.version -ne 2 -or $manifest.root -cne $captureRoot -or !$manifest.ContainsKey('captureStartedUtc')) {
        throw 'Private M19 runtime capture was not started before credential-bearing activity.'
    }
    if (Test-GeordiM19ManifestCompleted $manifest) { throw 'Completed M19 manifest is immutable.' }
    $validatedAttemptPaths = @{}
    foreach ($validatedAttemptDir in Get-GeordiM19FinalizeAttemptDirectories -CaptureRoot $captureRoot) {
        $validatedAttemptPaths[[IO.Path]::GetFullPath($validatedAttemptDir.FullName)] = $true
    }
    $priorAttemptIds = if ($manifest.ContainsKey('attempts')) { @($manifest.attempts.Keys) } else { @() }
    foreach ($priorId in $priorAttemptIds) {
        $priorAttempt = $manifest.attempts[$priorId]
        if ([string]$priorAttempt.status -notin @('running','failed','cleanup-pending','interrupted')) { continue }
        if ([string]$priorAttempt.attemptId -cne [string]$priorId -or
                [IO.Path]::GetFullPath([string]$priorAttempt.root) -cne
                    [IO.Path]::GetFullPath((Join-Path (Join-Path $captureRoot 'finalize-attempts') ([string]$priorId)))) {
            throw 'Unfinished M19 attempt identity cannot be reconciled safely.'
        }
        if (!$validatedAttemptPaths.ContainsKey([IO.Path]::GetFullPath([string]$priorAttempt.root))) {
            throw 'Unfinished M19 attempt directory is missing from the validated inventory.'
        }
        Assert-GeordiM19FinalizeLaunchRecordsRecoverable -AttemptRoot ([string]$priorAttempt.root)
        Stop-GeordiFinalizeAttemptFollowers -AttemptRoot ([string]$priorAttempt.root)
    }
    Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
    $attemptInfo = New-GeordiM19FinalizeAttempt -CaptureRoot $captureRoot -Manifest $manifest -ManifestPath $manifestPath -DiagnosticOnly:$DiagnosticOnly
    $manifest = $attemptInfo.Manifest
    $attemptId = [string]$attemptInfo.AttemptId
    $attemptRoot = [string]$attemptInfo.Root
    $startedAttemptProcesses = [Collections.Generic.List[System.Diagnostics.Process]]::new()
    $attemptLaunchRecords = [Collections.Generic.List[string]]::new()
    $attemptEvidence = @{
        controls = @{}
        captures = @{}
        captureMetadata = @{}
        generationCaptures = $manifest.generationCaptures
        captureGenerations = $manifest.captureGenerations
        captureHandoffs = $manifest.captureHandoffs
        runId = [string]$manifest.runId
        captureStartedUtc = [string]$manifest.captureStartedUtc
    }
    $attemptSources = @{}
    foreach ($source in @($manifest.additionalSources)) {
        $sourceChannel = [string]$source.channel
        if ([string]::IsNullOrWhiteSpace($sourceChannel) -or $attemptSources.ContainsKey($sourceChannel)) {
            throw 'M19 persisted-source inventory is duplicated or malformed.'
        }
        $attemptSources[$sourceChannel] = [ordered]@{
            channel = $sourceChannel
            control = [string]$source.control
            captures = @($source.captures | ForEach-Object { [string]$_ })
        }
    }
$currentPhase = 'runtime-restore'
$runtimeRestoreClock = [Diagnostics.Stopwatch]::StartNew()
# The M14-M17 history fixture removes its own backend and metrics source. Restore
# this run's M19 services before final live captures and persistence queries.
$restoreTimeoutSeconds=[int][Math]::Max(1,[Math]::Min(90,[Math]::Floor(($finalizationDeadlineMilliseconds-$finalizationClock.Elapsed.TotalMilliseconds)/1000)))
$restoreCommand = @('--file','compose.yaml','--file','compose.m19.yaml','up','-d','--no-deps','--force-recreate','--wait','--wait-timeout',"$restoreTimeoutSeconds")
$captureManifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $captureRoot
$restoreCommands = @(
    [pscustomobject]@{ Service='victoriametrics'; Captured=$false },
    [pscustomobject]@{ Service='otel-collector'; Captured=$true },
    [pscustomobject]@{ Service='backend'; Captured=$true }
)
foreach ($restore in $restoreCommands) {
    if ($restore.Captured) {
        $generationId = Invoke-GeordiFinalizeCaptureRestoration -CaptureRoot $captureRoot -Service $restore.Service `
            -RepositoryRoot $repositoryRoot -Replace {
                $serviceArguments = @($restoreCommand)
                if ($restore.Service -eq 'backend') { $serviceArguments += 'backend' } else { $serviceArguments += 'otel-collector' }
                & docker compose @serviceArguments
                if ($LASTEXITCODE -ne 0) { throw 'M19 captured service restoration failed.' }
            } -GetContainerIdentity ({
                param($service)
                Get-GeordiCurrentCaptureContainerIdentity -Service $service -RepositoryRoot $repositoryRoot
            }.GetNewClosure()) -Reason 'restore-m19-runtime-after-m14'
    } else {
        & docker compose @restoreCommand $restore.Service
        if ($LASTEXITCODE -ne 0) { throw 'M19 VictoriaMetrics restoration failed.' }
    }
}
$captureManifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $captureRoot
foreach ($service in @('frontend','backend','otel-collector','oidc-fixture')) {
    $active = Get-GeordiActiveCaptureGenerationRecord -Manifest $captureManifest -Service $service
}
$manifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $captureRoot
$runtimeRestoreTiming = Get-GeordiFinalizeTimingDetails $finalizationClock $runtimeRestoreClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
$null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
    -Phase 'runtime-restore' -Status PASS -Details @{ services=@('victoriametrics','backend','frontend','otel-collector','oidc-fixture'); timing=$runtimeRestoreTiming }
Write-GeordiFinalizeTiming 'runtime-restore' $runtimeRestoreTiming
$currentPhase = 'sentinel-validation'
if (Test-Path -LiteralPath $tokenSentinelPath -PathType Leaf) {
    if ((Get-Item -LiteralPath $tokenSentinelPath).Length -gt 64MB) { throw 'Private runtime token evidence exceeded its size bound.' }
    $tokens = [IO.File]::ReadAllLines($tokenSentinelPath) | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
    foreach ($token in $tokens) {
        if ($token -notmatch '^eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
            throw 'A recorded runtime token sentinel is malformed.'
        }
        $manifest.sentinels += $token
    }
    if ($tokens.Count -eq 0) { throw 'No runtime bearer token sentinel was recorded.' }
} else {
    throw 'Private runtime bearer token sentinel file is missing.'
}
if (!(Test-Path -LiteralPath $browserSentinelPath -PathType Leaf) -or (Get-Item -LiteralPath $browserSentinelPath).Length -gt 1MB) {
    throw 'Private browser credential sentinel evidence is missing or oversized.'
}
$browserSentinels = [IO.File]::ReadAllLines($browserSentinelPath) | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
foreach ($sentinel in $browserSentinels) {
    if ($sentinel.Length -lt 8 -or $sentinel.Length -gt 16384) { throw 'A private browser credential sentinel is malformed.' }
    $manifest.sentinels += $sentinel
}
$null = Assert-GeordiMinimumBrowserSentinels -Sentinels ([string[]]$browserSentinels)
foreach ($sentinel in @(Get-GeordiDiagnosticSentinelValues -Manifest $manifest)) { $manifest.sentinels += $sentinel }
$uniqueSentinels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$orderedSentinels = [Collections.Generic.List[string]]::new()
foreach ($sentinel in $manifest.sentinels) {
    if ($uniqueSentinels.Add([string]$sentinel)) { $orderedSentinels.Add([string]$sentinel) }
}
$manifest.sentinels = @($orderedSentinels.ToArray())
$null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
    -Phase 'sentinel-validation' -Status PASS -Details @{ sentinelCount=$manifest.sentinels.Count }

# Exercise the live protected endpoint before taking any channel snapshots. The
# unique sentinel is placed only in URL/header credentials, never emitted.
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
$currentPhase = 'problem-control'
$probe = [string]$manifest.probe
$captureManifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $captureRoot
$frontendGeneration = Get-GeordiActiveCaptureGenerationRecord -Manifest $captureManifest -Service 'frontend'
$frontendLog = [string]$frontendGeneration.capturePath
if (!(Test-Path -LiteralPath $frontendLog -PathType Leaf)) { throw 'Nginx access capture is unavailable before the controlled probe.' }
$frontendBeforeProbeBytes = (Get-Item -LiteralPath $frontendLog).Length
$probeUri = 'https://geordi.localhost:8443/api/platform?m19_capture=' + [Uri]::EscapeDataString($probe)
$problemCaptureClock = [Diagnostics.Stopwatch]::StartNew()
try {
    $problemTimeout=Get-GeordiFinalizeRequestTimeoutMilliseconds $finalizationClock $finalizationDeadlineMilliseconds 12000
    $problem = Invoke-WindowsGeordiHttpsRequest -Uri $probeUri -BearerToken $probe -TimeoutMilliseconds $problemTimeout
} catch { throw 'RFC 9457 credential-capture request failed.' }
$contentType = [string]$problem.ContentType
$problemFile = Join-Path $attemptRoot 'problem-response.json'
if ($problem.StatusCode -ne 401 -or $contentType -notmatch 'application/problem\+json') {
    throw 'Required RFC 9457 problem response positive control is unavailable.'
}
$problemContent = ConvertTo-Json -InputObject @{
    status = [int]$problem.StatusCode; contentType = $contentType; body = [string]$problem.Content
} -Compress
Write-GeordiM19AttemptFile -Path $problemFile -Content $problemContent
Add-ControlCapture $attemptEvidence 'problems' @($problemFile) 'application/problem+json'
$currentPhase = 'problem-control'
$problemCaptureTiming = Get-GeordiFinalizeTimingDetails $finalizationClock $problemCaptureClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ status=401; mediaType='application/problem+json'; timing=$problemCaptureTiming }
Write-GeordiFinalizeTiming 'problem-capture' $problemCaptureTiming
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
Start-Sleep -Seconds 3
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds

$browserLog = Join-Path $captureRoot 'browser-e2e.log'
$currentPhase = 'browser-channel'
if (!(Test-Path -LiteralPath $browserLog -PathType Leaf)) { throw 'Browser E2E capture is missing.' }
Add-ControlCapture $attemptEvidence 'browser' @($browserLog) 'M19_BROWSER_RUNTIME_CAPTURE'
$currentPhase = 'browser-channel'
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ status='PASS' }
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds

$finalLiveCaptureClock = [Diagnostics.Stopwatch]::StartNew()
$currentPhase = 'runtime-channel-capture'
Start-Sleep -Seconds 3
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
$captureManifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $captureRoot
foreach ($service in @('frontend','backend','otel-collector','oidc-fixture')) {
    $active = Get-GeordiActiveCaptureGenerationRecord -Manifest $captureManifest -Service $service
    $null = Seal-GeordiCaptureGeneration -CaptureRoot $captureRoot -Service $service -GenerationId ([string]$active.generationId)
}
$manifest = Get-GeordiCaptureGenerationManifest -CaptureRoot $captureRoot
Assert-GeordiCaptureHandoffCoverage -Manifest $manifest
Set-GeordiFinalizeGenerationEvidenceState -Evidence $attemptEvidence -Manifest $manifest
$frontendCaptures = @(Get-GeordiCaptureGenerationPaths -Manifest $manifest -Service 'frontend')
$backendCaptures = @(Get-GeordiCaptureGenerationPaths -Manifest $manifest -Service 'backend')
$collectorCaptures = @(Get-GeordiCaptureGenerationPaths -Manifest $manifest -Service 'otel-collector')
$oidcFixtureCaptures = @(Get-GeordiCaptureGenerationPaths -Manifest $manifest -Service 'oidc-fixture')
foreach ($path in @($frontendCaptures + $backendCaptures + $collectorCaptures)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'A required sealed generation capture is missing.'
    }
}
$currentPhase = 'channel-nginx-access'
Add-ControlCapture $attemptEvidence 'nginx-access' $frontendCaptures '"event":"http"'
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ fileCount=$frontendCaptures.Count }
$currentPhase = 'channel-backend'
Add-ControlCapture $attemptEvidence 'backend' $backendCaptures 'Started GeordiApplication'
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ fileCount=$backendCaptures.Count }
$currentPhase = 'channel-otel'
Add-ControlCapture $attemptEvidence 'otel' $collectorCaptures '"resource spans":'
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ fileCount=$collectorCaptures.Count }
$currentPhase = 'channel-collector'
Add-ControlCapture $attemptEvidence 'collector' $collectorCaptures '"resource metrics":'
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ fileCount=$collectorCaptures.Count }

# Nginx parser diagnostics can contain a raw request line before location routing.
# The supported M19 configuration disables that sink. Record a bounded equivalent
# only after confirming the live config and that request logs omit the probe value.
$currentPhase = 'channel-nginx-error'
$nginxConfig = & docker exec geordi-frontend-1 nginx -T 2>&1
if ($LASTEXITCODE -ne 0 -or ($nginxConfig -join "`n") -notmatch '(?m)^error_log /dev/null;') {
    throw 'Nginx error-channel suppression could not be verified.'
}
$nginxEvidence = Join-Path $attemptRoot 'nginx-error-suppression.txt'
$frontendText = Read-SharedTextFile $frontendLog
if ($frontendText.Contains([string]$manifest.probe, [StringComparison]::Ordinal)) {
    throw 'Credential material detected in the bounded nginx diagnostic channel.'
}
if ((Get-Item -LiteralPath $frontendLog).Length -le $frontendBeforeProbeBytes -or
        !$frontendText.Contains('"status":401', [StringComparison]::Ordinal)) {
    throw 'The controlled invalid-credential request was not observed at nginx ingress.'
}
Write-GeordiM19AttemptFile -Path $nginxEvidence -Content "nginx_error_channel=disabled`nprobe_request_observed=true`n"
$currentPhase = 'channel-nginx-error'
Add-ControlCapture $attemptEvidence 'nginx-error' @($nginxEvidence) 'nginx_error_channel=disabled'
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ configVerified=$true; probeObserved=$true }
$finalLiveCaptureTiming = Get-GeordiFinalizeTimingDetails $finalizationClock $finalLiveCaptureClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
$null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
    -Phase 'final-live-captures' -Status PASS -Details @{ channels=@('browser','nginx-access','nginx-error','backend','otel','collector'); timing=$finalLiveCaptureTiming } `
    -ChannelState @{controls=$attemptEvidence.controls;captures=$attemptEvidence.captures;captureMetadata=$attemptEvidence.captureMetadata;generationCaptures=$attemptEvidence.generationCaptures} `
    -AdditionalSources @($attemptSources.Values)
Write-GeordiFinalizeTiming 'final-live-captures' $finalLiveCaptureTiming
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds

$timeStart = [DateTimeOffset]$manifest.captureStartedUtc
$timeEnd = [DateTimeOffset]::UtcNow
$startNs = [string](($timeStart.UtcDateTime.Ticks - [DateTime]::UnixEpoch.Ticks) * 100L)
$endNs = [string]($timeEnd.ToUnixTimeMilliseconds() * 1000000L)

$tempoSegmentRoot = Join-Path $attemptRoot 'tempo-segments'
$tempoSearchTiming = $null
$tempoDetailTiming = $null
$tempoSearchCount = 0
$tempoSearchBytes = 0L
$tempoTraceCount = 0
$tempoBytes = 0L
$currentPhase = 'tempo-search'
$tempoPhaseState=@{ Name='tempo-search' }
try { $tempoAcquisition = Invoke-GeordiTempoAcquisition -Operation {
    param($tempoClient)
    $tempoSearchClock = [Diagnostics.Stopwatch]::StartNew()
    $tempoSearchIntervals = [Collections.Generic.Queue[object]]::new()
    $tempoSearchIntervals.Enqueue([pscustomobject]@{ Start=$timeStart.ToUnixTimeSeconds(); End=$timeEnd.ToUnixTimeSeconds() })
    $tempoTraces = [Collections.Generic.List[object]]::new()
    $tempoTraceKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $localSearchCount = 0
    $localSearchBytes = 0L
    while ($tempoSearchIntervals.Count -gt 0) {
        $remainingMilliseconds = Get-GeordiFinalizeRequestTimeoutMilliseconds $finalizationClock $finalizationDeadlineMilliseconds 12000
        $interval = $tempoSearchIntervals.Dequeue()
        $localSearchCount++
        if ($localSearchCount -gt 256) { throw 'Tempo search exceeded its bounded interval count.' }
        $tempoUri = 'http://127.0.0.1:3200/api/search?tags=' + [Uri]::EscapeDataString('service.name=geordi-backend') +
            '&start=' + [Uri]::EscapeDataString([string]$interval.Start) +
            '&end=' + [Uri]::EscapeDataString([string]$interval.End) + '&limit=5000'
        $searchTimeoutMilliseconds = $remainingMilliseconds
        $tempoResponse = Invoke-EvidenceRequest $tempoUri -TimeoutMilliseconds $searchTimeoutMilliseconds -Client $tempoClient
        if ($tempoResponse.StatusCode -ne 200) { throw 'Tempo persisted-source query was not successful.' }
        $localSearchBytes += [Text.Encoding]::UTF8.GetByteCount([string]$tempoResponse.Content)
        $tempoPayload = $tempoResponse.Content | ConvertFrom-Json
        $intervalTraces = @($tempoPayload.traces)
        if ($intervalTraces.Count -ge 5000) {
            if ($interval.End - $interval.Start -le 1) { throw 'Tempo interval remained saturated at its completeness limit.' }
            $midpoint = [long][Math]::Floor(($interval.Start + $interval.End) / 2)
            $tempoSearchIntervals.Enqueue([pscustomobject]@{ Start=$interval.Start; End=$midpoint })
            $tempoSearchIntervals.Enqueue([pscustomobject]@{ Start=$midpoint; End=$interval.End })
            continue
        }
        foreach ($trace in $intervalTraces) {
            $traceIdKey = [string]$trace.traceID
            if ($traceIdKey -match '^[A-Fa-f0-9]{29,32}$') { $traceIdKey = $traceIdKey.PadLeft(32, '0') }
            $traceKey = $traceIdKey + '|' + [string]$trace.startTimeUnixNano
            if ($tempoTraceKeys.Add($traceKey)) { $tempoTraces.Add($trace) }
        }
    }
    if ($tempoTraces.Count -eq 0) { throw 'Tempo persisted-source query returned no traces.' }
    $tempoSearchClock.Stop()
    $searchTiming = Get-GeordiFinalizeTimingDetails $finalizationClock $tempoSearchClock $finalizationDeadlineMilliseconds
    Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
    $null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
        -Phase 'tempo-search' -Status PASS -Details @{ intervals=$localSearchCount; traces=$tempoTraces.Count; responseBytes=$localSearchBytes; timing=$searchTiming }

    $tempoPhaseState.Name='tempo-detail'
    $detailTraces = @($tempoTraces.ToArray())
    $frozenSetSummary = $null
    if ($DiagnosticOnly -and $DiagnosticTempoTraceSetPath) {
        try {
            $frozenPath=[IO.Path]::GetFullPath($DiagnosticTempoTraceSetPath)
            if (!(Test-Path -LiteralPath $frozenPath -PathType Leaf) -or (Get-Item -LiteralPath $frozenPath).Length -gt 4MB) {
                throw 'invalid file'
            }
            $frozenHash=(Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $frozenIds=[IO.File]::ReadAllLines($frozenPath)
            $frozenUnique=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($frozenId in $frozenIds) {
                $id=[string]$frozenId.Trim()
                if($id -notmatch '^[A-Fa-f0-9]{29,32}$' -or !$frozenUnique.Add($id)) { throw 'invalid records' }
            }
            if($frozenHash -cne $DiagnosticTempoTraceSetSha256.ToLowerInvariant() -or
                    $frozenIds.Count -ne $DiagnosticTempoTraceCount -or $frozenUnique.Count -ne $DiagnosticTempoTraceCount) {
                throw 'identity mismatch'
            }
            $detailTraces=@($frozenIds | ForEach-Object { [pscustomobject]@{traceID=$_.Trim();startTimeUnixNano=$startNs} })
            $frozenSetSummary = [pscustomobject]@{ Count=$frozenUnique.Count; Sha256=$frozenHash }
        } catch { throw 'Diagnostic Tempo trace-set identity could not be verified.' }
    }
    if ($detailTraces.Count -eq 0) { throw 'Tempo has no current-run backend traces.' }
    $writer=[GeordiTempoSegmentWriter]::new($tempoSegmentRoot,33554432L,167772160L,256,67108864L)
    $detailClock=[Diagnostics.Stopwatch]::StartNew()
    $localDetailBytes=0L
    $localDetailCount=0L
    try {
        foreach ($trace in $detailTraces) {
            $timeoutMilliseconds=Get-GeordiFinalizeRequestTimeoutMilliseconds $finalizationClock $finalizationDeadlineMilliseconds 8000
            if (!$DiagnosticOnly -and (!$trace.startTimeUnixNano -or [double]$trace.startTimeUnixNano -lt [double]$startNs)) { continue }
            $traceId=[string]$trace.traceID
            if($traceId -notmatch '^[A-Fa-f0-9]{29,32}$'){throw 'Tempo persisted trace identifier is invalid.'}
            $traceId=$traceId.PadLeft(32,'0')
            $detail=Invoke-GeordiTempoDetailRequest -Client $tempoClient -Uri "http://127.0.0.1:3200/api/traces/$traceId" `
                -Writer $writer -Ordinal ($localDetailCount+1) -TimeoutMilliseconds $timeoutMilliseconds
            $localDetailBytes += [long]$detail.ResponseBytes
            $localDetailCount++
        }
        if($localDetailCount -eq 0){throw 'Tempo has no current-run backend traces.'}
        if ($DiagnosticOnly -and $DiagnosticTempoTraceSetPath) {
            $postRunHash=(Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $postRunCount=@([IO.File]::ReadLines($frozenPath)).Count
            if ($postRunHash -cne $DiagnosticTempoTraceSetSha256.ToLowerInvariant() -or
                    $postRunCount -ne $DiagnosticTempoTraceCount) {
                throw 'Diagnostic Tempo trace-set changed during detail acquisition.'
            }
        }
        $detailClock.Stop()
        $detailTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $detailClock $finalizationDeadlineMilliseconds
        Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
        $null=Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
            -Phase 'tempo-detail' -Status PASS -Details @{ traceCount=$localDetailCount; responseBytes=$localDetailBytes; timing=$detailTiming }
        return [pscustomobject]@{
            Writer=$writer; SearchIntervals=$localSearchCount; SearchBytes=$localSearchBytes
            SearchTraceCount=$tempoTraces.Count; DetailCount=$localDetailCount; DetailBytes=$localDetailBytes
            SearchTiming=$searchTiming; DetailTiming=$detailTiming; FrozenSetSummary=$frozenSetSummary
        }
    } catch {
        $writer.Dispose()
        throw
    }
} } catch { $currentPhase=$tempoPhaseState.Name; throw }
$tempoSearchCount=[int]$tempoAcquisition.SearchIntervals
$tempoSearchBytes=[long]$tempoAcquisition.SearchBytes
$tempoTraceCount=[long]$tempoAcquisition.DetailCount
$tempoBytes=[long]$tempoAcquisition.DetailBytes
$tempoSearchTiming=$tempoAcquisition.SearchTiming
$tempoDetailTiming=$tempoAcquisition.DetailTiming
Write-GeordiFinalizeTiming 'tempo-search' $tempoSearchTiming
Write-GeordiFinalizeTiming 'tempo-detail' $tempoDetailTiming
if ($tempoAcquisition.FrozenSetSummary) {
    Write-Output ("tempo_frozen_trace_set=PASS count={0} sha256={1}" -f
        $tempoAcquisition.FrozenSetSummary.Count,$tempoAcquisition.FrozenSetSummary.Sha256)
}
$currentPhase='tempo-segment-finalization'
$tempoSegmentClock=[Diagnostics.Stopwatch]::StartNew()
try {
    $tempoMetadata=$tempoAcquisition.Writer.Complete()
    $tempoPaths=@($tempoMetadata.segments | ForEach-Object { [string]$_.path })
    Add-ControlCapture $attemptEvidence 'tempo' $tempoPaths 'service.name' $tempoMetadata
} finally { $tempoAcquisition.Writer.Dispose() }
$tempoSegmentTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $tempoSegmentClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
$currentPhase='tempo-segment-finalization'
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{
        traceCount=$tempoTraceCount; logicalBytes=$tempoBytes; segmentCount=$tempoMetadata.segmentCount
        hashesVerified=$true; positiveControlFound=$true; timing=$tempoSegmentTiming
    }
Write-GeordiFinalizeTiming 'tempo-segment-finalization' $tempoSegmentTiming
Write-Output ("finalize_phase=tempo-detail status=PASS traces={0} response_bytes={1} segments={2}" -f
    $tempoTraceCount,$tempoBytes,$tempoMetadata.segmentCount)

$lokiFile = Join-Path $attemptRoot 'loki-query.json'
$lokiSelector = '{service_name="geordi-backend",service_namespace="geordi",deployment_environment_name="development",geordi_telemetry_origin="platform"}'
$currentPhase = 'loki'
$lokiPhaseClock = [Diagnostics.Stopwatch]::StartNew()
$lokiReadyClock = [Diagnostics.Stopwatch]::StartNew()
$lokiReadyTimeout=Get-GeordiFinalizeRequestTimeoutMilliseconds $finalizationClock $finalizationDeadlineMilliseconds 5000
$lokiReady = Invoke-EvidenceRequest 'http://127.0.0.1:3100/ready' -TimeoutMilliseconds $lokiReadyTimeout
$lokiReadyClock.Stop()
Assert-GeordiLokiReadiness -AttemptRoot $attemptRoot -HttpStatus $lokiReady.StatusCode
Write-Output ("loki_readiness=PASS status={0} duration_seconds={1:N2}" -f $lokiReady.StatusCode,$lokiReadyClock.Elapsed.TotalSeconds)
$lokiClock = [Diagnostics.Stopwatch]::StartNew()
$lokiUri = 'http://127.0.0.1:3100/loki/api/v1/query_range?query=' + [Uri]::EscapeDataString($lokiSelector) +
    '&start=' + $startNs + '&end=' + $endNs + '&limit=1000&direction=backward'
try {
    $lokiTimeout=Get-GeordiFinalizeRequestTimeoutMilliseconds $finalizationClock $finalizationDeadlineMilliseconds 10000
    $lokiResponse = Invoke-EvidenceRequest $lokiUri -TimeoutMilliseconds $lokiTimeout `
        -MaximumBytes 64MB -PrivateCapturePath $lokiFile -PrivateCaptureRoot $attemptRoot
    $lokiClock.Stop()
} catch {
    $lokiClock.Stop()
    $failureClass = if ($_.Exception.Message -match 'failure_class=(timeout|transport)') { $Matches[1] } else { 'request' }
    Write-Output ("loki_persisted_query=FAIL failure_class={0} duration_seconds={1:N2} current_run_interval=true" -f $failureClass,$lokiClock.Elapsed.TotalSeconds)
    throw
}
$lokiEvidence = Test-GeordiLokiPersistedResponse -AttemptRoot $attemptRoot -ResponsePath $lokiFile `
    -HttpStatus $lokiResponse.StatusCode -ExpectedByteCount $lokiResponse.ByteCount `
    -ExpectedSha256 $lokiResponse.Sha256 -StartNanoseconds ([long]$startNs) -EndNanoseconds ([long]$endNs) `
    -PositiveControl 'Security decision' -Sentinels ([string[]]@($manifest.sentinels))
$lokiEntryCount = [int]$lokiEvidence.EntryCount
$currentLokiStreamCount = [int]$lokiEvidence.StreamCount
$attemptEvidence.controls['loki'] = 'Security decision'
$attemptEvidence.captures['loki'] = @($lokiFile)
$attemptSources['loki'] = [ordered]@{ channel='loki'; control='Security decision'; captures=@($lokiFile) }
$attemptSourceList = @($attemptSources.Values)
$lokiPhaseTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $lokiPhaseClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase 'loki' `
    -Evidence $attemptEvidence -Sources $attemptSourceList -Details @{ status=200; streams=$currentLokiStreamCount; entries=$lokiEntryCount; `
        responseBytes=$lokiEvidence.ByteCount; responseSha256=$lokiEvidence.Sha256; timing=$lokiPhaseTiming }
Write-GeordiFinalizeTiming 'loki' $lokiPhaseTiming
Write-Output ("loki_persisted_query=PASS status=200 duration_seconds={0:N2} streams={1} entries={2} bytes={3} sha256={4} bound=1000 current_run_interval=true" -f
    $lokiClock.Elapsed.TotalSeconds,$currentLokiStreamCount,$lokiEntryCount,$lokiEvidence.ByteCount,$lokiEvidence.Sha256)

$vmSource = @($manifest.additionalSources | Where-Object { $_.channel -ceq 'victoriametrics' })
if ($vmSource.Count -ne 1) { throw 'VictoriaMetrics generation evidence is missing or duplicated.' }
$currentPhase = 'victoriametrics'
$victoriaPhaseClock = [Diagnostics.Stopwatch]::StartNew()
$victoriaFile = Join-Path $attemptRoot 'victoriametrics-export.jsonl'
. (Join-Path $PSScriptRoot 'lib/GeordiPersistedMetricEvidence.ps1')
$usedVmBytes = if ($manifest.ContainsKey('persistedMetricEvidenceBytes')) { [long]$manifest.persistedMetricEvidenceBytes } else { 0L }
$remainingVmBytes = 67108864L - $usedVmBytes
if ($remainingVmBytes -le 0) { throw 'Current-run persisted metric evidence exceeded its aggregate size bound.' }
$vmTimeout=Get-GeordiFinalizeRequestTimeoutMilliseconds $finalizationClock $finalizationDeadlineMilliseconds 12000
$vmEvidence = Export-GeordiPersistedMetricSamples -StartUtc $timeStart -EndUtc $timeEnd -Path $victoriaFile `
    -MaximumBytes $remainingVmBytes -TimeoutMilliseconds $vmTimeout -PreservePartialOnFailure
if (!$vmEvidence.PositiveControl) {
    throw 'VictoriaMetrics persisted-source positive control is unavailable.'
}
$vmAttemptSource = [ordered]@{
    channel='victoriametrics'
    control=$vmEvidence.PositiveMetricName
    captures=@(@($vmSource[0].captures | ForEach-Object { [string]$_ }) + @($victoriaFile))
}
$attemptSources['victoriametrics'] = $vmAttemptSource
$attemptSources['victoriametrics'] = $vmAttemptSource
$victoriaPhaseTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $victoriaPhaseClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
$null = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
    -Phase 'victoriametrics' -Status PASS -Details @{ series=$vmEvidence.Series; samples=$vmEvidence.Samples; bytes=$vmEvidence.Bytes; aggregateBytes=$usedVmBytes + $vmEvidence.Bytes; timing=$victoriaPhaseTiming } `
    -AdditionalSources @($attemptSources.Values)
Write-GeordiFinalizeTiming 'victoriametrics' $victoriaPhaseTiming
Write-Output ("victoriametrics_persisted_export=PASS series={0} samples={1} bytes={2} aggregate_bytes={3} bound=67108864 current_run_interval=true" -f
    $vmEvidence.Series,$vmEvidence.Samples,$vmEvidence.Bytes,($usedVmBytes + $vmEvidence.Bytes))

$credentialPreparationClock=[Diagnostics.Stopwatch]::StartNew()
$runtimeChannels=@('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo')
foreach($runtimeChannel in $runtimeChannels) {
    if(!$attemptEvidence.captures.ContainsKey($runtimeChannel) -or !$attemptEvidence.controls.ContainsKey($runtimeChannel) -or
            @($attemptEvidence.captures[$runtimeChannel]).Count -eq 0) { throw 'A runtime credential-scan channel is not prepared.' }
}
if(!$attemptEvidence.captureMetadata.ContainsKey('tempo') -or
        !$attemptEvidence.captureMetadata.tempo.positiveControlFound -or !$attemptEvidence.captureMetadata.tempo.complete) {
    throw 'Segmented Tempo credential-scan metadata is incomplete.'
}
$credentialPreparationTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $credentialPreparationClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
$null=Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
    -Phase 'runtime-credential-scan-preparation' -Status PASS -Details @{ channels=$runtimeChannels; timing=$credentialPreparationTiming } `
    -ChannelState @{controls=$attemptEvidence.controls;captures=$attemptEvidence.captures;captureMetadata=$attemptEvidence.captureMetadata} `
    -AdditionalSources @($attemptSources.Values)
Write-GeordiFinalizeTiming 'runtime-credential-scan-preparation' $credentialPreparationTiming

$artifactRoots = @(
    'backend/target/surefire-reports','backend/target/pmd.xml',
    'backend/target/spotbugsXml.xml','backend/target/geordi-backend-0.1.0-SNAPSHOT.jar',
    'backend/target/geordi-backend-0.1.0-SNAPSHOT-security-telemetry.jar',
    'backend/.ci-artifact/application.jar','backend/.ci-artifact/security-telemetry.jar',
    'backend/target/verified-artifact.properties','frontend/dist')
$currentPhase = 'artifact-scan'
$artifactPreparationClock=[Diagnostics.Stopwatch]::StartNew()
$artifactFiles = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($relative in $artifactRoots) {
    $absolute = Join-Path $repositoryRoot $relative
    if (!(Test-Path -LiteralPath $absolute)) { throw 'A required publishable artifact path is missing.' }
    $item = Get-Item -LiteralPath $absolute
    if ($item.PSIsContainer) {
        foreach ($file in Get-ChildItem -LiteralPath $absolute -File -Recurse) { $artifactFiles.Add($file) }
    } elseif ($item -is [IO.FileInfo]) { $artifactFiles.Add($item) }
}
if (Test-Path -LiteralPath (Join-Path $repositoryRoot 'backend/target/failsafe-reports')) {
    $artifactFiles.AddRange([IO.FileInfo[]]@(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'backend/target/failsafe-reports') -File -Recurse))
}
if ($artifactFiles.Count -eq 0) { throw 'Publishable artifact inventory is empty.' }
$archiveEntries = 0
$forbidden = @()
foreach ($file in $artifactFiles) {
    if ($file.FullName -match '(?i)(\.runtime[\\/]m19|oidc-fixture|(^|[\\/])[^\\/]+\.(key|pem|p12|pfx)$)') {
        $forbidden += $file.Name
    }
    if ($file.Extension -in @('.jar','.zip')) {
        try {
            $archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
            try {
                $archiveEntries += $archive.Entries.Count
                foreach ($entry in $archive.Entries) {
                    if ($entry.FullName -match '(?i)(oidc-fixture|\.runtime/m19|(^|/)[^/]+\.(key|pem|p12|pfx)$|io/geordi/test/oidc/)') {
                        $forbidden += $entry.FullName
                    }
                }
            } finally { $archive.Dispose() }
        } catch { throw 'A publishable archive could not be scanned.' }
    }
}
if ($forbidden.Count -gt 0) { throw 'Publishable artifacts include forbidden credential or fixture material.' }
$inventoryFile = Join-Path $attemptRoot 'publishable-artifact-inventory.json'
$artifactEntries = @($artifactFiles | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($repositoryRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\','/')
    [ordered]@{ path=$relative; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$inventory = [ordered]@{ artifactInventory='complete'; fileCount=$artifactFiles.Count;
    archiveCount=@($artifactFiles | Where-Object Extension -in @('.jar','.zip')).Count; archiveEntryCount=$archiveEntries }
$inventory.files = $artifactEntries
Write-PrivateJson $inventoryFile $inventory
$attemptEvidence.controls['ci-artifacts'] = 'artifactInventory'
$attemptEvidence.captures['ci-artifacts'] = @($inventoryFile) + @($artifactFiles | ForEach-Object FullName)
$currentPhase = 'artifact-scan'
$artifactPreparationTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $artifactPreparationClock $finalizationDeadlineMilliseconds
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
Save-GeordiFinalizePhase -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId -Phase $currentPhase `
    -Evidence $attemptEvidence -Sources @($attemptSources.Values) -Details @{ files=$artifactFiles.Count; archives=@($artifactFiles | Where-Object Extension -in @('.jar','.zip')).Count; timing=$artifactPreparationTiming }
Write-GeordiFinalizeTiming 'artifact-inventory-preparation' $artifactPreparationTiming
$credentialScanTiming=$null
if ($DiagnosticOnly) {
    $currentPhase='runtime-credential-scan'
    Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
    $credentialScanClock=[Diagnostics.Stopwatch]::StartNew()
    $scannerOutput=@(& (Join-Path $PSScriptRoot 'Test-GeordiCredentialLeaks.ps1') `
        -ManifestPath $manifestPath -DiagnosticAttemptId $attemptId)
    $expectedScannedChannels=@('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo','ci-artifacts','loki','victoriametrics')
    $reportedScannedChannels=[Collections.Generic.List[string]]::new()
    foreach($scanLine in $scannerOutput) {
        if ([string]$scanLine -notmatch '^channel=([a-z-]+) positive_control=True raw_matches=0 encoded_matches=0 result=PASS$') {
            throw 'Diagnostic runtime credential scanner did not pass safely.'
        }
        $reportedScannedChannels.Add($Matches[1])
    }
    if ($reportedScannedChannels.Count -ne $expectedScannedChannels.Count -or
            @($expectedScannedChannels | Where-Object { $reportedScannedChannels -cnotcontains $_ }).Count -gt 0 -or
            @($reportedScannedChannels | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
        throw 'Diagnostic runtime credential scanner channel inventory was incomplete.'
    }
    $credentialScanTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $credentialScanClock $finalizationDeadlineMilliseconds
    Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
    $manifest=Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
        -Phase 'runtime-credential-scan' -Status PASS -Details @{ channels=$expectedScannedChannels; timing=$credentialScanTiming }
    Write-GeordiFinalizeTiming 'runtime-credential-scan' $credentialScanTiming
    Write-Output 'runtime_credential_scan=PASS channels=11 raw_matches=0 encoded_matches=0'
}
$currentPhase = 'manifest'
$acceptedChannels = @{ controls=$attemptEvidence.controls; captures=$attemptEvidence.captures; captureMetadata=$attemptEvidence.captureMetadata;
    generationCaptures=$attemptEvidence.generationCaptures; captureGenerations=$attemptEvidence.captureGenerations; captureHandoffs=$attemptEvidence.captureHandoffs }
$manifestPublishClock=[Diagnostics.Stopwatch]::StartNew()
$manifestPublishEstimate=Get-GeordiFinalizeTimingDetails $finalizationClock $manifestPublishClock $finalizationDeadlineMilliseconds -KeepRunning
$manifestPublishEstimate.samplePoint='immediately-before-atomic-publication'
$manifestPublishEstimate.elapsedExcludesAtomicPublication=$true
Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds
if ($DiagnosticOnly) {
    $manifest = Complete-GeordiM19DiagnosticAttempt -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
        -ChannelState $acceptedChannels -AdditionalSources @($attemptSources.Values) -Timing $manifestPublishEstimate `
        -BeforePublish ({ Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds }.GetNewClosure())
} else {
    $manifest = Complete-GeordiM19FinalizeAttempt -Manifest $manifest -ManifestPath $manifestPath -AttemptId $attemptId `
        -ChannelState $acceptedChannels -AdditionalSources @($attemptSources.Values) `
        -PersistedMetricEvidenceBytes ($usedVmBytes + $vmEvidence.Bytes) -Timing $manifestPublishEstimate `
        -BeforePublish ({ Assert-GeordiFinalizeDeadline $finalizationClock $finalizationDeadlineMilliseconds }.GetNewClosure())
}
$manifestPublishTiming=Get-GeordiFinalizeTimingDetails $finalizationClock $manifestPublishClock $finalizationDeadlineMilliseconds
Write-GeordiFinalizeTiming 'manifest-publication' $manifestPublishTiming
Write-Output 'manifest_publication_timing_sample=atomic-publisher-return'
if ($DiagnosticOnly) {
    Write-Output 'Private M19 diagnostic evidence finalized; it was not accepted as a production candidate.'
} else {
    Write-Output 'Private M19 runtime evidence finalized; all nine channels and persisted sources have positive controls.'
}
$finalizationClock.Stop()
if ($DiagnosticOnly) {
    Write-Output ("finalize_attempt=$attemptId phase=diagnostic-manifest status=DIAGNOSTIC_ONLY")
} else {
    Write-Output ("finalize_attempt=$attemptId phase=manifest status=PASS")
}
Write-Output ("finalize_total_seconds={0:N2}" -f $finalizationClock.Elapsed.TotalSeconds)
}
catch {
    $failureCategory = Get-GeordiFinalizeFailureCategory -Exception $_.Exception
    $safePhase = if ([string]::IsNullOrWhiteSpace($currentPhase)) { 'unknown' } else { $currentPhase }
    $followersStopped = $true
    $safeLokiPredicate = $null
    if ($attemptRoot) {
        try {
            Stop-GeordiFinalizeAttemptFollowers -AttemptRoot $attemptRoot -StartedProcesses @($startedAttemptProcesses.ToArray())
            foreach ($launchPath in $attemptLaunchRecords) {
                $processRecord = $launchPath -replace '\.launch\.json$','.process.json'
                if (!(Test-Path -LiteralPath $processRecord)) {
                    $stoppedMarker = $launchPath -replace '\.launch\.json$','.stopped.json'
                    Write-GeordiM19AttemptFile -Path $stoppedMarker -Content "stopped=true`n"
                }
            }
        }
        catch { $followersStopped = $false; $failureCategory = 'process-cleanup' }
    }
    if ($attemptId -and !(Test-GeordiM19ManifestCompleted $manifest)) {
        try {
            $state = if ($followersStopped) { 'FAIL' } else { 'CLEANUP_PENDING' }
            $failureDetails=@{}
            if ($safePhase -ceq 'loki' -and $attemptRoot) {
                $validationRecordPath=Join-Path $attemptRoot 'loki-validation.json'
                if (Test-Path -LiteralPath $validationRecordPath -PathType Leaf) {
                    $validationRecord=Get-Content -LiteralPath $validationRecordPath -Raw | ConvertFrom-Json -AsHashtable
                    if ($validationRecord.phase -ceq 'loki' -and
                            (Test-GeordiLokiPredicateId ([string]$validationRecord.predicateId)) -and
                            $validationRecord.failureCategory -ceq 'validation') {
                        $failureDetails.validation=$validationRecord
                        $safeLokiPredicate=[string]$validationRecord.predicateId
                    }
                }
            }
            $manifest = Set-GeordiM19FinalizeAttemptState -Manifest $manifest -ManifestPath $manifestPath `
                -AttemptId $attemptId -Phase $safePhase -Status $state -Details $failureDetails -FailureCategory $failureCategory
        } catch { }
    }
    if ($attemptId) {
        $predicateSuffix=if($safeLokiPredicate){" predicate_id=$safeLokiPredicate"}else{''}
        Write-Output ("finalize_attempt=$attemptId phase=$safePhase status=FAIL category=$failureCategory{0}" -f $predicateSuffix)
    }
    throw 'M19 Finalize stopped at a bounded failed phase.'
}
finally {
    if ($finalizeLock) { $finalizeLock.Dispose() }
}
