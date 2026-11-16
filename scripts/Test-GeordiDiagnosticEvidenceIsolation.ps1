[CmdletBinding()]
param([switch] $SentinelsOnly, [switch] $SnapshotsOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ($SentinelsOnly -and $SnapshotsOnly) { throw 'Select one diagnostic evidence test group.' }
. (Join-Path $PSScriptRoot 'lib/GeordiDiagnosticEvidence.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')

function Assert-DiagnosticEvidence([bool] $Condition,[string] $Message) { if (!$Condition) { throw "Diagnostic evidence self-test failed: $Message" } }
function New-TestCaptureRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-m19-capture-diagnostic-test-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $manifest=[ordered]@{ version=2; root=$root; runId='synthetic-run'; startedUtc=[DateTimeOffset]::UtcNow.ToString('o'); captureStartedUtc=[DateTimeOffset]::UtcNow.ToString('o'); sentinels=@(); additionalSources=@(); controls=@{browser='synthetic-browser-control'}; captures=@{browser=@('synthetic-browser-capture')}; attempts=@{prior=@{attemptId='prior';status='running';channels=@{controls=@{browser='prior-control'};captures=@{browser=@('prior-capture')}}}} }
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 12),[Text.UTF8Encoding]::new($false))
    return @{Root=$root;Manifest=$manifest;ManifestPath=(Join-Path $root 'manifest.json')}
}
function Remove-TestCaptureRoot([string] $Root) {
    if (Test-Path -LiteralPath $Root) {
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object { $_.IsReadOnly=$false }
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}

if (!$SnapshotsOnly) {
    $test=New-TestCaptureRoot
    try {
        $shared=Join-Path $test.Root 'browser-secret-sentinels.txt'
        $sharedBytes=[Text.UTF8Encoding]::new($false).GetBytes("historical-sentinel-a`nhistorical-sentinel-b`n")
        [IO.File]::WriteAllBytes($shared,$sharedBytes)
        $first=New-GeordiDiagnosticSentinelSource -CaptureRoot $test.Root
        Add-GeordiDiagnosticSentinel -Source $first -Class browser-state -Value 'synthetic-state-0001'
        Add-GeordiDiagnosticSentinel -Source $first -Class webhook-token -Value 'synthetic-hook-000001'
        $eventB=[ordered]@{candidateId='synthetic-run';runId='synthetic-run';diagnosticInvocationId='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';phase='m14-final';occurrenceId='cccccccccccccccccccccccccccccccc';status='complete';files=@(@{path='synthetic';identity='synthetic';byteCount=1;sha256='synthetic'})}
        $test.Manifest=Update-GeordiM19ManifestAtomic -ManifestPath $test.ManifestPath -ExpectedRunId 'synthetic-run' -Mutation {
            param($latest)
            if(!$latest.ContainsKey('generationCaptureEvents')){$latest.generationCaptureEvents=@{}}
            $latest.generationCaptureEvents[$eventB.occurrenceId]=$eventB
        }
        $eventBBefore=ConvertTo-Json -InputObject $test.Manifest.generationCaptureEvents[$eventB.occurrenceId] -Depth 12 -Compress
        $beforeAttempts=ConvertTo-Json -InputObject $test.Manifest.attempts -Depth 8 -Compress
        $beforeChannels=ConvertTo-Json -InputObject @{controls=$test.Manifest.controls;captures=$test.Manifest.captures} -Depth 8 -Compress
        $sealed=Seal-GeordiDiagnosticSentinelSource -Source $first
        $latestAfterSeal=Get-Content -LiteralPath $test.ManifestPath -Raw | ConvertFrom-Json -AsHashtable
        $eventBAfter=ConvertTo-Json -InputObject $latestAfterSeal.generationCaptureEvents[$eventB.occurrenceId] -Depth 12 -Compress
        Assert-DiagnosticEvidence ($eventBAfter -ceq $eventBBefore) 'sealing changed or discarded the concurrent generation event'
        Assert-DiagnosticEvidence ((ConvertTo-Json -InputObject $latestAfterSeal.attempts -Depth 8 -Compress) -ceq $beforeAttempts) 'sealing changed prior Finalize attempts'
        Assert-DiagnosticEvidence ((ConvertTo-Json -InputObject @{controls=$latestAfterSeal.controls;captures=$latestAfterSeal.captures} -Depth 8 -Compress) -ceq $beforeChannels) 'sealing changed existing channel mappings'
        Assert-DiagnosticEvidence (!$latestAfterSeal.ContainsKey('acceptedAttemptId') -and !$latestAfterSeal.ContainsKey('completedUtc')) 'sealing created an accepted Finalize state'
        Assert-DiagnosticEvidence ($sealed.state -ceq 'sealed') 'successful source did not reach its terminal success state'
        $sealedHash=$sealed.sha256
        $again=Seal-GeordiDiagnosticSentinelSource -Source $first
        Assert-DiagnosticEvidence ($again.sha256 -ceq $sealedHash -and $again.sentinelCount -eq $sealed.sentinelCount) 'repeated sealing replaced or duplicated evidence'
        $lock=[IO.File]::Open((Join-Path $test.Root 'manifest.update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $lockRejected=$false
        try { Update-GeordiM19ManifestAtomic -ManifestPath $test.ManifestPath -ExpectedRunId 'synthetic-run' -Mutation { param($latest) $latest.shouldNotPublish=$true } | Out-Null } catch { $lockRejected=$true }
        finally { $lock.Dispose() }
        Assert-DiagnosticEvidence $lockRejected 'simultaneous manifest lock conflict did not fail closed'
        $conflict=[IO.File]::ReadAllText($test.ManifestPath) | ConvertFrom-Json -AsHashtable
        $sourceRecord=$conflict.diagnosticSentinelSources[$first.Source.diagnosticInvocationId]
        $conflict.diagnosticSentinelSources[$first.Source.diagnosticInvocationId].path=Join-Path $test.Root 'conflict.jsonl'
        Write-GeordiM19ManifestAtomic -Path $test.ManifestPath -Manifest $conflict
        $sourceTamperRejected=$false
        try { Seal-GeordiDiagnosticSentinelSource -Source $first | Out-Null } catch { $sourceTamperRejected=$true }
        Assert-DiagnosticEvidence $sourceTamperRejected 'conflicting registered source metadata was accepted'
        $conflict.diagnosticSentinelSources[$first.Source.diagnosticInvocationId].path=$first.Path
        Write-GeordiM19ManifestAtomic -Path $test.ManifestPath -Manifest $conflict
        foreach ($identityField in @('candidateId','diagnosticInvocationId')) {
            $identitySource=New-GeordiDiagnosticSentinelSource -CaptureRoot $test.Root
            Add-GeordiDiagnosticSentinel -Source $identitySource -Class browser-state -Value ('identity-check-' + $identityField)
            $identityConflict=Get-Content -LiteralPath $test.ManifestPath -Raw | ConvertFrom-Json -AsHashtable
            $identityKey=[string]$identitySource.Source.diagnosticInvocationId
            $identityConflict.diagnosticSentinelSources[$identityKey][$identityField]='conflicting-identity'
            Write-GeordiM19ManifestAtomic -Path $test.ManifestPath -Manifest $identityConflict
            $identityRejected=$false
            try { Seal-GeordiDiagnosticSentinelSource -Source $identitySource | Out-Null } catch { $identityRejected=$true }
            Assert-DiagnosticEvidence $identityRejected "conflicting $identityField update was accepted"
            $identityConflict.diagnosticSentinelSources[$identityKey][$identityField]=$identitySource.Source[$identityField]
            $identityConflict.diagnosticSentinelSources.Remove($identityKey)
            Write-GeordiM19ManifestAtomic -Path $test.ManifestPath -Manifest $identityConflict
        }
        $test.Manifest=Get-Content -LiteralPath $test.ManifestPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-DiagnosticEvidence (([Convert]::ToBase64String([IO.File]::ReadAllBytes($shared))) -ceq [Convert]::ToBase64String($sharedBytes)) 'existing shared browser source changed'
        $second=New-GeordiDiagnosticSentinelSource -CaptureRoot $test.Root
        Assert-DiagnosticEvidence ($first.Path -cne $second.Path) 'invocations reused a sentinel path'
        Add-GeordiDiagnosticSentinel -Source $second -Class runtime-bearer -Value 'synthetic-bearer-0001'
        $null=Seal-GeordiDiagnosticSentinelSource -Source $second
        $rejected=$false
        try { Add-GeordiDiagnosticSentinel -Source $first -Class browser-state -Value 'synthetic-state-0002' } catch { $rejected=$true }
        Assert-DiagnosticEvidence $rejected 'sealed source accepted another write'
        $test.Manifest=Get-Content -LiteralPath $test.ManifestPath -Raw | ConvertFrom-Json -AsHashtable
        $values=@(Get-GeordiDiagnosticSentinelValues -Manifest $test.Manifest)
        Assert-DiagnosticEvidence ($values.Count -eq 3) 'scanner inventory did not load every typed source value'
        Assert-DiagnosticEvidence ((Assert-GeordiMinimumBrowserSentinels -Sentinels @('browser-value-0001','browser-value-0002','browser-value-0003','browser-value-0004','browser-value-0004')) -eq 4) 'unique four-browser sentinel contract failed'
        $minimumRejected=$false
        try { $null=Assert-GeordiMinimumBrowserSentinels -Sentinels @('browser-value-0001','browser-value-0001','browser-value-0002','browser-value-0003') } catch { $minimumRejected=$true }
        Assert-DiagnosticEvidence $minimumRejected 'duplicate values satisfied four-browser minimum'
        $manifestBefore=Get-Content -LiteralPath $test.ManifestPath -Raw
        Assert-DiagnosticEvidence (!$test.Manifest.ContainsKey('acceptedAttemptId') -and $test.Manifest.attempts.ContainsKey('prior')) 'diagnostic source created accepted Finalize state or changed prior attempt records'
        $tamperPath=$first.Path
        (Get-Item -LiteralPath $tamperPath -Force).IsReadOnly=$false
        [IO.File]::AppendAllText($tamperPath,'x')
        $tamperRejected=$false
        try { $null=Get-GeordiDiagnosticSentinelValues -Manifest $test.Manifest } catch { $tamperRejected=$true }
        Assert-DiagnosticEvidence $tamperRejected 'altered evidence passed integrity validation'
        [IO.File]::WriteAllText($test.ManifestPath,$manifestBefore,[Text.UTF8Encoding]::new($false))
        Write-Output 'sentinel_isolation=PASS shared_unchanged=true unique_paths=true sealed=true integrity=true browser_minimum=true'
    } finally { Remove-TestCaptureRoot $test.Root }

    foreach($lifecycleCase in @('success','action-failure','seal-failure','primary-and-seal-failure','invalid-transition')) {
        $test=New-TestCaptureRoot
        try {
            $source=New-GeordiDiagnosticSentinelSource -CaptureRoot $test.Root
            $caught=$null
            switch($lifecycleCase) {
                'success' {
                    Invoke-GeordiDiagnosticEvidenceLifecycle -Source $source -Action { Add-GeordiDiagnosticSentinel -Source $source -Class runtime-bearer -Value 'synthetic-success-0001' }
                    $state=(Get-Content -LiteralPath $test.ManifestPath -Raw | ConvertFrom-Json -AsHashtable).diagnosticSentinelSources[$source.Source.diagnosticInvocationId].state
                    Assert-DiagnosticEvidence ($state -ceq 'sealed') 'finally downgraded a successful seal'
                }
                'action-failure' {
                    $sharedPath=Join-Path $test.Root 'browser-secret-sentinels.txt'
                    $sharedOriginal=[Text.UTF8Encoding]::new($false).GetBytes("shared-original-credential-a`nshared-original-credential-b`n")
                    [IO.File]::WriteAllBytes($sharedPath,$sharedOriginal)
                    $snapshotRoot=Join-Path $test.Root 'victoriametrics-generations';[void][IO.Directory]::CreateDirectory($snapshotRoot)
                    $snapshotPath=Join-Path $snapshotRoot 'm14-final.jsonl';[IO.File]::WriteAllText($snapshotPath,'historical-m14-final')
                    $snapshotOriginal=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
                    try { Invoke-GeordiDiagnosticEvidenceLifecycle -Source $source -Action { Add-GeordiDiagnosticSentinel -Source $source -Class runtime-bearer -Value 'synthetic-failure-0001'; throw [InvalidOperationException]::new('synthetic-primary-failure') } } catch { $caught=$_.Exception.Message }
                    $state=(Get-Content -LiteralPath $test.ManifestPath -Raw | ConvertFrom-Json -AsHashtable).diagnosticSentinelSources[$source.Source.diagnosticInvocationId].state
                    Assert-DiagnosticEvidence ($caught -ceq 'synthetic-primary-failure' -and $state -ceq 'failed-sealed') 'action failure was lost or accepted'
                    Assert-DiagnosticEvidence ([Convert]::ToBase64String([IO.File]::ReadAllBytes($sharedPath)) -ceq [Convert]::ToBase64String($sharedOriginal)) 'preflight failure changed shared browser evidence'
                    Assert-DiagnosticEvidence ((Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash -ceq $snapshotOriginal) 'preflight failure replaced an M14 generation snapshot'
                }
                'seal-failure' {
                    $script:GeordiPrivateTokenSentinelOverride={ param($Token) $null }
                    try { Invoke-GeordiDiagnosticEvidenceLifecycle -Source $source -Action { $source.Stream.Dispose() } } catch { $caught=$_.Exception.Message }
                    Assert-DiagnosticEvidence ($caught -ceq 'Diagnostic evidence finalization failed; private details withheld.' -and $null -eq $script:GeordiPrivateTokenSentinelOverride) 'seal failure was not sanitized or left the token override active'
                }
                'primary-and-seal-failure' {
                    try { Invoke-GeordiDiagnosticEvidenceLifecycle -Source $source -Action { $source.Stream.Dispose(); throw [InvalidOperationException]::new('synthetic-original-failure') } } catch { $caught=$_.Exception.Message }
                    Assert-DiagnosticEvidence ($caught -ceq 'synthetic-original-failure') 'secondary seal failure replaced the original exception'
                }
                'invalid-transition' {
                    Add-GeordiDiagnosticSentinel -Source $source -Class runtime-bearer -Value 'synthetic-transition-0001'
                    $null=Seal-GeordiDiagnosticSentinelSource -Source $source -Failed
                    try { Seal-GeordiDiagnosticSentinelSource -Source $source | Out-Null } catch { $caught=$_.Exception.Message }
                    Assert-DiagnosticEvidence ($caught -eq 'Invalid diagnostic sentinel terminal-state transition.') 'invalid terminal-state transition was accepted'
                }
            }
        } finally { Remove-TestCaptureRoot $test.Root }
    }
    Write-Output 'diagnostic_lifecycle=PASS success=sealed failure=failed-sealed repeat=stable conflicts=fail-closed primary-error=preserved'
}

if (!$SentinelsOnly) {
    $test=New-TestCaptureRoot
    try {
        $directory=Join-Path $test.Root 'victoriametrics-generations'
        [void][IO.Directory]::CreateDirectory($directory)
        $oldReset=Join-Path $directory 'm14-reset.jsonl'
        $oldFinal=Join-Path $directory 'm14-final.snapshot.json'
        [IO.File]::WriteAllText($oldReset,'historical-reset',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($oldFinal,'historical-final',[Text.UTF8Encoding]::new($false))
        $oldResetHash=(Get-FileHash -LiteralPath $oldReset -Algorithm SHA256).Hash
        $oldFinalHash=(Get-FileHash -LiteralPath $oldFinal -Algorithm SHA256).Hash
        $events=[ordered]@{}
        $capturePaths=[Collections.Generic.List[string]]::new()
        foreach ($phase in @('m14-reset','m14-final','m14-final')) {
            $occurrence=[guid]::NewGuid().ToString('N')
            $paths=New-GeordiM14GenerationPaths -CaptureRoot $test.Root -Phase $phase -OccurrenceId $occurrence
            $snapshotStream=[IO.File]::Open($paths.SnapshotPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $bytes=[Text.UTF8Encoding]::new($false).GetBytes("synthetic-snapshot-$occurrence`n")
            $snapshotStream.Write($bytes,0,$bytes.Length); $snapshotStream.Dispose()
            $ledgerStream=[IO.File]::Open($paths.LedgerPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            $ledgerBytes=[Text.UTF8Encoding]::new($false).GetBytes('{"complete":true}')
            $ledgerStream.Write($ledgerBytes,0,$ledgerBytes.Length); $ledgerStream.Dispose()
            $capturePaths.Add($paths.SnapshotPath); $capturePaths.Add($paths.LedgerPath)
            $fileMetadata=@($paths.SnapshotPath,$paths.LedgerPath | ForEach-Object {
                $item=Get-Item -LiteralPath $_ -Force
                [ordered]@{path=[IO.Path]::GetFullPath($_);identity=$item.Name;byteCount=[long]$item.Length;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()}
            })
            $events[$occurrence]=[ordered]@{ candidateId='synthetic-run';runId='synthetic-run';diagnosticInvocationId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';phase=$phase;occurrenceId=$occurrence;status='complete';files=$fileMetadata }
            $events[$occurrence].services=@('backend')
            $events[$occurrence].containerGenerations=@([ordered]@{service='backend';containerId=('a'*64);composeProject='geordi';
                workingDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'));createdUtc=[DateTimeOffset]::UtcNow.ToString('o')})
            foreach($file in $events[$occurrence].files){$file.service='backend';$file.containerId=('a'*64);$file.source='docker-container-logs'}
        }
        Assert-DiagnosticEvidence ((Get-FileHash -LiteralPath $oldReset -Algorithm SHA256).Hash -ceq $oldResetHash -and (Get-FileHash -LiteralPath $oldFinal -Algorithm SHA256).Hash -ceq $oldFinalHash) 'historical fixed-phase files changed'
        Assert-DiagnosticEvidence (@($capturePaths | Select-Object -Unique).Count -eq 6) 'multiple M14 captures shared a destination'
        $test.Manifest.generationCaptureEvents=$events
        $test.Manifest.root=$test.Root
        Assert-GeordiM14GenerationEvents -Manifest $test.Manifest
        $firstOccurrenceId = @($events.Keys)[0]
        $test.Manifest.generationCaptureEvents[$firstOccurrenceId].status = 'in_progress'
        $incompleteRejected=$false
        try { Assert-GeordiM14GenerationEvents -Manifest $test.Manifest } catch { $incompleteRejected=$true }
        Assert-DiagnosticEvidence $incompleteRejected 'incomplete event passed fail-closed validation'
        Write-Output 'snapshot_isolation=PASS unique_create_new_paths=true historical_preserved=true repeated_final_distinct=true event_integrity=true'
    } finally { Remove-TestCaptureRoot $test.Root }
}
