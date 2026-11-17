function Read-GeordiCaptureStartFile {
    param([Parameter(Mandatory)][string] $Path, [ValidateRange(1,67108864)][int] $MaximumBytes = 4096)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -gt $MaximumBytes) { throw 'Capture-start metadata exceeded its bound.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -le 0) { throw 'Capture-start metadata changed while being read.' }
            $offset += $read
        }
        return [Text.Encoding]::UTF8.GetString($bytes)
    } finally { $stream.Dispose() }
}

function Stop-GeordiCaptureProcessTree {
    param([Parameter(Mandatory)][int] $ProcessId)
    $taskkillPath = Join-Path $env:SystemRoot 'System32/taskkill.exe'
    & $taskkillPath /PID $ProcessId /T /F *> $null
    $taskkillExitCode = $LASTEXITCODE
    Wait-Process -Id $ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    if ((Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) -and $taskkillExitCode -ne 0) {
        throw 'Capture-start process tree could not be stopped within its bound.'
    }
}

function Invoke-GeordiBoundedLogFollowerStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PowerShellPath,
        [Parameter(Mandatory)][string] $WorkerPath,
        [Parameter(Mandatory)][string] $DockerPath,
        [Parameter(Mandatory)][string[]] $DockerArguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $StandardOutputPath,
        [Parameter(Mandatory)][string] $StandardErrorPath,
        [Parameter(Mandatory)][string] $ProcessRecordPath,
        [AllowNull()] $TargetMetadata,
        [ValidateRange(1,20)][int] $TimeoutSeconds = 8
    )
    $workerOutput = "$ProcessRecordPath.launcher.out"
    $workerError = "$ProcessRecordPath.launcher.err"
    $payload = @{ dockerPath=$DockerPath;dockerArguments=$DockerArguments;workingDirectory=$WorkingDirectory
        standardOutputPath=$StandardOutputPath;standardErrorPath=$StandardErrorPath;processRecordPath=$ProcessRecordPath
        targetMetadata=$TargetMetadata }
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        (ConvertTo-Json -InputObject $payload -Compress -Depth 4)))
    $quotedWorker = '"' + $WorkerPath + '"'
    $launcher = $null
    $cleanupVerified = $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $launcher = Start-Process -FilePath $PowerShellPath `
            -ArgumentList @('-NoLogo','-NoProfile','-File',$quotedWorker,'-PayloadBase64',$encodedPayload) `
            -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru `
        if (!$launcher.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-GeordiCaptureProcessTree -ProcessId $launcher.Id
            throw 'Capture follower process launch/readiness exceeded its bound.'
        }
        if ($launcher.ExitCode -ne 0 -or !(Test-Path -LiteralPath $ProcessRecordPath -PathType Leaf)) {
            throw 'Capture follower process failed its bounded startup check.'
        }
        $recordText = Read-GeordiCaptureStartFile -Path $ProcessRecordPath
        $record = $recordText | ConvertFrom-Json
        if ([int]$record.id -le 0 -or [string]::IsNullOrWhiteSpace([string]$record.name) -or
                [string]::IsNullOrWhiteSpace([string]$record.startUtc)) {
            throw 'Capture follower process identity record is malformed.'
        }
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        if (!$process -or $process.ProcessName -cne [string]$record.name -or
                $process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$record.startUtc).UtcTicks -or
                !(Test-Path -LiteralPath $StandardOutputPath -PathType Leaf) -or
                !(Test-Path -LiteralPath $StandardErrorPath -PathType Leaf)) {
            throw 'Capture log follower did not remain ready after launch.'
        }
        return $record
    } catch {
        if (Test-Path -LiteralPath $ProcessRecordPath) {
            try {
                $record = (Read-GeordiCaptureStartFile -Path $ProcessRecordPath) | ConvertFrom-Json
                Stop-GeordiCaptureProcessTree -ProcessId ([int]$record.id)
            } catch { $cleanupVerified = $false }
        }
        if ($launcher -and (Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue)) {
            try { Stop-GeordiCaptureProcessTree -ProcessId $launcher.Id } catch { $cleanupVerified = $false }
        }
        if ($cleanupVerified) {
            foreach ($path in @($ProcessRecordPath,$StandardOutputPath,$StandardErrorPath)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not $cleanupVerified) { throw 'Capture follower startup failed and process cleanup could not be confirmed.' }
        throw
    } finally {
        $clock.Stop()
        if ($launcher) {
            $launcher.Dispose()
        }
        if ($cleanupVerified) {
            foreach ($path in @($workerOutput,$workerError)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
