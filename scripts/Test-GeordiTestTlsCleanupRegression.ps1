[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourceScript = Join-Path $PSScriptRoot 'Remove-GeordiTestTls.ps1'
if (!(Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
    throw 'Cleanup regression cannot find Remove-GeordiTestTls.ps1.'
}

function Assert-CleanupRegression([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M19 TLS cleanup regression failed: $Message" }
}

function New-TestCa([string] $Directory, [string] $Name = 'ca') {
    $key = [Security.Cryptography.RSA]::Create(2048)
    $certificate = $null
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
        $now = [DateTimeOffset]::UtcNow
        $certificate = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(2))
        $path = Join-Path $Directory "$Name.cer"
        [IO.File]::WriteAllBytes($path, $certificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        return $certificate.Thumbprint
    } finally {
        if ($certificate) { $certificate.Dispose() }
        $key.Dispose()
    }
}

function New-CleanupFixture([string] $Name) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("geordi-m19-cleanup-{0}-{1}" -f $Name, [guid]::NewGuid().ToString('N'))
    $scripts = Join-Path $root 'scripts'
    $library = Join-Path $scripts 'lib'
    $runtimeParent = Join-Path $root '.runtime'
    New-Item -ItemType Directory -Path $library -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimeParent -Force | Out-Null
    Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $scripts 'Remove-GeordiTestTls.ps1')

    $mockModule = @'
function Test-GeordiTlsStoreThumbprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedThumbprint,
        [Parameter(Mandatory)][string] $ExpectedSubject
    )
    [IO.File]::AppendAllText($env:GEORDI_TLS_TEST_STORE_LOG, "Test|$ExpectedThumbprint|$ExpectedSubject" + [Environment]::NewLine)
    $statePath = $env:GEORDI_TLS_TEST_STORE_STATE
    $stored = if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath).Trim() } else { $null }
    $storedParts = if ($stored) { $stored -split '\|', 2 } else { @() }
    if ($storedParts.Count -gt 0 -and $storedParts[0] -eq $ExpectedThumbprint) {
        if ($storedParts.Count -ne 2 -or $storedParts[1] -ne $ExpectedSubject) {
            throw 'Mock LocalMachine Root subject does not match the expected ephemeral CA.'
        }
        return $true
    }
    return $false
}
function Invoke-GeordiTlsStoreActionBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Import','VerifyPresent','Remove','VerifyAbsent')][string] $Action,
        [string] $CertificatePath,
        [Parameter(Mandatory)][string] $ExpectedThumbprint,
        [Parameter(Mandatory)][string] $ExpectedSubject,
        [int] $TimeoutSeconds = 15
    )
    if ($ExpectedSubject -ne 'CN=Geordi M19 Ephemeral Test CA') {
        throw 'Mock rejected unexpected expected subject.'
    }
    $entry = "$Action|$ExpectedThumbprint|$ExpectedSubject" + [Environment]::NewLine
    [IO.File]::AppendAllText($env:GEORDI_TLS_TEST_STORE_LOG, $entry)
    $statePath = $env:GEORDI_TLS_TEST_STORE_STATE
    $stored = if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath).Trim() } else { $null }
    $storedParts = if ($stored) { $stored -split '\|', 2 } else { @() }
    switch ($Action) {
        'Remove' {
            if ($storedParts.Count -gt 0 -and $storedParts[0] -eq $ExpectedThumbprint) {
                if ($storedParts.Count -ne 2 -or $storedParts[1] -ne $ExpectedSubject) {
                    throw 'Mock LocalMachine Root subject does not match the expected ephemeral CA.'
                }
                Remove-Item -LiteralPath $statePath -Force
            }
        }
        'VerifyAbsent' {
            if ($storedParts.Count -gt 0 -and $storedParts[0] -eq $ExpectedThumbprint) {
                throw 'Mock LocalMachine Root still contains the requested thumbprint.'
            }
        }
    }
}
Export-ModuleMember -Function Invoke-GeordiTlsStoreActionBounded, Test-GeordiTlsStoreThumbprint
'@
    [IO.File]::WriteAllText((Join-Path $library 'GeordiTlsTrust.psm1'), $mockModule, [Text.Encoding]::UTF8)

    return [pscustomobject]@{
        Root = $root
        RuntimeParent = $runtimeParent
        Runtime = (Join-Path $runtimeParent 'm19')
        PublicManifest = (Join-Path $runtimeParent 'm19-ca-thumbprint.txt')
        Script = (Join-Path $scripts 'Remove-GeordiTestTls.ps1')
        StoreState = (Join-Path $root 'mock-store-state.txt')
        StoreLog = (Join-Path $root 'mock-store-actions.txt')
    }
}

function Invoke-CleanupFixture($Fixture) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [void]$start.ArgumentList.Add('-NoLogo')
    [void]$start.ArgumentList.Add('-NoProfile')
    [void]$start.ArgumentList.Add('-NonInteractive')
    [void]$start.ArgumentList.Add('-File')
    [void]$start.ArgumentList.Add($Fixture.Script)
    $start.Environment['GEORDI_TLS_TEST_STORE_STATE'] = $Fixture.StoreState
    $start.Environment['GEORDI_TLS_TEST_STORE_LOG'] = $Fixture.StoreLog

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'Could not start isolated cleanup process.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Set-RegisteredCa($Fixture) {
    New-Item -ItemType Directory -Path $Fixture.Runtime -Force | Out-Null
    $caThumbprint = New-TestCa $Fixture.Runtime
    [IO.File]::WriteAllText((Join-Path $Fixture.Runtime 'browser-trust-thumbprint'), $caThumbprint, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($Fixture.PublicManifest, $caThumbprint, [Text.Encoding]::ASCII)
    return $caThumbprint
}

$fixtures = [System.Collections.Generic.List[string]]::new()
try {
    # Normal cleanup: exact CA is installed, both manifests and ca.cer agree.
    $normal = New-CleanupFixture 'normal'
    $fixtures.Add($normal.Root)
    $thumbprint = Set-RegisteredCa $normal
    [IO.File]::WriteAllText($normal.StoreState, "$thumbprint|CN=Geordi M19 Ephemeral Test CA", [Text.Encoding]::ASCII)
    $sentinel = Join-Path $normal.RuntimeParent 'outside-sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'must remain', [Text.Encoding]::ASCII)
    $result = Invoke-CleanupFixture $normal
    Assert-CleanupRegression ($result.ExitCode -eq 0) "normal cleanup failed: $($result.Stderr)"
    Assert-CleanupRegression (!(Test-Path $normal.Runtime)) 'normal cleanup left .runtime/m19 behind.'
    Assert-CleanupRegression (!(Test-Path $normal.PublicManifest)) 'normal cleanup left the public thumbprint manifest behind.'
    Assert-CleanupRegression (!(Test-Path $normal.StoreState)) 'normal cleanup did not remove the exact installed CA.'
    Assert-CleanupRegression (Test-Path $sentinel) 'normal cleanup deleted a sibling file outside its owned paths.'
    $actions = [IO.File]::ReadAllText($normal.StoreLog)
    Assert-CleanupRegression ($actions -match '(?m)^Remove\|') 'normal cleanup did not request exact-thumbprint removal.'
    Assert-CleanupRegression (($actions -match '(?m)^Test\|') -and (($actions -split [Environment]::NewLine).Count -ge 3)) 'normal cleanup did not verify certificate absence before and after removal.'
    Write-Output 'm19_tls_cleanup_installed_ca=PASS'

    # Idempotent cleanup when the exact CA is already absent from the store.
    $absent = New-CleanupFixture 'already-absent'
    $fixtures.Add($absent.Root)
    $thumbprint = Set-RegisteredCa $absent
    $result = Invoke-CleanupFixture $absent
    Assert-CleanupRegression ($result.ExitCode -eq 0) "cleanup with already-absent CA failed: $($result.Stderr)"
    Assert-CleanupRegression (!(Test-Path $absent.Runtime) -and !(Test-Path $absent.PublicManifest)) 'already-absent cleanup left manifests or runtime.'
    $absentActions = [IO.File]::ReadAllText($absent.StoreLog)
    Assert-CleanupRegression ($absentActions -notmatch '(?m)^Remove\|') 'cleanup attempted store mutation although the CA was already absent.'
    Write-Output 'm19_tls_cleanup_ca_already_absent=PASS'

    # Inconsistent manifests must fail closed before store mutation or file deletion.
    $mismatch = New-CleanupFixture 'manifest-mismatch'
    $fixtures.Add($mismatch.Root)
    $thumbprint = Set-RegisteredCa $mismatch
    $mismatchThumbprint = if ($thumbprint -eq ('A' * 40)) { 'B' * 40 } else { 'A' * 40 }
    [IO.File]::WriteAllText($mismatch.PublicManifest, $mismatchThumbprint, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($mismatch.StoreState, "$thumbprint|CN=Geordi M19 Ephemeral Test CA", [Text.Encoding]::ASCII)
    $result = Invoke-CleanupFixture $mismatch
    Assert-CleanupRegression ($result.ExitCode -ne 0) 'inconsistent manifests were accepted.'
    Assert-CleanupRegression ((Test-Path $mismatch.Runtime) -and (Test-Path $mismatch.PublicManifest)) 'inconsistent-manifest failure deleted local material.'
    Assert-CleanupRegression ([IO.File]::ReadAllText($mismatch.StoreState).Trim() -eq $thumbprint) 'inconsistent-manifest failure changed mock store state.'
    Assert-CleanupRegression (!(Test-Path $mismatch.StoreLog)) 'inconsistent-manifest failure attempted a store operation.'
    Write-Output 'm19_tls_cleanup_manifest_mismatch=FAIL_CLOSED'

    # A thumbprint that does not identify ca.cer must fail closed.
    $wrongCa = New-CleanupFixture 'wrong-ca'
    $fixtures.Add($wrongCa.Root)
    $actualThumbprint = Set-RegisteredCa $wrongCa
    $differentThumbprint = if ($actualThumbprint -eq ('B' * 40)) { 'A' * 40 } else { 'B' * 40 }
    [IO.File]::WriteAllText((Join-Path $wrongCa.Runtime 'browser-trust-thumbprint'), $differentThumbprint, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($wrongCa.PublicManifest, $differentThumbprint, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($wrongCa.StoreState, "$differentThumbprint|CN=Geordi M19 Ephemeral Test CA", [Text.Encoding]::ASCII)
    $result = Invoke-CleanupFixture $wrongCa
    Assert-CleanupRegression ($result.ExitCode -ne 0) 'manifest thumbprint different from ca.cer was accepted.'
    Assert-CleanupRegression ((Test-Path $wrongCa.Runtime) -and (Test-Path $wrongCa.PublicManifest)) 'wrong-CA failure deleted local material.'
    Assert-CleanupRegression (!(Test-Path $wrongCa.StoreLog)) 'wrong-CA failure attempted a store operation.'
    Write-Output 'm19_tls_cleanup_ca_identity_mismatch=FAIL_CLOSED'

    # A matching thumbprint with a different installed subject must not be removed.
    $wrongStoreSubject = New-CleanupFixture 'wrong-store-subject'
    $fixtures.Add($wrongStoreSubject.Root)
    $storeSubjectThumbprint = Set-RegisteredCa $wrongStoreSubject
    [IO.File]::WriteAllText($wrongStoreSubject.StoreState, "$storeSubjectThumbprint|CN=Unrelated Root", [Text.Encoding]::ASCII)
    $result = Invoke-CleanupFixture $wrongStoreSubject
    Assert-CleanupRegression ($result.ExitCode -ne 0) 'matching thumbprint with an unrelated LocalMachine subject was accepted.'
    Assert-CleanupRegression ((Test-Path $wrongStoreSubject.Runtime) -and (Test-Path $wrongStoreSubject.PublicManifest)) 'wrong store subject failure deleted local material.'
    Assert-CleanupRegression ([IO.File]::ReadAllText($wrongStoreSubject.StoreState).Contains('CN=Unrelated Root')) 'wrong store subject failure changed mock store state.'
    Write-Output 'm19_tls_cleanup_store_subject_mismatch=FAIL_CLOSED'

    # Recovery after runtime removal but before public-manifest removal.
    $orphan = New-CleanupFixture 'orphan-manifest'
    $fixtures.Add($orphan.Root)
    $orphanThumbprint = 'C' * 40
    [IO.File]::WriteAllText($orphan.PublicManifest, $orphanThumbprint, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($orphan.StoreState, "$orphanThumbprint|CN=Geordi M19 Ephemeral Test CA", [Text.Encoding]::ASCII)
    $result = Invoke-CleanupFixture $orphan
    Assert-CleanupRegression ($result.ExitCode -eq 0) "orphan manifest recovery failed: $($result.Stderr)"
    Assert-CleanupRegression (!(Test-Path $orphan.PublicManifest) -and !(Test-Path $orphan.StoreState)) 'orphan manifest recovery did not complete cleanup.'
    Write-Output 'm19_tls_cleanup_orphan_manifest_recovery=PASS'

    # A runtime with no trust manifests is local-only and must not touch the store.
    $localOnly = New-CleanupFixture 'local-only'
    $fixtures.Add($localOnly.Root)
    New-Item -ItemType Directory -Path $localOnly.Runtime -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $localOnly.Runtime 'local-only.txt'), 'fixture', [Text.Encoding]::ASCII)
    $result = Invoke-CleanupFixture $localOnly
    Assert-CleanupRegression ($result.ExitCode -eq 0) "local-only cleanup failed: $($result.Stderr)"
    Assert-CleanupRegression (!(Test-Path $localOnly.Runtime)) 'local-only cleanup left runtime files.'
    Assert-CleanupRegression (!(Test-Path $localOnly.StoreLog)) 'local-only cleanup unexpectedly touched LocalMachine Root.'
    Write-Output 'm19_tls_cleanup_local_only=PASS'

    # A runtime junction to an external directory must be rejected without deleting its target.
    $junction = New-CleanupFixture 'junction-guard'
    $fixtures.Add($junction.Root)
    $outside = Join-Path $junction.Root 'outside'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    $outsideSentinel = Join-Path $outside 'keep.txt'
    [IO.File]::WriteAllText($outsideSentinel, 'must remain', [Text.Encoding]::ASCII)
    New-Item -ItemType Junction -Path $junction.Runtime -Target $outside | Out-Null
    $result = Invoke-CleanupFixture $junction
    Assert-CleanupRegression ($result.ExitCode -ne 0) 'runtime junction was accepted.'
    Assert-CleanupRegression (Test-Path $outsideSentinel) 'runtime junction guard deleted data outside the repository.'
    Remove-Item -LiteralPath $junction.Runtime -Force
    Write-Output 'm19_tls_cleanup_runtime_reparse_guard=FAIL_CLOSED'

    # The .runtime parent itself must not redirect cleanup outside the repository.
    $parentJunction = New-CleanupFixture 'parent-junction-guard'
    $fixtures.Add($parentJunction.Root)
    $externalRuntime = Join-Path $parentJunction.Root 'external-runtime'
    New-Item -ItemType Directory -Path (Join-Path $externalRuntime 'm19') -Force | Out-Null
    $externalSentinel = Join-Path $externalRuntime 'm19\keep.txt'
    [IO.File]::WriteAllText($externalSentinel, 'must remain', [Text.Encoding]::ASCII)
    Remove-Item -LiteralPath $parentJunction.RuntimeParent -Force
    New-Item -ItemType Junction -Path $parentJunction.RuntimeParent -Target $externalRuntime | Out-Null
    $result = Invoke-CleanupFixture $parentJunction
    Assert-CleanupRegression ($result.ExitCode -ne 0) '.runtime parent junction was accepted.'
    Assert-CleanupRegression (Test-Path $externalSentinel) '.runtime parent junction guard deleted external runtime data.'
    Remove-Item -LiteralPath $parentJunction.RuntimeParent -Force
    Write-Output 'm19_tls_cleanup_parent_reparse_guard=FAIL_CLOSED'

    Write-Output 'm19_tls_cleanup_regression=PASS'
} finally {
    foreach ($fixtureRoot in $fixtures) {
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
