[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to validate bounded Tempo acquisition and segmented evidence.' }
. (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiTempoEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')

if (-not ('GeordiTempoSelfTestHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class GeordiTempoSelfTestHandler : HttpMessageHandler {
    public int Requests { get; private set; }
    public bool WasDisposed { get; private set; }
    public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
    public bool FailTransport { get; set; }
    public int DelayMilliseconds { get; set; }
    public long LargeBodyBytes { get; set; }
    public string Body { get; set; } = "{\"service.name\":\"geordi-backend\"}";
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Requests++;
        if (DelayMilliseconds > 0) await Task.Delay(DelayMilliseconds, token).ConfigureAwait(false);
        if (FailTransport) throw new HttpRequestException("synthetic transport failure");
        HttpContent content = LargeBodyBytes > 0
            ? (HttpContent)new StreamContent(new GeordiTempoSelfTestStream(LargeBodyBytes, 0x78))
            : new StringContent(Body, Encoding.UTF8, "application/json");
        return new HttpResponseMessage(Status) { Content = content };
    }
    protected override void Dispose(bool disposing) { WasDisposed = true; base.Dispose(disposing); }
}

public sealed class GeordiTempoSelfTestStream : System.IO.Stream {
    private long remaining;
    private readonly byte value;
    public GeordiTempoSelfTestStream(long length, byte byteValue) { remaining = length; value = byteValue; }
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) {
        if (remaining <= 0) return 0;
        int take = (int)Math.Min(remaining, count);
        Array.Fill(buffer, value, offset, take);
        remaining -= take;
        return take;
    }
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) {
        token.ThrowIfCancellationRequested();
        if (remaining <= 0) return new ValueTask<int>(0);
        int take = (int)Math.Min(remaining, buffer.Length);
        buffer.Span.Slice(0, take).Fill(value);
        remaining -= take;
        return new ValueTask<int>(take);
    }
    public override void Flush() => throw new NotSupportedException();
    public override long Seek(long offset, System.IO.SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
'@
}

function Assert-GeordiTempoTest {
    param([bool] $Condition, [string] $Message)
    if (!$Condition) { throw "Tempo evidence self-test failed: $Message" }
}

function New-GeordiTempoTestWriter {
    param([string] $Root,[long] $Target,[long] $Maximum,[int] $Segments,[long] $Response = 67108864L)
    return [GeordiTempoSegmentWriter]::new($Root,$Target,$Maximum,$Segments,$Response)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('geordi-tempo-selftest-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    # One client and handler span all serial Tempo requests and both are disposed at
    # the end of the bounded acquisition operation.
    $handler = [GeordiTempoSelfTestHandler]::new()
    $operation = Invoke-GeordiTempoAcquisition -Handler $handler -Operation {
        param($client)
        $clientRefs=[Collections.Generic.List[Net.Http.HttpClient]]::new()
        $clientRefs.Add($client)
        $writerRoot = Join-Path $testRoot 'http-segments'
        $writer = New-GeordiTempoTestWriter $writerRoot 33554432L 167772160L 256
        try {
            $first = Invoke-EvidenceRequest 'http://tempo.test/search' -Client $client -TimeoutSeconds 2
            Assert-GeordiTempoTest ($first.StatusCode -eq 200) 'search uses shared client'
            for ($ordinal=1L; $ordinal -le 3L; $ordinal++) {
                $clientRefs.Add($client)
                $null = Invoke-GeordiTempoDetailRequest -Client $client -Uri "http://tempo.test/traces/$ordinal" `
                    -Writer $writer -Ordinal $ordinal -TimeoutMilliseconds 2000
            }
            $metadata = $writer.Complete()
            return [pscustomobject]@{ client=$client; metadata=$metadata; clientRefs=$clientRefs.ToArray() }
        } finally { $writer.Dispose() }
    }
    Assert-GeordiTempoTest ($handler.Requests -eq 4) 'one request per search/detail, no retries'
    Assert-GeordiTempoTest $handler.WasDisposed 'handler disposed at acquisition end'
    Assert-GeordiTempoTest ($operation.metadata.recordCount -eq 3) 'all detail records were written'
    Assert-GeordiTempoTest (@($operation.clientRefs | Where-Object { ![object]::ReferenceEquals($_,$operation.client) }).Count -eq 0) `
        'one client instance is reused across all serial requests'
    $disposedClientRejected = $false
    try { $null=$operation.client.GetAsync('http://tempo.test/after-dispose').GetAwaiter().GetResult() } catch { $disposedClientRejected=$true }
    Assert-GeordiTempoTest $disposedClientRejected 'client is disposed after acquisition'

    # Complete framed records roll over only between records; metadata is ordered,
    # bounded, and integrity checks reject missing, reordered, altered, or incomplete data.
    $segmentRoot = Join-Path $testRoot 'rollover'
    $writer = New-GeordiTempoTestWriter $segmentRoot 4L 200000L 16 1048576L
    try {
        foreach ($item in @(@{ ordinal=1L; text='prefix' },@{ ordinal=2L; text='suffix' },@{ ordinal=3L; text='service.name=geordi-backend' })) {
            $bytes=[Text.Encoding]::UTF8.GetBytes([string]$item.text)
            $writer.BeginRecord([long]$item.ordinal);$writer.WriteRecordBytes($bytes,$bytes.Length);$writer.CompleteRecord()
        }
        $blockContent=('x' * 65530) + 'block-crossing-sentinel'
        $blockBytes=[Text.Encoding]::UTF8.GetBytes($blockContent)
        $writer.BeginRecord(4L);$writer.WriteRecordBytes($blockBytes,$blockBytes.Length);$writer.CompleteRecord()
        $metadata=$writer.Complete()
    } finally { $writer.Dispose() }
    $captureStart=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    $metadata=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $metadata -Depth 20 -Compress) -AsHashtable
    $metadata.runId='tempo-self-test'
    $metadata.captureStartedUtc=$captureStart
    $metadata.captureCompletedUtc=[DateTimeOffset]::UtcNow.ToString('o')
    Assert-GeordiTempoTest ($metadata.segmentCount -ge 2) '32 MiB rollover policy supports complete-record segment rollover'
    $scan=Test-GeordiTempoSegmentChannel -Paths @($metadata.segments | ForEach-Object path) `
        -Metadata $metadata -Needles @("prefix`nsuffix",'service.name=geordi-backend','block-crossing-sentinel') `
        -Control 'service.name=geordi-backend' -MaximumLogicalBytes 200000L -AllowTestBounds `
        -ExpectedRunId 'tempo-self-test' -ExpectedCaptureStartedUtc $captureStart
    Assert-GeordiTempoTest $scan.PositiveControl 'scanner carries matcher overlap across ordered segment boundaries'
    Assert-GeordiTempoTest (@($scan.Matches | Where-Object { $_ -ceq "prefix`nsuffix" }).Count -eq 1) 'segment-boundary matcher overlap'
    Assert-GeordiTempoTest (@($scan.Matches | Where-Object { $_ -ceq 'block-crossing-sentinel' }).Count -eq 1) 'scanner preserves overlap across a 64 KiB block boundary'
    foreach($identityMutation in @(
        @{label='changed run identity';apply={param($m)$m.runId='historical-run'}},
        @{label='stale capture interval';apply={param($m)$m.captureStartedUtc=[DateTimeOffset]::Parse($captureStart).AddSeconds(-1).ToString('o')}})) {
        $copy=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $metadata -Depth 20 -Compress) -AsHashtable
        & $identityMutation.apply $copy
        $identityRejected=$false
        try { [void](Test-GeordiTempoSegmentChannel -Paths @($copy.segments | ForEach-Object path) -Metadata $copy `
            -Needles @('service.name=geordi-backend') -Control 'service.name=geordi-backend' `
            -MaximumLogicalBytes 200000L -AllowTestBounds -ExpectedRunId 'tempo-self-test' `
            -ExpectedCaptureStartedUtc $captureStart) } catch { $identityRejected=$true }
        Assert-GeordiTempoTest $identityRejected ([string]$identityMutation.label + ' is rejected')
    }

    $partialRoot=Join-Path $testRoot 'incomplete-record'
    $partialWriter=New-GeordiTempoTestWriter $partialRoot 4L 128L 16 64L
    try {
        $partialWriter.BeginRecord(1L);$partialBytes=[Text.Encoding]::UTF8.GetBytes('partial')
        $partialWriter.WriteRecordBytes($partialBytes,$partialBytes.Length)
        $incompleteRejected=$false
        try { [void]$partialWriter.Complete() } catch { $incompleteRejected=$true }
        Assert-GeordiTempoTest $incompleteRejected 'an incomplete framed record cannot complete a channel'
    } finally { $partialWriter.Dispose() }

    $mutations = @(
        @{ label='missing segment'; apply={ param($m) $m.segments=@($m.segments | Select-Object -Skip 1);$m.segmentCount=$m.segments.Count } },
        @{ label='reordered segment'; apply={ param($m) [array]::Reverse($m.segments) } },
        @{ label='missing record ordinal'; apply={ param($m) $m.segments[0].firstRecordOrdinal++ } },
        @{ label='duplicate record ordinal'; apply={ param($m) $m.segments[1].firstRecordOrdinal=$m.segments[0].firstRecordOrdinal } },
        @{ label='changed segment hash'; apply={ param($m) $m.segments[0].sha256=('0'*64) } },
        @{ label='changed byte count'; apply={ param($m) $m.segments[0].byteCount++ } },
        @{ label='incomplete final segment'; apply={ param($m) $m.segments[-1].complete=$false } })
    foreach ($mutation in $mutations) {
        $copy=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $metadata -Depth 20 -Compress) -AsHashtable
        & $mutation.apply $copy
        $rejected=$false
        try { [void](Test-GeordiTempoSegmentChannel -Paths @($copy.segments | ForEach-Object path) -Metadata $copy `
            -Needles @("prefix`nsuffix",'service.name=geordi-backend','block-crossing-sentinel') -Control 'service.name=geordi-backend' `
            -MaximumLogicalBytes 200000L -AllowTestBounds) } catch { $rejected=$true }
        Assert-GeordiTempoTest $rejected ([string]$mutation.label + ' is rejected')
    }
    $duplicate=$metadata.segments + @($metadata.segments[0])
    $duplicateRejected=$false
    try { [void](Test-GeordiTempoSegmentChannel -Paths @($duplicate | ForEach-Object path) -Metadata $metadata `
        -Needles @("prefix`nsuffix",'service.name=geordi-backend','block-crossing-sentinel') -Control 'service.name=geordi-backend' `
        -MaximumLogicalBytes 200000L -AllowTestBounds) } catch { $duplicateRejected=$true }
    Assert-GeordiTempoTest $duplicateRejected 'duplicate segment is rejected'

    # Exercise all supported sentinel encodings after the historic 64 MiB boundary
    # using bounded synthetic streamed data and a segment boundary between records.
    $largeRoot=Join-Path $testRoot 'large-channel'
    $largeSentinel='m19-tempo-' + [guid]::NewGuid().ToString('N') + '/+='
    $largeEncodings=@($largeSentinel,[Uri]::EscapeDataString($largeSentinel),
        (ConvertTo-Json -InputObject $largeSentinel -Compress).Trim('"'),
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($largeSentinel)),
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($largeSentinel)).TrimEnd('=').Replace('+','-').Replace('/','_'))
    $writer=New-GeordiTempoTestWriter $largeRoot 33554432L 167772160L 256
    try {
        $ordinal=0L
        foreach($fillerLength in @(33554432L,33554432L,1000000L)) {
            $ordinal++
            $writer.BeginRecord($ordinal)
            $filler=[GeordiTempoSelfTestStream]::new($fillerLength,0x78)
            try { $before=[byte[]]::new(65536);while(($n=$filler.Read($before,0,$before.Length)) -gt 0){$writer.WriteRecordBytes($before,$n)} }
            finally { $filler.Dispose() }
            $writer.CompleteRecord()
        }
        foreach($encoding in $largeEncodings) {
            $ordinal++
            $writer.BeginRecord($ordinal)
            $middle=([Text.Encoding]::UTF8.GetBytes([string]$encoding))
            $writer.WriteRecordBytes($middle,$middle.Length)
            $writer.CompleteRecord()
        }
        $ordinal++
        $control=[Text.Encoding]::UTF8.GetBytes('service.name=geordi-backend')
        $writer.BeginRecord($ordinal);$writer.WriteRecordBytes($control,$control.Length);$writer.CompleteRecord()
        $largeMetadata=$writer.Complete()
    } finally { $writer.Dispose() }
    Assert-GeordiTempoTest ($largeMetadata.logicalByteCount -gt 64MB -and $largeMetadata.logicalByteCount -lt 160MB) 'complete Tempo channel larger than 64 MiB remains bounded below 160 MiB'
    $largeScan=Test-GeordiTempoSegmentChannel -Paths @($largeMetadata.segments | ForEach-Object path) `
        -Metadata $largeMetadata -Needles (@($largeEncodings) + @('service.name=geordi-backend')) `
        -Control 'service.name=geordi-backend' -MaximumLogicalBytes 167772160L
    $missingEncodingLabels=@('raw','url','json','base64','base64url')
    $missingEncodings=[Collections.Generic.List[string]]::new()
    for($index=0;$index -lt $largeEncodings.Count;$index++){
        if(@($largeScan.Matches | Where-Object { $_ -ceq [string]$largeEncodings[$index] }).Count -eq 0){$missingEncodings.Add($missingEncodingLabels[$index])}
    }
    Assert-GeordiTempoTest ($missingEncodings.Count -eq 0) ('encoded sentinel classes missing=' + ($missingEncodings -join ','))
    Assert-GeordiTempoTest ($largeMetadata.segments.Count -lt 256) 'large Tempo capture stays within segment cap'
    $manifestJson=ConvertTo-Json -InputObject @{captureMetadata=@{tempo=$largeMetadata}} -Depth 20 -Compress
    Assert-GeordiTempoTest ([Text.Encoding]::UTF8.GetByteCount($manifestJson) -lt 1048576) 'serialized segment metadata remains below 1 MiB'

    # Exact 160 MiB acceptance and one-byte-over rejection, with fixed-size streaming
    # sources so the test does not allocate the complete channel in memory.
    $exactRoot=Join-Path $testRoot 'exact-limit'
    $writer=New-GeordiTempoTestWriter $exactRoot 33554432L 167772160L 256 67108864L
    try {
        $ordinal=0L
        foreach($length in @(33554432L,33554432L,33554432L,33554432L,33554432L)) {
            $ordinal++;$source=[GeordiTempoSelfTestStream]::new($length,0x78)
            try { $writer.BeginRecord($ordinal);$buffer=[byte[]]::new(65536);while(($n=$source.Read($buffer,0,$buffer.Length)) -gt 0){$writer.WriteRecordBytes($buffer,$n)};$writer.CompleteRecord() }
            finally { $source.Dispose() }
        }
        $exact=$writer.Complete()
    } finally { $writer.Dispose() }
    Assert-GeordiTempoTest ($exact.logicalByteCount -eq 167772160L) 'exactly-at-limit channel passes'
    Assert-GeordiTempoTest ($exact.segmentCount -eq 5 -and
        @($exact.segments | Where-Object { $_.logicalByteCount -ne 33554432L -or $_.recordCount -ne 1 }).Count -eq 0) `
        '32 MiB target rolls over only after a complete record'

    $overRoot=Join-Path $testRoot 'over-limit'
    $writer=New-GeordiTempoTestWriter $overRoot 33554432L 167772160L 256 67108864L
    try {
        $ordinal=0L
        foreach($length in @(33554432L,33554432L,33554432L,33554432L,33554432L)) {
            $ordinal++;$source=[GeordiTempoSelfTestStream]::new($length,0x78)
            try { $writer.BeginRecord($ordinal);$buffer=[byte[]]::new(65536);while(($n=$source.Read($buffer,0,$buffer.Length)) -gt 0){$writer.WriteRecordBytes($buffer,$n)};$writer.CompleteRecord() }
            finally { $source.Dispose() }
        }
        $writer.BeginRecord(6L);$one=[byte[]]::new(1);$overRejected=$false
        try { $writer.WriteRecordBytes($one,1);$writer.CompleteRecord() } catch { $overRejected=$true }
        Assert-GeordiTempoTest $overRejected 'one byte over 160 MiB fails closed'
    } finally { $writer.Dispose() }

    # The individual 64 MiB HTTP response cap is independent of the larger channel cap.
    $responseRoot=Join-Path $testRoot 'response-limit'
    $handler=[GeordiTempoSelfTestHandler]::new();$handler.LargeBodyBytes=67108865L
    $writer=New-GeordiTempoTestWriter $responseRoot 33554432L 167772160L 256
    try {
        $tooLarge=$false
        try { Invoke-GeordiTempoAcquisition -Handler $handler -Operation {
            param($client)
            Invoke-GeordiTempoDetailRequest -Client $client -Uri 'http://tempo.test/oversized' -Writer $writer `
                -Ordinal 1L -TimeoutMilliseconds 2000
        } | Out-Null } catch { $tooLarge=$_.Exception.Message -match 'failure_class=size-bound' }
        Assert-GeordiTempoTest $tooLarge 'single HTTP response above 64 MiB is rejected'
        Assert-GeordiTempoTest ($handler.Requests -eq 1 -and $handler.WasDisposed) 'oversized HTTP response stops and disposes without retry'
    } finally { $writer.Dispose() }

    $manyRoot=Join-Path $testRoot 'segment-cap'
    $writer=New-GeordiTempoTestWriter $manyRoot 1L 1024L 256 1L
    try {
        $one=[byte[]]::new(1)
        for($ordinal=1L;$ordinal -le 256L;$ordinal++){ $writer.BeginRecord($ordinal);$writer.WriteRecordBytes($one,1);$writer.CompleteRecord() }
        $capMetadata=$writer.Complete()
        Assert-GeordiTempoTest ($capMetadata.segmentCount -eq 256) '256 segments are accepted'
        $capManifest=ConvertTo-Json -InputObject @{captureMetadata=@{tempo=$capMetadata}} -Depth 20 -Compress
        Assert-GeordiTempoTest ([Text.Encoding]::UTF8.GetByteCount($capManifest) -lt 1048576) '256 ordered metadata entries remain under 1 MiB'
        $boundedManifestPath=Join-Path $testRoot 'tempo-bounded-manifest.json'
        $boundedManifest=[ordered]@{version=2;root=$testRoot;runId='tempo-metadata-size-test';
            startedUtc=[DateTimeOffset]::UtcNow.ToString('o');captureMetadata=@{tempo=$capMetadata}}
        Write-GeordiM19ManifestAtomic -Path $boundedManifestPath -Manifest $boundedManifest
        Assert-GeordiTempoTest ((Get-Item -LiteralPath $boundedManifestPath).Length -lt 1048576) `
            'atomic manifest publisher accepts the actual maximum segment metadata under 1 MiB'
    } finally { $writer.Dispose() }
    $tooManyRoot=Join-Path $testRoot 'segment-cap-over'
    $writer=New-GeordiTempoTestWriter $tooManyRoot 1L 1024L 256 1L
    try {
        $one=[byte[]]::new(1)
        for($ordinal=1L;$ordinal -le 256L;$ordinal++){ $writer.BeginRecord($ordinal);$writer.WriteRecordBytes($one,1);$writer.CompleteRecord() }
        $tooMany=$false
        try { $writer.BeginRecord(257L) } catch { $tooMany=$true }
        Assert-GeordiTempoTest $tooMany 'more than 256 segments are rejected'
    } finally { $writer.Dispose() }

    # Request failures stop immediately, do not retry, and expose no raw request data.
    foreach($failure in @('status','partial-content','transport','timeout')) {
        $handler=[GeordiTempoSelfTestHandler]::new()
        if($failure -eq 'status'){$handler.Status=[Net.HttpStatusCode]::ServiceUnavailable}
        if($failure -eq 'partial-content'){$handler.Status=[Net.HttpStatusCode]::PartialContent}
        if($failure -eq 'transport'){$handler.FailTransport=$true}
        if($failure -eq 'timeout'){$handler.DelayMilliseconds=500}
        $failureRoot=Join-Path $testRoot ('failure-' + $failure)
        $writer=New-GeordiTempoTestWriter $failureRoot 33554432L 167772160L 256
        try {
            $failed=$false
            try {
                Invoke-GeordiTempoAcquisition -Handler $handler -Operation {
                    param($client)
                    Invoke-GeordiTempoDetailRequest -Client $client -Uri 'http://tempo.test/private-trace-id' `
                        -Writer $writer -Ordinal 1L -TimeoutMilliseconds $(if($failure -eq 'timeout'){50}else{2000})
                } | Out-Null
            } catch { $failed=$true;Assert-GeordiTempoTest ($_.Exception.Message -notmatch 'private-trace-id|synthetic transport failure') 'failure output is sanitized' }
            Assert-GeordiTempoTest $failed ($failure + ' fails closed')
            Assert-GeordiTempoTest ($handler.Requests -eq 1) ($failure + ' stops without retry')
            Assert-GeordiTempoTest $handler.WasDisposed ($failure + ' disposes its handler')
        } finally { $writer.Dispose() }
    }

    $deadlineClock=[Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 20
    $boundedTimeout=Get-GeordiFinalizeRequestTimeoutMilliseconds $deadlineClock 10000L 8000
    Assert-GeordiTempoTest ($boundedTimeout -le 8000 -and $boundedTimeout -lt 10000) 'request timeout respects monotonic remaining budget'
    $deadlineRejected=$false
    try { Assert-GeordiFinalizeDeadline $deadlineClock 1L } catch { $deadlineRejected=$_.Exception.Message -match 'monotonic deadline' }
    Assert-GeordiTempoTest $deadlineRejected 'deadline exhaustion after completed acquisition fails before publication'

    Write-Output 'Tempo acquisition and segmented evidence self-test passed: client lifecycle, timeout/fail-closed, complete ordered framing, bounded sizes, integrity, cross-boundary scanning, metadata size, and no secret output.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $expected -or !(Split-Path $resolved -Leaf).StartsWith('geordi-tempo-selftest-')) {
        throw 'Unsafe Tempo self-test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
