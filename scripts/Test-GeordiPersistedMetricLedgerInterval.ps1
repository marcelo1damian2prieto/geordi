[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to exercise persisted VictoriaMetrics ledger/sample interval binding.' }
. (Join-Path $PSScriptRoot 'lib/GeordiPersistedMetricEvidence.ps1')

function Assert-GeordiVmInterval([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "VictoriaMetrics ledger interval regression failed: $Message" }
}
function New-GeordiVmSampleLine([long[]] $Timestamps,[switch] $MissingTimestamp,[switch] $MalformedTimestamp,[switch] $FractionalTimestamp) {
    $sample=[ordered]@{
        metric=[ordered]@{'__name__'='geordi.security.authentication.attempts_total';'service.name'='geordi-backend';'geordi.telemetry.origin'='platform'}
        values=@(for($index=0;$index -lt $Timestamps.Count;$index++){1})
    }
    if (!$MissingTimestamp) {
        if ($MalformedTimestamp) { $sample.timestamps=@('not-an-epoch') }
        elseif ($FractionalTimestamp) { $sample.timestamps=@(($Timestamps[0])+0.5) }
        else { $sample.timestamps=@($Timestamps) }
    }
    return ConvertTo-Json -InputObject $sample -Compress -Depth 8
}
function New-GeordiVmIntervalFixture([string] $Root,[long] $T0,[long] $T1,[long] $T2,[long] $T3) {
    $directory=Join-Path $Root 'victoriametrics-generations'
    [void][IO.Directory]::CreateDirectory($directory)
    $start=[DateTimeOffset]::FromUnixTimeMilliseconds($T0)
    $end=[DateTimeOffset]::FromUnixTimeMilliseconds($T3)
    $lokiPath=Join-Path $Root 'loki.json'
    $loki=@{status='success';data=@{result=@(@{stream=@{app='geordi-backend'};values=@(@('1','geordi.security.authentication.attempts'))})}} | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($lokiPath,$loki,[Text.UTF8Encoding]::new($false))
    $captures=[Collections.Generic.List[string]]::new()
    $ledgers=[ordered]@{}
    foreach($phase in @('m11-reset','m11-final')) {
        $artifact=Join-Path $directory "$phase.jsonl"
        $ledgerPath=Join-Path $directory "$phase.snapshot.json"
        $line=New-GeordiVmSampleLine -Timestamps @($T1,$T2)
        [IO.File]::WriteAllText($artifact,$line,[Text.UTF8Encoding]::new($false))
        $ledger=[ordered]@{intervalStartUtc=$start.ToString('o');intervalEndUtc=$end.ToString('o');source='victoriametrics-export';complete=$true;
            runStartBound=$true;series=1;samples=2;bytes=[long](Get-Item -LiteralPath $artifact).Length}
        $identity=@{sourceService='victoriametrics';sourceContainerId=$(if($phase -ceq 'm11-reset'){'a'*64}else{'b'*64})}
        Add-GeordiPersistedMetricArtifactBinding -Ledger $ledger -Source 'victoriametrics-export' -SourceIdentity $identity `
            -SnapshotTemporaryPath $artifact -Bytes ([long]$ledger.bytes)
        [IO.File]::WriteAllText($ledgerPath,($ledger|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
        $captures.Add($artifact);$captures.Add($ledgerPath)
        $ledgers[$phase]=[pscustomobject]@{Path=$ledgerPath;Artifact=$artifact;Value=$ledger;Identity=$identity}
    }
    $manifestPath=Join-Path $Root 'manifest.json'
    $manifest=[ordered]@{captureStartedUtc=$start.ToString('o');completedUtc=$end.ToString('o');additionalSources=@(
        @{channel='loki';control='geordi.security.authentication.attempts';captures=@($lokiPath)},
        @{channel='victoriametrics';control='geordi.security.authentication.attempts_total';captures=@($captures.ToArray())})}
    $manifest.persistedMetricEvidenceBytes=[long](@($captures|ForEach-Object{(Get-Item -LiteralPath $_).Length}|Measure-Object -Sum).Sum)
    [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Root=$Root;ManifestPath=$manifestPath;Manifest=$manifest;Captures=$captures;Ledgers=$ledgers;LokiPath=$lokiPath;T0=$T0;T1=$T1;T2=$T2;T3=$T3}
}
function Reset-GeordiVmIntervalFixture($Fixture) {
    $root=$Fixture.Root
    $times=@($Fixture.T0,$Fixture.T1,$Fixture.T2,$Fixture.T3)
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
    [void][IO.Directory]::CreateDirectory($root)
    return New-GeordiVmIntervalFixture -Root $root -T0 $times[0] -T1 $times[1] -T2 $times[2] -T3 $times[3]
}
function Set-GeordiVmFinalArtifact($Fixture,[long[]] $Timestamps,[long] $IntervalEnd,[switch] $MissingTimestamp,[switch] $MalformedTimestamp,[switch] $FractionalTimestamp) {
    $phase=$Fixture.Ledgers['m11-final']
    $line=New-GeordiVmSampleLine -Timestamps $Timestamps -MissingTimestamp:$MissingTimestamp -MalformedTimestamp:$MalformedTimestamp -FractionalTimestamp:$FractionalTimestamp
    [IO.File]::WriteAllText($phase.Artifact,$line,[Text.UTF8Encoding]::new($false))
    $phase.Value.intervalEndUtc=[DateTimeOffset]::FromUnixTimeMilliseconds($IntervalEnd).ToString('o')
    $phase.Value.samples=$Timestamps.Count
    $phase.Value.series=1
    Add-GeordiPersistedMetricArtifactBinding -Ledger $phase.Value -Source 'victoriametrics-export' -SourceIdentity $phase.Identity `
        -SnapshotTemporaryPath $phase.Artifact -Bytes ([long](Get-Item -LiteralPath $phase.Artifact).Length)
    [IO.File]::WriteAllText($phase.Path,($phase.Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Set-GeordiVmFinalRawArtifact($Fixture,[string] $Content,[long] $IntervalEnd) {
    $phase=$Fixture.Ledgers['m11-final']
    [IO.File]::WriteAllText($phase.Artifact,$Content,[Text.UTF8Encoding]::new($false))
    $phase.Value.intervalEndUtc=[DateTimeOffset]::FromUnixTimeMilliseconds($IntervalEnd).ToString('o')
    $phase.Value.samples=1
    $phase.Value.series=1
    Add-GeordiPersistedMetricArtifactBinding -Ledger $phase.Value -Source 'victoriametrics-export' -SourceIdentity $phase.Identity `
        -SnapshotTemporaryPath $phase.Artifact -Bytes ([long](Get-Item -LiteralPath $phase.Artifact).Length)
    [IO.File]::WriteAllText($phase.Path,($phase.Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-GeordiVmIntervalValidator($Fixture) {
    $script:vmIntervalFailureType=$null
    $vmSource=@($Fixture.Manifest.additionalSources|Where-Object{$_.channel -ceq 'victoriametrics'})[0]
    try {
        foreach($ledgerPath in @($vmSource.captures|Where-Object{[string]$_ -like '*.snapshot.json'})) {
            $ledger=Get-Content -LiteralPath $ledgerPath -Raw|ConvertFrom-Json -AsHashtable
            [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $ledger -LedgerPath $ledgerPath -Captures ([string[]]$vmSource.captures))
        }
        $Fixture.Manifest.persistedMetricEvidenceBytes=[long](@($vmSource.captures|ForEach-Object{(Get-Item -LiteralPath $_).Length}|Measure-Object -Sum).Sum)
        [IO.File]::WriteAllText($Fixture.ManifestPath,(ConvertTo-Json -InputObject $Fixture.Manifest -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
        $null=& (Join-Path $PSScriptRoot 'Test-GeordiPersistedCredentialEvidence.ps1') -ManifestPath $Fixture.ManifestPath
        return $true
    } catch { $script:vmIntervalFailureType=$_.Exception.GetType().Name; return $false }
}
function Assert-GeordiVmIntervalValidator($Fixture,[bool] $Expected,[string] $Case) {
    $actual=Invoke-GeordiVmIntervalValidator $Fixture
    $comparison = [bool]($actual -eq $Expected)
    Assert-GeordiVmInterval $comparison "$Case returned $actual; expected $Expected; validator exception type=$script:vmIntervalFailureType"
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-vm-ledger-interval-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$t0=[DateTimeOffset]::Parse('2025-01-01T00:00:00Z').ToUnixTimeMilliseconds()
$t1=$t0+1000;$t2=$t0+2000;$t3=$t0+3000;$t4=$t0+4000
$beforeStart=$t0-1;$afterEnd=$t3+1
try {
    $fixture=New-GeordiVmIntervalFixture -Root $root -T0 $t0 -T1 $t1 -T2 $t2 -T3 $t3
    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t0,$t1,$t3) $t3
    Assert-GeordiVmIntervalValidator $fixture $true 'all samples inside the inclusive interval'
    Write-Output 'vm_ledger_interval_all_samples_inside=PASS'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($beforeStart,$t1) $t3
    Assert-GeordiVmIntervalValidator $fixture $false 'sample before interval start'
    Write-Output 'vm_ledger_interval_before_start=REJECTED'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t1,$afterEnd) $t3
    Assert-GeordiVmIntervalValidator $fixture $false 'sample after interval end'
    Write-Output 'vm_ledger_interval_after_end=REJECTED'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($beforeStart,$t1) $t3
    Assert-GeordiVmIntervalValidator $fixture $false 'mixed inside and before-start samples'
    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t1,$afterEnd) $t3
    Assert-GeordiVmIntervalValidator $fixture $false 'mixed inside and after-end samples'
    Write-Output 'vm_ledger_interval_mixed_samples=REJECTED'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t1,$t3) $t3
    $artifactPath=$fixture.Ledgers['m11-final'].Artifact
    $ledgerPath=$fixture.Ledgers['m11-final'].Path
    $originalBytes=(Get-Item -LiteralPath $artifactPath).Length
    $originalHash=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    $originalSourceId=$fixture.Ledgers['m11-final'].Value.sourceContainerId
    $fixture.Ledgers['m11-final'].Value.intervalEndUtc=[DateTimeOffset]::FromUnixTimeMilliseconds($t2).ToString('o')
    [IO.File]::WriteAllText($ledgerPath,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Assert-GeordiVmIntervalValidator $fixture $false 'unchanged artifact with narrowed ledger interval'
    Assert-GeordiVmInterval ((Get-Item -LiteralPath $artifactPath).Length -eq $originalBytes -and
        (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash -ceq $originalHash -and
        $fixture.Ledgers['m11-final'].Value.sourceContainerId -ceq $originalSourceId) 'narrowed ledger test changed artifact or identity'
    Write-Output 'vm_ledger_narrowed_unchanged_artifact=REJECTED artifact_unchanged=true hash_unchanged=true identity_unchanged=true'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t1,$t3) $t4
    Assert-GeordiVmIntervalValidator $fixture $true 'widened ledger interval containing every sample'
    Write-Output 'vm_ledger_interval_widened=PASS all_samples_still_inside=true'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t0,$t3) $t3
    Assert-GeordiVmIntervalValidator $fixture $true 'start and end boundary samples'
    Write-Output 'vm_ledger_interval_boundaries=PASS start_inclusive=true end_inclusive=true'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t1) $t3 -MalformedTimestamp
    Assert-GeordiVmIntervalValidator $fixture $false 'malformed sample timestamp'
    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t1) $t3 -FractionalTimestamp
    Assert-GeordiVmIntervalValidator $fixture $false 'fractional unsupported timestamp precision'
    $fixture=Reset-GeordiVmIntervalFixture $fixture
    Set-GeordiVmFinalArtifact $fixture @($t1) $t3 -MissingTimestamp
    Assert-GeordiVmIntervalValidator $fixture $false 'missing sample timestamp'
    Write-Output 'vm_ledger_interval_timestamp_validation=PASS malformed=REJECTED fractional=REJECTED missing=REJECTED'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    $offsetStart=([DateTimeOffset]::FromUnixTimeMilliseconds($t0)).ToOffset([TimeSpan]::FromHours(1)).ToString('o')
    $offsetEnd=([DateTimeOffset]::FromUnixTimeMilliseconds($t3)).ToOffset([TimeSpan]::FromHours(-4)).ToString('o')
    $fixture.Ledgers['m11-final'].Value.intervalStartUtc=$offsetStart
    $fixture.Ledgers['m11-final'].Value.intervalEndUtc=$offsetEnd
    [IO.File]::WriteAllText($fixture.Ledgers['m11-final'].Path,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Assert-GeordiVmIntervalValidator $fixture $true 'offset-equivalent ledger instants'
    Write-Output 'vm_ledger_interval_utc_normalization=PASS offset_equivalent_instants=true'

    $fixture=Reset-GeordiVmIntervalFixture $fixture
    $fixture.Ledgers['m11-final'].Value.intervalStartUtc='2025-01-01T00:00:00'
    [IO.File]::WriteAllText($fixture.Ledgers['m11-final'].Path,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Assert-GeordiVmIntervalValidator $fixture $false 'ambiguous local ledger timestamp'
    Write-Output 'vm_ledger_interval_ambiguous_local=REJECTED'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if([IO.Path]::GetDirectoryName($resolved) -cne $expected -or (Split-Path $resolved -Leaf) -notmatch '^geordi-vm-ledger-interval-[0-9a-f]{32}$') {
        throw 'Unsafe persisted metric ledger interval self-test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
