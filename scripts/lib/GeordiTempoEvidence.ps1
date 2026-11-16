if (-not ('GeordiTempoSegmentWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public sealed class GeordiTempoSegmentInfo {
    public int order { get; set; }
    public string identity { get; set; }
    public string path { get; set; }
    public long firstRecordOrdinal { get; set; }
    public long lastRecordOrdinal { get; set; }
    public long recordCount { get; set; }
    public long logicalByteCount { get; set; }
    public long byteCount { get; set; }
    public long physicalByteCount { get; set; }
    public string sha256 { get; set; }
    public bool complete { get; set; }
}

public sealed class GeordiTempoChannelInfo {
    public int version { get; set; }
    public bool complete { get; set; }
    public string completionMarker { get; set; }
    public string framing { get; set; }
    public string overlapPolicy { get; set; }
    public long segmentTargetBytes { get; set; }
    public long maximumLogicalByteCount { get; set; }
    public int maximumSegmentCount { get; set; }
    public long maximumResponseBytes { get; set; }
    public int segmentCount { get; set; }
    public long recordCount { get; set; }
    public long logicalByteCount { get; set; }
    public GeordiTempoSegmentInfo[] segments { get; set; }
}

public sealed class GeordiTempoSegmentWriter : IDisposable {
    private readonly string root;
    private readonly long targetBytes;
    private readonly long maximumLogicalBytes;
    private readonly int maximumSegments;
    private readonly long maximumResponseBytes;
    private readonly List<GeordiTempoSegmentInfo> completed = new List<GeordiTempoSegmentInfo>();
    private FileStream current;
    private string currentPath;
    private int currentOrder;
    private long currentFirstOrdinal;
    private long currentLastOrdinal;
    private long currentRecords;
    private long currentLogicalBytes;
    private long expectedOrdinal = 1;
    private long logicalBytes;
    private long recordBytes;
    private long recordOrdinal;
    private long recordHeaderOffset;
    private long recordCount;
    private bool recordOpen;
    private bool completedChannel;
    private bool disposed;

    public GeordiTempoSegmentWriter(string directory, long segmentTargetBytes, long maximumLogicalBytes,
            int maximumSegmentCount, long maximumResponseBytes) {
        if (String.IsNullOrWhiteSpace(directory) || segmentTargetBytes < 1 || maximumLogicalBytes < 1 ||
                maximumSegmentCount < 1 || maximumSegmentCount > 256 || maximumResponseBytes < 1 ||
                maximumResponseBytes > 64L * 1024 * 1024)
            throw new InvalidDataException("Tempo segment writer bounds are invalid.");
        root = Path.GetFullPath(directory);
        targetBytes = segmentTargetBytes;
        this.maximumLogicalBytes = maximumLogicalBytes;
        maximumSegments = maximumSegmentCount;
        this.maximumResponseBytes = maximumResponseBytes;
        Directory.CreateDirectory(root);
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Tempo segment directory must not be redirected.");
        if (Directory.GetFileSystemEntries(root).Length != 0)
            throw new InvalidDataException("Tempo segment directory is not empty.");
    }

    public void BeginRecord(long ordinal) {
        EnsureOpen();
        if (recordOpen || ordinal != expectedOrdinal)
            throw new InvalidDataException("Tempo detail record ordinal is invalid.");
        if (current == null || currentLogicalBytes >= targetBytes) {
            CloseCurrentSegment();
            OpenSegment();
        }
        recordOrdinal = ordinal;
        recordBytes = 0;
        recordHeaderOffset = current.Position;
        byte[] header = new byte[16];
        Buffer.BlockCopy(BitConverter.GetBytes(ordinal), 0, header, 0, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(-1L), 0, header, 8, 8);
        current.Write(header, 0, header.Length);
        recordOpen = true;
    }

    public void WriteRecordBytes(byte[] buffer, int count) {
        EnsureOpen();
        if (!recordOpen || buffer == null || count < 0 || count > buffer.Length)
            throw new InvalidDataException("Tempo detail record write is invalid.");
        if (recordBytes + count > maximumResponseBytes)
            throw new InvalidDataException("Tempo detail response exceeded its configured size bound.");
        if (logicalBytes + recordBytes + count > maximumLogicalBytes)
            throw new InvalidDataException("Tempo logical channel exceeded its configured size bound.");
        current.Write(buffer, 0, count);
        recordBytes += count;
    }

    public void CompleteRecord() {
        EnsureOpen();
        if (!recordOpen || recordBytes <= 0)
            throw new InvalidDataException("Tempo detail record is incomplete.");
        long end = current.Position;
        current.Position = recordHeaderOffset + 8;
        byte[] encodedLength = BitConverter.GetBytes(recordBytes);
        current.Write(encodedLength, 0, encodedLength.Length);
        current.Position = end;
        if (currentRecords == 0) currentFirstOrdinal = recordOrdinal;
        currentLastOrdinal = recordOrdinal;
        currentRecords++;
        currentLogicalBytes += recordBytes;
        logicalBytes += recordBytes;
        recordCount++;
        expectedOrdinal++;
        recordOpen = false;
        recordBytes = 0;
    }

    public GeordiTempoChannelInfo Complete() {
        EnsureOpen();
        if (recordOpen || recordCount == 0)
            throw new InvalidDataException("Tempo logical channel is incomplete or empty.");
        CloseCurrentSegment();
        completedChannel = true;
        return new GeordiTempoChannelInfo {
            version = 2,
            complete = true,
            completionMarker = "COMPLETE",
            framing = "int64-le ordinal, int64-le byte length, response bytes",
            overlapPolicy = "complete framed records scanned in order with matcher overlap across blocks and segments",
            segmentTargetBytes = targetBytes,
            maximumLogicalByteCount = maximumLogicalBytes,
            maximumSegmentCount = maximumSegments,
            maximumResponseBytes = maximumResponseBytes,
            segmentCount = completed.Count,
            recordCount = recordCount,
            logicalByteCount = logicalBytes,
            segments = completed.ToArray()
        };
    }

    private void OpenSegment() {
        if (completed.Count >= maximumSegments)
            throw new InvalidDataException("Tempo logical channel exceeded its segment-count bound.");
        currentOrder = completed.Count;
        currentPath = Path.Combine(root, "tempo-segment-" + (currentOrder + 1).ToString("D4") + ".bin");
        current = new FileStream(currentPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read,
            65536, FileOptions.SequentialScan);
        currentFirstOrdinal = 0;
        currentLastOrdinal = 0;
        currentRecords = 0;
        currentLogicalBytes = 0;
    }

    private void CloseCurrentSegment() {
        if (current == null) return;
        if (currentRecords <= 0)
            throw new InvalidDataException("Tempo logical channel contains an unexpected empty segment.");
        current.Flush(true);
        current.Dispose();
        current = null;
        long physicalBytes = new FileInfo(currentPath).Length;
        string hash;
        using (var stream = new FileStream(currentPath, FileMode.Open, FileAccess.Read, FileShare.Read,
                65536, FileOptions.SequentialScan))
        using (var sha = SHA256.Create()) {
            hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", String.Empty).ToLowerInvariant();
        }
        completed.Add(new GeordiTempoSegmentInfo {
            order = currentOrder,
            identity = Path.GetFileName(currentPath),
            path = Path.GetFullPath(currentPath),
            firstRecordOrdinal = currentFirstOrdinal,
            lastRecordOrdinal = currentLastOrdinal,
            recordCount = currentRecords,
            logicalByteCount = currentLogicalBytes,
            byteCount = physicalBytes,
            physicalByteCount = physicalBytes,
            sha256 = hash,
            complete = true
        });
        currentPath = null;
    }

    private void EnsureOpen() {
        if (disposed || completedChannel) throw new ObjectDisposedException("GeordiTempoSegmentWriter");
    }

    public void Dispose() {
        if (disposed) return;
        disposed = true;
        if (current != null) {
            current.Flush(true);
            current.Dispose();
            current = null;
        }
    }
}

public sealed class GeordiTempoScanResult {
    public long logicalByteCount { get; set; }
    public long recordCount { get; set; }
    public string[] Matches { get; set; }
}

public sealed class GeordiTempoScanAccumulator {
    private readonly HashSet<string> patterns = new HashSet<string>(StringComparer.Ordinal);
    private readonly HashSet<string> matched = new HashSet<string>(StringComparer.Ordinal);
    private readonly Encoding[] encodings = new Encoding[] {
        new UTF8Encoding(false, false), Encoding.Latin1, Encoding.Unicode
    };
    private readonly Decoder[] decoders = new Decoder[3];
    private readonly char[][] charBuffers = new char[3][];
    private readonly string[] tails = new string[3];
    private readonly int largestNeedle;
    public long LogicalByteCount { get; private set; }
    public long RecordCount { get; private set; }

    public GeordiTempoScanAccumulator(string[] needles) {
        if (needles == null || needles.Length == 0) throw new InvalidDataException("Tempo scanner needles are missing.");
        long characters = 0;
        foreach (string needle in needles) {
            if (String.IsNullOrEmpty(needle) || needle.Length > 131072)
                throw new InvalidDataException("Tempo scanner needle is invalid.");
            patterns.Add(needle);
            characters += needle.Length;
        }
        if (patterns.Count > 2048 || characters > 4L * 1024 * 1024)
            throw new InvalidDataException("Tempo scanner needle inventory exceeded its bound.");
        foreach (string needle in patterns) largestNeedle = Math.Max(largestNeedle, needle.Length);
        for (int i = 0; i < encodings.Length; i++) {
            decoders[i] = encodings[i].GetDecoder();
            charBuffers[i] = new char[encodings[i].GetMaxCharCount(65536)];
            tails[i] = String.Empty;
        }
    }

    public void BeginRecord() {
        if (RecordCount > 0) {
            FeedEncoding(0, new byte[] { 10 }, 1);
            FeedEncoding(1, new byte[] { 10 }, 1);
            FeedEncoding(2, new byte[] { 10, 0 }, 2);
        }
    }

    public void Feed(byte[] bytes, int count) {
        if (bytes == null || count < 0 || count > bytes.Length) throw new InvalidDataException("Tempo scanner block is invalid.");
        LogicalByteCount += count;
        for (int i = 0; i < decoders.Length; i++) FeedEncoding(i, bytes, count);
    }

    public void CompleteRecord() { RecordCount++; }

    private void FeedEncoding(int index, byte[] bytes, int count) {
        int chars = decoders[index].GetChars(bytes, 0, count, charBuffers[index], 0, false);
        string decoded = chars == 0 ? String.Empty : new string(charBuffers[index], 0, chars);
        string window = tails[index] + decoded;
        foreach (string needle in patterns) {
            if (!matched.Contains(needle) && window.IndexOf(needle, StringComparison.Ordinal) >= 0) matched.Add(needle);
        }
        int tailLength = Math.Min(Math.Max(0, largestNeedle - 1), window.Length);
        tails[index] = tailLength == 0 ? String.Empty : window.Substring(window.Length - tailLength, tailLength);
    }

    public string[] GetMatches() { return new List<string>(matched).ToArray(); }
}

public static class GeordiTempoSegmentScanner {
    public static GeordiTempoScanResult Scan(string path, long expectedFirstOrdinal, long expectedLastOrdinal,
            long expectedRecordCount, long expectedPhysicalBytes, long expectedLogicalBytes, string expectedSha256,
            long maximumResponseBytes, GeordiTempoScanAccumulator accumulator) {
        if (String.IsNullOrWhiteSpace(path) || expectedFirstOrdinal < 1 || expectedLastOrdinal < expectedFirstOrdinal ||
                expectedRecordCount != expectedLastOrdinal - expectedFirstOrdinal + 1 || expectedPhysicalBytes < 1 ||
                expectedLogicalBytes < 1 || accumulator == null || !IsSha256(expectedSha256))
            throw new InvalidDataException("Tempo segment metadata is invalid.");
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                65536, FileOptions.SequentialScan)) {
            long initialLength = stream.Length;
            if (initialLength != expectedPhysicalBytes) throw new InvalidDataException("Tempo segment byte count changed.");
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
                byte[] header = new byte[16];
                byte[] buffer = new byte[65536];
                long physical = 0;
                long logical = 0;
                long records = 0;
                long ordinalExpected = expectedFirstOrdinal;
                while (stream.Position < initialLength) {
                    ReadExactly(stream, header, 0, header.Length);
                    hash.AppendData(header);
                    physical += header.Length;
                    long ordinal = BitConverter.ToInt64(header, 0);
                    long length = BitConverter.ToInt64(header, 8);
                    if (ordinal != ordinalExpected || length <= 0 || length > maximumResponseBytes ||
                            logical + length > expectedLogicalBytes)
                        throw new InvalidDataException("Tempo segment record framing is invalid.");
                    accumulator.BeginRecord();
                    long remaining = length;
                    while (remaining > 0) {
                        int requested = (int)Math.Min(buffer.Length, remaining);
                        int read = stream.Read(buffer, 0, requested);
                        if (read <= 0) throw new InvalidDataException("Tempo segment contains an incomplete record.");
                        hash.AppendData(buffer, 0, read);
                        accumulator.Feed(buffer, read);
                        remaining -= read;
                        logical += read;
                        physical += read;
                    }
                    accumulator.CompleteRecord();
                    records++;
                    ordinalExpected++;
                }
                string actualSha = BitConverter.ToString(hash.GetHashAndReset()).Replace("-", String.Empty).ToLowerInvariant();
                if (stream.Position != initialLength || physical != expectedPhysicalBytes || logical != expectedLogicalBytes ||
                        records != expectedRecordCount || ordinalExpected - 1 != expectedLastOrdinal ||
                        stream.Length != initialLength || !String.Equals(actualSha, expectedSha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Tempo segment integrity verification failed.");
                return new GeordiTempoScanResult { logicalByteCount = logical, recordCount = records, Matches = accumulator.GetMatches() };
            }
        }
    }

    private static void ReadExactly(Stream stream, byte[] buffer, int offset, int count) {
        int readTotal = 0;
        while (readTotal < count) {
            int read = stream.Read(buffer, offset + readTotal, count - readTotal);
            if (read <= 0) throw new InvalidDataException("Tempo segment contains incomplete framing.");
            readTotal += read;
        }
    }

    private static bool IsSha256(string value) {
        if (value == null || value.Length != 64) return false;
        foreach (char c in value) if (!Uri.IsHexDigit(c)) return false;
        return true;
    }
}
'@
}

function New-GeordiTempoHttpClient {
    [CmdletBinding()]
    param([Net.Http.HttpMessageHandler] $Handler)
    if (!$Handler) {
        $Handler = [Net.Http.HttpClientHandler]::new()
        $Handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor
            [Net.DecompressionMethods]::Deflate -bor [Net.DecompressionMethods]::Brotli
    }
    $client = [Net.Http.HttpClient]::new($Handler,$true)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    return $client
}

function Invoke-GeordiTempoAcquisition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Operation,
        [Net.Http.HttpMessageHandler] $Handler
    )
    $client = New-GeordiTempoHttpClient -Handler $Handler
    try { return & $Operation $client }
    finally { $client.Dispose() }
}

function Invoke-EvidenceRequest {
    param([string] $Uri, [ValidateRange(1,30)][int] $TimeoutSeconds = 12,
        [ValidateRange(1,67108864)][long] $MaximumBytes = 64MB,
        [Net.Http.HttpClient] $Client,
        [ValidateRange(0,30000)][int] $TimeoutMilliseconds = 0,
        [string] $PrivateCapturePath,
        [string] $PrivateCaptureRoot)
    if ([bool]$PrivateCapturePath -ne [bool]$PrivateCaptureRoot) {
        throw 'Private persisted-source capture requires both an attempt root and target path.'
    }
    $ownsClient = $false
    if (!$Client) {
        $Client = New-GeordiTempoHttpClient
        $ownsClient = $true
    }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
    $response = $null
    $body = $null
    $memory = $null
    $stream = $null
    $privateCapture = $null
    $requestTimeout = if ($TimeoutMilliseconds -gt 0) { [TimeSpan]::FromMilliseconds($TimeoutMilliseconds) } else { [TimeSpan]::FromSeconds($TimeoutSeconds) }
    $cancellation = [Threading.CancellationTokenSource]::new($requestTimeout)
    try {
        $response = $Client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancellation.Token).GetAwaiter().GetResult()
        if (!$PrivateCapturePath -and $response.Content.Headers.ContentLength -gt $MaximumBytes) {
            throw 'Persisted-source response exceeded its configured size bound.'
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        if ($PrivateCapturePath) {
            $privateCapture=Write-GeordiLokiResponseBody -InputStream $stream -Path $PrivateCapturePath `
                -AttemptRoot $PrivateCaptureRoot -MaximumBytes $MaximumBytes -CancellationToken $cancellation.Token
            return [pscustomobject]@{ StatusCode=[int]$response.StatusCode; Content=$null;
                ByteCount=[long]$privateCapture.ByteCount; Sha256=[string]$privateCapture.Sha256;
                PersistedPath=[string]$privateCapture.Path }
        }
        $memory = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(65536)
        while (($read = $stream.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($memory.Length + $read -gt $MaximumBytes) { throw 'Persisted-source response exceeded its configured size bound.' }
            $memory.Write($buffer,0,$read)
        }
        $body = [Text.Encoding]::UTF8.GetString($memory.ToArray())
        return [pscustomobject]@{ StatusCode=[int]$response.StatusCode; Content=$body }
    }
    catch {
        $exception = $_.Exception
        $failureClass = 'transport'
        while ($null -ne $exception) {
            if ($exception -is [TimeoutException] -or $exception -is [Threading.Tasks.TaskCanceledException]) {
                $failureClass = 'timeout'; break
            }
            $exception = $exception.InnerException
        }
        if ($_.Exception.Message -match 'configured size bound') { throw }
        throw "A required persisted-source query could not be verified (failure_class=$failureClass)."
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($memory) { $memory.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        if ($ownsClient) { $Client.Dispose() }
        $cancellation.Dispose()
    }
}

function Get-GeordiTempoFailureClass {
    param([Parameter(Mandatory)][System.Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [TimeoutException] -or $current -is [Threading.Tasks.TaskCanceledException] -or
                $current -is [OperationCanceledException]) { return 'timeout' }
        if ($current -is [Net.Http.HttpRequestException] -or $current -is [Net.Sockets.SocketException]) { return 'transport' }
        if ($current -is [IO.InvalidDataException] -and $current.Message -match 'size bound') { return 'size-bound' }
        $current = $current.InnerException
    }
    return 'transport'
}

function Invoke-GeordiTempoDetailRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][GeordiTempoSegmentWriter] $Writer,
        [Parameter(Mandatory)][long] $Ordinal,
        [ValidateRange(1,30000)][int] $TimeoutMilliseconds = 8000,
        [ValidateRange(1,67108864)][long] $MaximumResponseBytes = 67108864L
    )
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
    $response = $null
    $body = $null
    $cancellation = [Threading.CancellationTokenSource]::new($TimeoutMilliseconds)
    try {
        $response = $Client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancellation.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200) {
            throw 'Tempo detail response status was not successful (failure_class=http-status).'
        }
        if ($response.Content.Headers.ContentLength -gt $MaximumResponseBytes) {
            throw 'Tempo detail response exceeded its configured size bound.'
        }
        $body = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $Writer.BeginRecord($Ordinal)
        $buffer = [byte[]]::new(65536)
        $responseBytes = 0L
        while (($read = $body.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
            $responseBytes += $read
            if ($responseBytes -gt $MaximumResponseBytes) { throw 'Tempo detail response exceeded its configured size bound.' }
            $Writer.WriteRecordBytes($buffer,$read)
        }
        $Writer.CompleteRecord()
        return [pscustomobject]@{ StatusCode=[int]$response.StatusCode; ResponseBytes=$responseBytes; Ordinal=$Ordinal }
    } catch {
        if ($_.Exception.Message -match 'failure_class=http-status') { throw 'Tempo detail request failed (failure_class=http-status).' }
        if ($_.Exception.Message -match '(?i)configured size bound') { throw 'Tempo detail request failed (failure_class=size-bound).' }
        $failureClass = Get-GeordiTempoFailureClass -Exception $_.Exception
        throw "Tempo detail request failed (failure_class=$failureClass)."
    } finally {
        if ($body) { $body.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $cancellation.Dispose()
    }
}

function Test-GeordiTempoSegmentChannel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Paths,
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)][string[]] $Needles,
        [string] $Control = $Needles[0],
        [string] $ExpectedRunId,
        [string] $ExpectedCaptureStartedUtc,
        [ValidateRange(1,167772160)][long] $MaximumLogicalBytes = 167772160L,
        [switch] $AllowTestBounds
    )
    $segments = @($Metadata.segments)
    $maximumSegments = [int]$Metadata.maximumSegmentCount
    if ($Metadata.version -ne 2 -or $Metadata.complete -ne $true -or
            [string]$Metadata.completionMarker -cne 'COMPLETE' -or
            [string]$Metadata.framing -cne 'int64-le ordinal, int64-le byte length, response bytes' -or
            [string]$Metadata.overlapPolicy -cne 'complete framed records scanned in order with matcher overlap across blocks and segments' -or
            $Metadata.maximumLogicalByteCount -ne $MaximumLogicalBytes -or
            $Metadata.segmentTargetBytes -lt 1 -or $Metadata.segmentTargetBytes -gt $MaximumLogicalBytes -or
            $maximumSegments -lt 1 -or $maximumSegments -gt 256 -or
            $Metadata.maximumResponseBytes -lt 1 -or $Metadata.maximumResponseBytes -gt 67108864L -or
            $segments.Count -eq 0 -or $segments.Count -gt $maximumSegments -or
            $Metadata.segmentCount -ne $segments.Count -or $Paths.Count -ne $segments.Count -or
            $Metadata.recordCount -lt 1 -or $Metadata.logicalByteCount -lt 1 -or
            $Metadata.logicalByteCount -gt $MaximumLogicalBytes -or [string]::IsNullOrEmpty($Control)) {
        throw 'Tempo logical-channel metadata is incomplete or malformed.'
    }
    if (!$AllowTestBounds -and ($Metadata.segmentTargetBytes -ne 33554432L -or
            $MaximumLogicalBytes -ne 167772160L -or $maximumSegments -ne 256 -or
            $Metadata.maximumResponseBytes -ne 67108864L)) {
        throw 'Tempo logical-channel sizing differs from the accepted bounds.'
    }
    if ($ExpectedRunId -and [string]$Metadata.runId -cne $ExpectedRunId) {
        throw 'Tempo logical-channel run identity does not match the manifest.'
    }
    if ($ExpectedCaptureStartedUtc) {
        try {
            $metadataStart = [DateTimeOffset]::Parse([string]$Metadata.captureStartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            $manifestStart = [DateTimeOffset]::Parse($ExpectedCaptureStartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            $metadataComplete = [DateTimeOffset]::Parse([string]$Metadata.captureCompletedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        } catch { throw 'Tempo logical-channel capture interval is malformed.' }
        if ($metadataStart.UtcTicks -ne $manifestStart.UtcTicks -or $metadataComplete -le $metadataStart) {
            throw 'Tempo logical-channel capture interval does not match the manifest.'
        }
    }
    $pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $identitySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $accumulator = [GeordiTempoScanAccumulator]::new($Needles)
    $expectedOrdinal = 1L
    $records = 0L
    $logicalBytes = 0L
    for ($index=0; $index -lt $segments.Count; $index++) {
        $entry = $segments[$index]
        $path = [IO.Path]::GetFullPath([string]$Paths[$index])
        if ($entry.order -ne $index -or [string]$entry.path -cne $path -or
                [string]$entry.identity -cne [IO.Path]::GetFileName($path) -or
                !$pathSet.Add($path) -or !$identitySet.Add([string]$entry.identity) -or $entry.complete -ne $true -or
                $entry.firstRecordOrdinal -ne $expectedOrdinal -or
                $entry.lastRecordOrdinal -lt $entry.firstRecordOrdinal -or
                $entry.recordCount -ne ($entry.lastRecordOrdinal - $entry.firstRecordOrdinal + 1) -or
                $entry.byteCount -lt 1 -or $entry.physicalByteCount -ne $entry.byteCount -or
                $entry.logicalByteCount -lt 1 -or [string]$entry.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Tempo segment identity, ordering, ordinal, or completion metadata is invalid.'
        }
        $scan = [GeordiTempoSegmentScanner]::Scan($path,[long]$entry.firstRecordOrdinal,[long]$entry.lastRecordOrdinal,
            [long]$entry.recordCount,[long]$entry.byteCount,[long]$entry.logicalByteCount,[string]$entry.sha256,
            [long]$Metadata.maximumResponseBytes,$accumulator)
        $expectedOrdinal = [long]$entry.lastRecordOrdinal + 1
        $records += $scan.recordCount
        $logicalBytes += $scan.logicalByteCount
        if ($logicalBytes -gt $MaximumLogicalBytes) { throw 'Tempo logical channel exceeded its configured size bound.' }
    }
    if ($records -ne [long]$Metadata.recordCount -or $logicalBytes -ne [long]$Metadata.logicalByteCount -or
            $accumulator.RecordCount -ne $records) {
        throw 'Tempo logical channel record or byte coverage is incomplete.'
    }
    $matches = @($accumulator.GetMatches())
    $controlFound = @($matches | Where-Object { $_ -ceq $Control }).Count -gt 0
    if (!$controlFound) { throw 'Tempo logical channel positive control is missing.' }
    return [pscustomobject]@{ RecordCount=$records; LogicalByteCount=$logicalBytes; Matches=$matches; PositiveControl=$true }
}
