[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/GeordiTlsTrust.psm1') -Force

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeParent = Join-Path $repositoryRoot '.runtime'
$runtimeDirectory = Join-Path $runtimeParent 'm19'
$publicThumbprintPath = Join-Path $runtimeParent 'm19-ca-thumbprint.txt'
$expectedCaSubject = 'CN=Geordi M19 Ephemeral Test CA'

function Remove-ExactM19LocalMachineRoot([string] $Thumbprint, [string] $Subject) {
    $installed = Test-GeordiTlsStoreThumbprint -ExpectedThumbprint $Thumbprint -ExpectedSubject $Subject
    if (!$installed) {
        Write-Output 'Recorded M19 CA thumbprint is already absent from LocalMachine Root; no store mutation required.'
        return
    }

    Invoke-GeordiTlsStoreActionBounded -Action Remove -ExpectedThumbprint $Thumbprint -ExpectedSubject $Subject
    if (Test-GeordiTlsStoreThumbprint -ExpectedThumbprint $Thumbprint -ExpectedSubject $Subject) {
        throw 'Recorded M19 CA thumbprint remains in LocalMachine Root after removal.'
    }
}

$runtimeExists = Test-Path -LiteralPath $runtimeDirectory
$publicPathExists = Test-Path -LiteralPath $publicThumbprintPath
if ($publicPathExists -and !(Test-Path -LiteralPath $publicThumbprintPath -PathType Leaf)) {
    throw 'Public M19 thumbprint manifest path exists but is not a regular file; refusing cleanup.'
}
$publicManifestExists = $publicPathExists

if (!$runtimeExists -and !$publicManifestExists) {
    Write-Output 'M19 TLS runtime and public thumbprint manifest are already absent.'
    return
}

if (!(Test-Path -LiteralPath $runtimeParent -PathType Container)) {
    throw 'M19 runtime parent directory is missing; refusing cleanup.'
}
$resolvedRuntimeParent = (Resolve-Path -LiteralPath $runtimeParent).Path

if ($runtimeExists) {
    $runtimeItem = Get-Item -LiteralPath $runtimeDirectory -Force
    if (($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to remove M19 runtime material through a reparse point.'
    }
    $resolvedRuntimeDirectory = (Resolve-Path -LiteralPath $runtimeDirectory).Path
    $expectedRuntimeDirectory = [IO.Path]::GetFullPath((Join-Path $resolvedRuntimeParent 'm19'))
    if (![string]::Equals($resolvedRuntimeDirectory, $expectedRuntimeDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove M19 runtime material outside the repository runtime directory.'
    }
}

if ($publicManifestExists) {
    $manifestItem = Get-Item -LiteralPath $publicThumbprintPath -Force
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to remove the public M19 thumbprint manifest through a reparse point.'
    }
    $resolvedManifest = (Resolve-Path -LiteralPath $publicThumbprintPath).Path
    $expectedManifest = [IO.Path]::GetFullPath((Join-Path $resolvedRuntimeParent 'm19-ca-thumbprint.txt'))
    if (![string]::Equals($resolvedManifest, $expectedManifest, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a public M19 thumbprint manifest outside the repository runtime directory.'
    }
}

$browserManifestPath = if ($runtimeExists) { Join-Path $runtimeDirectory 'browser-trust-thumbprint' } else { $null }
$browserManifestPathExists = $runtimeExists -and (Test-Path -LiteralPath $browserManifestPath)
if ($browserManifestPathExists -and !(Test-Path -LiteralPath $browserManifestPath -PathType Leaf)) {
    throw 'Browser trust thumbprint manifest exists but is not a regular file; refusing cleanup.'
}
$browserManifestExists = $browserManifestPathExists

if ($runtimeExists -and ($browserManifestExists -ne $publicManifestExists)) {
    throw 'M19 thumbprint manifests are incomplete or inconsistent; refusing cleanup.'
}

if ($browserManifestExists -and $publicManifestExists) {
    $browserManifestItem = Get-Item -LiteralPath $browserManifestPath -Force
    if (($browserManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to read the browser trust thumbprint manifest through a reparse point.'
    }
    $browserThumbprint = [IO.File]::ReadAllText($browserManifestPath).Trim()
    $publicThumbprint = [IO.File]::ReadAllText($publicThumbprintPath).Trim()
    if ($browserThumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or $publicThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw 'Invalid M19 CA thumbprint manifest; refusing cleanup.'
    }
    if (![string]::Equals($browserThumbprint, $publicThumbprint, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'M19 CA thumbprint manifests do not match; refusing cleanup.'
    }

    $caPath = Join-Path $runtimeDirectory 'ca.cer'
    if (!(Test-Path -LiteralPath $caPath -PathType Leaf)) {
        throw 'Recorded ephemeral CA certificate is missing; refusing store cleanup.'
    }
    $caItem = Get-Item -LiteralPath $caPath -Force
    if (($caItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to validate a CA certificate through a reparse point.'
    }

    $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new($caPath)
    try {
        if ($ca.Thumbprint -ine $browserThumbprint -or $ca.Subject -cne $expectedCaSubject -or $ca.Issuer -cne $expectedCaSubject -or $ca.HasPrivateKey) {
            throw 'Recorded CA identity does not match the expected public ephemeral CA.'
        }
        $basicConstraintsExtension = $ca.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
        if ($null -eq $basicConstraintsExtension) {
            throw 'Recorded CA certificate has no Basic Constraints extension.'
        }
        $basicConstraints = [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($basicConstraintsExtension, $basicConstraintsExtension.Critical)
        if (!$basicConstraints.CertificateAuthority) {
            throw 'Recorded certificate is not a CA; refusing store cleanup.'
        }

        # Read-only probe avoids requiring elevation when the exact CA is already absent.
        Remove-ExactM19LocalMachineRoot $browserThumbprint $expectedCaSubject
    } finally {
        $ca.Dispose()
    }
}
elseif (!$runtimeExists -and $publicManifestExists) {
    # Recovery if a prior cleanup removed .runtime/m19 but stopped before deleting the public manifest.
    $publicThumbprint = [IO.File]::ReadAllText($publicThumbprintPath).Trim()
    if ($publicThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw 'Invalid orphaned public M19 thumbprint manifest; refusing cleanup.'
    }
    Remove-ExactM19LocalMachineRoot $publicThumbprint $expectedCaSubject
}

if ($runtimeExists) {
    Remove-Item -LiteralPath $resolvedRuntimeDirectory -Recurse -Force
    if (Test-Path -LiteralPath $resolvedRuntimeDirectory) {
        throw 'M19 TLS runtime files remain after cleanup.'
    }
}

if ($publicManifestExists) {
    Remove-Item -LiteralPath $publicThumbprintPath -Force
    if (Test-Path -LiteralPath $publicThumbprintPath) {
        throw 'Public M19 CA thumbprint manifest remains after cleanup.'
    }
}

Write-Output 'Ephemeral M19 TLS material and thumbprint manifests were removed; recorded CA thumbprint is absent from LocalMachine Root.'
