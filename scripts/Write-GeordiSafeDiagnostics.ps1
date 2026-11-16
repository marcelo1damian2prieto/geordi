[CmdletBinding()]
param([string] $SummaryPath = (Join-Path $PSScriptRoot '..\backend\target\.m19-evidence-gate-summary.txt'))

$ErrorActionPreference = 'Stop'
$summaryPath = $SummaryPath
if (!(Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    Write-Output 'diagnostics=withheld reason=required-gate-not-passed'
    return
}

try {
    $lines = @(Get-Content -LiteralPath $summaryPath)
    $allChannelLines = @($lines | Where-Object { $_ -match '^channel=[a-z-]+ positive_control=true raw_matches=0 encoded_matches=0 result=PASS$' })
    $channelLines = @($allChannelLines | Where-Object { $_ -notmatch '^channel=(loki|victoriametrics) ' })
    $persistedLines = @($lines | Where-Object { $_ -match '^persisted_channel=(loki|victoriametrics) positive_control=true result=PASS$' })
    $artifactLines = @($lines | Where-Object { $_ -match '^artifact_files=\d+ archives=\d+ archive_entries=\d+ result=PASS$' })
    if ($channelLines.Count -ne 9 -or $allChannelLines.Count -ne 11 -or $persistedLines.Count -ne 2 -or
            $artifactLines.Count -ne 1 -or $lines.Count -ne 14) {
        throw 'Invalid gate summary.'
    }
    Write-Output ("credential_gate=passed channels={0} persisted={1} artifacts=passed" -f $channelLines.Count,$persistedLines.Count)
    $state = & docker compose --file compose.yaml --file compose.m19.yaml --file compose.m14.yaml ps --all --format json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Container state unavailable.' }
    $count = 0
    foreach ($line in $state) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $count += @($line | ConvertFrom-Json).Count
    }
    Write-Output ("container_state_records={0}" -f $count)
} catch {
    Write-Output 'diagnostics=withheld reason=summary-validation-failed'
}
