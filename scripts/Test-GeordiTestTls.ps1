[CmdletBinding()]
param(
    [string] $Uri = 'https://geordi.localhost:8443/actuator/health/liveness',
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [int] $TimeoutSeconds = 20
)
$ErrorActionPreference = 'Stop'
$runtime = Join-Path $RepositoryRoot '.runtime/m19'
$thumbprintPath = Join-Path $runtime 'browser-trust-thumbprint'
$caPath = Join-Path $runtime 'ca.cer'
if (!(Test-Path $thumbprintPath -PathType Leaf) -or !(Test-Path $caPath -PathType Leaf)) {
    throw 'M19 TLS trust is not initialized; refusing native HTTPS validation.'
}
$thumbprint = [IO.File]::ReadAllText($thumbprintPath).Trim()
$ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path -LiteralPath $caPath).Path)
if ($ca.Thumbprint -ne $thumbprint) { throw 'Recorded CA thumbprint does not match the generated CA file.' }
$store = [Security.Cryptography.X509Certificates.X509Store]::new(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    if (@($store.Certificates | Where-Object Thumbprint -eq $thumbprint).Count -ne 1) {
        throw 'Exact M19 CA thumbprint is not present in LocalMachine Root.'
    }
} finally { $store.Close() }
if (-not ('GeordiWindowsTlsLoopback' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public static class GeordiWindowsTlsLoopback {
    public static ValueTask<Stream> Connect(SocketsHttpConnectionContext context, CancellationToken token) {
        if (!String.Equals(context.DnsEndPoint.Host, "geordi.localhost", StringComparison.OrdinalIgnoreCase)
                || context.DnsEndPoint.Port != 8443) throw new InvalidOperationException("Unexpected TLS probe target.");
        return ConnectLoopback(context.DnsEndPoint.Port, token);
    }
    private static async ValueTask<Stream> ConnectLoopback(int port, CancellationToken token) {
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp);
        try { await socket.ConnectAsync(new IPEndPoint(IPAddress.Loopback, port), token).ConfigureAwait(false); return new NetworkStream(socket, true); }
        catch { socket.Dispose(); throw; }
    }
}
'@
}
$handler = [Net.Http.SocketsHttpHandler]::new()
$handler.ConnectCallback = [Func[Net.Http.SocketsHttpConnectionContext,Threading.CancellationToken,Threading.Tasks.ValueTask[IO.Stream]]] [GeordiWindowsTlsLoopback]::Connect
$client = [Net.Http.HttpClient]::new($handler, $true)
$client.Timeout = [TimeSpan]::FromSeconds(5)
$lastFailureCategory = 'not-connected'
$lastStatus = 0
try {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            $response.Dispose()
            if ($status -eq 200) {
                Write-Output "Windows-native TLS passed: trusted CA thumbprint present, HTTPS status 200."
                return
            }
        } catch {
            $status = 0
            $exceptionName = $_.Exception.GetBaseException().GetType().Name
            $lastFailureCategory = if ($exceptionName -match 'Authentication|Certificate|Cryptographic') {
                'tls-certificate-validation'
            } elseif ($exceptionName -match 'Socket|NameResolution|HttpRequest') {
                'connection-or-name-resolution'
            } else {
                'transport-failure'
            }
        }
        $lastStatus = $status
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Windows-native HTTPS validation did not return 200 before the bounded deadline (category=$lastFailureCategory; status=$lastStatus)."
} finally { $client.Dispose(); $ca.Dispose() }
