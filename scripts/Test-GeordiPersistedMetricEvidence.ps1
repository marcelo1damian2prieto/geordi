[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to exercise the bounded raw VictoriaMetrics export verifier.' }
. (Join-Path $PSScriptRoot 'lib/GeordiPersistedMetricEvidence.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-vm-export-selftest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$start=[DateTimeOffset]::UtcNow.AddMinutes(-1)
$end=[DateTimeOffset]::UtcNow
$stamp=$end.ToUnixTimeMilliseconds()
$path=Join-Path $root 'metrics.jsonl'
try {
    $lines=@(
        (@{metric=@{'__name__'='geordi.security.authentication.attempts_total';'service.name'='geordi-backend';'geordi.telemetry.origin'='platform'};values=@('1');timestamps=@($stamp)}|ConvertTo-Json -Compress -Depth 8),
        (@{metric=@{'__name__'='geordi.test.short_lived';service_name='geordi-backend';geordi_telemetry_origin='platform';http_request_header_authorization=''};values=@(0);timestamps=@($stamp)}|ConvertTo-Json -Compress -Depth 8)
    )
    [IO.File]::WriteAllText($path,($lines -join "`n"),[Text.UTF8Encoding]::new($false))
    $result=Test-GeordiPersistedMetricExportFile -Path $path -StartUtc $start -EndUtc $end
    if (!$result.PositiveControl -or $result.PositiveMetricName -cne 'geordi.security.authentication.attempts_total' -or
            $result.Series -ne 2 -or $result.Samples -ne 2) { throw 'VictoriaMetrics raw export positive self-test failed.' }
    $missingTemporary=Join-Path $root 'verified-prior-generation.tmp'
    $emptySnapshot=Join-Path $root 'verified-prior-generation.jsonl'
    if ($null -ne (Complete-GeordiPersistedMetricSnapshotFile -TemporaryPath $missingTemporary -SnapshotPath $emptySnapshot -Bytes 0) -or
            (Test-Path -LiteralPath $missingTemporary) -or (Test-Path -LiteralPath $emptySnapshot)) {
        throw 'VictoriaMetrics removed-generation handoff self-test failed.'
    }
    [IO.File]::WriteAllBytes($missingTemporary,[byte[]]::new(0))
    [void](Complete-GeordiPersistedMetricSnapshotFile -TemporaryPath $missingTemporary -SnapshotPath $emptySnapshot -Bytes 0)
    if (Test-Path -LiteralPath $missingTemporary) { throw 'VictoriaMetrics empty temporary snapshot cleanup self-test failed.' }
    $outOfScopePath=Join-Path $root 'out-of-scope.jsonl'
    $bad=@{metric=@{'__name__'='geordi.test.unrelated';service_name='another-service';geordi_telemetry_origin='platform'};values=@(0);timestamps=@($stamp)}|
        ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($outOfScopePath,$bad,[Text.UTF8Encoding]::new($false))
    $rejected=$false
    try { [void](Test-GeordiPersistedMetricExportFile -Path $outOfScopePath -StartUtc $start -EndUtc $end) }
    catch { $rejected=$_.Exception.Message -like '*out-of-scope*' }
    if (!$rejected) { throw 'VictoriaMetrics raw export accepted an out-of-scope metric.' }
    Write-Output 'victoriametrics_raw_export_self_test=PASS cases=dotted_otlp_labels,underscore_compatibility,zero_value_series,short_lived_series,removed_generation_handoff,out_of_scope_rejected'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $expected -or
            (Split-Path $resolved -Leaf) -notmatch '^geordi-vm-export-selftest-[0-9a-f]{32}$') { throw 'Unsafe VictoriaMetrics self-test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
