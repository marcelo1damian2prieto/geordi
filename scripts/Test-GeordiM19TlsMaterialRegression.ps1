[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeDirectory = Join-Path $repositoryRoot '.runtime/m19'
$validator = Join-Path $PSScriptRoot 'Test-GeordiM19TlsMaterial.ps1'
if (!(Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
    throw 'M19 TLS material regression requires a generated .runtime/m19 fixture.'
}

function Assert-TlsRegression([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M19 TLS material regression failed: $Message" }
}

function New-TlsNegativeFixture([string] $Name) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("geordi-m19-tls-test-{0}-{1}" -f $Name,[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Copy-Item -Path (Join-Path $runtimeDirectory '*') -Destination $path -Recurse -Force
    return $path
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
    $key = [Security.Cryptography.RSA]::Create(2048)
    $certificate = $null
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=Geordi M19 Expired Test CA',
            $key,
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
        $request.CertificateExtensions.Add(
            [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign, $true))
        $now = [DateTimeOffset]::UtcNow
        if ($Expired) {
            $certificate = $request.CreateSelfSigned($now.AddDays(-3), $now.AddDays(-1))
        } else {
            $certificate = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(2))
        }
        [IO.File]::WriteAllText((Join-Path $Path 'ca.pem'), $certificate.ExportCertificatePem(), [Text.Encoding]::ASCII)
        [IO.File]::WriteAllBytes((Join-Path $Path 'ca.cer'), $certificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    } finally {
        if ($certificate) { $certificate.Dispose() }
        $key.Dispose()
    }
}

# Positive control: validate the real runtime fixture before exercising negative cases.
& $validator -RuntimeDirectory $runtimeDirectory | Out-Null
Write-Output 'm19_tls_material_positive=PASS'

$fixtures = [System.Collections.Generic.List[string]]::new()
try {
    $missingPassword = New-TlsNegativeFixture 'missing-password'
    $fixtures.Add($missingPassword)
    Remove-Item -LiteralPath (Join-Path $missingPassword 'truststore.password') -Force
    Assert-TlsFixtureRejected $missingPassword 'missing truststore password'
    Write-Output 'm19_tls_material_missing_file=FAIL_CLOSED'

    $wrongPassword = New-TlsNegativeFixture 'wrong-password'
    $fixtures.Add($wrongPassword)
    [IO.File]::WriteAllText((Join-Path $wrongPassword 'truststore.password'), 'not-the-truststore-password')
    Assert-TlsFixtureRejected $wrongPassword 'incorrect truststore password'
    Write-Output 'm19_tls_material_wrong_password=FAIL_CLOSED'

    $wrongSan = New-TlsNegativeFixture 'wrong-san'
    $fixtures.Add($wrongSan)
    Copy-Item -LiteralPath (Join-Path $wrongSan 'geordi-cert.pem') -Destination (Join-Path $wrongSan 'auth-cert.pem') -Force
    Assert-TlsFixtureRejected $wrongSan 'auth certificate with incorrect DNS SAN'
    Write-Output 'm19_tls_material_wrong_san=FAIL_CLOSED'

    $wrongChain = New-TlsNegativeFixture 'wrong-chain'
    $fixtures.Add($wrongChain)
    Set-ReplacementCa $wrongChain $false
    Assert-TlsFixtureRejected $wrongChain 'leaf certificate signed by a different CA'
    Write-Output 'm19_tls_material_wrong_chain=FAIL_CLOSED'

    $expiredCa = New-TlsNegativeFixture 'expired-ca'
    $fixtures.Add($expiredCa)
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
