# Dot-source this helper in the runspace that will make authenticated requests.
# Fixture tokens stay in process memory and are also appended to the private M19
# evidence sink while a runtime leak-scan run is active.

$script:GeordiAuthState = @{}
$script:GeordiPrivateTokenSentinelOverride = $null

function Add-GeordiPrivateTokenSentinel {
    param([Parameter(Mandatory)][string] $Token, [Parameter(Mandatory)][string] $RepositoryRoot)
    if ($script:GeordiPrivateTokenSentinelOverride) {
        & $script:GeordiPrivateTokenSentinelOverride $Token
        return
    }
    $pointerPath = Join-Path $RepositoryRoot '.runtime/m19-capture-root.txt'
    if (!(Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return }
    $captureRoot = [IO.Path]::GetFullPath([IO.File]::ReadAllText($pointerPath).Trim())
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedParent -or
            (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
        throw 'Active M19 evidence token root is invalid.'
    }
    $sentinelPath = Join-Path $captureRoot 'runtime-token-sentinels.txt'
    if (!(Test-Path -LiteralPath $sentinelPath -PathType Leaf)) { throw 'Active M19 evidence token sink is missing.' }
    $mutexName = 'GeordiM19TokenSentinels-' + ([Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sentinelPath))).Substring(0,24))
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    try {
        if (!$mutex.WaitOne([TimeSpan]::FromSeconds(5))) { throw 'Private token evidence lock timed out.' }
        [IO.File]::AppendAllText($sentinelPath, $Token + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    } finally {
        if ($mutex) { try { $mutex.ReleaseMutex() } catch { } ; $mutex.Dispose() }
    }
}

function Get-GeordiApplicationBaseUrl {
    [CmdletBinding()]
    param([string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)
    $configured = [Environment]::GetEnvironmentVariable('GEORDI_PUBLIC_BASE_URL', 'Process')
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = 'https://geordi.localhost:8443' }
    $uri = [uri]$configured
    if (!$uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'geordi.localhost' -or $uri.Port -ne 8443 -or $uri.AbsolutePath -ne '/') {
        throw 'M19 application origin must be the configured trusted HTTPS ingress.'
    }
    return $configured.TrimEnd('/')
}
$geordiCaPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path '.runtime/m19/ca.pem'
if (Test-Path -LiteralPath $geordiCaPath -PathType Leaf) {
    [Environment]::SetEnvironmentVariable('GEORDI_M19_CA_PATH', (Resolve-Path -LiteralPath $geordiCaPath).Path, 'Process')
}

if (-not ('GeordiFixtureConnectCallback' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Net.Security;
using System.Threading;
using System.Threading.Tasks;

public static class GeordiFixtureConnectCallback {
    public static ValueTask<Stream> Connect(SocketsHttpConnectionContext context, CancellationToken cancellationToken) {
        var isFixture = String.Equals(context.DnsEndPoint.Host, "auth.localhost", StringComparison.Ordinal)
                && context.DnsEndPoint.Port == 9444;
        var isBrowserIssuer = String.Equals(context.DnsEndPoint.Host, "auth.localhost", StringComparison.Ordinal)
                && context.DnsEndPoint.Port == 9445;
        var isIngress = String.Equals(context.DnsEndPoint.Host, "geordi.localhost", StringComparison.Ordinal)
                && context.DnsEndPoint.Port == 8443;
        if (!isFixture && !isBrowserIssuer && !isIngress) {
            throw new InvalidOperationException("Unexpected fixture endpoint.");
        }
        return ConnectLoopback(context.DnsEndPoint.Port, cancellationToken);
    }

    private static async ValueTask<Stream> ConnectLoopback(int port, CancellationToken cancellationToken) {
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp);
        try {
            await socket.ConnectAsync(new IPEndPoint(IPAddress.Loopback, port), cancellationToken).ConfigureAwait(false);
            return new NetworkStream(socket, true);
        } catch {
            socket.Dispose();
            throw;
        }
    }
}

public static class GeordiFixtureCertificateValidation {
    public static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
        if ((errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0
                || (errors & SslPolicyErrors.RemoteCertificateNotAvailable) != 0) return false;
        var caPath = Environment.GetEnvironmentVariable("GEORDI_M19_CA_PATH");
        if (String.IsNullOrWhiteSpace(caPath) || !System.IO.File.Exists(caPath)) return false;
        using var root = X509CertificateLoader.LoadCertificateFromFile(caPath);
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(root);
        using var leaf = new X509Certificate2(certificate);
        return chain.Build(leaf);
    }
}

public static class GeordiFixtureDelegates {
    public static RemoteCertificateValidationCallback CertificateValidator() =>
        new RemoteCertificateValidationCallback(GeordiFixtureCertificateValidation.Validate);
    public static Func<SocketsHttpConnectionContext, CancellationToken, ValueTask<Stream>> Connector() =>
        new Func<SocketsHttpConnectionContext, CancellationToken, ValueTask<Stream>>(GeordiFixtureConnectCallback.Connect);
}
'@
}

function Initialize-GeordiAuthentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('VIEWER', 'OPERATOR', 'EVALUATOR', 'REGRESSION')]
        [string] $Identity,
        [switch] $AlternateOperator,
        [switch] $WrongAudience,
        [switch] $IdToken,
        [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    )
    if ($AlternateOperator -and $Identity -cne 'OPERATOR') {
        throw 'The alternate fixture principal is available only for OPERATOR permission-conflict tests.'
    }

    $runtime = Join-Path $RepositoryRoot '.runtime/m19'
    $secretPath = Join-Path $runtime 'control-secret'
    $caPath = Join-Path $runtime 'ca.pem'
    if (!(Test-Path -LiteralPath $secretPath -PathType Leaf) -or
        !(Test-Path -LiteralPath $caPath -PathType Leaf)) {
        throw 'M19 fixture authentication is unavailable; restart the stack and initialize a new runspace.'
    }

    $secret = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $secretPath)).Trim()
    if ($secret.Length -lt 32) { throw 'M19 fixture authentication configuration is invalid.' }
    $handler = [Net.Http.SocketsHttpHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.SslOptions.RemoteCertificateValidationCallback = [GeordiFixtureDelegates]::CertificateValidator()
    $handler.ConnectCallback = [GeordiFixtureDelegates]::Connector()

    # Route only the fixture control listener to loopback. TLS still validates the
    # auth.localhost certificate against the ephemeral CA; no validation bypass exists.
    $client = [Net.Http.HttpClient]::new($handler, $true)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,
            'https://auth.localhost:9444/__control/token')
        $request.Headers.Add('X-Geordi-Fixture-Control', $secret)
        $request.Content = [Net.Http.StringContent]::new(
            (@{ identity = $Identity; alternateOperator = [bool]$AlternateOperator;
                wrongAudience = [bool]$WrongAudience; idToken = [bool]$IdToken } | ConvertTo-Json -Compress),
            [Text.Encoding]::UTF8, 'application/json')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            if (!$response.IsSuccessStatusCode) { throw 'M19 fixture rejected authentication; request was not sent.' }
            $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($payload.access_token) -or $payload.token_type -cne 'Bearer' -or
                [int]$payload.expires_in -lt 30 -or [int]$payload.expires_in -gt 240) {
                throw 'M19 fixture returned an invalid access token response.'
            }
            $script:GeordiAuthState = @{
                Identity = $Identity
                AlternateOperator = [bool]$AlternateOperator
                WrongAudience = [bool]$WrongAudience
                IdToken = [bool]$IdToken
                Token = [string]$payload.access_token
                ExpiresAt = [DateTimeOffset]::UtcNow.AddSeconds([int]$payload.expires_in)
                RepositoryRoot = $RepositoryRoot
            }
            Add-GeordiPrivateTokenSentinel -Token ([string]$payload.access_token) -RepositoryRoot $RepositoryRoot
        } finally {
            $response.Dispose()
            $request.Dispose()
        }
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Ensure-GeordiAuthenticationReady {
    [CmdletBinding()]
    param()
    if (!$script:GeordiAuthState.Token -or
        $script:GeordiAuthState.ExpiresAt -le [DateTimeOffset]::UtcNow.AddSeconds(20)) {
        if (!$script:GeordiAuthState.Identity) { throw 'M19 authentication identity is not initialized.' }
        $identity = $script:GeordiAuthState.Identity
        $alternate = [bool]$script:GeordiAuthState.AlternateOperator
        $wrongAudience = [bool]$script:GeordiAuthState.WrongAudience
        $idToken = [bool]$script:GeordiAuthState.IdToken
        $root = $script:GeordiAuthState.RepositoryRoot
        Initialize-GeordiAuthentication -Identity $identity -AlternateOperator:$alternate `
            -WrongAudience:$wrongAudience -IdToken:$idToken -RepositoryRoot $root
    }
}

function New-GeordiHttpClient {
    [CmdletBinding()]
    param([ValidateRange(1,120)][int] $TimeoutSeconds = 15)
    $handler = [Net.Http.SocketsHttpHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.SslOptions.RemoteCertificateValidationCallback = [GeordiFixtureDelegates]::CertificateValidator()
    $handler.ConnectCallback = [GeordiFixtureDelegates]::Connector()
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    return $client
}

function Invoke-GeordiHttpsRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET','HEAD','POST','PUT','PATCH','DELETE')][string] $Method = 'GET',
        [AllowNull()] $Body,
        [string] $ContentType = 'application/json',
        [int] $TimeoutSeconds = 15,
        [switch] $Anonymous,
        [switch] $AllowOidcBrowserEndpoint,
        [string] $Cookie,
        [string] $CsrfToken,
        [ValidateSet('NONE','INVALID_SIGNATURE','DUPLICATE_AUTHORIZATION','DUPLICATE_SESSION_COOKIE','UNKNOWN_SESSION_WITH_BEARER')]
        [string] $SecurityCase = 'NONE'
    )
    $uriValue = [uri]$Uri
    $isIngress = $uriValue.IsAbsoluteUri -and $uriValue.Scheme -ceq 'https' -and
        $uriValue.Host -ceq 'geordi.localhost' -and $uriValue.Port -eq 8443
    $isBrowserIssuer = $AllowOidcBrowserEndpoint -and $Anonymous -and $uriValue.IsAbsoluteUri -and
        $uriValue.Scheme -ceq 'https' -and $uriValue.Host -ceq 'auth.localhost' -and $uriValue.Port -eq 9445
    if (!$isIngress -and !$isBrowserIssuer) {
        throw 'M19 HTTPS requests must target the configured ingress.'
    }
    if (!$Anonymous) { Ensure-GeordiAuthenticationReady }
    $client = New-GeordiHttpClient -TimeoutSeconds $TimeoutSeconds
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $uriValue)
    if (!$Anonymous) {
        $token = [string]$script:GeordiAuthState.Token
        if ($SecurityCase -eq 'INVALID_SIGNATURE') {
            $segments = $token.Split('.')
            $first = $segments[2].Substring(0, 1)
            $segments[2] = $(if ($first -ceq 'A') { 'B' } else { 'A' }) + $segments[2].Substring(1)
            $token = [string]::Join('.', $segments)
        }
        Add-GeordiPrivateTokenSentinel -Token $token -RepositoryRoot $script:GeordiAuthState.RepositoryRoot
        if ($SecurityCase -eq 'DUPLICATE_AUTHORIZATION') {
            [void]$request.Headers.TryAddWithoutValidation('Authorization', [string[]]@("Bearer $token", "Bearer $token"))
        } else {
            $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        }
    }
    if ($Cookie) { [void]$request.Headers.TryAddWithoutValidation('Cookie', $Cookie) }
    if ($Method -eq 'POST' -and $CsrfToken) { [void]$request.Headers.TryAddWithoutValidation('X-CSRF-TOKEN', $CsrfToken) }
    if ($SecurityCase -eq 'DUPLICATE_SESSION_COOKIE') {
        [void]$request.Headers.TryAddWithoutValidation('Cookie', '__Host-GEORDISESSION=unknown-one; __Host-GEORDISESSION=unknown-two')
    } elseif ($SecurityCase -eq 'UNKNOWN_SESSION_WITH_BEARER') {
        [void]$request.Headers.TryAddWithoutValidation('Cookie', '__Host-GEORDISESSION=unknown-session')
    }
    if ($null -ne $Body) {
        $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, $ContentType)
    }
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                Headers = $response.Headers
                ContentHeaders = $response.Content.Headers
                ResponseMessage = $response
            }
        } finally { $response.Dispose() }
    } finally { $request.Dispose(); $client.Dispose() }
}

function Invoke-GeordiAuthenticatedRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET','HEAD','POST','PUT','PATCH','DELETE')][string] $Method = 'GET',
        [AllowNull()] $Body,
        [string] $ContentType = 'application/json',
        [int] $TimeoutSeconds = 15,
        [ValidateSet('NONE','INVALID_SIGNATURE','DUPLICATE_AUTHORIZATION','DUPLICATE_SESSION_COOKIE','UNKNOWN_SESSION_WITH_BEARER')]
        [string] $SecurityCase = 'NONE'
    )
    Ensure-GeordiAuthenticationReady
    $uriValue = [uri]$Uri
    if (!$uriValue.IsAbsoluteUri -or $uriValue.Scheme -cne 'https' -or
        $uriValue.Host -cne 'geordi.localhost' -or $uriValue.Port -ne 8443) {
        throw 'M19 authenticated requests must target the configured HTTPS ingress.'
    }
    # Deliberately one request only: auth failures never replay a mutation.
    Invoke-GeordiHttpsRequest -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType `
        -TimeoutSeconds $TimeoutSeconds -SecurityCase $SecurityCase
}

function Invoke-GeordiAnonymousRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET','HEAD','POST','PUT','PATCH','DELETE')][string] $Method = 'GET',
        [int] $TimeoutSeconds = 15
    )
    $uriValue = [uri]$Uri
    if (!$uriValue.IsAbsoluteUri -or $uriValue.Scheme -cne 'https' -or
        $uriValue.Host -cne 'geordi.localhost' -or $uriValue.Port -ne 8443) {
        throw 'M19 anonymous requests must target the configured HTTPS ingress.'
    }
    Invoke-GeordiHttpsRequest -Uri $Uri -Method $Method -TimeoutSeconds $TimeoutSeconds -Anonymous
}

function Invoke-GeordiScriptRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET','HEAD','POST','PUT','PATCH','DELETE')][string] $Method = 'GET',
        [AllowNull()] $Body,
        [string] $ContentType = 'application/json',
        [ValidateRange(1,120)][int] $TimeoutSeconds = 15
    )
    $uriValue = [uri]$Uri
    if ($uriValue.IsAbsoluteUri -and $uriValue.Scheme -ceq 'https' -and
            $uriValue.Host -ceq 'geordi.localhost' -and $uriValue.Port -eq 8443) {
        if ($uriValue.AbsolutePath -match '^/actuator/health/(?:liveness|readiness)$') {
            return Invoke-GeordiAnonymousRequest -Uri $Uri -Method $Method -TimeoutSeconds $TimeoutSeconds
        }
        if (!$script:GeordiAuthState.Identity) {
            Initialize-GeordiAuthentication -Identity REGRESSION
        }
        return Invoke-GeordiAuthenticatedRequest -Uri $Uri -Method $Method -Body $Body `
            -ContentType $ContentType -TimeoutSeconds $TimeoutSeconds
    }
    # Provider, collector, demo-source and webhook fixture APIs intentionally keep
    # their loopback topology; only Geordi application routes use the TLS ingress.
    $allowedFixturePorts = @(8081,8082,8083,8084,8428,8888,13133,3100,3200,18080,18081,18082,18083)
    if (!$uriValue.IsAbsoluteUri -or $uriValue.Scheme -cne 'http' -or
            $uriValue.Host -cnotin @('127.0.0.1','localhost') -or $uriValue.Port -notin $allowedFixturePorts) {
        throw 'Semantic smoke request is outside the Geordi ingress and local fixture allow-lists.'
    }
    $request = @{ Uri = $Uri; Method = $Method; TimeoutSec = $TimeoutSeconds; UseBasicParsing = $true; SkipHttpErrorCheck = $true }
    if ($null -ne $Body) {
        $request.ContentType = $ContentType
        $request.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Compress }
    }
    $response = Invoke-WebRequest @request
    $contentTypeValue = [string]$response.Headers['Content-Type']
    if (!$contentTypeValue -and $response.BaseResponse -and $response.BaseResponse.Content) {
        $contentTypeValue = [string]$response.BaseResponse.Content.Headers.ContentType
    }
    return [pscustomobject]@{
        StatusCode = $response.StatusCode
        Content = [string]$response.Content
        Headers = $response.Headers
        ContentHeaders = [pscustomobject]@{ ContentType = $contentTypeValue }
    }
}

function Test-GeordiRuntimePreflight {
    [CmdletBinding()]
    param(
        [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
        [ValidateRange(1,120)][int] $TimeoutSeconds = 45
    )
    $origin = Get-GeordiApplicationBaseUrl -RepositoryRoot $RepositoryRoot
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $probe = $null
    do {
        try { $probe = Invoke-GeordiAnonymousRequest -Uri "$origin/actuator/health/readiness" -TimeoutSeconds 5 }
        catch { $probe = $null }
        if ($probe -and $probe.StatusCode -eq 200) { break }
        Start-Sleep -Milliseconds 300
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (!$probe -or $probe.StatusCode -ne 200) { throw 'M19 preflight failed: anonymous readiness.' }
    Initialize-GeordiAuthentication -Identity REGRESSION -RepositoryRoot $RepositoryRoot
    foreach ($path in @('/api/platform','/api/me')) {
        $response = Invoke-GeordiAuthenticatedRequest -Uri "$origin$path" -TimeoutSeconds 10
        if ($response.StatusCode -ne 200) { throw "M19 preflight failed: authenticated application read $path." }
    }
    $frontend = Invoke-GeordiAnonymousRequest -Uri "$origin/" -TimeoutSeconds 10
    if ($frontend.StatusCode -ne 200) { throw 'M19 preflight failed: HTTPS frontend root.' }
    foreach ($uri in @('http://127.0.0.1:8428/health','http://127.0.0.1:3200/ready',
            'http://127.0.0.1:3100/ready','http://127.0.0.1:13133/')) {
        $result = Invoke-GeordiScriptRequest -Uri $uri -TimeoutSeconds 10
        if ($result.StatusCode -ne 200) { throw 'M19 preflight failed: required internal provider readiness.' }
    }
    Write-Output 'M19 preflight passed: anonymous probe, authenticated platform/me, HTTPS frontend and private providers.'
}

function Test-GeordiAuthenticatedTransport {
    [CmdletBinding()]
    param(
        [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
        [ValidateRange(1,120)][int] $TimeoutSeconds = 45
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $readiness = $null
    $readinessError = $null

    do {
        try {
            $readiness = Invoke-GeordiAnonymousRequest `
                -Uri 'https://geordi.localhost:8443/actuator/health/readiness' `
                -TimeoutSeconds ([math]::Min(10,$TimeoutSeconds))

            if ($null -ne $readiness -and
                $readiness.PSObject.Properties['StatusCode'] -and
                [int]$readiness.StatusCode -eq 200) {
                break
            }
        }
        catch {
            $readiness = $null
            $readinessError = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 300
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    if ($null -eq $readiness) {
        throw "M19 transport preflight: anonymous readiness request failed. Detail: $readinessError"
    }

    if (!$readiness.PSObject.Properties['StatusCode']) {
        $typeName = $readiness.GetType().FullName
        $propertyNames = @($readiness.PSObject.Properties.Name) -join ', '
        throw "M19 transport preflight: unexpected readiness response type '$typeName'. Properties: $propertyNames"
    }

    if ([int]$readiness.StatusCode -ne 200) {
        throw 'M19 transport preflight failed at anonymous readiness.'
    }

    Initialize-GeordiAuthentication -Identity REGRESSION -RepositoryRoot $RepositoryRoot

    $platform = Invoke-GeordiAuthenticatedRequest `
        -Uri 'https://geordi.localhost:8443/api/platform' -TimeoutSeconds 10

    if ($null -eq $platform -or !$platform.PSObject.Properties['StatusCode']) {
        throw 'M19 transport preflight: authenticated platform response violates the response contract.'
    }

    if ([int]$platform.StatusCode -ne 200) {
        throw 'M19 transport preflight failed at authenticated platform read.'
    }

    $me = Invoke-GeordiAuthenticatedRequest `
        -Uri 'https://geordi.localhost:8443/api/me' -TimeoutSeconds 10

    if ($null -eq $me -or !$me.PSObject.Properties['StatusCode'] -or
        !$me.PSObject.Properties['Content']) {
        throw 'M19 transport preflight: authenticated identity response violates the response contract.'
    }

    if ([int]$me.StatusCode -ne 200 -or
        ($me.Content | ConvertFrom-Json).authMode -cne 'BEARER') {
        throw 'M19 transport preflight failed at authenticated identity read.'
    }

    return [pscustomobject]@{
        ReadinessStatus = $readiness.StatusCode
        PlatformStatus = $platform.StatusCode
        IdentityStatus = $me.StatusCode
    }
}

function Clear-GeordiAuthentication {
    [CmdletBinding()]
    param()
    $script:GeordiAuthState = @{}
}
