function ConvertTo-GeordiCaptureUtcInstant {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][object] $Value,
        [Parameter(Mandatory)][string] $Field)
    if ($null -eq $Value) {
        throw "Capture timestamp '$Field' is missing or malformed."
    }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw "Capture timestamp '$Field' has ambiguous DateTime semantics." }
        return ([DateTimeOffset]::new($Value)).ToUniversalTime()
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
            $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw "Capture timestamp '$Field' is missing or malformed."
    }
    try {
        return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch {
        throw "Capture timestamp '$Field' is invalid."
    }
}
