[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/GeordiTlsTrust.psm1') -Force

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeParent = Join-Path $repositoryRoot '.runtime'
$runtimeDirectory = Join-Path $runtimeParent 'm19'
$publicThumbprintPath = Join-Path $runtimeParent 'm19-ca-thumbprint.txt'
$expectedCaSubject = 'CN=Geordi M19 Ephemeral Test CA'
$tlsOwnedFiles = @(
    'auth-cert.pem',
    'auth-key.pem',
    'auth-localhost-cert.pem',
    'auth-localhost-key.pem',
    'auth.p12',
    'auth.password',
    'browser-trust-thumbprint',
    'ca.cer',
    'ca.pem',
    'client-secret',
    'control-secret',
    'geordi-cert.pem',
    'geordi-key.pem',
    'geordi.p12',
    'geordi.password',
    'truststore.p12',
    'truststore.password'
)

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

function Assert-RegularNonReparseFile([string] $Path, [string] $Description) {
    if (!(Test-Path -LiteralPath $Path)) { return $false }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description exists but is not a regular file; refusing cleanup."
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to access $Description through a reparse point."
    }
    return $true
}

$runtimeExists = Test-Path -LiteralPath $runtimeDirectory
$publicManifestExists = Assert-RegularNonReparseFile $publicThumbprintPath 'Public M19 thumbprint manifest'

if (!$runtimeExists -and !$publicManifestExists) {
    Write-Output 'M19 TLS runtime and public thumbprint manifest are already absent.'
    return
}

if (!(Test-Path -LiteralPath $runtimeParent -PathType Container)) {
    throw 'M19 runtime parent directory is missing; refusing cleanup.'
}
$runtimeParentItem = Get-Item -LiteralPath $runtimeParent -Force
if (($runtimeParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Refusing to remove M19 runtime material through a redirected .runtime parent.'
}
$resolvedRuntimeParent = (Resolve-Path -LiteralPath $runtimeParent).Path
$expectedRuntimeParent = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
if (![string]::Equals($resolvedRuntimeParent, $expectedRuntimeParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to remove M19 runtime material outside the repository .runtime directory.'
}

if ($runtimeExists) {
    if (!(Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
        throw 'M19 runtime path exists but is not a directory; refusing cleanup.'
    }
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

$browserManifestPath = if ($runtimeExists) { Join-Path $runtimeDirectory 'browser-trust-thumbprint' } else { $null }
$browserManifestExists = $false
if ($runtimeExists) {
    $browserManifestExists = Assert-RegularNonReparseFile $browserManifestPath 'Browser trust thumbprint manifest'
}

if ($runtimeExists -and ($browserManifestExists -ne $publicManifestExists)) {
    throw 'M19 thumbprint manifests are incomplete or inconsistent; refusing cleanup.'
}

if ($browserManifestExists -and $publicManifestExists) {
    $browserThumbprint = [IO.File]::ReadAllText($browserManifestPath).Trim()
    $publicThumbprint = [IO.File]::ReadAllText($publicThumbprintPath).Trim()
    if ($browserThumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or
        $publicThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw 'Invalid M19 CA thumbprint manifest; refusing cleanup.'
    }
    if (![string]::Equals($browserThumbprint, $publicThumbprint, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'M19 CA thumbprint manifests do not match; refusing cleanup.'
    }

    $caPath = Join-Path $runtimeDirectory 'ca.cer'
    if (!(Assert-RegularNonReparseFile $caPath 'Recorded ephemeral CA certificate')) {
        throw 'Recorded ephemeral CA certificate is missing; refusing store cleanup.'
    }

    $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new($caPath)
    try {
        if ($ca.Thumbprint -ine $browserThumbprint -or
            $ca.Subject -cne $expectedCaSubject -or
            $ca.Issuer -cne $expectedCaSubject -or
            $ca.HasPrivateKey) {
            throw 'Recorded CA identity does not match the expected public ephemeral CA.'
        }
        $basicConstraintsExtension = $ca.Extensions |
            Where-Object { $_.Oid.Value -eq '2.5.29.19' } |
            Select-Object -First 1
        if ($null -eq $basicConstraintsExtension) {
            throw 'Recorded CA certificate has no Basic Constraints extension.'
        }
        $basicConstraints = [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
            $basicConstraintsExtension, $basicConstraintsExtension.Critical)
        if (!$basicConstraints.CertificateAuthority) {
            throw 'Recorded certificate is not a CA; refusing store cleanup.'
        }

        Remove-ExactM19LocalMachineRoot $browserThumbprint $expectedCaSubject
    } finally {
        $ca.Dispose()
    }
}
elseif (!$runtimeExists -and $publicManifestExists) {
    # Recovery after a prior cleanup removed .runtime/m19 but stopped before deleting the public manifest.
    $publicThumbprint = [IO.File]::ReadAllText($publicThumbprintPath).Trim()
    if ($publicThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
        throw 'Invalid orphaned public M19 thumbprint manifest; refusing cleanup.'
    }
    Remove-ExactM19LocalMachineRoot $publicThumbprint $expectedCaSubject
}
elseif ($runtimeExists -and !$browserManifestExists -and !$publicManifestExists) {
    # Local-only generation normally has no trust manifests. Inspect ca.cer read-only
    # so a lost manifest cannot leave a run-owned CA trusted in Windows.
    $caPath = Join-Path $runtimeDirectory 'ca.cer'
    if (Assert-RegularNonReparseFile $caPath 'Local-only CA certificate') {
        $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new($caPath)
        try {
            if ($ca.Subject -cne $expectedCaSubject -or
                $ca.Issuer -cne $expectedCaSubject -or
                $ca.HasPrivateKey) {
                throw 'Local-only CA certificate identity is not the expected public ephemeral CA.'
            }
            $basicConstraintsExtension = $ca.Extensions |
                Where-Object { $_.Oid.Value -eq '2.5.29.19' } |
                Select-Object -First 1
            if ($null -eq $basicConstraintsExtension) {
                throw 'Local-only CA certificate has no Basic Constraints extension.'
            }
            $basicConstraints = [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
                $basicConstraintsExtension, $basicConstraintsExtension.Critical)
            if (!$basicConstraints.CertificateAuthority) {
                throw 'Local-only certificate is not a CA; refusing store cleanup.'
            }
            Remove-ExactM19LocalMachineRoot $ca.Thumbprint $expectedCaSubject
        } finally {
            $ca.Dispose()
        }
    }
}

# Delete only files owned by the TLS generator. Preserve M18/M19 policy and
# evidence files (for example alert-policies.yaml, slos.yaml and M18 IDs).
if ($runtimeExists) {
    foreach ($fileName in $tlsOwnedFiles) {
        $path = Join-Path $runtimeDirectory $fileName
        if (Assert-RegularNonReparseFile $path "M19 TLS artifact '$fileName'") {
            Remove-Item -LiteralPath $path -Force
            if (Test-Path -LiteralPath $path) {
                throw "M19 TLS artifact '$fileName' remains after cleanup."
            }
        }
    }

    $remainingItems = @(Get-ChildItem -LiteralPath $runtimeDirectory -Force)
    if ($remainingItems.Count -eq 0) {
        Remove-Item -LiteralPath $runtimeDirectory -Force
    } else {
        $remainingNames = ($remainingItems | Select-Object -ExpandProperty Name) -join ', '
        Write-Output "Preserved non-TLS M19 runtime files: $remainingNames"
    }
}

if ($publicManifestExists) {
    Remove-Item -LiteralPath $publicThumbprintPath -Force
    if (Test-Path -LiteralPath $publicThumbprintPath) {
        throw 'Public M19 CA thumbprint manifest remains after cleanup.'
    }
}

Write-Output 'M19 TLS cleanup completed; only TLS-owned files and trust manifests were removed.'
