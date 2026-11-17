[CmdletBinding()]
param([Parameter(Mandatory)][string] $PayloadBase64)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$process = $null
$diagnosticPath = $null

function Write-GeordiWorkerStartupDiagnostic {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $FailureStage,
        [Parameter(Mandatory)][string] $FailureCode,
        [AllowNull()][object] $WorkerExitCode,
        [AllowNull()][object] $ExceptionType,
        [Parameter(Mandatory)][ValidateSet('confirmed','unconfirmed','not-required')][string] $CleanupStatus
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryPath = $fullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $diagnostic = [ordered]@{
        version = 1
        failureStage = $FailureStage
        failureCode = $FailureCode
        workerExitCode = $WorkerExitCode
        exceptionType = $ExceptionType
        cleanupStatus = $CleanupStatus
        observedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    try {
        [IO.File]::WriteAllText($temporaryPath,(ConvertTo-Json -InputObject $diagnostic -Compress),[Text.UTF8Encoding]::new($false))
        try {
            [IO.File]::Move($temporaryPath,$fullPath)
        } catch {
            if (-not [IO.File]::Exists($fullPath)) { throw }
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

try {
    $payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64))
    $payload = $payloadJson | ConvertFrom-Json -DateKind String
    $diagnosticPath = [string]$payload.startupDiagnosticPath
    if ([string]::IsNullOrWhiteSpace($diagnosticPath)) {
        $diagnosticPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath([string]$payload.processRecordPath))) 'startup-diagnostic.json'
    }
    if ($null -ne $payload.targetMetadata) {
        foreach ($key in @('containerId','service','project','createdUtc')) {
            if ([string]::IsNullOrWhiteSpace([string]$payload.targetMetadata.$key)) { throw 'Capture target identity was incomplete.' }
        }
    }
    $process = Start-Process -FilePath ([string]$payload.dockerPath) -ArgumentList @($payload.dockerArguments) -WorkingDirectory ([string]$payload.workingDirectory) -RedirectStandardOutput ([string]$payload.standardOutputPath) -RedirectStandardError ([string]$payload.standardErrorPath) -WindowStyle Hidden -PassThru
    # Persist identity immediately so the parent can clean up if readiness fails.
    $record = @{ id=$process.Id;name=$process.ProcessName;startUtc=$process.StartTime.ToUniversalTime().ToString('o') }
    if ($null -ne $payload.targetMetadata) {
        foreach ($key in @('containerId','service','project','createdUtc')) {
            $record[$key]=[string]$payload.targetMetadata.$key
        }
    }
    $temporaryRecord = ([string]$payload.processRecordPath) + '.tmp'
    [IO.File]::WriteAllText($temporaryRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryRecord,[string]$payload.processRecordPath)
    Start-Sleep -Milliseconds 250
    $process.Refresh()
    if ($process.HasExited) {
        try {
            Write-GeordiWorkerStartupDiagnostic -Path $diagnosticPath -FailureStage 'worker-readiness' -FailureCode 'worker-exited-early' -WorkerExitCode 21 -ExceptionType $null -CleanupStatus 'not-required'
        } catch { }
        exit 21
    }
    exit 0
} catch {
    $workerFailureType = $_.Exception.GetType().FullName
    $cleanupConfirmed = $true
    if ($process) {
        try {
            $process.Refresh()
            # Keep the root ID in the ancestry walk even if the root exited:
            # if CIM cannot distinguish its original instance, fail closed.
            $snapshot = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,CreationDate -ErrorAction Stop)
            $rootSnapshot = @($snapshot | Where-Object { [int]$_.ProcessId -eq $process.Id })
            if ($rootSnapshot.Count -ne 1) { throw 'Worker could not prove its child process identity during cleanup.' }
            $treeIds = @([int]$process.Id)
            $changed = $true
            while ($changed) {
                $changed = $false
                foreach ($candidate in $snapshot) {
                    $candidateId = [int]$candidate.ProcessId
                    if (($treeIds -contains [int]$candidate.ParentProcessId) -and ($treeIds -notcontains $candidateId)) {
                        $treeIds += $candidateId
                        $changed = $true
                    }
                }
            }
            $tracked = @($snapshot | Where-Object { $treeIds -contains [int]$_.ProcessId } |
                ForEach-Object { [pscustomobject]@{ Id=[int]$_.ProcessId; CreationDate=[string]$_.CreationDate } })
            if (-not $process.HasExited) {
                # Kill through the already opened Process handle so a reused
                # PID cannot redirect a later PID-only taskkill command.
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
            $clock = [Diagnostics.Stopwatch]::StartNew()
            try {
                do {
                    $current = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,CreationDate -ErrorAction Stop)
                    $remaining = @(
                        foreach ($entry in $tracked) {
                            if (@($current | Where-Object {
                                [int]$_.ProcessId -eq $entry.Id -and [string]$_.CreationDate -ceq $entry.CreationDate
                            }).Count -gt 0) { $entry }
                        }
                    )
                    if ($remaining.Count -eq 0) { break }
                    if ($clock.Elapsed.TotalSeconds -ge 5) { $cleanupConfirmed = $false; break }
                    Start-Sleep -Milliseconds 25
                } while ($true)
            } finally { $clock.Stop() }
        } catch {
            $cleanupConfirmed = $false
        }
        try {
            $process.Refresh()
            if (-not $process.HasExited) { $cleanupConfirmed = $false }
        } catch {
            $cleanupConfirmed = $false
        }
    }
    $workerExitCode = if ($cleanupConfirmed) { 22 } else { 23 }
    $workerFailureCode = if ($cleanupConfirmed) { 'worker-startup-failed' } else { 'worker-cleanup-unconfirmed' }
    $workerCleanupStatus = if ($cleanupConfirmed) { 'confirmed' } else { 'unconfirmed' }
    try {
        Write-GeordiWorkerStartupDiagnostic -Path $diagnosticPath -FailureStage 'worker-startup' -FailureCode $workerFailureCode -WorkerExitCode $workerExitCode -ExceptionType $workerFailureType -CleanupStatus $workerCleanupStatus
    } catch { }
    if (-not $cleanupConfirmed) { exit 23 }
    exit 22
}
