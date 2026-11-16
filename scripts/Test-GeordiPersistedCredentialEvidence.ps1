[CmdletBinding()]
param([string] $ManifestPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiPersistedMetricEvidence.ps1')

try {
    if (!$ManifestPath -or !(Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw 'Persisted evidence manifest missing.'
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
    $manifestStart = ConvertTo-GeordiCaptureUtcInstant -Value $manifest.captureStartedUtc -Field 'manifest.captureStartedUtc'
    $manifestComplete = ConvertTo-GeordiCaptureUtcInstant -Value $manifest.completedUtc -Field 'manifest.completedUtc'
    foreach ($channel in @('loki', 'victoriametrics')) {
        $channelSources = @($manifest.additionalSources | Where-Object { [string]$_.channel -ceq $channel })
        if ($channelSources.Count -ne 1 -or !$channelSources[0].control -or @($channelSources[0].captures).Count -eq 0) {
            throw 'Persisted evidence source missing or ambiguous.'
        }
        $positive = $false
        [long]$aggregateBytes = 0
        $m11ResetContainerId = $null
        $m11FinalContainerId = $null
        foreach ($path in @($channelSources[0].captures)) {
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Persisted evidence capture missing.' }
            $fileBytes=[long](Get-Item -LiteralPath $path).Length
            if ($fileBytes -le 0 -or $fileBytes -gt 64MB) { throw 'Persisted evidence capture size is outside its bound.' }
            $aggregateBytes += $fileBytes
            if ($aggregateBytes -gt 64MB) { throw 'Persisted metric evidence exceeded its aggregate bound.' }
            $content = [IO.File]::ReadAllText($path)
            if ($channel -eq 'loki') {
                $payload = $content | ConvertFrom-Json
                if ([string]$payload.status -cne 'success' -or @($payload.data.result).Count -eq 0 -or
                        !$content.Contains([string]$channelSources[0].control, [StringComparison]::Ordinal)) {
                    throw 'Loki returned no persisted positive-control stream.'
                }
                $positive = $true
                continue
            }
            if ($path.EndsWith('.snapshot.json',[StringComparison]::OrdinalIgnoreCase)) {
                $ledger = $content | ConvertFrom-Json -AsHashtable
                if (!$ledger.ContainsKey('bytes') -or
                        ($ledger.bytes -isnot [byte] -and $ledger.bytes -isnot [int16] -and $ledger.bytes -isnot [int] -and $ledger.bytes -isnot [long] -and
                         $ledger.bytes -isnot [uint16] -and $ledger.bytes -isnot [uint32] -and $ledger.bytes -isnot [uint64])) {
                    throw 'VictoriaMetrics generation snapshot byte count is missing or malformed.'
                }
                $ledgerInterval = Get-GeordiPersistedMetricLedgerInterval -Ledger $ledger
                $intervalStart = $ledgerInterval.StartUtc
                $intervalEnd = $ledgerInterval.EndUtc
                $sourceValid = $ledger.source -ceq 'victoriametrics-export' -or
                    ($ledger.source -ceq 'verified-prior-generation-removal' -and $ledger.priorSnapshot -ceq 'm11-final' -and
                        [long]$ledger.series -eq 0 -and [long]$ledger.samples -eq 0 -and [long]$ledger.bytes -eq 0)
                if (!$sourceValid -or $ledger.complete -isnot [bool] -or !$ledger.complete -or
                        $ledger.runStartBound -isnot [bool] -or !$ledger.runStartBound -or
                        $intervalStart.UtcTicks -ne $manifestStart.UtcTicks -or $intervalEnd.UtcTicks -lt $intervalStart.UtcTicks) {
                    throw 'VictoriaMetrics generation snapshot ledger is incomplete.'
                }
                if ($ledger.source -ceq 'victoriametrics-export') {
                    $ledgerPath = [IO.Path]::GetFullPath([string]$path)
                    $ledgerName = [IO.Path]::GetFileName($ledgerPath)
                    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath `
                        -Captures ([string[]]$channelSources[0].captures))
                    if ($ledgerName -ceq 'm11-reset.snapshot.json') { $m11ResetContainerId = [string]$ledger.sourceContainerId }
                    if ($ledgerName -ceq 'm11-final.snapshot.json') { $m11FinalContainerId = [string]$ledger.sourceContainerId }
                }
                continue
            }
            foreach ($line in @($content -split "`r?`n" | Where-Object { ![string]::IsNullOrWhiteSpace($_) })) {
                $sampleSet = $line | ConvertFrom-Json -AsHashtable
                if ($null -eq $sampleSet.metric) { throw 'VictoriaMetrics raw export contained incomplete or out-of-scope metric data.' }
                $serviceName = if ($sampleSet.metric.Contains('service.name')) { [string]$sampleSet.metric['service.name'] } elseif ($sampleSet.metric.Contains('service_name')) { [string]$sampleSet.metric.service_name } else { '' }
                $telemetryOrigin = if ($sampleSet.metric.Contains('geordi.telemetry.origin')) { [string]$sampleSet.metric['geordi.telemetry.origin'] } elseif ($sampleSet.metric.Contains('geordi_telemetry_origin')) { [string]$sampleSet.metric.geordi_telemetry_origin } else { '' }
                if ($null -eq $sampleSet.metric -or $null -eq $sampleSet.values -or $null -eq $sampleSet.timestamps -or
                        @($sampleSet.values).Count -eq 0 -or @($sampleSet.timestamps).Count -eq 0 -or
                        @($sampleSet.values).Count -ne @($sampleSet.timestamps).Count -or
                        $serviceName -cne 'geordi-backend' -or $telemetryOrigin -cne 'platform') {
                    throw 'VictoriaMetrics raw export contained incomplete or out-of-scope metric data.'
                }
                foreach ($stamp in @($sampleSet.timestamps)) {
                    $sampleTime = ConvertTo-GeordiPersistedMetricSampleUtcInstant -Value $stamp
                    if ($sampleTime.UtcTicks -lt $manifestStart.UtcTicks -or
                            $sampleTime.UtcTicks -gt $manifestComplete.UtcTicks) {
                        throw 'VictoriaMetrics raw export escaped the current-run interval.'
                    }
                }
                    if ([string]$sampleSet.metric.'__name__' -ceq [string]$channelSources[0].control) { $positive = $true }
            }
        }
        if ($channel -eq 'victoriametrics' -and [long]$manifest.persistedMetricEvidenceBytes -ne $aggregateBytes) {
            throw 'VictoriaMetrics evidence byte ledger did not match captured files.'
        }
        if ($channel -eq 'victoriametrics' -and $m11ResetContainerId -and $m11FinalContainerId) {
            Assert-GeordiM11PersistedMetricIdentityBoundary -ResetContainerId $m11ResetContainerId -FinalContainerId $m11FinalContainerId
        }
        if (!$positive) { throw 'Persisted evidence capture was empty.' }
        Write-Output ("persisted_channel={0} positive_control=true result=PASS" -f $channel)
    }
} catch {
    throw 'Persisted credential evidence validation failed; private captures withheld.'
}
