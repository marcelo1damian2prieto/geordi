[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$validator = Join-Path $PSScriptRoot 'Test-GeordiM19TlsMaterial.ps1'
if (!(Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw 'M19 TLS material regression cannot find Test-GeordiM19TlsMaterial.ps1.'
}

function Assert-TlsRegression([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M19 TLS material regression failed: $Message" }
}

function New-TlsFixtureDirectory([string] $Name) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("geordi-m19-tls-test-{0}-{1}" -f $Name,[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-TestCa([bool] $Expired = $false) {
    $key = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=Geordi M19 Ephemeral Test CA',
            $key,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign, $true))
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false))
        $now = [DateTimeOffset]::UtcNow
        if ($Expired) {
            $certificate = $request.CreateSelfSigned($now.AddDays(-3), $now.AddDays(-1))
        } else {
            $certificate = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(2))
        }
        # Keep the issuer key alive until all leaf certificates have been signed.
        return [pscustomobject]@{ Certificate = $certificate; Key = $key }
    } catch {
        $key.Dispose()
        throw
    }
}

function Write-TestLeaf(
    [string] $Directory,
    [string] $Name,
    [Security.Cryptography.X509Certificates.X509Certificate2] $Ca
) {
    $key = [Security.Cryptography.RSA]::Create(2048)
    $publicCertificate = $null
    $certificate = $null
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$Name.localhost",
            $key,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
        $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName("$Name.localhost")
        $request.CertificateExtensions.Add($san.Build())
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false))
        $serial = [byte[]]::new(16)
        [Security.Cryptography.RandomNumberGenerator]::Fill($serial)
        $publicCertificate = $request.Create($Ca, [DateTimeOffset]::UtcNow.AddMinutes(-5), $Ca.NotAfter.AddMinutes(-1), $serial)
        $certificate = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($publicCertificate, $key)

        [IO.File]::WriteAllText(
            (Join-Path $Directory "$Name-cert.pem"),
            $certificate.ExportCertificatePem(),
            [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText(
            (Join-Path $Directory "$Name-key.pem"),
            $key.ExportPkcs8PrivateKeyPem(),
            [Text.Encoding]::ASCII)

        if ($Name -eq 'auth') {
            $password = 'regression-auth-password'
            [IO.File]::WriteAllText((Join-Path $Directory 'auth.password'), $password, [Text.Encoding]::ASCII)
            [IO.File]::WriteAllBytes(
                (Join-Path $Directory 'auth.p12'),
                $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
        }
    } finally {
        if ($certificate) { $certificate.Dispose() }
        if ($publicCertificate) { $publicCertificate.Dispose() }
        $key.Dispose()
    }
}

function New-ValidTlsFixture([string] $Directory) {
    $caMaterial = New-TestCa
    $ca = $caMaterial.Certificate
    try {
        [IO.File]::WriteAllText((Join-Path $Directory 'ca.pem'), $ca.ExportCertificatePem(), [Text.Encoding]::ASCII)
        [IO.File]::WriteAllBytes(
            (Join-Path $Directory 'ca.cer'),
            $ca.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))

        Write-TestLeaf $Directory 'auth' $ca
        Write-TestLeaf $Directory 'geordi' $ca

        $trustPassword = 'regression-truststore-password'
        [IO.File]::WriteAllText((Join-Path $Directory 'truststore.password'), $trustPassword, [Text.Encoding]::ASCII)
        $trustedCertificates = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        [void]$trustedCertificates.Add([Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Join-Path $Directory 'ca.cer')))
        try {
            $trustBytes = $trustedCertificates.Export(
                [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
                $trustPassword)
            [IO.File]::WriteAllBytes((Join-Path $Directory 'truststore.p12'), $trustBytes)
        } finally {
            foreach ($certificate in $trustedCertificates) { $certificate.Dispose() }
        }
    } finally {
        $ca.Dispose()
        $caMaterial.Key.Dispose()
    }
}

function Assert-TlsFixtureRejected([string] $Path, [string] $Label) {
    $rejected = $false
    try {
        & $validator -RuntimeDirectory $Path | Out-Null
    } catch {
        $rejected = $true
    }
    Assert-TlsRegression $rejected "$Label was accepted."
}

function Set-ReplacementCa([string] $Path, [bool] $Expired) {
    $replacementMaterial = New-TestCa -Expired:$Expired
    $replacement = $replacementMaterial.Certificate
    try {
        [IO.File]::WriteAllText((Join-Path $Path 'ca.pem'), $replacement.ExportCertificatePem(), [Text.Encoding]::ASCII)
        [IO.File]::WriteAllBytes(
            (Join-Path $Path 'ca.cer'),
            $replacement.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    } finally {
        $replacement.Dispose()
        $replacementMaterial.Key.Dispose()
    }
}

$fixtures = [System.Collections.Generic.List[string]]::new()
try {
    # The positive control is generated in isolation; regression does not depend
    # on the state, age, or existence of the developer's .runtime/m19 directory.
    $positive = New-TlsFixtureDirectory 'positive'
    $fixtures.Add($positive)
    New-ValidTlsFixture $positive
    & $validator -RuntimeDirectory $positive | Out-Null
    Write-Output 'm19_tls_material_positive=PASS'

    $missingPassword = New-TlsFixtureDirectory 'missing-password'
    $fixtures.Add($missingPassword)
    New-ValidTlsFixture $missingPassword
    Remove-Item -LiteralPath (Join-Path $missingPassword 'truststore.password') -Force
    Assert-TlsFixtureRejected $missingPassword 'missing truststore password'
    Write-Output 'm19_tls_material_missing_file=FAIL_CLOSED'

    $wrongAuthPassword = New-TlsFixtureDirectory 'wrong-auth-password'
    $fixtures.Add($wrongAuthPassword)
    New-ValidTlsFixture $wrongAuthPassword
    [IO.File]::WriteAllText((Join-Path $wrongAuthPassword 'auth.password'), 'incorrect-password')
    Assert-TlsFixtureRejected $wrongAuthPassword 'incorrect OIDC PKCS12 password'
    Write-Output 'm19_tls_material_wrong_auth_password=FAIL_CLOSED'

    $wrongTrustPassword = New-TlsFixtureDirectory 'wrong-trust-password'
    $fixtures.Add($wrongTrustPassword)
    New-ValidTlsFixture $wrongTrustPassword
    [IO.File]::WriteAllText((Join-Path $wrongTrustPassword 'truststore.password'), 'incorrect-password')
    Assert-TlsFixtureRejected $wrongTrustPassword 'incorrect truststore password'
    Write-Output 'm19_tls_material_wrong_truststore_password=FAIL_CLOSED'

    $wrongSan = New-TlsFixtureDirectory 'wrong-san'
    $fixtures.Add($wrongSan)
    New-ValidTlsFixture $wrongSan
    Copy-Item -LiteralPath (Join-Path $wrongSan 'geordi-cert.pem') -Destination (Join-Path $wrongSan 'auth-cert.pem') -Force
    Assert-TlsFixtureRejected $wrongSan 'auth certificate with incorrect DNS SAN'
    Write-Output 'm19_tls_material_wrong_san=FAIL_CLOSED'

    $wrongFrontendKey = New-TlsFixtureDirectory 'wrong-frontend-key'
    $fixtures.Add($wrongFrontendKey)
    New-ValidTlsFixture $wrongFrontendKey
    Copy-Item -LiteralPath (Join-Path $wrongFrontendKey 'auth-key.pem') -Destination (Join-Path $wrongFrontendKey 'geordi-key.pem') -Force
    Assert-TlsFixtureRejected $wrongFrontendKey 'frontend certificate/private-key mismatch'
    Write-Output 'm19_tls_material_wrong_frontend_key=FAIL_CLOSED'

    $wrongChain = New-TlsFixtureDirectory 'wrong-chain'
    $fixtures.Add($wrongChain)
    New-ValidTlsFixture $wrongChain
    Set-ReplacementCa $wrongChain $false
    Assert-TlsFixtureRejected $wrongChain 'leaf certificate signed by a different CA'
    Write-Output 'm19_tls_material_wrong_chain=FAIL_CLOSED'

    $expiredCa = New-TlsFixtureDirectory 'expired-ca'
    $fixtures.Add($expiredCa)
    New-ValidTlsFixture $expiredCa
    Set-ReplacementCa $expiredCa $true
    Assert-TlsFixtureRejected $expiredCa 'expired CA certificate'
    Write-Output 'm19_tls_material_expired_ca=FAIL_CLOSED'

    Write-Output 'm19_tls_material_regression=PASS'
} finally {
    foreach ($fixture in $fixtures) {
        if (Test-Path -LiteralPath $fixture) {
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
