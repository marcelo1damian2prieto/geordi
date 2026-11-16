[CmdletBinding()]
param([switch] $Live, [switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Live -eq $SelfTest) { throw 'Select exactly one of -Live or -SelfTest.' }
. (Join-Path $PSScriptRoot 'lib/GeordiPrivateEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiLokiEvidence.ps1')

function Invoke-BoundedLokiGet {
    param([Parameter(Mandatory)][string] $Uri,[ValidateRange(1,30000)][int] $TimeoutMilliseconds=10000,
        [ValidateRange(1,67108864)][long] $MaximumBytes=67108864)
    $client=[Net.Http.HttpClient]::new()
    $client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $cancellation=[Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds($TimeoutMilliseconds))
    $request=$null; $response=$null; $output=[IO.MemoryStream]::new(); $input=$null
    try {
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
        $response=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancellation.Token).GetAwaiter().GetResult()
        $input=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer=[byte[]]::new(65536)
        while (($read=$input.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
            if ($output.Length + $read -gt $MaximumBytes) { throw 'Loki persisted-source response exceeded its configured size bound.' }
            $output.Write($buffer,0,$read)
        }
        return [pscustomobject]@{ StatusCode=[int]$response.StatusCode; Content=[Text.Encoding]::UTF8.GetString($output.ToArray()) }
    } catch {
        if ($_.Exception.Message -match 'configured size bound') { throw }
        $exception=$_.Exception; $class='transport'
        while ($null -ne $exception) {
            if ($exception -is [Threading.Tasks.TaskCanceledException] -or $exception -is [TimeoutException]) { $class='timeout'; break }
            $exception=$exception.InnerException
        }
        throw "Loki persisted-source request failed (failure_class=$class)."
    } finally {
        if ($input) { $input.Dispose() }; if ($response) { $response.Dispose() }; if ($request) { $request.Dispose() }
        $output.Dispose(); $cancellation.Dispose(); $client.Dispose()
    }
}

function Get-LokiPersistedControlCount {
    param([Parameter(Mandatory)][string] $Content,[Parameter(Mandatory)][long] $StartNs,
        [Parameter(Mandatory)][long] $EndNs)
    try { $payload=$Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Loki persisted-source response was malformed.' }
    if ([string]$payload.status -cne 'success') { throw 'Loki persisted-source query did not return success.' }
    $entries=0; $control=$false
    foreach ($stream in @($payload.data.result)) {
        foreach ($value in @($stream.values)) {
            $timestamp=[long]$value[0]
            if ($timestamp -lt $StartNs -or $timestamp -gt $EndNs) { continue }
            $entries++
            if ([string]$value[1] -match 'Security decision') { $control=$true }
        }
    }
    if ($entries -ge 1000) { throw 'Loki persisted-source result was saturated.' }
    if (!$control -or $entries -eq 0) { throw 'Loki persisted-source positive control is awaiting ingestion.' }
    return $entries
}

function Assert-LokiPersistedControlCompleted([int] $Entries) {
    if ($Entries -le 0) { throw 'Loki persisted-source positive control did not arrive before the bounded deadline.' }
}

function Get-LokiRequestTimeoutMilliseconds([DateTimeOffset] $Deadline) {
    $remaining=[int][math]::Floor(($Deadline-[DateTimeOffset]::UtcNow).TotalMilliseconds)
    if ($remaining -le 0) { throw 'Loki persisted-source positive control did not arrive before the bounded deadline.' }
    return [math]::Min(10000,$remaining)
}

function Assert-LokiResponseBeforeDeadline([DateTimeOffset] $Deadline) {
    if ([DateTimeOffset]::UtcNow -ge $Deadline) {
        throw 'Loki persisted-source response completed after the bounded deadline.'
    }
}

function New-LokiSelfTestResponse([Collections.Generic.List[object]] $Pairs) {
    $stream=[ordered]@{values=$Pairs.ToArray()}
    $result=[object[]]::new(1); $result[0]=$stream
    return ConvertTo-Json -InputObject ([ordered]@{status='success';data=[ordered]@{result=$result}}) -Compress -Depth 8
}

function Add-LokiSelfTestPair([Collections.Generic.List[object]] $Pairs,[long] $Timestamp,[string] $Line) {
    $pair=[object[]]::new(2); $pair[0]=[string]$Timestamp; $pair[1]=$Line; $Pairs.Add($pair)
}

function New-LokiSelfTestAttempt([string] $Root) {
    $path=Join-Path $Root ('finalize-attempts/' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

if (-not ('GeordiLokiCancellationReadStream' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class GeordiLokiCancellationReadStream : Stream {
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WaitForCancellation(cancellationToken);
    private static async Task<int> WaitForCancellation(CancellationToken token) {
        await Task.Delay(Timeout.Infinite, token).ConfigureAwait(false);
        return 0;
    }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
'@
}

function Invoke-LokiSelfTestValidation {
    param([string] $AttemptRoot,[string] $Content,[string] $ExpectedPredicate,
        [string[]] $Sentinels=@(),[int] $HttpStatus=200,[string] $Mutation='none',
        [long] $Start=1760000000000000000L,[long] $End=1760000001000000000L,
        [long] $ValidationMaximumBytes=1048576L)
    $path=Join-Path $AttemptRoot 'loki-query.json'
    $bytes=[Text.Encoding]::UTF8.GetBytes($Content)
    $input=[IO.MemoryStream]::new($bytes,0,$bytes.Length,$false,$true)
    try { $receipt=Write-GeordiLokiResponseBody -InputStream $input -Path $path -AttemptRoot $AttemptRoot -MaximumBytes 1048576L }
    finally { $input.Dispose() }
    $before=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedBytes=[long]$receipt.ByteCount
    $expectedHash=[string]$receipt.Sha256
    if ($Mutation -eq 'byte-count') { $expectedBytes++ }
    if ($Mutation -eq 'sha256') { $expectedHash=('0'*64) }
    if ($ExpectedPredicate -eq 'loki.response.size') { $ValidationMaximumBytes=1L }
    $failureOutput=$null; $failureType=$null; $result=$null
    try {
        $result=Test-GeordiLokiPersistedResponse -AttemptRoot $AttemptRoot -ResponsePath $path `
            -HttpStatus $HttpStatus -ExpectedByteCount $expectedBytes -ExpectedSha256 $expectedHash `
            -StartNanoseconds $Start -EndNanoseconds $End -PositiveControl 'Security decision' `
            -Sentinels $Sentinels -MaximumBytes $ValidationMaximumBytes
    } catch { $failureOutput=[string]$_.Exception.Message; $failureType=$_.Exception.GetType().FullName }
    $after=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($before -cne $after) { throw 'Loki failed-response evidence changed during validation.' }
    if ($ExpectedPredicate -eq 'PASS') {
        if ($null -ne $failureOutput -or !$result -or !(Test-Path -LiteralPath (Join-Path $AttemptRoot 'loki-query.json'))) {
            throw 'Loki positive validation self-test failed.'
        }
        if ($result.Record.phase -cne 'loki' -or $null -ne $result.Record.failureCategory -or
                $result.Record.parseValid -ne $true -or $result.Record.intervalValid -ne $true -or
                $result.Record.positiveControlPresent -ne $true -or
                !$result.Record.scannedRaw -or !$result.Record.scannedUrlEncoded -or
                !$result.Record.scannedJsonEscaped -or !$result.Record.scannedBase64 -or !$result.Record.scannedBase64Url) {
            throw 'Loki positive validation metadata self-test failed.'
        }
        if (Test-Path -LiteralPath (Join-Path $AttemptRoot 'loki-validation.json')) {
            throw 'Loki successful validation unexpectedly published a failure record.'
        }
    } else {
        if ([string]::IsNullOrEmpty($failureOutput) -or !$failureOutput.Contains($ExpectedPredicate)) {
            $actualPredicate='missing-record'
            $candidateRecordPath=Join-Path $AttemptRoot 'loki-validation.json'
            if(Test-Path -LiteralPath $candidateRecordPath){$actualPredicate=[string](Get-Content -LiteralPath $candidateRecordPath -Raw | ConvertFrom-Json -AsHashtable).predicateId}
            throw "Loki expected predicate did not fail: expected=$ExpectedPredicate actual=$actualPredicate exception_type=$failureType"
        }
        $recordPath=Join-Path $AttemptRoot 'loki-validation.json'
        if (!(Test-Path -LiteralPath $recordPath)) { throw 'Loki sanitized failure record was not persisted.' }
        $record=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable
        $expectedRecordHash=if($ExpectedPredicate -eq 'loki.response.size'){$null}else{$receipt.Sha256}
        if ($record.phase -cne 'loki' -or $record.predicateId -cne $ExpectedPredicate -or
                $record.failureCategory -cne 'validation' -or $record.httpStatus -ne $HttpStatus -or
                $record.responseByteCount -ne $receipt.ByteCount -or $record.responseSha256 -cne $expectedRecordHash) {
            throw 'Loki sanitized validation record metadata did not match the persisted response.'
        }
        if (($ExpectedPredicate -eq 'loki.response.parse' -and $record.parseValid -ne $false) -or
                ($ExpectedPredicate -eq 'loki.response.shape' -and $record.parseValid -ne $true) -or
                ($ExpectedPredicate -eq 'loki.interval.valid' -and $record.intervalValid -ne $false) -or
                ($ExpectedPredicate -eq 'loki.positive_control.present' -and $record.positiveControlPresent -ne $false)) {
            throw 'Loki failure record did not identify evaluated predicate state.'
        }
        if ($ExpectedPredicate -in @('loki.sentinel.raw','loki.sentinel.url','loki.sentinel.json',
                'loki.sentinel.base64','loki.sentinel.base64url') -and
                (!$record.scannedRaw -or !$record.scannedUrlEncoded -or !$record.scannedJsonEscaped -or
                 !$record.scannedBase64 -or !$record.scannedBase64Url)) {
            throw 'Loki sentinel failure record did not record scan completion.'
        }
        if ($record.ContainsKey('responseBody') -or
                (ConvertTo-Json -InputObject $record -Compress) -ceq $Content -or
                (Get-Content -LiteralPath $recordPath -Raw).Contains($Content)) {
            throw 'Loki raw response content entered its validation record.'
        }
        if ($failureOutput.Contains($Content)) { throw 'Loki raw response content reached captured output.' }
        $publicManifest=ConvertTo-Json -InputObject @{attempts=@{test=@{phases=@{loki=@{details=$record}}}};
            additionalSources=@(@{channel='loki';control='Security decision';captures=@($path)})} -Depth 12 -Compress
        if ($publicManifest.Contains($Content)) { throw 'Loki raw response content entered manifest metadata.' }
    }
    return [pscustomobject]@{Path=$path;Receipt=$receipt;Result=$result;Failure=$failureOutput}
}

if ($SelfTest) {
    $start=1760000000000000000L; $end=$start+1000000000L
    $validPairs=[Collections.Generic.List[object]]::new()
    $validPair=[object[]]::new(2); $validPair[0]=$start; $validPair[1]='Security decision allowed'; $validPairs.Add($validPair)
    $validPair=[object[]]::new(2); $validPair[0]=$end; $validPair[1]='other event'; $validPairs.Add($validPair)
    $valid=New-LokiSelfTestResponse -Pairs $validPairs
    if ((Get-LokiPersistedControlCount -Content $valid -StartNs $start -EndNs $end) -ne 2) { throw 'Loki positive-control self-test failed.' }
    $pendingPair=[object[]]::new(2); $pendingPair[0]=$start; $pendingPair[1]='unrelated current event'
    $pendingPairs=[Collections.Generic.List[object]]::new(); $pendingPairs.Add($pendingPair)
    $pending=New-LokiSelfTestResponse -Pairs $pendingPairs
    $pendingRejected=$false
    try { [void](Get-LokiPersistedControlCount -Content $pending -StartNs $start -EndNs $end) }
    catch { $pendingRejected=$_.Exception.Message -like '*awaiting ingestion*'; $pendingError=$_.Exception.Message }
    if (!$pendingRejected) { throw "Loki missing positive-control self-test failed: $pendingError" }
    $retryPass=$false
    foreach ($candidate in @($pending,$valid)) {
        try { [void](Get-LokiPersistedControlCount -Content $candidate -StartNs $start -EndNs $end); $retryPass=$true; break }
        catch { if ($_.Exception.Message -notlike '*awaiting ingestion*') { throw } }
    }
    if (!$retryPass) { throw 'Loki delayed-ingestion retry self-test failed.' }
    $deadlineRejected=$false
    try { Assert-LokiPersistedControlCompleted 0 }
    catch { $deadlineRejected=$_.Exception.Message -like '*before the bounded deadline*' }
    if (!$deadlineRejected) { throw 'Loki deadline-exhaustion self-test failed.' }
    $expiredDeadlineRejected=$false
    try { [void](Get-LokiRequestTimeoutMilliseconds ([DateTimeOffset]::UtcNow.AddMilliseconds(-1))) }
    catch { $expiredDeadlineRejected=$_.Exception.Message -like '*bounded deadline*' }
    if (!$expiredDeadlineRejected) { throw 'Loki request-timeout self-test failed.' }
    $lateResponseRejected=$false
    try { Assert-LokiResponseBeforeDeadline ([DateTimeOffset]::UtcNow.AddMilliseconds(-1)) }
    catch { $lateResponseRejected=$_.Exception.Message -like '*completed after*' }
    if (!$lateResponseRejected) { throw 'Loki delayed-response deadline self-test failed.' }
    $stalePair=[object[]]::new(2); $stalePair[0]=$start-1; $stalePair[1]='Security decision stale'
    $stalePairs=[Collections.Generic.List[object]]::new(); $stalePairs.Add($stalePair)
    $stale=New-LokiSelfTestResponse -Pairs $stalePairs
    try { [void](Get-LokiPersistedControlCount -Content $stale -StartNs $start -EndNs $end); throw 'Loki accepted stale evidence.' }
    catch { if ($_.Exception.Message -eq 'Loki accepted stale evidence.') { throw } }
    $saturatedValues=[Collections.Generic.List[object]]::new()
    for ($index=0;$index -lt 1000;$index++) {
        $pair=[object[]]::new(2); $pair[0]=$start; $pair[1]='Security decision current'; $saturatedValues.Add($pair)
    }
    $saturated=New-LokiSelfTestResponse -Pairs $saturatedValues
    $saturatedRejected=$false
    try { [void](Get-LokiPersistedControlCount -Content $saturated -StartNs $start -EndNs $end) }
    catch { $saturatedRejected=$_.Exception.Message -like '*saturated*' }
    if (!$saturatedRejected) { throw 'Loki saturated response self-test failed.' }
    $lokiEvidenceRoot=Join-Path ([IO.Path]::GetTempPath()) ('geordi-loki-evidence-selftest-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($lokiEvidenceRoot)
    try {
        $evidencePairs=[Collections.Generic.List[object]]::new()
        Add-LokiSelfTestPair $evidencePairs $start 'Security decision allowed'
        $validEvidence=New-LokiSelfTestResponse -Pairs $evidencePairs

        # Prove the validator consumes only the flushed file and its bounded receipt.
        $successRoot=New-LokiSelfTestAttempt $lokiEvidenceRoot
        $sourceBytes=[Text.Encoding]::UTF8.GetBytes($validEvidence)
        $sourceStream=[IO.MemoryStream]::new($sourceBytes,0,$sourceBytes.Length,$false,$true)
        try { $successReceipt=Write-GeordiLokiResponseBody -InputStream $sourceStream `
                -Path (Join-Path $successRoot 'loki-query.json') -AttemptRoot $successRoot -MaximumBytes 1048576L }
        finally { $sourceStream.Dispose() }
        [Array]::Clear($sourceBytes,0,$sourceBytes.Length)
        if ($successReceipt.PSObject.Properties.Name -contains 'Content' -or
                [IO.File]::ReadAllText($successReceipt.Path) -cne $validEvidence) {
            throw 'Loki response was not persisted exactly before validation.'
        }
        $success=Test-GeordiLokiPersistedResponse -AttemptRoot $successRoot -ResponsePath $successReceipt.Path `
            -HttpStatus 200 -ExpectedByteCount $successReceipt.ByteCount -ExpectedSha256 $successReceipt.Sha256 `
            -StartNanoseconds $start -EndNanoseconds $end -PositiveControl 'Security decision' `
            -Sentinels @('unmatched-private-sentinel-' + [guid]::NewGuid().ToString('N')) -MaximumBytes 1048576L
        if ($success.EntryCount -ne 1 -or $success.Record.responseSha256 -cne $successReceipt.Sha256 -or
                (Test-Path -LiteralPath (Join-Path $successRoot 'loki-validation.json'))) {
            throw 'Loki persisted-response success self-test failed.'
        }
        $duplicateRejected=$false
        try {
            $duplicateStream=[IO.MemoryStream]::new([byte[]]@([byte]0x7b))
            try { [void](Write-GeordiLokiResponseBody -InputStream $duplicateStream `
                    -Path $successReceipt.Path -AttemptRoot $successRoot -MaximumBytes 1048576L) }
            finally { $duplicateStream.Dispose() }
        } catch { $duplicateRejected=$true }
        if (!$duplicateRejected -or (Get-FileHash -LiteralPath $successReceipt.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $successReceipt.Sha256) {
            throw 'Loki response create-new semantics did not preserve the first file.'
        }
        $outsidePath=Join-Path (Split-Path $successRoot -Parent) 'outside-attempt-response.json'
        $outsideRejected=$false
        $outsideStream=[IO.MemoryStream]::new([byte[]]@([byte]0x7b))
        try { [void](Write-GeordiLokiResponseBody -InputStream $outsideStream -Path $outsidePath `
                -AttemptRoot $successRoot -MaximumBytes 1048576L) }
        catch { $outsideRejected=$_.Exception.Message -like '*inside its attempt root*' }
        finally { $outsideStream.Dispose() }
        if(!$outsideRejected -or (Test-Path -LiteralPath $outsidePath)){throw 'Loki private response escaped its attempt directory.'}
        $oversizePath=Join-Path $successRoot 'oversize-response.json'
        $oversizeStream=[IO.MemoryStream]::new([byte[]]@([byte]1,[byte]2,[byte]3))
        $oversizeRejected=$false
        try { [void](Write-GeordiLokiResponseBody -InputStream $oversizeStream -Path $oversizePath `
                -AttemptRoot $successRoot -MaximumBytes 2L) }
        catch { $oversizeRejected=$_.Exception.Message -like '*configured size bound*' }
        finally { $oversizeStream.Dispose() }
        if(!$oversizeRejected -or (Test-Path -LiteralPath $oversizePath)){throw 'Loki response writer exceeded its byte cap or kept an incomplete body.'}
        $cancelPath=Join-Path $successRoot 'cancelled-response.json'
        $cancelStream=[GeordiLokiCancellationReadStream]::new()
        $cancelSource=[Threading.CancellationTokenSource]::new(); $cancelSource.Cancel(); $cancelRejected=$false
        try { [void](Write-GeordiLokiResponseBody -InputStream $cancelStream -Path $cancelPath `
                -AttemptRoot $successRoot -MaximumBytes 1048576L -CancellationToken $cancelSource.Token) }
        catch {
            $cancelException=$_.Exception
            while ($cancelException -and $cancelException -isnot [OperationCanceledException]) {
                $cancelException=$cancelException.InnerException
            }
            $cancelRejected=$cancelException -is [OperationCanceledException]
        }
        finally { $cancelStream.Dispose(); $cancelSource.Dispose() }
        if(!$cancelRejected -or (Test-Path -LiteralPath $cancelPath)){throw 'Loki response writer did not honor per-request cancellation.'}

        $casePairs=[Collections.Generic.List[object]]::new()
        Add-LokiSelfTestPair $casePairs $start 'Security decision allowed'
        $caseJson=New-LokiSelfTestResponse -Pairs $casePairs
        $cases=[Collections.Generic.List[object]]::new()
        $cases.Add(@{name='malformed JSON';content='{malformed';predicate='loki.response.parse';sentinels=@()})
        $cases.Add(@{name='wrong response shape';content='{"status":"success","data":{"result":{}}}';predicate='loki.response.shape';sentinels=@()})
        $cases.Add(@{name='non-string log body';content='{"status":"success","data":{"result":[{"values":[["1760000000000000000","Security decision allowed"],["1760000000000000000",{"bad":"body"}]]}]}}';predicate='loki.response.shape';sentinels=@()})
        $emptyPairs=[Collections.Generic.List[object]]::new()
        $cases.Add(@{name='empty result';content=(New-LokiSelfTestResponse -Pairs $emptyPairs);predicate='loki.result.nonempty';sentinels=@()})
        $outsidePairs=[Collections.Generic.List[object]]::new()
        Add-LokiSelfTestPair $outsidePairs ($end+1) 'Security decision outside interval'
        $cases.Add(@{name='out-of-range timestamp';content=(New-LokiSelfTestResponse -Pairs $outsidePairs);predicate='loki.interval.valid';sentinels=@()})
        $badTimestampPairs=[Collections.Generic.List[object]]::new()
        Add-LokiSelfTestPair $badTimestampPairs $start 'Security decision allowed'
        $badTimestamp=(New-LokiSelfTestResponse -Pairs $badTimestampPairs).Replace([string]$start,'not-nanoseconds')
        $cases.Add(@{name='malformed timestamp';content=$badTimestamp;predicate='loki.entry.timestamp';sentinels=@()})
        $missingControlPairs=[Collections.Generic.List[object]]::new()
        Add-LokiSelfTestPair $missingControlPairs $start 'unrelated current event'
        $cases.Add(@{name='missing positive control';content=(New-LokiSelfTestResponse -Pairs $missingControlPairs);predicate='loki.positive_control.present';sentinels=@()})
        $cases.Add(@{name='response HTTP status';content=$caseJson;predicate='loki.http.status';sentinels=@();httpStatus=503})
        $cases.Add(@{name='response status field';content=$caseJson.Replace('"success"','"error"');predicate='loki.response.status';sentinels=@()})
        $saturatedPairs=[Collections.Generic.List[object]]::new()
        for($index=0;$index -lt 1000;$index++){Add-LokiSelfTestPair $saturatedPairs $start 'Security decision saturated'}
        $cases.Add(@{name='saturated result';content=(New-LokiSelfTestResponse -Pairs $saturatedPairs);predicate='loki.result.saturated';sentinels=@()})
        $rawSentinel='raw-loki-private-' + [guid]::NewGuid().ToString('N')
        $rawPairs=[Collections.Generic.List[object]]::new(); Add-LokiSelfTestPair $rawPairs $start ('Security decision ' + $rawSentinel)
        $cases.Add(@{name='raw sentinel';content=(New-LokiSelfTestResponse -Pairs $rawPairs);predicate='loki.sentinel.raw';sentinels=@($rawSentinel)})
        $urlSentinel='url sentinel/plus+=' + [guid]::NewGuid().ToString('N')
        $urlPairs=[Collections.Generic.List[object]]::new(); Add-LokiSelfTestPair $urlPairs $start ('Security decision ' + [Uri]::EscapeDataString($urlSentinel))
        $cases.Add(@{name='URL sentinel';content=(New-LokiSelfTestResponse -Pairs $urlPairs);predicate='loki.sentinel.url';sentinels=@($urlSentinel)})
        $jsonSentinel='json"private-' + [guid]::NewGuid().ToString('N')
        $jsonPairs=[Collections.Generic.List[object]]::new(); Add-LokiSelfTestPair $jsonPairs $start ('Security decision ' + $jsonSentinel)
        $cases.Add(@{name='JSON sentinel';content=(New-LokiSelfTestResponse -Pairs $jsonPairs);predicate='loki.sentinel.json';sentinels=@($jsonSentinel)})
        $base64Sentinel='base64-loki-private-' + [guid]::NewGuid().ToString('N')
        $base64Value=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($base64Sentinel))
        $base64Pairs=[Collections.Generic.List[object]]::new(); Add-LokiSelfTestPair $base64Pairs $start ('Security decision ' + $base64Value)
        $cases.Add(@{name='base64 sentinel';content=(New-LokiSelfTestResponse -Pairs $base64Pairs);predicate='loki.sentinel.base64';sentinels=@($base64Sentinel)})
        $base64UrlSentinel='base64url-loki-' + [char]::ConvertFromUtf32(0x1F642)
        $base64UrlB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($base64UrlSentinel))
        if($base64UrlB64 -notmatch '[+/]'){throw 'Could not construct a base64url self-test sentinel.'}
        $base64UrlValue=$base64UrlB64.TrimEnd('=').Replace('+','-').Replace('/','_')
        $base64UrlPairs=[Collections.Generic.List[object]]::new(); Add-LokiSelfTestPair $base64UrlPairs $start ('Security decision ' + $base64UrlValue)
        $cases.Add(@{name='base64url sentinel';content=(New-LokiSelfTestResponse -Pairs $base64UrlPairs);predicate='loki.sentinel.base64url';sentinels=@($base64UrlSentinel)})
        foreach($case in $cases){
            $caseRoot=New-LokiSelfTestAttempt $lokiEvidenceRoot
            $mutation=if($case.predicate -eq 'loki.byte_accounting'){'byte-count'}elseif($case.predicate -eq 'loki.response.sha256'){'sha256'}else{'none'}
            try {
                [void](Invoke-LokiSelfTestValidation -AttemptRoot $caseRoot -Content $case.content `
                    -ExpectedPredicate $case.predicate -Sentinels $case.sentinels `
                    -HttpStatus $(if($case.ContainsKey('httpStatus')){$case.httpStatus}else{200}) -Mutation $mutation)
            } catch { throw "Loki evidence self-test case '$($case.name)' failed: $($_.Exception.Message)" }
        }
        foreach($mutationCase in @(@{name='byte-count mismatch';mutation='byte-count';predicate='loki.byte_accounting'},
                @{name='changed response hash';mutation='sha256';predicate='loki.response.sha256'},
                @{name='response exceeds bound';mutation='none';predicate='loki.response.size'})){
            $caseRoot=New-LokiSelfTestAttempt $lokiEvidenceRoot
            [void](Invoke-LokiSelfTestValidation -AttemptRoot $caseRoot -Content $caseJson `
                -ExpectedPredicate $mutationCase.predicate -Sentinels @('unused-size-test-sentinel') -Mutation $mutationCase.mutation)
        }
        $missingResponseRoot=New-LokiSelfTestAttempt $lokiEvidenceRoot
        $missingResponseFailure=$false
        try {
            [void](Test-GeordiLokiPersistedResponse -AttemptRoot $missingResponseRoot `
                -ResponsePath (Join-Path $missingResponseRoot 'missing-response.json') -HttpStatus 200 `
                -ExpectedByteCount 0L -ExpectedSha256 ('0'*64) -StartNanoseconds $start -EndNanoseconds $end `
                -PositiveControl 'Security decision' -Sentinels @('unused-missing-test-sentinel'))
        } catch { $missingResponseFailure=$_.Exception.Message.Contains('loki.response.persisted') }
        $missingResponseRecord=Get-Content -LiteralPath (Join-Path $missingResponseRoot 'loki-validation.json') -Raw | ConvertFrom-Json -AsHashtable
        if(!$missingResponseFailure -or $missingResponseRecord.predicateId -cne 'loki.response.persisted' -or
                $null -ne $missingResponseRecord.responseSha256) {throw 'Loki missing persisted response was not diagnosed safely.'}
        $emptySentinelRoot=New-LokiSelfTestAttempt $lokiEvidenceRoot
        [void](Invoke-LokiSelfTestValidation -AttemptRoot $emptySentinelRoot -Content $caseJson `
            -ExpectedPredicate 'loki.sentinel.inventory' -Sentinels @())
        $readinessRoot=New-LokiSelfTestAttempt $lokiEvidenceRoot
        $readinessFailure=$false
        try { Assert-GeordiLokiReadiness -AttemptRoot $readinessRoot -HttpStatus 503 }
        catch { $readinessFailure=$_.Exception.Message.Contains('loki.readiness.status') }
        $readinessRecord=Get-Content -LiteralPath (Join-Path $readinessRoot 'loki-validation.json') -Raw | ConvertFrom-Json -AsHashtable
        if(!$readinessFailure -or $readinessRecord.predicateId -cne 'loki.readiness.status' -or
                $readinessRecord.httpStatus -ne 503 -or $null -ne $readinessRecord.responseByteCount -or
                $null -ne $readinessRecord.responseSha256) {
            throw "Loki readiness failure metadata mismatch: thrown=$readinessFailure predicate=$($readinessRecord.predicateId) status=$($readinessRecord.httpStatus) bytesNull=$($null -eq $readinessRecord.responseByteCount) hashNull=$($null -eq $readinessRecord.responseSha256)"
        }
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-GeordiCredentialEvidence.ps1') -Raw
        $persistIndex=$source.IndexOf('-PrivateCapturePath $lokiFile',[StringComparison]::Ordinal)
        $validateIndex=$source.IndexOf('Test-GeordiLokiPersistedResponse -AttemptRoot $attemptRoot',[StringComparison]::Ordinal)
        $victoriaIndex=$source.IndexOf('$vmSource = @(',[StringComparison]::Ordinal)
        if($persistIndex -lt 0 -or $validateIndex -le $persistIndex -or $victoriaIndex -le $validateIndex){
            throw 'Finalize must persist and validate Loki before any later VictoriaMetrics gate.'
        }
        if($source -notmatch '-Details \$failureDetails -FailureCategory \$failureCategory' -or
                $source -notmatch 'loki-validation\.json') {throw 'Loki validation failure metadata is not wired into the failed attempt record.'}
        if (!(Test-GeordiLokiPredicateId 'loki.response.sha256') -or
                !([string]$source).Contains('Test-GeordiLokiPredicateId ([string]$validationRecord.predicateId)')) {
            throw 'Numeric Loki predicate IDs are not preserved in failed-attempt metadata.'
        }
    } finally {
        if(Test-Path -LiteralPath $lokiEvidenceRoot){Remove-Item -LiteralPath $lokiEvidenceRoot -Recurse -Force}
    }
    Write-Output 'loki_persisted_self_test=PASS predicates=20 private_persisted_bytes=create_new,same_bytes,incremental_hash,size_bound=PASS cancellation=PASS cleanup_scope=attempt_only raw_output=absent later_gates=blocked'
    return
}

$repositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pointer=Join-Path $repositoryRoot '.runtime/m19-capture-root.txt'
if (!(Test-Path -LiteralPath $pointer -PathType Leaf)) { throw 'Active private M19 capture pointer is missing.' }
$captureRoot=[IO.Path]::GetFullPath([IO.File]::ReadAllText($pointer).Trim())
$expectedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedTemp -or
        (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
    throw 'Active private M19 capture path failed validation.'
}
$manifestPath=Join-Path $captureRoot 'manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
if (!$manifest.ContainsKey('captureStartedUtc')) { throw 'Focused Loki gate requires an active private capture.' }
$startUtc=[DateTimeOffset]$manifest.captureStartedUtc
$ingress='https://geordi.localhost:8443/api/me'
$anonymous=Invoke-GeordiAnonymousRequest -Uri $ingress -Method GET -TimeoutSeconds 10
if ([int]$anonymous.StatusCode -ne 401) { throw 'Focused Loki gate did not receive the expected anonymous authorization rejection.' }
$ready=Invoke-BoundedLokiGet -Uri 'http://127.0.0.1:3100/ready' -TimeoutMilliseconds 5000
if ($ready.StatusCode -ne 200) { throw 'Loki was not ready for focused persisted-source verification.' }
$selector='{service_name="geordi-backend",service_namespace="geordi",deployment_environment_name="development",geordi_telemetry_origin="platform"}'
$queryStart=([DateTimeOffset]::UtcNow.AddSeconds(-45) -lt $startUtc) ? $startUtc : [DateTimeOffset]::UtcNow.AddSeconds(-45)
$deadline=[DateTimeOffset]::UtcNow.AddSeconds(35)
$entries=0; $payloadText=$null; $startNs=[long](($startUtc.UtcDateTime.Ticks-[DateTime]::UnixEpoch.Ticks)*100L)
do {
    $endUtc=[DateTimeOffset]::UtcNow
    $queryStartNs=[long](($queryStart.UtcDateTime.Ticks-[DateTime]::UnixEpoch.Ticks)*100L)
    $endNs=[long](($endUtc.UtcDateTime.Ticks-[DateTime]::UnixEpoch.Ticks)*100L)
    $uri='http://127.0.0.1:3100/loki/api/v1/query_range?query='+[Uri]::EscapeDataString($selector)+
        '&start='+$queryStartNs+'&end='+$endNs+'&limit=1000&direction=backward'
    $response=Invoke-BoundedLokiGet -Uri $uri -TimeoutMilliseconds (Get-LokiRequestTimeoutMilliseconds $deadline)
    Assert-LokiResponseBeforeDeadline $deadline
    if ($response.StatusCode -ne 200) { throw 'Focused Loki persisted-source query was not successful.' }
    $payloadText=$response.Content
    try { $entries=Get-LokiPersistedControlCount -Content $payloadText -StartNs $queryStartNs -EndNs $endNs }
    catch {
        if ($_.Exception.Message -notlike '*awaiting ingestion*') { throw }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw }
        $sleepMilliseconds=[math]::Min(2000,[math]::Max(1,[int][math]::Floor(($deadline-[DateTimeOffset]::UtcNow).TotalMilliseconds)))
        Start-Sleep -Milliseconds $sleepMilliseconds
    }
} while ($entries -eq 0 -and [DateTimeOffset]::UtcNow -lt $deadline)
Assert-LokiPersistedControlCompleted $entries
$capturePath=Join-Path $captureRoot 'loki-focused-query.json'
[IO.File]::WriteAllText($capturePath,$payloadText,[Text.UTF8Encoding]::new($false))
$needles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($sentinel in @($manifest.sentinels)) {
    [void]$needles.Add([string]$sentinel)
    [void]$needles.Add([Uri]::EscapeDataString([string]$sentinel))
    $base64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$sentinel))
    [void]$needles.Add($base64); [void]$needles.Add($base64.TrimEnd('=').Replace('+','-').Replace('/','_'))
    $json=ConvertTo-Json -InputObject ([string]$sentinel) -Compress
    if ($json.Length -ge 2) { [void]$needles.Add($json.Substring(1,$json.Length-2)) }
}
$scan=[GeordiPrivateCaptureScanner]::Scan($capturePath,[string[]]@($needles),64MB)
if (@($scan.Matches).Count -gt 0) { throw 'Focused Loki capture contained a private sentinel.' }
Write-Output ("loki_focused_gate=PASS readiness=PASS status={0} entries={1} duration_bound_seconds=35 query_timeout_seconds=10 current_run_interval=true sentinel_scans=5/5" -f
    $response.StatusCode,$entries)
