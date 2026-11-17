[CmdletBinding()]
param([Parameter(Mandatory)][string] $PayloadBase64)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$process = $null
try {
    $payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64))
    $payload = $payloadJson | ConvertFrom-Json -DateKind String
    $process = Start-Process -FilePath ([string]$payload.dockerPath) -ArgumentList @($payload.dockerArguments) -WorkingDirectory ([string]$payload.workingDirectory) -RedirectStandardOutput ([string]$payload.standardOutputPath) -RedirectStandardError ([string]$payload.standardErrorPath) -WindowStyle Hidden -PassThru
    # Persist identity immediately so the parent can clean up if readiness fails.
    $record = @{ id=$process.Id;name=$process.ProcessName;startUtc=$process.StartTime.ToUniversalTime().ToString('o') }
    $temporaryRecord = ([string]$payload.processRecordPath) + '.tmp'
    [IO.File]::WriteAllText($temporaryRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryRecord,[string]$payload.processRecordPath)
    Start-Sleep -Milliseconds 250
    $process.Refresh()
    if ($process.HasExited) { exit 21 }
    if ($null -ne $payload.targetMetadata) {
        foreach ($key in @('containerId','service','project','createdUtc')) {
            if ([string]::IsNullOrWhiteSpace([string]$payload.targetMetadata.$key)) { throw 'Capture target identity was incomplete.' }
            $record[$key]=[string]$payload.targetMetadata.$key
        }
    }
    exit 0
} catch {
    $cleanupConfirmed = $true
    if ($process) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                & (Join-Path $env:SystemRoot 'System32/taskkill.exe') /PID $process.Id /T /F *> $null
                [void]$process.WaitForExit(5000)
                $process.Refresh()
                if (-not $process.HasExited) { $cleanupConfirmed = $false }
            }
        } catch {
            $cleanupConfirmed = $false
        }
        if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) { $cleanupConfirmed = $false }
    }
    if (-not $cleanupConfirmed) { exit 23 }
    exit 22
}
