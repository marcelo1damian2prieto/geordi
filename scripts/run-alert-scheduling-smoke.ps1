[CmdletBinding()]
param([int]$TimeoutSeconds=360,[string]$OutputDirectory=(Join-Path $env:TEMP 'geordi-m12'),[string]$TargetScript=(Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1'))

$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory|Out-Null
$resultFile=Join-Path $OutputDirectory 'm12-smoke.result.json'
$stdoutFile=Join-Path $OutputDirectory 'm12-smoke.stdout.log'
$stderrFile=Join-Path $OutputDirectory 'm12-smoke.stderr.log'
$statusFile=Join-Path $OutputDirectory 'm12-smoke.status.json'
Remove-Item -LiteralPath $resultFile,$stdoutFile,$stderrFile,$statusFile -Force -ErrorAction SilentlyContinue
$started=[DateTime]::UtcNow; $exitCode=1; $classification='FAIL'; $errorMessage=$null; $targetPid=$null
function Test-DeadlineDiagnostic([string]$Diagnostic){$Diagnostic -match '(?i)global smoke deadline expired|native process timeout|operation timed out|timed out waiting|timeout exception'}
try {
  $targetPath=(Resolve-Path -LiteralPath $TargetScript -ErrorAction Stop).Path
  $arguments=@('-NoProfile','-NonInteractive','-File',$targetPath,'-TimeoutSeconds',$TimeoutSeconds)
  if($targetPath -eq (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'verify-alert-scheduling.ps1')).Path){$arguments+=@('-StatusFile',$statusFile)}
  $target=Start-Process -FilePath pwsh -ArgumentList $arguments -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru -Wait -WindowStyle Hidden
  $targetPid=$target.Id; $exitCode=$target.ExitCode
  if($exitCode -eq 0){$classification='PASS'} else {
    $errorMessage=(Get-Content -Raw -LiteralPath $stderrFile -ErrorAction SilentlyContinue).Trim()
    if((Test-DeadlineDiagnostic $errorMessage) -or (Test-DeadlineDiagnostic (Get-Content -Raw -LiteralPath $stdoutFile -ErrorAction SilentlyContinue))){$classification='TIMEOUT'}
  }
}
catch { $errorMessage=$_.Exception.ToString(); if(Test-DeadlineDiagnostic $errorMessage){$classification='TIMEOUT'}; [Console]::Error.WriteLine($errorMessage) }
finally {
  $finished=[DateTime]::UtcNow
  $lastSmokeStatus=$null
  if(Test-Path -LiteralPath $statusFile){try{$lastSmokeStatus=Get-Content -Raw -LiteralPath $statusFile|ConvertFrom-Json}catch{$lastSmokeStatus=[pscustomobject]@{readError=$_.Exception.Message}}}
  [pscustomobject]@{startedAt=$started.ToString('O');finishedAt=$finished.ToString('O');elapsedSeconds=[math]::Round(($finished-$started).TotalSeconds,3);exitCode=$exitCode;classification=$classification;pid=$PID;targetPid=$targetPid;timeoutSeconds=$TimeoutSeconds;error=$errorMessage;lastSmokeStatus=$lastSmokeStatus}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $resultFile
}
exit $exitCode
