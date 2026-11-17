[CmdletBinding()]
param(
    [string] $RuntimeDirectory
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
    $RuntimeDirectory = Join-Path $repositoryRoot '.runtime/m19'
}
$RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)

function Stop-TlsMaterialValidation([string] $Message) {
    throw "M19 TLS material preflight failed: $Message"
}

function Require-TlsFile([string] $Name) {
    $path = Join-Path $RuntimeDirectory $Name
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        Stop-TlsMaterialValidation "required file '$Name' is missing."
    }
    return $path
}

function Read-TlsPassword([string] $Name) {
    $path = Require-TlsFile $Name
    # Remove line terminators only; do not trim or print the secret itself.
    return [IO.File]::ReadAllText($path).TrimEnd([char[]]@([char]13, [char]10))
}

function Assert-CertificateValidity(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
    [string] $Label
) {
    $now = [DateTime]::UtcNow
    if ($Certificate.NotBefore.ToUniversalTime() -gt $now) {
        Stop-TlsMaterialValidation "$Label is not valid yet."
    }
    if ($Certificate.NotAfter.ToUniversalTime() -le $now) {
        Stop-TlsMaterialValidation "$Label has expired."
    }
}

function Get-BasicConstraints(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
    [string] $Label
) {
    $extension = $Certificate.Extensions |
        Where-Object { $_.Oid.Value -eq '2.5.29.19' } |
        Select-Object -First 1
    if ($null -eq $extension) {
        Stop-TlsMaterialValidation "$Label has no Basic Constraints extension."
    }
    return [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
        $extension, $extension.Critical)
}

function Assert-DnsSubjectAlternativeName(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
    [string] $DnsName,
    [string] $Label
) {
    $extension = $Certificate.Extensions |
        Where-Object { $_.Oid.Value -eq '2.5.29.17' } |
        Select-Object -First 1
    if ($null -eq $extension) {
        Stop-TlsMaterialValidation "$Label has no Subject Alternative Name extension."
    }
    $formatted = $extension.Format($true)
    if ($formatted -notmatch "(?im)(?:^|,\\s*)DNS Name\\s*=\\s*$([regex]::Escape($DnsName))(?:\\s*,|$)") {
        Stop-TlsMaterialValidation "$Label does not contain the required DNS SAN '$DnsName'."
    }
}

function Assert-LeafCertificate(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
    [string] $DnsName,
    [string] $Label
) {
    Assert-CertificateValidity $Certificate $Label
    $constraints = Get-BasicConstraints $Certificate $Label
    if ($constraints.CertificateAuthority) {
        Stop-TlsMaterialValidation "$Label is marked as a CA."
    }
    Assert-DnsSubjectAlternativeName $Certificate $DnsName $Label
}

function Assert-ChainsToExactCa(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Leaf,
    [Security.Cryptography.X509Certificates.X509Certificate2] $Ca,
    [string] $Label
) {
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        [void]$chain.ChainPolicy.CustomTrustStore.Add($Ca)
        $valid = $chain.Build($Leaf)
        if (!$valid -or $chain.ChainElements.Count -ne 2 -or
            $chain.ChainElements[1].Certificate.Thumbprint -cne $Ca.Thumbprint) {
            Stop-TlsMaterialValidation "$Label does not chain to the exact configured M19 CA."
        }
    } finally {
        $chain.Dispose()
    }
}

$loadedCertificates = [Collections.Generic.List[IDisposable]]::new()
try {
    foreach ($name in @(
        'ca.pem', 'ca.cer',
        'auth-cert.pem', 'auth.p12', 'auth.password',
        'truststore.p12', 'truststore.password',
        'geordi-cert.pem', 'geordi-key.pem'
    )) {
        [void](Require-TlsFile $name)
    }

    # The PEM and DER CA files must identify the exact same certificate.
    $caPemText = [IO.File]::ReadAllText((Join-Path $RuntimeDirectory 'ca.pem'))
    try {
        $caPem = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($caPemText)
    } catch {
        Stop-TlsMaterialValidation 'ca.pem is not a readable X.509 certificate.'
    }
    $loadedCertificates.Add($caPem)
    try {
        $caDer = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Join-Path $RuntimeDirectory 'ca.cer'))
    } catch {
        Stop-TlsMaterialValidation 'ca.cer is not a readable X.509 certificate.'
    }
    $loadedCertificates.Add($caDer)
    if ($caPem.Thumbprint -cne $caDer.Thumbprint) {
        Stop-TlsMaterialValidation 'ca.pem and ca.cer do not identify the same CA certificate.'
    }
    Assert-CertificateValidity $caPem 'M19 CA certificate'
    $caConstraints = Get-BasicConstraints $caPem 'M19 CA certificate'
    if (!$caConstraints.CertificateAuthority) {
        Stop-TlsMaterialValidation 'M19 CA certificate is not marked as a CA.'
    }
    $caKeyUsageExtension = $caPem.Extensions |
        Where-Object { $_.Oid.Value -eq '2.5.29.15' } |
        Select-Object -First 1
    if ($null -eq $caKeyUsageExtension) {
        Stop-TlsMaterialValidation 'M19 CA certificate has no Key Usage extension.'
    }
    $caKeyUsage = [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        $caKeyUsageExtension, $caKeyUsageExtension.Critical)
    if (($caKeyUsage.KeyUsages -band [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign) -eq 0) {
        Stop-TlsMaterialValidation 'M19 CA certificate does not permit certificate signing.'
    }

    # The OIDC fixture consumes auth.p12; auth-cert.pem is its public counterpart.
    $authPassword = Read-TlsPassword 'auth.password'
    try {
        $authP12 = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Join-Path $RuntimeDirectory 'auth.p12'),
            $authPassword,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    } catch {
        Stop-TlsMaterialValidation 'auth.p12 cannot be opened with auth.password.'
    }
    $loadedCertificates.Add($authP12)
    if (!$authP12.HasPrivateKey) {
        Stop-TlsMaterialValidation 'auth.p12 does not contain the OIDC fixture private key.'
    }
    Assert-LeafCertificate $authP12 'auth.localhost' 'OIDC auth certificate'
    Assert-ChainsToExactCa $authP12 $caPem 'OIDC auth certificate'

    try {
        $authPem = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
            [IO.File]::ReadAllText((Join-Path $RuntimeDirectory 'auth-cert.pem')))
    } catch {
        Stop-TlsMaterialValidation 'auth-cert.pem is not a readable X.509 certificate.'
    }
    $loadedCertificates.Add($authPem)
    Assert-LeafCertificate $authPem 'auth.localhost' 'OIDC auth PEM certificate'
    if ($authPem.Thumbprint -cne $authP12.Thumbprint) {
        Stop-TlsMaterialValidation 'auth-cert.pem does not match the certificate in auth.p12.'
    }
    Assert-ChainsToExactCa $authPem $caPem 'OIDC auth PEM certificate'

    # Open the Java PKCS12 truststore without writing it or importing anything into OS trust.
    $trustPassword = Read-TlsPassword 'truststore.password'
    $trustCollection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    try {
        $trustBytes = [IO.File]::ReadAllBytes((Join-Path $RuntimeDirectory 'truststore.p12'))
        $trustCollection.Import(
            $trustBytes,
            $trustPassword,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    } catch {
        Stop-TlsMaterialValidation 'truststore.p12 cannot be opened with truststore.password.'
    }
    if ($trustCollection.Count -ne 1) {
        Stop-TlsMaterialValidation "truststore.p12 must contain exactly one certificate; found $($trustCollection.Count)."
    }
    if ($trustCollection[0].HasPrivateKey -or $trustCollection[0].Thumbprint -cne $caPem.Thumbprint) {
        Stop-TlsMaterialValidation 'truststore.p12 does not contain only the exact expected M19 CA certificate.'
    }

    # Nginx consumes the PEM/key pair directly; geordi.p12 has no runtime consumer.
    try {
        $geordiPair = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
            [IO.File]::ReadAllText((Join-Path $RuntimeDirectory 'geordi-cert.pem')),
            [IO.File]::ReadAllText((Join-Path $RuntimeDirectory 'geordi-key.pem')))
    } catch {
        Stop-TlsMaterialValidation 'geordi-cert.pem and geordi-key.pem are not a matching readable certificate/private-key pair.'
    }
    $loadedCertificates.Add($geordiPair)
    if (!$geordiPair.HasPrivateKey) {
        Stop-TlsMaterialValidation 'geordi-key.pem does not match geordi-cert.pem.'
    }
    Assert-LeafCertificate $geordiPair 'geordi.localhost' 'Frontend geordi certificate'
    Assert-ChainsToExactCa $geordiPair $caPem 'Frontend geordi certificate'

    Write-Output 'm19_tls_material_preflight=PASS ca=valid oidc=valid truststore=exact_ca frontend=valid mode=read_only'
} finally {
    foreach ($certificate in $loadedCertificates) {
        if ($null -ne $certificate) { $certificate.Dispose() }
    }
}
