[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/GeordiTlsTrust.psm1') -Force
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeDirectory = Join-Path $repositoryRoot '.runtime/m19'
if (!(Test-Path -LiteralPath $runtimeDirectory)) { return }
$resolvedRuntimeDirectory = (Resolve-Path -LiteralPath $runtimeDirectory).Path
$expectedParent = (Resolve-Path -LiteralPath (Join-Path $repositoryRoot '.runtime')).Path
if (!$resolvedRuntimeDirectory.StartsWith($expectedParent + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to remove M19 runtime material outside the repository runtime directory.'
}

$thumbprintFile = Join-Path $resolvedRuntimeDirectory 'browser-trust-thumbprint'
if (Test-Path -LiteralPath $thumbprintFile) {
    $thumbprint = [IO.File]::ReadAllText($thumbprintFile).Trim()
    if ($thumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'Invalid ephemeral CA thumbprint manifest.' }
    $caPath = Join-Path $resolvedRuntimeDirectory 'ca.cer'
    if (!(Test-Path -LiteralPath $caPath -PathType Leaf)) { throw 'Recorded ephemeral CA certificate is missing; refusing store cleanup.' }
    $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new($caPath)
    try {
        if ($ca.Thumbprint -ne $thumbprint) { throw 'Recorded CA thumbprint does not match its public certificate.' }
        Invoke-GeordiTlsStoreActionBounded -Action Remove -ExpectedThumbprint $thumbprint -ExpectedSubject $ca.Subject
        Invoke-GeordiTlsStoreActionBounded -Action VerifyAbsent -ExpectedThumbprint $thumbprint -ExpectedSubject $ca.Subject
    } finally {
        $ca.Dispose()
    }
}

Remove-Item -LiteralPath $resolvedRuntimeDirectory -Recurse -Force
if (Test-Path -LiteralPath $resolvedRuntimeDirectory) { throw 'M19 TLS runtime files remain after cleanup.' }
Write-Output 'Ephemeral M19 TLS material was removed; recorded CA thumbprint is absent from LocalMachine Root.'
