[CmdletBinding()]
param(
    [switch] $TrustForLocalMachine
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/GeordiTlsTrust.psm1') -Force
$script:GeordiImportedM19Thumbprint = $null
if ($TrustForLocalMachine) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'LOCALMACHINE TLS TRUST REQUIRES an effective administrator context; no M19 material was created.'
    }
}
if (-not ('GeordiCertificateExtensions' -as [type])) {
Add-Type -TypeDefinition @'
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class GeordiCertificateExtensions {
    public static X509Certificate2 CopyPrivateKey(X509Certificate2 certificate, RSA key) {
        return certificate.CopyWithPrivateKey(key);
    }
}
'@
}
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeDirectory = Join-Path $repositoryRoot '.runtime/m19'
$publicThumbprintPath = Join-Path (Join-Path $repositoryRoot '.runtime') 'm19-ca-thumbprint.txt'
if (Test-Path -LiteralPath $runtimeDirectory) {
    $tlsOwnedNames = @(
        'auth-cert.pem', 'auth-key.pem', 'auth-localhost-cert.pem', 'auth-localhost-key.pem',
        'auth.p12', 'auth.password', 'browser-trust-thumbprint', 'ca.cer', 'ca.pem',
        'client-secret', 'control-secret', 'geordi-cert.pem', 'geordi-key.pem',
        'geordi.p12', 'geordi.password', 'truststore.p12', 'truststore.password'
    )
    $existingTlsMaterial = @($tlsOwnedNames | Where-Object {
        Test-Path -LiteralPath (Join-Path $runtimeDirectory $_)
    })
    if ($existingTlsMaterial.Count -gt 0) {
        throw "M19 TLS material already exists ($($existingTlsMaterial -join ', ')). Remove it with Remove-GeordiTestTls.ps1 before generating another set."
    }
    Write-Output 'Preserving existing non-TLS M19 runtime files while generating fresh TLS material.'
}
if (Test-Path -LiteralPath $publicThumbprintPath) {
    throw 'A prior M19 CA thumbprint record remains; complete exact-thumbprint cleanup before generating another set.'
}
New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null

function Write-Utf8Secret([string] $Path, [string] $Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function New-RandomSecret([int] $Bytes = 32) {
    $buffer = [byte[]]::new($Bytes)
    [Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    try { [Convert]::ToBase64String($buffer) } finally { [Array]::Clear($buffer) }
}

function New-SignedLeaf(
    [string] $CommonName,
    [string[]] $DnsNames,
    [Security.Cryptography.X509Certificates.X509Certificate2] $Issuer,
    [Security.Cryptography.RSA] $IssuerKey,
    [string] $CertificatePath,
    [string] $PrivateKeyPath,
    [string] $PfxPath,
    [string] $PfxPasswordPath
) {
    $key = [Security.Cryptography.RSA]::Create(2048)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=$CommonName", $key,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
    $names = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    foreach ($dnsName in $DnsNames) { $names.AddDnsName($dnsName) }
    $request.CertificateExtensions.Add($names.Build())
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false))
    $serial = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Fill($serial)
    $now = [DateTimeOffset]::UtcNow
    $publicCertificate = $request.Create($Issuer, $now.AddMinutes(-5), $Issuer.NotAfter.AddMinutes(-1), $serial)
    $certificate = [GeordiCertificateExtensions]::CopyPrivateKey($publicCertificate, $key)
    $password = New-RandomSecret
    [IO.File]::WriteAllText($CertificatePath, $certificate.ExportCertificatePem(), [Text.Encoding]::ASCII)
    Write-Utf8Secret $PrivateKeyPath $key.ExportPkcs8PrivateKeyPem()
    Write-Utf8Secret $PfxPasswordPath $password
    [IO.File]::WriteAllBytes($PfxPath, $certificate.Export(
        [Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
    $certificate.Dispose()
    $publicCertificate.Dispose()
    $key.Dispose()
}

try {
    $caKey = [Security.Cryptography.RSA]::Create(3072)
    $caRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=Geordi M19 Ephemeral Test CA', $caKey,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $caRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
    $caRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign, $true))
    $caRequest.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($caRequest.PublicKey, $false))
    $now = [DateTimeOffset]::UtcNow
    $caCertificate = $caRequest.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(2))
    $caPemPath = Join-Path $runtimeDirectory 'ca.pem'
    $caDerPath = Join-Path $runtimeDirectory 'ca.cer'
    [IO.File]::WriteAllText($caPemPath, $caCertificate.ExportCertificatePem(), [Text.Encoding]::ASCII)
    [IO.File]::WriteAllBytes($caDerPath, $caCertificate.Export(
        [Security.Cryptography.X509Certificates.X509ContentType]::Cert))

    New-SignedLeaf 'auth.localhost' @('auth.localhost') $caCertificate $caKey `
        (Join-Path $runtimeDirectory 'auth-cert.pem') (Join-Path $runtimeDirectory 'auth-key.pem') `
        (Join-Path $runtimeDirectory 'auth.p12') (Join-Path $runtimeDirectory 'auth.password')
    New-SignedLeaf 'geordi.localhost' @('geordi.localhost') $caCertificate $caKey `
        (Join-Path $runtimeDirectory 'geordi-cert.pem') (Join-Path $runtimeDirectory 'geordi-key.pem') `
        (Join-Path $runtimeDirectory 'geordi.p12') (Join-Path $runtimeDirectory 'geordi.password')

    # Verify the generated leaves chain to the exact CA created in this run and
    # carry the expected hostname SAN before publishing the trust anchor.
    foreach ($leafName in @('auth', 'geordi')) {
$leafPem = [IO.File]::ReadAllText((Join-Path $runtimeDirectory "$leafName-cert.pem"))
$leaf = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($leafPem)
        $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.CustomTrustStore.Add($caCertificate)
        $validChain = $chain.Build($leaf)
        $sanExtension = $leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
        $san = $sanExtension.Format($true)
        $expectedName = "$leafName.localhost"
        if (!$validChain -or $chain.ChainElements.Count -ne 2 -or
            $chain.ChainElements[1].Certificate.Thumbprint -ne $caCertificate.Thumbprint -or
            $san -notmatch [regex]::Escape($expectedName)) {
            throw "Generated $leafName TLS certificate did not chain to the exact ephemeral CA with the expected SAN (chain=$validChain elements=$($chain.ChainElements.Count) san=$san status=$($chain.ChainStatus.Status -join ','))."
        }
        $leaf.Dispose()
        $chain.Dispose()
    }
    [IO.File]::Copy((Join-Path $runtimeDirectory 'auth-cert.pem'), (Join-Path $runtimeDirectory 'auth-localhost-cert.pem'))
    [IO.File]::Copy((Join-Path $runtimeDirectory 'auth-key.pem'), (Join-Path $runtimeDirectory 'auth-localhost-key.pem'))

    Write-Utf8Secret (Join-Path $runtimeDirectory 'client-secret') (New-RandomSecret)
    Write-Utf8Secret (Join-Path $runtimeDirectory 'control-secret') (New-RandomSecret)
    Write-Utf8Secret (Join-Path $runtimeDirectory 'truststore.password') 'm19-local-test-store'
    $truststoreMount = "type=bind,source=$runtimeDirectory,target=/m19-runtime"
    & docker run --rm --mount $truststoreMount eclipse-temurin:21-jdk-jammy `
        keytool -importcert -noprompt -alias geordi-m19-test-ca -file /m19-runtime/ca.cer `
        -keystore /m19-runtime/truststore.p12 -storetype PKCS12 `
        -storepass:file /m19-runtime/truststore.password
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the Java truststore for the ephemeral M19 CA.' }

    if ($TrustForLocalMachine) {
        $thumbprint = $caCertificate.Thumbprint
        $subject = $caCertificate.Subject
        Invoke-GeordiTlsStoreActionBounded -Action VerifyAbsent -ExpectedThumbprint $thumbprint -ExpectedSubject $subject
        $script:GeordiImportedM19Thumbprint = $thumbprint
        [IO.File]::WriteAllText($publicThumbprintPath, $thumbprint, [Text.UTF8Encoding]::new($false))
        Write-Utf8Secret (Join-Path $runtimeDirectory 'browser-trust-thumbprint') $thumbprint
        Invoke-GeordiTlsStoreActionBounded -Action Import -CertificatePath $caDerPath `
            -ExpectedThumbprint $thumbprint -ExpectedSubject $subject
        Invoke-GeordiTlsStoreActionBounded -Action VerifyPresent -ExpectedThumbprint $thumbprint -ExpectedSubject $subject
    }

    Write-Output 'Ephemeral M19 TLS material created under .runtime/m19. No key or secret was printed.'
} catch {
    $originalError = $_
    $trustCleanupConfirmed = $true
    if ($script:GeordiImportedM19Thumbprint) {
        try {
            Invoke-GeordiTlsStoreActionBounded -Action Remove -ExpectedThumbprint $script:GeordiImportedM19Thumbprint `
                -ExpectedSubject $caCertificate.Subject
            Invoke-GeordiTlsStoreActionBounded -Action VerifyAbsent -ExpectedThumbprint $script:GeordiImportedM19Thumbprint `
                -ExpectedSubject $caCertificate.Subject
            $script:GeordiImportedM19Thumbprint = $null
        } catch { $trustCleanupConfirmed = $false }
    }
    if ($trustCleanupConfirmed) {
        Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $publicThumbprintPath) { Remove-Item -LiteralPath $publicThumbprintPath -Force -ErrorAction SilentlyContinue }
        throw $originalError
    }
    $privateFiles = @('auth-key.pem','geordi-key.pem','auth-localhost-key.pem','auth.p12','geordi.p12',
        'auth.password','geordi.password','client-secret','control-secret','truststore.password','truststore.p12')
    foreach ($privateName in $privateFiles) {
        $privatePath = Join-Path $runtimeDirectory $privateName
        if (Test-Path -LiteralPath $privatePath) { Remove-Item -LiteralPath $privatePath -Force -ErrorAction SilentlyContinue }
    }
    $privateRemainders = @($privateFiles | Where-Object { Test-Path -LiteralPath (Join-Path $runtimeDirectory $_) })
    if ($privateRemainders.Count -gt 0) {
        throw 'M19 TLS bootstrap failed; exact LocalMachine root cleanup and private-material cleanup both require operator recovery.'
    }
    throw "M19 TLS bootstrap failed and LocalMachine Root cleanup could not be confirmed; run-owned thumbprint manifest is retained for Finalize. Failure=$($originalError.Exception.GetType().Name)."
} finally {
    if ($caCertificate) { $caCertificate.Dispose() }
    if ($caKey) { $caKey.Dispose() }
}
