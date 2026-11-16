[CmdletBinding()]
param(
    [ValidateSet('ValidateOnly', 'Run', 'Internal')]
    [string] $Mode = 'ValidateOnly',
    [ValidateSet('Import', 'VerifyPresent', 'Remove', 'VerifyAbsent')]
    [string] $InternalAction,
    [string] $CertificatePath,
    [string] $ExpectedThumbprint,
    [string] $ExpectedSubject
)

# Development/CI-only probe. The default mode is in-memory validation and never opens a certificate store.
$ErrorActionPreference = 'Stop'
$expectedHost = 'localhost'
$operationTimeoutSeconds = 15
$tlsTimeoutSeconds = 10

if (!('GeordiM19LocalMachineTlsFixture' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;

public static class GeordiM19LocalMachineTlsFixture
{
    public static X509Certificate2 AttachPrivateKey(X509Certificate2 certificate, RSA key)
    {
        return certificate.CopyWithPrivateKey(key);
    }

    public static async Task ServeOneAsync(TcpListener listener, X509Certificate2 certificate, int timeoutSeconds)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        using var client = await listener.AcceptTcpClientAsync(timeout.Token).ConfigureAwait(false);
        using var stream = new SslStream(client.GetStream(), false);
        var protocols = SslProtocols.Tls12 | SslProtocols.Tls13;
        await stream.AuthenticateAsServerAsync(certificate, false, protocols, false)
            .WaitAsync(TimeSpan.FromSeconds(timeoutSeconds)).ConfigureAwait(false);

        // Drain the complete HTTP request headers before closing the connection. On Windows,
        // closing a socket with unread request bytes can reset the connection and cause the
        // client to observe WSAECONNABORTED/10053 even though the TLS handshake succeeded.
        var requestBuffer = new byte[2048];
        var requestBytes = new MemoryStream();
        var headerComplete = false;
        while (!headerComplete)
        {
            var read = await stream.ReadAsync(requestBuffer, 0, requestBuffer.Length, timeout.Token)
                .ConfigureAwait(false);
            if (read == 0)
            {
                throw new IOException("HTTPS fixture peer closed before request headers completed.");
            }
            requestBytes.Write(requestBuffer, 0, read);
            if (requestBytes.Length > 16384)
            {
                throw new IOException("HTTPS fixture request headers exceeded the bounded limit.");
            }
            var bytes = requestBytes.GetBuffer();
            var length = checked((int)requestBytes.Length);
            for (var i = Math.Max(0, length - read - 3); i <= length - 4; i++)
            {
                if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10)
                {
                    headerComplete = true;
                    break;
                }
            }
        }

        var header = System.Text.Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n");
        var body = System.Text.Encoding.ASCII.GetBytes("ok");
        await stream.WriteAsync(header, 0, header.Length, timeout.Token).ConfigureAwait(false);
        await stream.WriteAsync(body, 0, body.Length, timeout.Token).ConfigureAwait(false);
        await stream.FlushAsync(timeout.Token).ConfigureAwait(false);
    }

    public static SocketsHttpHandler CreateLoopbackHandler()
    {
        var handler = new SocketsHttpHandler { UseProxy = false };
        handler.ConnectCallback = ConnectLoopbackAsync;
        return handler;
    }

    private static async ValueTask<Stream> ConnectLoopbackAsync(
        SocketsHttpConnectionContext context, CancellationToken cancellationToken)
    {
        var client = new TcpClient(AddressFamily.InterNetwork);
        try
        {
            await client.ConnectAsync(IPAddress.Loopback, context.DnsEndPoint.Port, cancellationToken)
                .ConfigureAwait(false);
            return client.GetStream();
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }
}
'@
}

function New-EphemeralAuthority([string] $DistinguishedName) {
    $key = [Security.Cryptography.RSA]::Create(3072)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $DistinguishedName, $key,
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
    $certificate = $request.CreateSelfSigned($now.AddMinutes(-1), $now.AddHours(1))
    return [pscustomobject]@{ Certificate = $certificate; Key = $key }
}

function New-EphemeralServerCertificate(
    [string] $CommonName,
    [string] $DnsName,
    [Security.Cryptography.X509Certificates.X509Certificate2] $Authority,
    [Security.Cryptography.RSA] $AuthorityKey
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
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
            [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment, $true))
    $names = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $names.AddDnsName($DnsName)
    $request.CertificateExtensions.Add($names.Build())
    $enhancedUsages = [Security.Cryptography.OidCollection]::new()
    [void]$enhancedUsages.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
            $enhancedUsages, $true))
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false))
    $serial = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Fill($serial)
    $now = [DateTimeOffset]::UtcNow
    $public = $request.Create($Authority, $now.AddMinutes(-1), $now.AddMinutes(30), $serial)
    try {
        $certificate = [GeordiM19LocalMachineTlsFixture]::AttachPrivateKey($public, $key)
    }
    finally {
        $public.Dispose()
    }
    return [pscustomobject]@{ Certificate = $certificate; Key = $key }
}

function New-SchannelBackedServerCertificate(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Leaf
) {
    $pkcs12 = $null
    $certificate = $null
    try {
        # Schannel cannot use the in-memory/ephemeral RSA key attached above as a server credential.
        # Round-trip through PKCS#12 and import into the machine key set without PersistKeySet or
        # EphemeralKeySet. The imported key is therefore OS-backed for Schannel during this
        # certificate object's lifetime and is removed when the certificate is disposed.
        $pkcs12 = $Leaf.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,
            [string]::Empty)
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $pkcs12,
            [string]::Empty,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet)

        if (!$certificate.HasPrivateKey -or $certificate.Thumbprint -ne $Leaf.Thumbprint) {
            throw 'Schannel leaf reload did not preserve the expected certificate/private key.'
        }

        $privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
        try {
            if ($null -eq $privateKey) {
                throw 'Schannel leaf reload did not expose an RSA private key.'
            }
            if ($privateKey -is [Security.Cryptography.RSACng] -and $privateKey.Key.IsEphemeral) {
                throw 'Schannel leaf reload still produced an ephemeral private key.'
            }
        }
        finally {
            if ($privateKey) { $privateKey.Dispose() }
        }

        return $certificate
    }
    catch {
        if ($certificate) { $certificate.Dispose() }
        throw
    }
    finally {
        # The PKCS#12 transport buffer contains the private key; wipe it explicitly.
        if ($pkcs12) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($pkcs12) }
    }
}

function Get-ExactCertificateMatches(
    [Security.Cryptography.X509Certificates.X509Certificate2Collection] $Certificates,
    [string] $Thumbprint
) {
    return @($Certificates | Where-Object { $_.Thumbprint -eq $Thumbprint })
}

function Assert-CertificatePair(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Authority,
    [Security.Cryptography.X509Certificates.X509Certificate2] $Leaf,
    [string] $DnsName
) {
    if (!$Authority.HasPrivateKey -or $Authority.Subject -ne $Authority.Issuer) {
        throw 'Generated authority failed self-signed CA validation.'
    }
    $caConstraint = $Authority.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
    $constraints = [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($caConstraint, $caConstraint.Critical)
    if (!$constraints.CertificateAuthority) { throw 'Generated authority is not a CA.' }

    $san = $Leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if ($null -eq $san -or $san.Format($true) -notmatch [regex]::Escape($DnsName)) {
        throw 'Generated leaf is missing the expected DNS SAN.'
    }
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        [void]$chain.ChainPolicy.CustomTrustStore.Add($Authority)
        if (!$chain.Build($Leaf) -or $chain.ChainElements.Count -ne 2 -or
            $chain.ChainElements[1].Certificate.Thumbprint -ne $Authority.Thumbprint) {
            throw 'Generated leaf did not chain to the exact ephemeral authority.'
        }
    }
    finally { $chain.Dispose() }
}

function Invoke-InternalStoreAction {
    if ($ExpectedThumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or
        [string]::IsNullOrWhiteSpace($ExpectedSubject)) {
        throw 'Internal store action requires an exact SHA-1 thumbprint and expected subject.'
    }
    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    try {
        $access = if ($InternalAction -in @('Import', 'Remove')) {
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite
        } else {
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly
        }
        $store.Open($access)
        $matches = Get-ExactCertificateMatches $store.Certificates $ExpectedThumbprint.ToUpperInvariant()
        switch ($InternalAction) {
            'Import' {
                if (!(Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
                    throw 'Public CA certificate file is missing.'
                }
                $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
                try {
                    $now = [DateTime]::UtcNow
                    $constraintExtension = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
                    $constraints = if ($constraintExtension) {
                        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
                            $constraintExtension, $constraintExtension.Critical)
                    } else { $null }
                    if ($certificate.Thumbprint -ne $ExpectedThumbprint.ToUpperInvariant() -or
                        $certificate.Subject -ne $ExpectedSubject -or $certificate.Issuer -ne $ExpectedSubject -or
                        $certificate.HasPrivateKey -or $null -eq $constraints -or
                        !$constraints.CertificateAuthority -or $certificate.NotBefore.ToUniversalTime() -gt $now -or
                        $certificate.NotAfter.ToUniversalTime() -le $now) {
                        throw 'Public CA identity validation failed.'
                    }
                    if ($matches.Count -ne 0) { throw 'Exact CA thumbprint already exists before import.' }
                    $store.Add($certificate)
                }
                finally { $certificate.Dispose() }
                'IMPORT_OK'
            }
            'VerifyPresent' {
                if ($matches.Count -ne 1) { throw "Expected exactly one matching root; found $($matches.Count)." }
                $certificate = $matches[0]
                if ($certificate.Subject -ne $ExpectedSubject -or $certificate.Issuer -ne $ExpectedSubject -or
                    $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
                    $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
                    throw 'Exact root subject, issuer, or validity check failed.'
                }
                'PRESENT_OK'
            }
            'Remove' {
                if ($matches.Count -ne 1) { throw "Expected exactly one matching root before removal; found $($matches.Count)." }
                $store.Remove($matches[0])
                'REMOVE_OK'
            }
            'VerifyAbsent' {
                if ($matches.Count -ne 0) { throw 'Exact root thumbprint remains after removal.' }
                'ABSENT_OK'
            }
        }
    }
    finally { $store.Close() }
}

function Invoke-BoundedInternalAction(
    [string] $Action,
    [string] $CertPath,
    [string] $Thumbprint,
    [string] $Subject
) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
        '-Mode', 'Internal', '-InternalAction', $Action, '-ExpectedThumbprint', $Thumbprint,
        '-ExpectedSubject', $Subject)) {
        [void]$start.ArgumentList.Add($argument)
    }
    if ($CertPath) {
        [void]$start.ArgumentList.Add('-CertificatePath')
        [void]$start.ArgumentList.Add($CertPath)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw "Could not start bounded $Action child process." }
        if (!$process.WaitForExit($operationTimeoutSeconds * 1000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw "Bounded $Action operation timed out."
        }
        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0 -or $stdout -notmatch "(?m)^$Action`_OK$|^(PRESENT|ABSENT)_OK$") {
            throw "Bounded $Action operation failed (exit=$($process.ExitCode))."
        }
    }
    finally { $process.Dispose() }
}

function Invoke-NormalHttpsCheck(
    [Security.Cryptography.X509Certificates.X509Certificate2] $Leaf,
    [string] $DnsName
) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $server = [GeordiM19LocalMachineTlsFixture]::ServeOneAsync($listener, $Leaf, $tlsTimeoutSeconds)
    $handler = [GeordiM19LocalMachineTlsFixture]::CreateLoopbackHandler()
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($tlsTimeoutSeconds)
    try {
        $response = $client.GetAsync("https://${DnsName}:$port/").WaitAsync(
            [TimeSpan]::FromSeconds($tlsTimeoutSeconds)).GetAwaiter().GetResult()
        try {
            if ($response.StatusCode -ne [Net.HttpStatusCode]::OK) { throw 'HTTPS fixture returned a non-200 status.' }
        }
        finally { $response.Dispose() }
        [void]$server.WaitAsync([TimeSpan]::FromSeconds($tlsTimeoutSeconds)).GetAwaiter().GetResult()
    }
    finally {
        $client.Dispose()
        $listener.Stop()
        try { [void]$server.WaitAsync([TimeSpan]::FromSeconds($tlsTimeoutSeconds)).GetAwaiter().GetResult() }
        catch { }
    }
}

function Invoke-ValidateOnly {
    $first = New-EphemeralAuthority 'CN=Geordi M19 Validation CA One'
    $second = New-EphemeralAuthority 'CN=Geordi M19 Validation CA Two'
    $leaf = $null
    try {
        if ($first.Certificate.Thumbprint -eq $second.Certificate.Thumbprint) {
            throw 'Independent authority generation produced a duplicate thumbprint.'
        }
        $leaf = New-EphemeralServerCertificate 'localhost' $expectedHost $first.Certificate $first.Key
        Assert-CertificatePair $first.Certificate $leaf.Certificate $expectedHost
        $collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        [void]$collection.Add($first.Certificate)
        [void]$collection.Add($second.Certificate)
        if ((Get-ExactCertificateMatches $collection $first.Certificate.Thumbprint).Count -ne 1 -or
            (Get-ExactCertificateMatches $collection ('0' * 40)).Count -ne 0) {
            throw 'Exact-thumbprint selector validation failed.'
        }
        'VALIDATE_ONLY PASS: unique authorities, CA/leaf chain, SAN, and exact-thumbprint selection validated; no certificate store was opened.'
    }
    finally {
        if ($leaf) { $leaf.Certificate.Dispose(); $leaf.Key.Dispose() }
        $first.Certificate.Dispose(); $first.Key.Dispose()
        $second.Certificate.Dispose(); $second.Key.Dispose()
    }
}

if ($Mode -eq 'Internal') {
    try {
        $internalIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $internalPrincipal = [Security.Principal.WindowsPrincipal]::new($internalIdentity)
        if (!$internalPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Internal LocalMachine operation lacks effective administrator rights.'
        }
        Invoke-InternalStoreAction
        exit 0
    }
    catch {
        [Console]::Error.WriteLine("INTERNAL_OPERATION_FAILED: $($_.Exception.GetType().Name)")
        exit 1
    }
}

if ($Mode -eq 'ValidateOnly') {
    Invoke-ValidateOnly
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'LOCALMACHINE PROBE REQUIRES RUNNER CONTEXT: current PowerShell is not an effective administrator; no certificate store was accessed.'
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-localmachine-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$seenThumbprints = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$results = [Collections.Generic.List[object]]::new()
try {
    for ($cycle = 1; $cycle -le 3; $cycle++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $authority = $null
        $leaf = $null
        $schannelLeaf = $null
        $thumbprint = $null
        $importMayHaveOccurred = $false
        $publicPath = Join-Path $tempRoot "ca-$cycle.cer"
        $subject = "CN=Geordi M19 LocalMachine Probe CA $cycle"
        $cycleResult = [ordered]@{ Cycle = $cycle; Thumbprint = ''; Import = 'NOT RUN'; ExactPresent = 'NOT RUN'; TLS = 'NOT RUN'; Remove = 'NOT RUN'; ExactAbsent = 'NOT RUN'; Cleanup = 'NOT RUN' }
        $cycleFailed = $false
        try {
            $authority = New-EphemeralAuthority $subject
            $thumbprint = $authority.Certificate.Thumbprint
            if (!$seenThumbprints.Add($thumbprint)) { throw 'CA thumbprint was reused in this run.' }
            $cycleResult.Thumbprint = $thumbprint
            $leaf = New-EphemeralServerCertificate 'localhost' $expectedHost $authority.Certificate $authority.Key
            Assert-CertificatePair $authority.Certificate $leaf.Certificate $expectedHost
            $schannelLeaf = New-SchannelBackedServerCertificate $leaf.Certificate
            [IO.File]::WriteAllBytes($publicPath, $authority.Certificate.Export(
                [Security.Cryptography.X509Certificates.X509ContentType]::Cert))

            $importMayHaveOccurred = $true
            Invoke-BoundedInternalAction 'Import' $publicPath $thumbprint $subject
            $cycleResult.Import = 'PASS'
            Invoke-BoundedInternalAction 'VerifyPresent' '' $thumbprint $subject
            $cycleResult.ExactPresent = 'PASS'
            Invoke-NormalHttpsCheck $schannelLeaf $expectedHost
            $cycleResult.TLS = 'PASS'
            Invoke-BoundedInternalAction 'Remove' '' $thumbprint $subject
            $importMayHaveOccurred = $false
            $cycleResult.Remove = 'PASS'
            Invoke-BoundedInternalAction 'VerifyAbsent' '' $thumbprint $subject
            $cycleResult.ExactAbsent = 'PASS'
        }
        catch {
            $cycleResult.Failure = $_.Exception.GetType().Name
            if ($importMayHaveOccurred -and $thumbprint) {
                try {
                    try {
                        Invoke-BoundedInternalAction 'VerifyPresent' '' $thumbprint $subject
                        Invoke-BoundedInternalAction 'Remove' '' $thumbprint $subject
                    }
                    catch {
                        # A failed/uncertain import is safe only when exact absence is proven.
                    }
                    Invoke-BoundedInternalAction 'VerifyAbsent' '' $thumbprint $subject
                    $cycleResult.Cleanup = 'PASS (failure path)'
                }
                catch { $cycleResult.Cleanup = 'FAIL (exact removal/absence not proven)' }
            }
            else { $cycleResult.Cleanup = 'PASS (store was not mutated)' }
            $cycleFailed = $true
        }
        finally {
            # Disposing the Schannel-loaded certificate releases its temporary machine-key container
            # because PersistKeySet was intentionally not used.
            if ($schannelLeaf) { $schannelLeaf.Dispose() }
            if ($leaf) { $leaf.Certificate.Dispose(); $leaf.Key.Dispose() }
            if ($authority) { $authority.Certificate.Dispose(); $authority.Key.Dispose() }
            try {
                if (Test-Path -LiteralPath $publicPath) { Remove-Item -LiteralPath $publicPath -Force }
                if (Test-Path -LiteralPath $publicPath) { throw 'Public CA temp file remains.' }
                if ($cycleResult.ExactAbsent -eq 'PASS' -or $cycleResult.Cleanup -eq 'PASS (store was not mutated)') {
                    $cycleResult.Cleanup = 'PASS'
                }
            }
            catch { $cycleResult.Cleanup = 'FAIL (temporary artifact cleanup not proven)' }
            $watch.Stop()
            $cycleResult.DurationSeconds = [Math]::Round($watch.Elapsed.TotalSeconds, 2)
            $results.Add([pscustomobject]$cycleResult)
        }
        if ($cycleFailed) {
            $results | Select-Object -Last 1 | ConvertTo-Json -Compress
            throw 'LOCALMACHINE TRUST MODEL NOT PROVEN.'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    if (Test-Path -LiteralPath $tempRoot) { throw 'Temporary LocalMachine probe directory remains after cleanup.' }
}

$results | Format-Table -AutoSize
if ($results.Count -ne 3 -or @($results | Where-Object { $_.Import -ne 'PASS' -or $_.ExactPresent -ne 'PASS' -or $_.TLS -ne 'PASS' -or $_.Remove -ne 'PASS' -or $_.ExactAbsent -ne 'PASS' -or $_.Cleanup -ne 'PASS' }).Count -ne 0) {
    throw 'LOCALMACHINE TRUST MODEL NOT PROVEN.'
}
'LOCALMACHINE EPHEMERAL TRUST MODEL PROVEN FOR WINDOWS DEV/CI'
