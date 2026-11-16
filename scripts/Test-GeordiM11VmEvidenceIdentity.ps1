[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to exercise M11 persisted VictoriaMetrics identity binding.' }
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiPersistedMetricEvidence.ps1')

function Assert-M11Vm([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M11 VictoriaMetrics identity regression failed: $Message" }
}
function New-VmIdentity([string] $Id, [string] $Project='geordi', [string] $Service='victoriametrics', [string] $WorkingDirectory=(Get-Location).Path, [bool] $Running=$true) {
    return [pscustomobject]@{Id=$Id;Project=$Project;Service=$Service;WorkingDirectory=$WorkingDirectory;
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$Running}
}
function Invoke-OfflineValidator([string] $ManifestPath) {
    try { $null = & (Join-Path $PSScriptRoot 'Test-GeordiPersistedCredentialEvidence.ps1') -ManifestPath $ManifestPath; return $true }
    catch { return $false }
}
function New-ValidMetricFixture([string] $Root, [bool] $IncludeReset=$true, [bool] $IncludeFinal=$true) {
    $directory=Join-Path $Root 'victoriametrics-generations'
    [void][IO.Directory]::CreateDirectory($directory)
    $start=[DateTimeOffset]::UtcNow.AddMinutes(-1)
    $end=[DateTimeOffset]::UtcNow.AddSeconds(1)
    $stamp=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $control='geordi.security.authentication.attempts_total'
    $sample=@{metric=@{'__name__'=$control;'service.name'='geordi-backend';'geordi.telemetry.origin'='platform'};values=@('1');timestamps=@($stamp)} | ConvertTo-Json -Compress -Depth 8
    $lokiPath=Join-Path $Root 'loki.json'
    $loki=@{status='success';data=@{result=@(@{stream=@{app='geordi-backend'};values=@(@('1','geordi.security.authentication.attempts'))})}} | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($lokiPath,$loki,[Text.UTF8Encoding]::new($false))
    $captures=[Collections.Generic.List[string]]::new();$ledgers=[ordered]@{}
    foreach($phase in @('m11-reset','m11-final')) {
        if (($phase -ceq 'm11-reset' -and !$IncludeReset) -or ($phase -ceq 'm11-final' -and !$IncludeFinal)) { continue }
        $artifact=Join-Path $directory "$phase.jsonl"
        $ledgerPath=Join-Path $directory "$phase.snapshot.json"
        [IO.File]::WriteAllText($artifact,$sample,[Text.UTF8Encoding]::new($false))
        $sourceId=if($phase -ceq 'm11-reset'){'a'*64}else{'b'*64}
        $identity=@{sourceService='victoriametrics';sourceContainerId=$sourceId}
        $ledger=@{intervalStartUtc=$start.ToString('o');intervalEndUtc=$end.ToString('o');source='victoriametrics-export';complete=$true;
            runStartBound=$true;series=1;samples=1;bytes=[long](Get-Item -LiteralPath $artifact).Length}
        Add-GeordiPersistedMetricArtifactBinding -Ledger $ledger -Source 'victoriametrics-export' -SourceIdentity $identity -SnapshotTemporaryPath $artifact -Bytes ([long]$ledger.bytes)
        [IO.File]::WriteAllText($ledgerPath,($ledger|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
        $captures.Add($artifact);$captures.Add($ledgerPath);$ledgers[$phase]=[pscustomobject]@{Path=$ledgerPath;Artifact=$artifact;Value=$ledger;Identity=$identity}
    }
    $manifestPath=Join-Path $Root 'manifest.json'
    $metricSource=@{channel='victoriametrics';control=$control;captures=@($captures.ToArray())}
    $manifest=[ordered]@{captureStartedUtc=$start.ToString('o');completedUtc=$end.ToString('o');additionalSources=@(
        @{channel='loki';control='geordi.security.authentication.attempts';captures=@($lokiPath)},$metricSource)}
    $manifest.persistedMetricEvidenceBytes=[long](@($captures|ForEach-Object{(Get-Item -LiteralPath $_).Length}|Measure-Object -Sum).Sum)
    [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Root=$Root;ManifestPath=$manifestPath;Manifest=$manifest;Captures=$captures;Ledgers=$ledgers;LokiPath=$lokiPath;Control=$control}
}
function Reset-VmFixture($Fixture) {
    foreach($path in @($Fixture.Captures)+@($Fixture.LokiPath)) { if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force} }
    $directory=Join-Path $Fixture.Root 'victoriametrics-generations'
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force}
    return New-ValidMetricFixture -Root $Fixture.Root
}
function Invoke-FixtureValidator($Fixture) {
    $vmSource=@($Fixture.Manifest.additionalSources|Where-Object{$_.channel -ceq 'victoriametrics'})[0]
    $aggregate=0L
    foreach($capture in @($vmSource.captures)){if(Test-Path -LiteralPath $capture -PathType Leaf){$aggregate += [long](Get-Item -LiteralPath $capture).Length}}
    $Fixture.Manifest.persistedMetricEvidenceBytes=$aggregate
    [IO.File]::WriteAllText($Fixture.ManifestPath,(ConvertTo-Json -InputObject $Fixture.Manifest -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
    return Invoke-OfflineValidator $Fixture.ManifestPath
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m11-vm-identity-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $expectedRoot=[IO.Path]::GetFullPath((Get-Location).Path)
    $validIdentity=New-VmIdentity -Id ('1'*64) -WorkingDirectory $expectedRoot
    $resolverState=@{Values=@($validIdentity);Failure=$false}
    $resolver={param($service) if($resolverState.Failure){throw 'synthetic resolver fault'};$resolverState.Values}.GetNewClosure()
    $resolved=Get-GeordiPersistedMetricSourceIdentity -Phase m11-reset -RepositoryRoot $expectedRoot -ResolveIdentity $resolver
    Assert-M11Vm ($resolved.sourceService -ceq 'victoriametrics' -and $resolved.sourceContainerId -ceq ('1'*64)) 'single valid live VM identity rejected'
    Write-Output 'vm_identity_resolver_matrix=PASS exactly_one_correct=PASS'
    foreach($case in @(
        @{name='zero';values=@();failure=$false},
        @{name='multiple';values=@((New-VmIdentity -Id ('2'*64) -WorkingDirectory $expectedRoot),(New-VmIdentity -Id ('3'*64) -WorkingDirectory $expectedRoot));failure=$false},
        @{name='wrong-owner';values=@((New-VmIdentity -Id ('4'*64) -Project 'other' -WorkingDirectory $expectedRoot));failure=$false},
        @{name='wrong-service';values=@((New-VmIdentity -Id ('5'*64) -Service 'backend' -WorkingDirectory $expectedRoot));failure=$false},
        @{name='not-running';values=@((New-VmIdentity -Id ('7'*64) -WorkingDirectory $expectedRoot -Running:$false));failure=$false},
        @{name='malformed-id';values=@((New-VmIdentity -Id 'abcd' -WorkingDirectory $expectedRoot));failure=$false},
        @{name='resolver-failure';values=@();failure=$true}
    )) {
        $resolverState.Values=$case.values;$resolverState.Failure=$case.failure
        $caseRoot=Join-Path $root ("identity-failure-"+$case.name)
        $snapshotDirectory=Join-Path $caseRoot 'victoriametrics-generations'
        [void][IO.Directory]::CreateDirectory($snapshotDirectory)
        $snapshotPath=Join-Path $snapshotDirectory 'm11-reset.jsonl'
        $ledgerPath=Join-Path $snapshotDirectory 'm11-reset.snapshot.json'
        $manifestPath=Join-Path $caseRoot 'manifest.json'
        $manifestBefore=[ordered]@{additionalSources=@(@{channel='victoriametrics';control='geordi.security.authentication.attempts';captures=@()})}
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifestBefore -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
        $manifestHashBefore=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $rejected=$false
        try{[void](Get-GeordiPersistedMetricSourceIdentity -Phase m11-reset -RepositoryRoot $expectedRoot -ResolveIdentity $resolver)}catch{$rejected=$true}
        Assert-M11Vm $rejected ("$($case.name) identity was accepted")
        Assert-M11Vm (!(Test-Path -LiteralPath $snapshotPath) -and !(Test-Path -LiteralPath $ledgerPath) -and
            @([IO.Directory]::EnumerateFiles($snapshotDirectory,'m11-reset.jsonl.*.tmp')).Count -eq 0 -and
            @([IO.Directory]::EnumerateFiles($snapshotDirectory,'m11-reset.snapshot.json.*.tmp')).Count -eq 0) `
            ("$($case.name) identity failure wrote an authoritative or temporary destination")
        Assert-M11Vm ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $manifestHashBefore) `
            ("$($case.name) identity failure changed manifest references")
    }
    Write-Output 'vm_identity_resolver_matrix=PASS zero=FAIL_CLOSED multiple=FAIL_CLOSED wrong_owner=FAIL_CLOSED wrong_service=FAIL_CLOSED stopped=FAIL_CLOSED malformed=FAIL_CLOSED resolver_error=FAIL_CLOSED'
    $captureSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Capture-GeordiM19Generation.ps1'))
    $identityResolveAt=$captureSource.IndexOf('Get-GeordiPersistedMetricSourceIdentity -Phase', [StringComparison]::Ordinal)
    $exportAt=$captureSource.IndexOf('Export-GeordiPersistedMetricSamples -StartUtc', [StringComparison]::Ordinal)
    $publishAt=$captureSource.IndexOf('Complete-GeordiPersistedMetricSnapshotFile -TemporaryPath', [StringComparison]::Ordinal)
    Assert-M11Vm ($identityResolveAt -ge 0 -and $identityResolveAt -lt $exportAt -and $exportAt -lt $publishAt) `
        'production capture resolves source identity after export or publication'
    $snapshotPathSource='$snapshotPath = if ($isM14Event) { $snapshotPaths.SnapshotPath } else { Join-Path $snapshotDirectory "$snapshotKey.jsonl" }'
    $ledgerPathSource='$snapshotLedgerPath = if ($isM14Event) { $snapshotPaths.LedgerPath } else { Join-Path $snapshotDirectory "$snapshotKey.snapshot.json" }'
    Assert-M11Vm ($captureSource.Contains($snapshotPathSource,[StringComparison]::Ordinal) -and
        $captureSource.Contains($ledgerPathSource,[StringComparison]::Ordinal)) 'identity failure matrix did not derive destinations from production path construction'
    Write-Output 'identity_failure_before_evidence_publication=PASS actual_destinations=checked manifest_unchanged=true'

    $fixture=New-ValidMetricFixture -Root $root
    $resetLedger=Get-Content -LiteralPath $fixture.Ledgers['m11-reset'].Path -Raw | ConvertFrom-Json -AsHashtable
    [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $resetLedger -LedgerPath $fixture.Ledgers['m11-reset'].Path `
        -Captures ([string[]]$fixture.Manifest.additionalSources[1].captures))
    Assert-M11Vm ($resetLedger.sourceContainerId -ceq $fixture.Ledgers['m11-reset'].Identity.sourceContainerId) 'm11-reset ledger lost VM_OLD identity'
    Write-Output 'm11_reset_exact_source_binding=PASS'

    $finalIdentity=$fixture.Ledgers['m11-final'].Identity
    $resetId=Assert-GeordiM11FinalSourceTransition -Manifest $fixture.Manifest `
        -SnapshotDirectory (Join-Path $root 'victoriametrics-generations') -FinalSourceIdentity $finalIdentity `
        -CaptureStartedUtc ([DateTimeOffset]$fixture.Manifest.captureStartedUtc)
    Assert-M11Vm ($resetId -ceq $fixture.Ledgers['m11-reset'].Identity.sourceContainerId -and
        $finalIdentity.sourceContainerId -ceq $fixture.Ledgers['m11-final'].Identity.sourceContainerId) 'm11-final did not bind the distinct live VM_NEW identity'
    Assert-M11Vm (Invoke-FixtureValidator $fixture) 'valid m11-reset/m11-final ledger/artifact pair was rejected'
    Write-Output 'm11_final_exact_source_binding=PASS'

    Assert-GeordiM11PersistedMetricIdentityBoundary -ResetContainerId $fixture.Ledgers['m11-reset'].Identity.sourceContainerId `
        -FinalContainerId $fixture.Ledgers['m11-final'].Identity.sourceContainerId
    Write-Output 'm11_reset_binding=PASS VM_OLD';Write-Output 'm11_final_binding=PASS VM_NEW';Write-Output 'vm_old_not_equal_vm_new=PASS'

    $fixture=Reset-VmFixture $fixture
    $fixture.Ledgers['m11-final'].Value.sourceContainerId=$fixture.Ledgers['m11-reset'].Identity.sourceContainerId
    [IO.File]::WriteAllText($fixture.Ledgers['m11-final'].Path,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    $preflightSnapshotHash=(Get-FileHash -LiteralPath $fixture.Ledgers['m11-final'].Artifact -Algorithm SHA256).Hash
    $sameIdRejected=$false
    try { [void](Assert-GeordiM11FinalSourceTransition -Manifest $fixture.Manifest -SnapshotDirectory (Join-Path $root 'victoriametrics-generations') `
        -FinalSourceIdentity @{sourceService='victoriametrics';sourceContainerId=$fixture.Ledgers['m11-reset'].Identity.sourceContainerId} `
        -CaptureStartedUtc ([DateTimeOffset]$fixture.Manifest.captureStartedUtc)) } catch { $sameIdRejected=$true }
    Assert-M11Vm ($sameIdRejected -and (Get-FileHash -LiteralPath $fixture.Ledgers['m11-final'].Artifact -Algorithm SHA256).Hash -ceq $preflightSnapshotHash) `
        'M11 final transition accepted the same VM identity or published evidence'
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'same VictoriaMetrics identity was accepted across the M11 destructive boundary'
    Write-Output 'vm_old_equals_vm_new=PASS REJECTED'

    foreach($case in @(
        @{name='missing-identity';mutate={param($f)$l=$f.Ledgers['m11-final'].Value;$l.Remove('sourceContainerId')}},
        @{name='malformed-identity';mutate={param($f)$f.Ledgers['m11-final'].Value.sourceContainerId='short'}},
        @{name='wrong-service';mutate={param($f)$f.Ledgers['m11-final'].Value.sourceService='backend'}}
    )) {
        $fixture=Reset-VmFixture $fixture
        & $case.mutate $fixture
        [IO.File]::WriteAllText($fixture.Ledgers['m11-final'].Path,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
        Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) ("$($case.name) identity accepted")
    }
    Write-Output 'identity_tampering=PASS missing=REJECTED malformed=REJECTED wrong_service=REJECTED'

    $fixture=Reset-VmFixture $fixture
    $fixture.Ledgers['m11-final'].Value.Remove('bytes')
    [IO.File]::WriteAllText($fixture.Ledgers['m11-final'].Path,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'missing ledger byte count accepted'
    $fixture=Reset-VmFixture $fixture
    $fixture.Ledgers['m11-final'].Value.bytes++
    [IO.File]::WriteAllText($fixture.Ledgers['m11-final'].Path,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'snapshot byte mismatch accepted'
    Write-Output 'artifact_byte_binding=PASS mismatch=REJECTED'

    $fixture=Reset-VmFixture $fixture
    $snapshotFile=$fixture.Ledgers['m11-final'].Artifact
    $originalSample=[IO.File]::ReadAllText($snapshotFile)
    $modifiedSample=$originalSample.Replace('"1"','"2"')
    Assert-M11Vm ($modifiedSample -cne $originalSample) 'snapshot tamper fixture did not change artifact bytes'
    [IO.File]::WriteAllText($snapshotFile,$modifiedSample,[Text.UTF8Encoding]::new($false))
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'modified snapshot with stale ledger hash accepted'
    $fixture=Reset-VmFixture $fixture
    $fixture.Ledgers['m11-final'].Value.snapshotSha256='0'*64
    [IO.File]::WriteAllText($fixture.Ledgers['m11-final'].Path,($fixture.Ledgers['m11-final'].Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'ledger hash tampering accepted'
    Write-Output 'artifact_hash_binding=PASS snapshot_tampering=REJECTED ledger_hash_tampering=REJECTED'

    $fixture=Reset-VmFixture $fixture
    $emptyFinal=$fixture.Ledgers['m11-final']
    Remove-Item -LiteralPath $emptyFinal.Artifact -Force
    $emptyFinal.Value.bytes=0L;$emptyFinal.Value.series=0;$emptyFinal.Value.samples=0L
    $emptyFinal.Value.Remove('snapshotSha256')
    [IO.File]::WriteAllText($emptyFinal.Path,($emptyFinal.Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    $fixture.Manifest.additionalSources[1].captures=@($fixture.Ledgers['m11-reset'].Artifact,$fixture.Ledgers['m11-reset'].Path,$emptyFinal.Path)
    Assert-M11Vm (Invoke-FixtureValidator $fixture) 'valid empty m11-final export was not accepted without a physical snapshot'
    Write-Output 'empty_snapshot_semantics=PASS no_jsonl_no_hash_zero_bytes=true'

    $fixture=Reset-VmFixture $fixture
    $emptyFinal=$fixture.Ledgers['m11-final']
    $emptyFinal.Value.bytes=0L;$emptyFinal.Value.series=0;$emptyFinal.Value.samples=0L
    $emptyFinal.Value.Remove('snapshotSha256')
    [IO.File]::WriteAllText($emptyFinal.Path,($emptyFinal.Value|ConvertTo-Json -Compress -Depth 8),[Text.UTF8Encoding]::new($false))
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'zero-byte ledger accepted its contradictory nonempty artifact'
    Write-Output 'zero_byte_contradictory_artifact=PASS REJECTED'

    $fixture=Reset-VmFixture $fixture
    $finalArtifact=$fixture.Ledgers['m11-final'].Artifact
    Remove-Item -LiteralPath $finalArtifact -Force
    $fixture.Manifest.additionalSources[1].captures=@($fixture.Ledgers['m11-reset'].Artifact,$fixture.Ledgers['m11-reset'].Path,$fixture.Ledgers['m11-final'].Path)
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'm11-final ledger accepted m11-reset artifact pairing'
    Write-Output 'phase_artifact_pairing=PASS wrong_phase=REJECTED'

    $fixture=Reset-VmFixture $fixture
    Remove-Item -LiteralPath $fixture.Ledgers['m11-final'].Artifact -Force
    Assert-M11Vm (!(Invoke-FixtureValidator $fixture)) 'nonzero snapshot claim with missing artifact accepted'
    Write-Output 'missing_nonempty_artifact=PASS REJECTED'

    $fixture=Reset-VmFixture $fixture
    $null=& (Join-Path $PSScriptRoot 'Test-GeordiM11FinalEvidence.ps1') -SelfTest
    Write-Output 'm11_final_second_publication=PASS REJECTED'
    Write-Output 'm11_final_historical_evidence=PASS IMMUTABLE'
    Assert-M11Vm (Invoke-FixtureValidator $fixture) 'existing persisted credential evidence validator rejected source-bound ledgers'
    Write-Output 'persisted_evidence_validator=PASS'

    $fixture=Reset-VmFixture $fixture
    $priorLedgerPath=Join-Path (Join-Path $root 'victoriametrics-generations') 'm12-reset.snapshot.json'
    $priorLedger=@{intervalStartUtc=$fixture.Manifest.captureStartedUtc;intervalEndUtc=$fixture.Manifest.completedUtc;source='verified-prior-generation-removal';
        priorSnapshot='m11-final';complete=$true;runStartBound=$true;series=0;samples=0;bytes=0}
    [IO.File]::WriteAllText($priorLedgerPath,($priorLedger|ConvertTo-Json -Compress -Depth 5),[Text.UTF8Encoding]::new($false))
    $fixture.Manifest.additionalSources[1].captures=@(@($fixture.Manifest.additionalSources[1].captures)+$priorLedgerPath)
    $fixture.Manifest.persistedMetricEvidenceBytes=[long](@($fixture.Manifest.additionalSources[1].captures|ForEach-Object{(Get-Item -LiteralPath $_).Length}|Measure-Object -Sum).Sum)
    Assert-M11Vm (Invoke-FixtureValidator $fixture) 'verified-prior-generation-removal compatibility failed'
    Write-Output 'verified_prior_generation_removal=PASS'

    $m14Generation=[ordered]@{service='victoriametrics';containerId=('6'*64);composeProject='geordi';workingDirectory=$expectedRoot;createdUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    $m14Identity=Get-GeordiPersistedMetricSourceIdentity -Phase m14-final -RepositoryRoot $expectedRoot -ResolvedM14ContainerGenerations @($m14Generation) `
        -ResolveIdentity { throw 'M14 must reuse its resolved VM identity.' }
    Assert-M11Vm ($m14Identity.sourceContainerId -ceq $m14Generation.containerId) 'M14 ledger identity differs from its validated event inventory'
    $m14Artifact=Join-Path $root 'm14-final-synthetic.jsonl'
    [IO.File]::WriteAllText($m14Artifact,'synthetic-export',[Text.UTF8Encoding]::new($false))
    $m14Ledger=@{}
    Add-GeordiPersistedMetricArtifactBinding -Ledger $m14Ledger -Source 'victoriametrics-export' -SourceIdentity $m14Identity `
        -SnapshotTemporaryPath $m14Artifact -Bytes ([long](Get-Item -LiteralPath $m14Artifact).Length)
    Assert-M11Vm ($m14Ledger.sourceContainerId -ceq $m14Generation.containerId -and $m14Ledger.sourceService -ceq 'victoriametrics') `
        'M14 ledger identity contradicts the existing exact container generation inventory'
    Write-Output 'm14_identity_compatibility=PASS existing_resolved_identity_reused=true'

    $validatorText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-GeordiPersistedCredentialEvidence.ps1'))
    Assert-M11Vm ($validatorText -notmatch '(?im)^\s*docker(?:\.exe)?\s') 'offline validator invokes Docker for historical identity'
    Write-Output 'offline_historical_identity_validation=PASS no_live_container_lookup=true'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if([IO.Path]::GetDirectoryName($resolved) -cne $expected -or (Split-Path $resolved -Leaf) -notmatch '^geordi-m11-vm-identity-[0-9a-f]{32}$'){
        throw 'Unsafe M11 VictoriaMetrics identity self-test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
