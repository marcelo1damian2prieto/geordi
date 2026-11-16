function Test-GeordiLokiPredicateId {
    param([AllowNull()][string] $PredicateId)
    return $PredicateId -cmatch '^loki\.[a-z0-9_.]+$'
}

function Write-GeordiLokiResponseBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.Stream] $InputStream,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $AttemptRoot,
        [ValidateRange(1,67108864)][long] $MaximumBytes = 67108864L,
        [Threading.CancellationToken] $CancellationToken = [Threading.CancellationToken]::None
    )
    $fullPath=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetFullPath($AttemptRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $parent=[IO.Path]::GetDirectoryName($fullPath)
    if ($parent -cne $root -or !(Test-Path -LiteralPath $root -PathType Container) -or
            ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Private Loki response path must be directly inside its attempt root.'
    }
    $file=$null; $hash=$null; $created=$false; $complete=$false; $total=0L
    try {
        $file=[IO.File]::Open($fullPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $created=$true
        $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        $buffer=[byte[]]::new(65536)
        while (($read=$InputStream.ReadAsync($buffer,0,$buffer.Length,$CancellationToken).GetAwaiter().GetResult()) -gt 0) {
            if ($total + $read -gt $MaximumBytes) { throw 'Loki persisted-source response exceeded its configured size bound.' }
            $file.Write($buffer,0,$read)
            $hash.AppendData($buffer,0,$read)
            $total += $read
        }
        $file.Flush($true)
        $file.Dispose(); $file=$null
        $sha=[Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        $complete=$true
        return [pscustomobject]@{ Path=$fullPath; ByteCount=$total; Sha256=$sha }
    } finally {
        if ($file) { $file.Dispose() }
        if ($hash) { $hash.Dispose() }
        if ($created -and !$complete -and (Test-Path -LiteralPath $fullPath)) {
            Remove-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-GeordiLokiValidationRecord {
    param([object] $HttpStatus,[object] $ResponseByteCount,[object] $ResponseSha256)
    return [ordered]@{
        phase='loki'; predicateId=$null; failureCategory=$null; httpStatus=$HttpStatus
        responseByteCount=$ResponseByteCount; responseSha256=$ResponseSha256
        parseValid=$null; resultEntryCount=$null; positiveControlPresent=$null; intervalValid=$null
        scannedRaw=$null; scannedUrlEncoded=$null; scannedJsonEscaped=$null
        scannedBase64=$null; scannedBase64Url=$null
    }
}

function Assert-GeordiLokiReadiness {
    param([string] $AttemptRoot,[int] $HttpStatus)
    if ($HttpStatus -eq 200) { return }
    $record=New-GeordiLokiValidationRecord $HttpStatus $null $null
    Throw-GeordiLokiValidationFailure ([IO.Path]::GetFullPath($AttemptRoot)) $record 'loki.readiness.status'
}

function Throw-GeordiLokiValidationFailure {
    param([string] $AttemptRoot,[System.Collections.IDictionary] $Record,[string] $PredicateId)
    $Record.predicateId=$PredicateId
    $Record.failureCategory='validation'
    $recordPath=Join-Path ([IO.Path]::GetFullPath($AttemptRoot)) 'loki-validation.json'
    Write-GeordiM19AttemptFile -Path $recordPath -Content (ConvertTo-Json -InputObject $Record -Depth 6 -Compress)
    throw "Loki validation failed (predicateId=$PredicateId)."
}

function Test-GeordiLokiPersistedResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AttemptRoot,
        [Parameter(Mandatory)][string] $ResponsePath,
        [Parameter(Mandatory)][int] $HttpStatus,
        [Parameter(Mandatory)][long] $ExpectedByteCount,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ExpectedSha256,
        [Parameter(Mandatory)][long] $StartNanoseconds,
        [Parameter(Mandatory)][long] $EndNanoseconds,
        [Parameter(Mandatory)][string] $PositiveControl,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Sentinels,
        [ValidateRange(1,67108864)][long] $MaximumBytes=67108864L
    )
    $root=[IO.Path]::GetFullPath($AttemptRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $path=[IO.Path]::GetFullPath($ResponsePath)
    if ([IO.Path]::GetDirectoryName($path) -cne $root -or
            !(Test-Path -LiteralPath $path -PathType Leaf) -or
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $record=New-GeordiLokiValidationRecord $HttpStatus 0L $null
        Throw-GeordiLokiValidationFailure $root $record 'loki.response.persisted'
    }

    $file=$null; $memory=$null; $hash=$null
    try {
        $file=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $initialLength=$file.Length
        $record=New-GeordiLokiValidationRecord $HttpStatus $initialLength $null
        if ($initialLength -gt $MaximumBytes) { Throw-GeordiLokiValidationFailure $root $record 'loki.response.size' }
        $memory=[IO.MemoryStream]::new([int][Math]::Min($initialLength,1048576L))
        $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        $buffer=[byte[]]::new(65536); $total=0L
        while (($read=$file.Read($buffer,0,$buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaximumBytes -or $total -gt $initialLength) {
                $record.responseByteCount=$total
                Throw-GeordiLokiValidationFailure $root $record 'loki.byte_accounting'
            }
            $hash.AppendData($buffer,0,$read)
            $memory.Write($buffer,0,$read)
        }
        $actualHash=[Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        $record.responseByteCount=$total
        $record.responseSha256=$actualHash
        if ($total -ne $initialLength -or $total -ne $ExpectedByteCount -or $file.Length -ne $initialLength) {
            Throw-GeordiLokiValidationFailure $root $record 'loki.byte_accounting'
        }
        if ($actualHash -cne $ExpectedSha256.ToLowerInvariant()) {
            Throw-GeordiLokiValidationFailure $root $record 'loki.response.sha256'
        }
        if ($HttpStatus -ne 200) { Throw-GeordiLokiValidationFailure $root $record 'loki.http.status' }

        $payloadText=$null
        try { $payloadText=[Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray()) }
        catch { $record.parseValid=$false; Throw-GeordiLokiValidationFailure $root $record 'loki.response.parse' }
        try { $payload=ConvertFrom-Json -InputObject $payloadText -AsHashtable -ErrorAction Stop }
        catch { $record.parseValid=$false; Throw-GeordiLokiValidationFailure $root $record 'loki.response.parse' }
        $record.parseValid=$true
        if ($payload -isnot [System.Collections.IDictionary] -or
                !$payload.Contains('status') -or !$payload.Contains('data') -or
                $payload.data -isnot [System.Collections.IDictionary] -or
                !$payload.data.Contains('result') -or $payload.data.result -isnot [System.Collections.IList]) {
            Throw-GeordiLokiValidationFailure $root $record 'loki.response.shape'
        }
        if ([string]$payload.status -cne 'success') {
            Throw-GeordiLokiValidationFailure $root $record 'loki.response.status'
        }

        $entryCount=0L; $positiveControlPresent=$false
        foreach ($stream in $payload.data.result) {
            if ($stream -isnot [System.Collections.IDictionary] -or !$stream.Contains('values') -or
                    $stream.values -isnot [System.Collections.IList]) {
                Throw-GeordiLokiValidationFailure $root $record 'loki.response.shape'
            }
            foreach ($value in $stream.values) {
                if ($value -isnot [System.Collections.IList] -or $value.Count -ne 2 -or $value[1] -isnot [string]) {
                    Throw-GeordiLokiValidationFailure $root $record 'loki.response.shape'
                }
                $timestamp=0L
                if (![long]::TryParse([string]$value[0],[Globalization.NumberStyles]::Integer,
                        [Globalization.CultureInfo]::InvariantCulture,[ref]$timestamp)) {
                    $record.resultEntryCount=$entryCount
                    Throw-GeordiLokiValidationFailure $root $record 'loki.entry.timestamp'
                }
                if ($timestamp -lt $StartNanoseconds -or $timestamp -gt $EndNanoseconds) {
                    $record.resultEntryCount=$entryCount
                    $record.intervalValid=$false
                    Throw-GeordiLokiValidationFailure $root $record 'loki.interval.valid'
                }
                $entryCount++
                if ([string]$value[1] -match [regex]::Escape($PositiveControl)) { $positiveControlPresent=$true }
            }
        }
        $record.resultEntryCount=$entryCount
        $record.intervalValid=$true
        if ($entryCount -eq 0) { Throw-GeordiLokiValidationFailure $root $record 'loki.result.nonempty' }
        if ($entryCount -ge 1000) { Throw-GeordiLokiValidationFailure $root $record 'loki.result.saturated' }
        $record.positiveControlPresent=$positiveControlPresent
        if (!$positiveControlPresent) { Throw-GeordiLokiValidationFailure $root $record 'loki.positive_control.present' }

        $patternKinds=[Collections.Generic.Dictionary[string,Collections.Generic.HashSet[string]]]::new([StringComparer]::Ordinal)
        $addPattern={
            param([string] $Pattern,[string] $Kind)
            if (!$patternKinds.ContainsKey($Pattern)) {
                $patternKinds[$Pattern]=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            }
            [void]$patternKinds[$Pattern].Add($Kind)
        }
        foreach ($sentinel in $Sentinels) {
            if ([string]::IsNullOrEmpty($sentinel)) { continue }
            & $addPattern $sentinel 'raw'
            & $addPattern ([Uri]::EscapeDataString($sentinel)) 'url'
            $json=ConvertTo-Json -InputObject $sentinel -Compress
            if ($json.Length -ge 2) { & $addPattern $json.Substring(1,$json.Length-2) 'json' }
            $base64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel))
            & $addPattern $base64 'base64'
            & $addPattern ($base64.TrimEnd('=').Replace('+','-').Replace('/','_')) 'base64url'
        }
        if ($patternKinds.Count -eq 0) { Throw-GeordiLokiValidationFailure $root $record 'loki.sentinel.inventory' }
        $record.scannedRaw=$true; $record.scannedUrlEncoded=$true; $record.scannedJsonEscaped=$true
        $record.scannedBase64=$true; $record.scannedBase64Url=$true
        $scan=[GeordiPrivateCaptureScanner]::Scan($path,[string[]]@($patternKinds.Keys),$MaximumBytes)
        if ($scan.ByteCount -ne $total) { Throw-GeordiLokiValidationFailure $root $record 'loki.byte_accounting' }
        if ([string]$scan.Sha256 -cne $actualHash) { Throw-GeordiLokiValidationFailure $root $record 'loki.response.sha256' }
        $matches=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($match in $scan.Matches) { [void]$matches.Add([string]$match) }
        foreach ($kind in @('raw','url','json','base64','base64url')) {
            foreach ($pattern in $patternKinds.Keys) {
                if ($patternKinds[$pattern].Contains($kind) -and $matches.Contains($pattern)) {
                    $predicateId=switch($kind){
                        'raw' {'loki.sentinel.raw'}
                        'url' {'loki.sentinel.url'}
                        'json' {'loki.sentinel.json'}
                        'base64' {'loki.sentinel.base64'}
                        'base64url' {'loki.sentinel.base64url'}
                    }
                    Throw-GeordiLokiValidationFailure $root $record $predicateId
                }
            }
        }
        return [pscustomobject]@{
            Record=$record; EntryCount=$entryCount; StreamCount=@($payload.data.result).Count
            ByteCount=$total; Sha256=$actualHash; PositiveControlPresent=$positiveControlPresent
        }
    } finally {
        if ($hash) { $hash.Dispose() }
        if ($memory) { $memory.Dispose() }
        if ($file) { $file.Dispose() }
    }
}
