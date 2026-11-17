Set-StrictMode -Version Latest

function Invoke-GeordiTlsStoreAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Import', 'VerifyPresent', 'Remove', 'VerifyAbsent')]
        [string] $Action,
        [string] $CertificatePath,
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Fa-f0-9]{40}$')]
        [string] $ExpectedThumbprint,
        [Parameter(Mandatory)]
        [string] $ExpectedSubject
    )

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'LocalMachine Root operation requires effective administrator rights.'
    }

    $thumbprint = $ExpectedThumbprint.ToUpperInvariant()
    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    try {
        $write = $Action -in @('Import', 'Remove')
        $flags = if ($write) {
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite
        } else {
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly
        }
        $store.Open($flags)
        $matches = @($store.Certificates | Where-Object { $_.Thumbprint -eq $thumbprint })

        switch ($Action) {
            'Import' {
                if (!$CertificatePath -or !(Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
                    throw 'Public CA certificate file is missing.'
                }
                $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
                try {
                    $constraint = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
                    $basicConstraints = if ($constraint) {
                        [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($constraint, $constraint.Critical)
                    } else { $null }
                    $now = [DateTime]::UtcNow
                    if ($certificate.Thumbprint -ne $thumbprint -or $certificate.Subject -ne $ExpectedSubject -or
                        $certificate.Issuer -ne $ExpectedSubject -or $certificate.HasPrivateKey -or
                        !$basicConstraints -or !$basicConstraints.CertificateAuthority -or
                        $certificate.NotBefore.ToUniversalTime() -gt $now -or
                        $certificate.NotAfter.ToUniversalTime() -le $now) {
                        throw 'Public CA identity or validity check failed.'
                    }
                    if ($matches.Count -ne 0) { throw 'Exact CA thumbprint already exists before import.' }
                    $store.Add($certificate)
                }
                finally { $certificate.Dispose() }
                'IMPORT_OK'
            }
            'VerifyPresent' {
                if ($matches.Count -ne 1) { throw "Expected exactly one matching LocalMachine root; found $($matches.Count)." }
                $certificate = $matches[0]
                if ($certificate.Subject -ne $ExpectedSubject -or $certificate.Issuer -ne $ExpectedSubject -or
                    $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
                    $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
                    throw 'Exact LocalMachine root subject, issuer, or validity check failed.'
                }
                'PRESENT_OK'
            }
            'Remove' {
                if ($matches.Count -gt 1) { throw 'Multiple LocalMachine roots matched the run-owned thumbprint.' }
                if ($matches.Count -eq 1) {
                    $certificate = $matches[0]
                    if ($certificate.Subject -ne $ExpectedSubject -or $certificate.Issuer -ne $ExpectedSubject) {
                        throw 'Matching LocalMachine root subject or issuer does not match the expected ephemeral CA.'
                    }
                    $store.Remove($certificate)
                }
                'REMOVE_OK'
            }
            'VerifyAbsent' {
                if ($matches.Count -ne 0) { throw 'Exact LocalMachine root thumbprint remains after cleanup.' }
                'ABSENT_OK'
            }
        }
    }
    finally { $store.Close() }
}

function Invoke-GeordiTlsStoreActionBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Import', 'VerifyPresent', 'Remove', 'VerifyAbsent')]
        [string] $Action,
        [string] $CertificatePath,
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Fa-f0-9]{40}$')]
        [string] $ExpectedThumbprint,
        [Parameter(Mandatory)]
        [string] $ExpectedSubject,
        [ValidateRange(1, 120)]
        [int] $TimeoutSeconds = 15
    )

    $actionScript = Join-Path $PSScriptRoot 'Invoke-GeordiTlsTrustAction.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $actionScript,
        '-Action', $Action, '-ExpectedThumbprint', $ExpectedThumbprint, '-ExpectedSubject', $ExpectedSubject)) {
        [void]$start.ArgumentList.Add($argument)
    }
    if ($CertificatePath) {
        [void]$start.ArgumentList.Add('-CertificatePath')
        [void]$start.ArgumentList.Add([IO.Path]::GetFullPath($CertificatePath))
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw "Could not start bounded LocalMachine $Action operation." }
        $process.StandardInput.Close()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit(5000)
            throw "Bounded LocalMachine $Action operation timed out."
        }
        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0) { throw "Bounded LocalMachine $Action operation failed (exit=$($process.ExitCode))." }
        $expectedOutput = switch ($Action) {
            'Import' { 'IMPORT_OK' }
            'VerifyPresent' { 'PRESENT_OK' }
            'Remove' { 'REMOVE_OK' }
            'VerifyAbsent' { 'ABSENT_OK' }
        }
        if ($stdout -ne $expectedOutput) { throw "Bounded LocalMachine $Action verification returned an unexpected result." }
    }
    finally { $process.Dispose() }
}

Export-ModuleMember -Function Invoke-GeordiTlsStoreAction, Invoke-GeordiTlsStoreActionBounded
