[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Add','Remove')][string] $Action,
    [Parameter(Mandatory)][string] $CertificatePath,
    [Parameter(Mandatory)][string] $StagePath
)

$ErrorActionPreference = 'Stop'
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    (Resolve-Path -LiteralPath $CertificatePath).Path)
$store = [Security.Cryptography.X509Certificates.X509Store]::new(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
try {
    [IO.File]::WriteAllText($StagePath, 'before-open', [Text.UTF8Encoding]::new($false))
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    [IO.File]::WriteAllText($StagePath, 'before-' + $Action.ToLowerInvariant(), [Text.UTF8Encoding]::new($false))
    if ($Action -eq 'Add') { $store.Add($certificate) } else { $store.Remove($certificate) }
    [IO.File]::WriteAllText($StagePath, 'after-' + $Action.ToLowerInvariant(), [Text.UTF8Encoding]::new($false))
} finally {
    $store.Close()
    $certificate.Dispose()
}
