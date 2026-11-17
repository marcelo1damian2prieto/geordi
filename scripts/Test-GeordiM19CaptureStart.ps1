[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to exercise bounded M19 log follower startup.' }
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureStart.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-capture-start-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$powerShellPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$commandProcessorPath = (Get-Command cmd.exe -ErrorAction Stop).Source
$workerPath = Join-Path $PSScriptRoot 'lib/Start-GeordiLogFollowerWorker.ps1'
$healthyPath = Join-Path $root 'healthy.ps1'
$healthyStdoutPath = Join-Path $root 'healthy.stdout'
$healthyStderrPath = Join-Path $root 'healthy.stderr'
$healthyChildPidPath = Join-Path $root 'healthy.child.pid'
$expectedSince = '2026-11-17T08:18:36.7258700+00:00'
$exitsPath = Join-Path $root 'exits.ps1'
$hangPath = Join-Path $root 'hang.ps1'
$childPidPath = Join-Path $root 'hang.child.pid'
$healthyRecord = Join-Path $root 'healthy.process.json'
$exitRecord = Join-Path $root 'exit.process.json'
try {
    $escapedPowerShellPath = $powerShellPath.Replace("'","''")
    $escapedHealthyChildPidPath = $healthyChildPidPath.Replace("'","''")
    $healthyScript = @"
param([string] `$Since)
`$child = Start-Process -FilePath '$escapedPowerShellPath' -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText('$escapedHealthyChildPidPath',[string]`$child.Id)
Write-Output "follower-since=`$Since"
Write-Output 'follower-ready'
Start-Sleep -Seconds 30
"@
    [IO.File]::WriteAllText($healthyPath,$healthyScript,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($exitsPath,'exit 0',[Text.UTF8Encoding]::new($false))
    $hangWorker = @"
param([string]`$PayloadBase64)
`$child = Start-Process -FilePath '$($powerShellPath.Replace("'","''"))' -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText('$($childPidPath.Replace("'","''"))',[string]`$child.Id)
Start-Sleep -Seconds 30
"@
    [IO.File]::WriteAllText($hangPath,$hangWorker,[Text.UTF8Encoding]::new($false))
    $healthy = Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $powerShellPath -WorkerPath $workerPath `
        -DockerPath $powerShellPath -DockerArguments @('-NoLogo','-NoProfile','-File',$healthyPath,$expectedSince) `
        -WorkingDirectory $root -StandardOutputPath $healthyStdoutPath `
        -StandardErrorPath $healthyStderrPath -ProcessRecordPath $healthyRecord -TimeoutSeconds 5
    if (-not (Test-Path -LiteralPath $healthyRecord) -or [int]$healthy.id -le 0) {
        throw 'Healthy follower startup did not produce bounded process identity evidence.'
    }
    $healthyClock = [Diagnostics.Stopwatch]::StartNew()
    $healthyOutput = ''
    do {
        if (Test-Path -LiteralPath $healthyStdoutPath) {
            $healthyOutput = [IO.File]::ReadAllText($healthyStdoutPath)
        }
        if ($healthyOutput -cmatch [regex]::Escape("follower-since=$expectedSince")) { break }
        Start-Sleep -Milliseconds 25
    } while ($healthyClock.Elapsed.TotalSeconds -lt 2)
    $healthyClock.Stop()
    if (-not (Test-Path -LiteralPath $healthyChildPidPath -PathType Leaf)) {
        throw 'Healthy follower did not create its descendant-process evidence.'
    }
    $healthyChildId = [int][IO.File]::ReadAllText($healthyChildPidPath)
    Stop-GeordiCaptureProcessTree -ProcessId ([int]$healthy.id)
    if (Get-Process -Id $healthyChildId -ErrorAction SilentlyContinue) {
        throw 'Stopping the healthy follower left its descendant process running.'
    }
    Wait-GeordiCaptureFilesReleased -Path @($healthyStdoutPath,$healthyStderrPath) -TimeoutSeconds 5
    if ($healthyOutput -cnotmatch [regex]::Escape("follower-since=$expectedSince")) {
        throw 'ISO-8601 follower argument was not preserved as its original string.'
    }
    Write-Output 'capture_start_case=iso8601_argument_preserved result=PASS'
    Write-Output 'capture_start_case=live_follower result=PASS bounded=5s deterministic_stop=PASS'

    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $powerShellPath -WorkerPath $workerPath `
            -DockerPath $commandProcessorPath -DockerArguments @('/c','exit','0') `
            -WorkingDirectory $root -StandardOutputPath (Join-Path $root 'exit.stdout') `
            -StandardErrorPath (Join-Path $root 'exit.stderr') -ProcessRecordPath $exitRecord -TimeoutSeconds 5 | Out-Null
        throw 'Exited follower was accepted as ready.'
    } catch {
        if ($_.Exception.Message -eq 'Exited follower was accepted as ready.') { throw }
    }
    $clock.Stop()
    if ($clock.Elapsed.TotalSeconds -ge 5 -or (Test-Path -LiteralPath $exitRecord)) {
        throw 'Exited follower did not fail within the startup bound.'
    }
    Write-Output ("capture_start_case=early_exit result=FAIL_CLOSED duration_seconds={0:N2} no_orphan=PASS" -f $clock.Elapsed.TotalSeconds)

    $clock.Restart()
    try {
        Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $powerShellPath -WorkerPath $hangPath `
            -DockerPath $powerShellPath -DockerArguments @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30') `
            -WorkingDirectory $root -StandardOutputPath (Join-Path $root 'hang.stdout') `
            -StandardErrorPath (Join-Path $root 'hang.stderr') -ProcessRecordPath (Join-Path $root 'hang.process.json') -TimeoutSeconds 1 | Out-Null
        throw 'Hung follower launcher was accepted.'
    } catch {
        if ($_.Exception.Message -eq 'Hung follower launcher was accepted.') { throw }
    }
    $clock.Stop()
    if ($clock.Elapsed.TotalSeconds -ge 5 -or !(Test-Path -LiteralPath $childPidPath)) {
        throw 'Hung follower launcher did not fail inside its deterministic bound.'
    }
    $childId = [int][IO.File]::ReadAllText($childPidPath)
    if (Get-Process -Id $childId -ErrorAction SilentlyContinue) {
        throw 'Hung follower launcher left a descendant process running.'
    }
    Write-Output ("capture_start_case=launcher_timeout result=FAIL_CLOSED duration_seconds={0:N2} descendant_cleanup=PASS" -f $clock.Elapsed.TotalSeconds)
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($resolvedRoot) -cne $expectedParent -or
            (Split-Path $resolvedRoot -Leaf) -notmatch '^geordi-m19-capture-start-test-[0-9a-f]{32}$') {
        throw 'Unsafe capture-start self-test cleanup path.'
    }
    if (Test-Path -LiteralPath $healthyRecord -PathType Leaf) {
        try {
            $remainingRecord = (Read-GeordiCaptureStartFile -Path $healthyRecord) | ConvertFrom-Json
            Stop-GeordiCaptureProcessTree -ProcessId ([int]$remainingRecord.id) -TimeoutSeconds 5
        } catch {
            throw "Self-test cleanup could not stop the healthy follower: $($_.Exception.Message)"
        }
    }
    Wait-GeordiCaptureFilesReleased -Path @($healthyStdoutPath,$healthyStderrPath) -TimeoutSeconds 5
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop
}
