[CmdletBinding()]
param([switch] $BestEffort)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiCleanupPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeRoot = Join-Path $repositoryRoot '.runtime/m19'
$publicThumbprintPath = Join-Path (Join-Path $repositoryRoot '.runtime') 'm19-ca-thumbprint.txt'
$pointer = Join-Path (Join-Path $repositoryRoot '.runtime') 'm19-capture-root.txt'
$captureRoot = $null
$failures = [Collections.Generic.List[string]]::new()

function Get-GeordiDockerInventoryBounded {
    $nonce = [guid]::NewGuid().ToString('N')
    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) "geordi-m19-docker-inventory-$nonce.ps1"
    $stdoutPath = "$scriptPath.out"
    $stderrPath = "$scriptPath.err"
    $inventoryScript = @'
$ErrorActionPreference = 'Stop'
$containers = @(& docker ps -a --filter 'label=com.docker.compose.project=geordi' --format '{{.Names}}' 2>$null)
if ($LASTEXITCODE -ne 0) { exit 10 }
$networks = @(& docker network ls --filter 'name=^geordi_default$' --format '{{.Name}}' 2>$null)
if ($LASTEXITCODE -ne 0) { exit 11 }
$volumes = @(& docker volume ls --format '{{.Name}}' 2>$null)
if ($LASTEXITCODE -ne 0) { exit 12 }
ConvertTo-Json -InputObject @{ containers=$containers; networks=$networks; volumes=$volumes } -Compress
'@
    try {
        [IO.File]::WriteAllText($scriptPath, $inventoryScript, [Text.UTF8Encoding]::new($false))
        $powershell = (Get-Process -Id $PID).Path
        $child = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-File',$scriptPath) `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (!$child.WaitForExit(20000)) {
            $child.Kill($true)
            [void]$child.WaitForExit(5000)
            throw 'Docker inventory query timed out.'
        }
        if ($child.ExitCode -ne 0) { throw 'Docker inventory query failed.' }
        return Get-Content -LiteralPath $stdoutPath -Raw | ConvertFrom-Json
    } finally {
        foreach ($path in @($scriptPath,$stdoutPath,$stderrPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }
}

if (Test-Path -LiteralPath $pointer -PathType Leaf) {
    $candidate = [IO.Path]::GetFullPath([IO.File]::ReadAllText($pointer).Trim())
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($candidate) -cne $expectedParent -or
            (Split-Path $candidate -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
        $failures.Add('private capture path invalid')
    } elseif (Test-Path -LiteralPath $candidate -PathType Container) {
        $item = Get-Item -LiteralPath $candidate -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $failures.Add('private capture root is a reparse point') }
        else { $captureRoot = $candidate }
    } else {
        # A previous cleanup attempt may have removed captures before another
        # bounded cleanup step failed. Keep the validated pointer so this run can
        # finish TLS/container cleanup and remove the pointer idempotently.
        $captureRoot = $candidate
    }
}

 $captureProcessCleanupVerified = $true
if ($captureRoot -and (Test-Path -LiteralPath $captureRoot -PathType Container)) {
    $processRecords = @()
    try {
        foreach ($attempt in Get-GeordiM19FinalizeAttemptDirectories -CaptureRoot $captureRoot) {
            Assert-GeordiM19FinalizeLaunchRecordsRecoverable -AttemptRoot $attempt.FullName
        }
        $processRecords = @(Get-ChildItem -LiteralPath $captureRoot -File -Filter '*.process.json' -Recurse)
    } catch { $failures.Add('capture attempt inventory invalid'); $captureProcessCleanupVerified = $false }
    foreach ($processRecord in $processRecords) {
        try {
            if ($processRecord.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Process record redirected.' }
            $processInfo = Get-Content -LiteralPath $processRecord.FullName -Raw | ConvertFrom-Json
            $capturePid = [int]$processInfo.id
            $captureProcess = Get-Process -Id $capturePid -ErrorAction SilentlyContinue
            if ($captureProcess) {
                if ($captureProcess.ProcessName -cne [string]$processInfo.name -or
                        $captureProcess.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$processInfo.startUtc).UtcTicks) {
                    throw 'Capture process identity changed.'
                }
                $taskkillPath = Join-Path $env:SystemRoot 'System32/taskkill.exe'
                & $taskkillPath /PID $capturePid /T /F *> $null
                if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $capturePid -ErrorAction SilentlyContinue)) {
                    throw 'Capture process tree did not stop.'
                }
                Wait-Process -Id $capturePid -Timeout 5 -ErrorAction SilentlyContinue
            }
            if (Get-Process -Id $capturePid -ErrorAction SilentlyContinue) {
                $failures.Add('runtime capture process remains')
                $captureProcessCleanupVerified = $false
            }
        } catch { $failures.Add('runtime capture process cleanup failed'); $captureProcessCleanupVerified = $false }
    }
}

$composeArgs = @('--file','compose.yaml','--file','compose.m19.yaml','--file','compose.m14.yaml','down','--timeout','10','--remove-orphans')
$composeLog = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-compose-cleanup-' + [guid]::NewGuid().ToString('N'))
$composeEnvironment = $null
try {
    $composeEnvironment = Set-GeordiM19CleanupComposeInterpolation
    $dockerPath = (Get-Command docker.exe -ErrorAction Stop).Source
    $composeProcess = Start-Process -FilePath $dockerPath -ArgumentList (@('compose') + $composeArgs) `
        -WorkingDirectory $repositoryRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$composeLog.out" -RedirectStandardError "$composeLog.err"
    if (!$composeProcess.WaitForExit(25000)) {
        $composeProcess.Kill($true)
        [void]$composeProcess.WaitForExit(5000)
        $failures.Add('compose teardown timed out')
    } elseif ($composeProcess.ExitCode -ne 0) {
        $diagnostic = 'Compose diagnostic suppressed.'
        $stderrPath = "$composeLog.err"
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $stderr = [IO.File]::ReadAllText($stderrPath)
            $missingVariables = @([regex]::Matches($stderr,
                '(?i)(?:required variable|variable)\s+(GEORDI_M13_WEBHOOK_TOKEN_[AB])(?:\s+is missing|\s+is required)') |
                ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Select-Object -Unique)
            if ($missingVariables.Count -gt 0) {
                $diagnostic = 'Missing Compose interpolation variable(s): ' + ($missingVariables -join ', ') + '.'
            }
        }
        $failures.Add("compose teardown failed (exit=$($composeProcess.ExitCode); $diagnostic)")
    }
} catch { $failures.Add('compose teardown unavailable') }
finally {
    if ($composeEnvironment) { Restore-GeordiM19CleanupComposeInterpolation -Previous $composeEnvironment }
}
foreach ($path in @("$composeLog.out","$composeLog.err")) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
    $runtimeThumbprintPath = Join-Path $runtimeRoot 'browser-trust-thumbprint'
    if (Test-Path -LiteralPath $runtimeThumbprintPath -PathType Leaf) {
        try {
            $runtimeThumbprint = [IO.File]::ReadAllText($runtimeThumbprintPath).Trim()
            if ($runtimeThumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'runtime thumbprint malformed' }
            if (Test-Path -LiteralPath $publicThumbprintPath) {
                if ([IO.File]::ReadAllText($publicThumbprintPath).Trim() -cne $runtimeThumbprint) { throw 'thumbprint records disagree' }
            } else {
                [IO.File]::WriteAllText($publicThumbprintPath,$runtimeThumbprint,[Text.UTF8Encoding]::new($false))
            }
        } catch { $failures.Add('exact TLS thumbprint metadata unavailable') }
    }
    $cleanupOut = if ($captureRoot -and (Test-Path -LiteralPath $captureRoot -PathType Container)) {
        Join-Path $captureRoot 'tls-cleanup.out'
    } else { Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-tls-cleanup-' + [guid]::NewGuid().ToString('N') + '.log') }
    $cleanupErr = "$cleanupOut.err"
    try {
        $powershell = (Get-Process -Id $PID).Path
        $child = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-File',
            (Join-Path $PSScriptRoot 'Remove-GeordiTestTls.ps1')) -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $cleanupOut -RedirectStandardError $cleanupErr
        if (!$child.WaitForExit(60000)) {
            $child.Kill($true)
            [void]$child.WaitForExit(5000)
            $failures.Add('TLS trust removal timed out')
        } elseif ($child.ExitCode -ne 0) { $failures.Add('TLS trust removal failed') }
    } catch { $failures.Add('TLS trust removal unavailable') }
    if (Test-Path -LiteralPath $runtimeRoot) { $failures.Add('M19 runtime TLS directory remains') }
    if (Test-Path -LiteralPath (Join-Path $runtimeRoot 'truststore.p12')) { $failures.Add('Java truststore remains') }
    if (Test-Path -LiteralPath $cleanupOut) { Remove-Item -LiteralPath $cleanupOut -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $cleanupErr) { Remove-Item -LiteralPath $cleanupErr -Force -ErrorAction SilentlyContinue }
}

$exactThumbprintAbsent = $false
if (Test-Path -LiteralPath $publicThumbprintPath -PathType Leaf) {
    try {
        $expectedThumbprint = [IO.File]::ReadAllText($publicThumbprintPath).Trim()
        if ($expectedThumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'thumbprint metadata malformed' }
        $exactMatches = @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -ceq $expectedThumbprint })
        if ($exactMatches.Count -ne 0) {
            $failures.Add('exact LocalMachine CA thumbprint remains')
        } else {
            $exactThumbprintAbsent = $true
            Remove-Item -LiteralPath $publicThumbprintPath -Force -ErrorAction Stop
        }
    } catch { $failures.Add('exact LocalMachine CA thumbprint absence could not be verified') }
} elseif (Test-Path -LiteralPath (Join-Path $runtimeRoot 'browser-trust-thumbprint') -PathType Leaf) {
    $failures.Add('exact TLS thumbprint metadata unavailable')
}

if ($captureRoot -and (Test-Path -LiteralPath $captureRoot) -and !$captureProcessCleanupVerified) {
    $failures.Add('private capture cleanup blocked')
} elseif ($captureRoot -and (Test-Path -LiteralPath $captureRoot)) {
    try {
        Remove-GeordiM19FinalizeAttempts -CaptureRoot $captureRoot
        Remove-Item -LiteralPath $captureRoot -Recurse -Force -ErrorAction Stop
    }
    catch { $failures.Add('private capture cleanup blocked') }
}
if ($captureRoot -and (Test-Path -LiteralPath $captureRoot)) { $failures.Add('private capture directory remains') }
if ($captureRoot -and !(Test-Path -LiteralPath $captureRoot) -and !(Test-Path -LiteralPath $runtimeRoot)) {
    try {
        if (Test-Path -LiteralPath $pointer) { Remove-Item -LiteralPath $pointer -Force -ErrorAction Stop }
    } catch { $failures.Add('private evidence pointer cleanup failed') }
}
if (Test-Path -LiteralPath $pointer) {
    $failures.Add('private evidence pointer remains')
}

$dockerInventory = $null
try { $dockerInventory = Get-GeordiDockerInventoryBounded }
catch { $failures.Add('Docker inventory unavailable or timed out') }
if ($dockerInventory -and $null -ne $dockerInventory.containers -and @($dockerInventory.containers).Count -gt 0) {
    $failures.Add('Geordi project containers remain')
}
if ($dockerInventory -and $null -ne $dockerInventory.networks -and @($dockerInventory.networks).Count -gt 0) {
    $failures.Add('Geordi transient network remains')
}
if (!$dockerInventory -or @('geordi_m19-alert-lifecycle-data','geordi_m19-victoriametrics-data' |
        Where-Object { $_ -notin @($dockerInventory.volumes) }).Count -gt 0) {
    $failures.Add('Preserved M19 data volumes are unavailable')
}

if ($BestEffort) {
    $summaryPath = Join-Path $repositoryRoot 'backend/target/.m19-evidence-gate-summary.txt'
    if (Test-Path -LiteralPath $summaryPath) { Remove-Item -LiteralPath $summaryPath -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    $primaryExit = if ($BestEffort -and $env:CI_JOB_STATUS -in @('failed','canceled')) { 1 } else { 0 }
    $outcome = Resolve-GeordiM19CleanupOutcome -PrimaryExitCode $primaryExit -CleanupExitCode 1
    $primaryText = if ($outcome.PrimaryExitCode -ne 0) { 'failed' } else { 'passed-or-previously-recorded' }
    Write-Output ("cleanup=failed checks={0} primary={1} original_failure_preserved={2}" -f
        $failures.Count,$primaryText,$outcome.OriginalFailurePreserved.ToString().ToLowerInvariant())
    Write-Output ("cleanup_failed_checks=" + ($failures -join ','))
    if (!$BestEffort -and $outcome.EffectiveExitCode -ne 0) { throw 'M19 cleanup verification failed.' }
    return
}
$primaryExit = if ($BestEffort -and $env:CI_JOB_STATUS -in @('failed','canceled')) { 1 } else { 0 }
$outcome = Resolve-GeordiM19CleanupOutcome -PrimaryExitCode $primaryExit -CleanupExitCode 0
Write-Output ("cleanup=passed containers=0 networks=0 tls=removed exact_thumbprint_absent={1} private_captures=removed preserved_volumes=2 original_failure_preserved={0}" -f
    $outcome.OriginalFailurePreserved.ToString().ToLowerInvariant(),$exactThumbprintAbsent.ToString().ToLowerInvariant())
