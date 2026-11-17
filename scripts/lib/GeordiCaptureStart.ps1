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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int] $ProcessId,
        [ValidateRange(1,30)][int] $TimeoutSeconds = 5,
        [string] $TaskkillPath = (Join-Path $env:SystemRoot 'System32/taskkill.exe')
    )

    # Snapshot descendants before terminating the root and retain creation
    # times to avoid treating a quickly reused PID as the original process.
    $processSnapshot = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,CreationDate -ErrorAction Stop)
    $treeIds = @($ProcessId)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($candidate in $processSnapshot) {
            $candidateId = [int]$candidate.ProcessId
            if (($treeIds -contains [int]$candidate.ParentProcessId) -and ($treeIds -notcontains $candidateId)) {
                $treeIds += $candidateId
                $changed = $true
            }
        }
    }
    $trackedProcesses = @($processSnapshot | Where-Object { $treeIds -contains [int]$_.ProcessId } |
        ForEach-Object { [pscustomobject]@{ Id=[int]$_.ProcessId; CreationDate=[string]$_.CreationDate } })

    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        & $TaskkillPath /PID $ProcessId /T /F *> $null
        $taskkillExitCode = $LASTEXITCODE
    } else {
        $taskkillExitCode = 128
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $currentProcesses = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,CreationDate -ErrorAction Stop)
            $remaining = @(
                foreach ($tracked in $trackedProcesses) {
                    $isAlive = $false
                    foreach ($current in $currentProcesses) {
                        if (([int]$current.ProcessId -eq $tracked.Id) -and ([string]$current.CreationDate -ceq $tracked.CreationDate)) {
                            $isAlive = $true
                            break
                        }
                    }
                    if ($isAlive) { $tracked }
                }
            )
            if ($remaining.Count -eq 0) { return }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            Start-Sleep -Milliseconds 25
        } while ($true)
    } finally {
        $clock.Stop()
    }

    $remainingIds = @($remaining | ForEach-Object { $_.Id }) -join ','
    throw "Capture-start process tree could not be confirmed stopped within $TimeoutSeconds seconds (remaining PIDs: $remainingIds; taskkill exit: $taskkillExitCode)."
}

function Wait-GeordiCaptureFilesReleased {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Path,
        [ValidateRange(1,30)][int] $TimeoutSeconds = 5
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $lockedPaths = [Collections.Generic.List[string]]::new()
            foreach ($filePath in $Path) {
                if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { continue }
                try {
                    $stream = [IO.File]::Open($filePath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                    $stream.Dispose()
                } catch [IO.IOException] {
                    $lockedPaths.Add($filePath)
                } catch [UnauthorizedAccessException] {
                    $lockedPaths.Add($filePath)
                }
            }
            if ($lockedPaths.Count -eq 0) { return }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            Start-Sleep -Milliseconds 25
        } while ($true)
    } finally {
        $clock.Stop()
    }
    throw "Capture log files remained locked beyond $TimeoutSeconds seconds: $($lockedPaths -join ', ')"
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
    $payload = @{ dockerPath=$DockerPath;dockerArguments=$DockerArguments;workingDirectory=$WorkingDirectory
        standardOutputPath=$StandardOutputPath;standardErrorPath=$StandardErrorPath;processRecordPath=$ProcessRecordPath
        targetMetadata=$TargetMetadata }
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        (ConvertTo-Json -InputObject $payload -Compress -Depth 4)))
    $quotedWorker = '"' + $WorkerPath + '"'
    $launcher = $null
    $cleanupVerified = $true
    $cleanupFailure = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $launcher = Start-Process -FilePath $PowerShellPath `
            -ArgumentList @('-NoLogo','-NoProfile','-File',$quotedWorker,'-PayloadBase64',$encodedPayload) `
            -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
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
            try {
                Wait-GeordiCaptureFilesReleased -Path @($StandardOutputPath,$StandardErrorPath) -TimeoutSeconds 5
                foreach ($path in @($ProcessRecordPath,$StandardOutputPath,$StandardErrorPath)) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
                }
            } catch {
                $cleanupVerified = $false
                $cleanupFailure = $_.Exception.Message
            }
        }
        if (-not $cleanupVerified) {
            throw "Capture follower startup failed; process/file cleanup could not be confirmed. $cleanupFailure"
        }
        throw
    } finally {
        $clock.Stop()
        if ($launcher) {
            $launcher.Dispose()
        }
    }
}
