. (Join-Path $PSScriptRoot 'GeordiM12BackendReplacement.ps1')
. (Join-Path $PSScriptRoot 'GeordiM12OverlapCollector.ps1')
. (Join-Path $PSScriptRoot 'GeordiFinalizeAttempts.ps1')

function Get-GeordiM12OverlapBackendReplacementArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $ComposeArguments)
    if (@($ComposeArguments | ForEach-Object { [IO.Path]::GetFileName([string]$_) } | Where-Object { $_ -ceq 'compose.m12-overlap-isolation.yaml' }).Count -ne 1) {
        throw 'Generation-aware M12 overlap backend mutation requires the accepted isolation Compose overlay.'
    }
    return @($ComposeArguments)+@('up','-d','--no-deps','--force-recreate','backend')
}

function Get-GeordiM12OverlapProviderReplacementArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $ComposeArguments)
    if (@($ComposeArguments | ForEach-Object { [IO.Path]::GetFileName([string]$_) } | Where-Object { $_ -ceq 'compose.m12-overlap-isolation.yaml' }).Count -ne 1) {
        throw 'Generation-aware M12 overlap provider mutation requires the accepted isolation Compose overlay.'
    }
    return @($ComposeArguments)+@('up','-d','--no-deps','--force-recreate','victoriametrics','m12-query-gate')
}

function Get-GeordiM12OverlapTrafficFixtureArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $ComposeArguments)
    if (@($ComposeArguments | ForEach-Object { [IO.Path]::GetFileName([string]$_) } | Where-Object { $_ -ceq 'compose.m12-overlap-isolation.yaml' }).Count -ne 1) {
        throw 'Generation-aware M12 overlap fixture mutation requires the accepted isolation Compose overlay.'
    }
    return @($ComposeArguments)+@('up','-d','--no-deps','--force-recreate','m12-burn-demo')
}

function Get-GeordiM12OverlapProtectedVolumeAllowlist {
    [CmdletBinding()]
    param()
    return [ordered]@{
        'm19-alert-lifecycle-data' = 'geordi_m19-alert-lifecycle-data'
        'm19-victoriametrics-data' = 'geordi_m19-victoriametrics-data'
    }
}

function Assert-GeordiM12OverlapNoIncompleteHandoffs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][string[]] $Services)
    foreach ($handoff in @($Manifest.captureHandoffs.Values)) {
        if ([string]$handoff.logicalService -in $Services -and [string]$handoff.status -cne 'complete') {
            throw 'M12 overlap entry has an incomplete capture handoff.'
        }
    }
}

function Assert-GeordiM12OverlapNoLegacyEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest)
    $knownPaths=@('m12-overlap-reset.jsonl','m12-overlap-reset.snapshot.json',
        'm12-overlap-recreate.jsonl','m12-overlap-recreate.snapshot.json')
    foreach ($source in @($Manifest.additionalSources)) {
        foreach ($path in @($source.captures)) {
            if ([IO.Path]::GetFileName([string]$path) -cin $knownPaths) {
                throw 'M12 overlap entry contains mutable legacy overlap metric evidence.'
            }
        }
    }
    foreach ($paths in @($Manifest.generationCaptures.Values)) {
        foreach ($path in @($paths)) {
            $name=[IO.Path]::GetFileName([string]$path)
            if ($name -match '^m12-overlap-(reset|recreate)-.+\.(log|stderr\.log)$') {
                throw 'M12 overlap entry contains unbound legacy backend or Collector log evidence.'
            }
        }
    }
    $metricSource=@($Manifest.additionalSources|Where-Object{[string]$_.channel -ceq 'victoriametrics'})
    if($metricSource.Count -gt 1){throw 'M12 overlap persisted metric source is ambiguous.'}
    $registered=@()
    if($metricSource.Count -eq 1){$registered=@($metricSource[0].captures|ForEach-Object{[IO.Path]::GetFullPath([string]$_)})}
    $metricDirectory=Join-Path ([IO.Path]::GetFullPath([string]$Manifest.root)) 'victoriametrics-generations'
    if(Test-Path -LiteralPath $metricDirectory -PathType Container){
        foreach($file in Get-ChildItem -LiteralPath $metricDirectory -File -Force | Where-Object {
            $_.Name -match '^m12-overlap-(reset|recreate)-[0-9a-f]{32}(\.snapshot\.json|\.jsonl)$'
        }){
            if([IO.Path]::GetFullPath($file.FullName) -notin $registered){throw 'M12 overlap has unregistered persisted metric evidence.'}
        }
        foreach($name in $knownPaths){
            if(Test-Path -LiteralPath (Join-Path $metricDirectory $name)){throw 'M12 overlap has a mutable legacy persisted metric artifact.'}
        }
    }
}

function Assert-GeordiM12OverlapOwnedVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Volume,[Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $LogicalName,[Parameter(Mandatory)][string] $Kind)
    if (!$Volume -or [string]$Volume.Name -cne $Name -or
            [string]$Volume.Labels.'com.docker.compose.project' -cne 'geordi' -or
            [string]$Volume.Labels.'com.docker.compose.volume' -cne $LogicalName) {
        throw "M12 overlap $Kind volume ownership is missing or invalid."
    }
}

function Assert-GeordiM12OverlapEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,[Parameter(Mandatory)][scriptblock] $InspectVolume,
        [scriptblock] $TestFollowerProcess)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    Assert-GeordiM12OverlapNoIncompleteHandoffs -Manifest $manifest -Services @('backend','otel-collector')
    Assert-GeordiM12OverlapNoLegacyEvidence -Manifest $manifest
    $followerCheck=$TestFollowerProcess
    if (!$followerCheck) { $followerCheck={param($record) Test-GeordiM11TransferFollowerProcess -FollowerRecord $record} }
    $identities=@{}
    foreach ($service in @('backend','otel-collector')) {
        $identity=@(& $ResolveIdentity $service)
        if ($identity.Count -ne 1) { throw "M12 overlap $service identity is missing or ambiguous." }
        $null=Assert-GeordiM11TransferActiveGeneration -Manifest $manifest -Service $service -Identity $identity[0] `
            -TestFollowerProcess $followerCheck -RepositoryRoot $root
        $identities[$service]=$identity[0]
    }
    $vmIdentity=Get-GeordiPersistedMetricSourceIdentity -Phase 'm12-overlap-reset' -RepositoryRoot $root -ResolveIdentity $ResolveIdentity
    $resolvedVm=@(& $ResolveIdentity 'victoriametrics')
    if ($resolvedVm.Count -ne 1 -or [string]$resolvedVm[0].Id -cne [string]$vmIdentity.sourceContainerId) {
        throw 'M12 overlap VictoriaMetrics identity is missing or changed during entry authentication.'
    }
    $identities.victoriametrics=$resolvedVm[0]

    $m12Volumes=Get-GeordiM12DedicatedFixtureVolumeAllowlist
    foreach ($logical in $m12Volumes.Keys) {
        $matches=@(& $InspectVolume ([string]$m12Volumes[$logical]))
        if ($matches.Count -ne 1) { throw 'M12 overlap expected dedicated volume is absent or ambiguous.' }
        Assert-GeordiM12OverlapOwnedVolume -Volume $matches[0] -Name ([string]$m12Volumes[$logical]) `
            -LogicalName ([string]$logical) -Kind 'dedicated'
    }
    $protected=Get-GeordiM12OverlapProtectedVolumeAllowlist
    foreach ($logical in $protected.Keys) {
        $matches=@(& $InspectVolume ([string]$protected[$logical]))
        if ($matches.Count -ne 1) { throw 'Protected M19 volume is absent or ambiguous at M12 overlap entry.' }
        Assert-GeordiM12OverlapOwnedVolume -Volume $matches[0] -Name ([string]$protected[$logical]) `
            -LogicalName ([string]$logical) -Kind 'protected M19'
    }
    return [pscustomobject]@{Manifest=$manifest;Backend=$identities.backend;Collector=$identities['otel-collector'];
        VictoriaMetrics=$identities.victoriametrics;M12Volumes=$m12Volumes;ProtectedVolumes=$protected}
}

function Remove-GeordiM12OverlapDedicatedVolumes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock] $InspectVolume,[Parameter(Mandatory)][scriptblock] $RemoveVolume)
    $expected=Get-GeordiM12DedicatedFixtureVolumeAllowlist
    Remove-GeordiM12DedicatedFixtureVolumes -ExpectedVolumes $expected -InspectVolume $InspectVolume -RemoveVolume $RemoveVolume
    foreach ($name in @($expected.Values)) {
        $remaining=@(& $InspectVolume ([string]$name))
        if ($remaining.Count -ne 0) { throw 'M12 overlap dedicated volume remains after the owned reset.' }
    }
    return $expected
}

function Assert-GeordiM12OverlapRenderedVolumes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Configuration)
    if (!$Configuration.Contains('services') -or !$Configuration.Contains('volumes') -or
            !$Configuration.volumes.Contains('m12-alert-lifecycle-data') -or
            !$Configuration.volumes.Contains('m12-victoriametrics-data') -or
            !$Configuration.volumes.Contains('m19-alert-lifecycle-data') -or
            [string]$Configuration.volumes['m12-alert-lifecycle-data'].name -cne 'geordi_m12-alert-lifecycle-data' -or
            [string]$Configuration.volumes['m12-victoriametrics-data'].name -cne 'geordi_m12-victoriametrics-data' -or
            [string]$Configuration.volumes['m19-alert-lifecycle-data'].name -cne 'geordi_m19-alert-lifecycle-data' -or
            ($Configuration.volumes.Contains('m19-victoriametrics-data') -and
                [string]$Configuration.volumes['m19-victoriametrics-data'].name -cne 'geordi_m19-victoriametrics-data')) {
        throw 'M12 overlap rendered dedicated volume names are not authoritative.'
    }
    foreach ($service in @('backend','victoriametrics')) {
        if (!$Configuration.services.Contains($service)) { throw 'M12 overlap rendered configuration omitted a required service.' }
    }
    $vmMounts=@($Configuration.services.victoriametrics.volumes | Where-Object {
        [string]$_.target -ceq '/victoria-metrics-data'
    })
    if ($vmMounts.Count -ne 1 -or [string]$vmMounts[0].source -cne 'm12-victoriametrics-data') {
        throw 'M12 overlap VictoriaMetrics datasource is not bound to its dedicated volume.'
    }
    $backendMounts=@($Configuration.services.backend.volumes | Where-Object {
        [string]$_.source -ceq 'm12-alert-lifecycle-data' -and [string]$_.target -ceq '/var/lib/geordi/alerts-m12'
    })
    if ($backendMounts.Count -ne 1 -or [string]$backendMounts[0].source -cne 'm12-alert-lifecycle-data') {
        throw 'M12 overlap backend persistence is not bound to its dedicated volume.'
    }
    if (@($Configuration.services.victoriametrics.volumes | Where-Object {
        [string]$_.source -in @('m19-alert-lifecycle-data','m19-victoriametrics-data')
    }).Count -gt 0) {
        throw 'Protected M19 volume was substituted for the VictoriaMetrics overlap datasource.'
    }
    return $true
}

function Publish-GeordiM12OverlapPersistedMetricEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('m12-overlap-reset','m12-overlap-recreate')][string] $Phase,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,[scriptblock] $ExportSamples,
        [DateTimeOffset] $EndUtc=[DateTimeOffset]::UtcNow)
    $root=[IO.Path]::GetFullPath($CaptureRoot)
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $root
    if (Test-GeordiM19ManifestCompleted $manifest) { throw 'Completed M19 capture evidence is immutable.' }
    $runId=[string]$manifest.runId
    $runStart=ConvertTo-GeordiCaptureUtcInstant -Value $manifest.captureStartedUtc -Field 'manifest.captureStartedUtc'
    if ($EndUtc -lt $runStart) { throw 'M12 overlap metric evidence interval is invalid.' }
    $identity=Get-GeordiPersistedMetricSourceIdentity -Phase $Phase -RepositoryRoot $RepositoryRoot -ResolveIdentity $ResolveIdentity
    $occurrenceId=[guid]::NewGuid().ToString('N')
    $key="$Phase-$occurrenceId"
    $directory=Join-Path $root 'victoriametrics-generations'
    [void][IO.Directory]::CreateDirectory($directory)
    $snapshotPath=Join-Path $directory "$key.jsonl"
    $ledgerPath=Join-Path $directory "$key.snapshot.json"
    foreach ($path in @($snapshotPath,$ledgerPath)) {
        if (Test-Path -LiteralPath $path) { throw 'M12 overlap persisted evidence path is already occupied.' }
    }
    $latestSource=@($manifest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
    if ($latestSource.Count -gt 1) { throw 'M12 overlap persisted VictoriaMetrics source is duplicated.' }
    foreach ($source in $latestSource) {
        if (@($source.captures | Where-Object { [IO.Path]::GetFullPath([string]$_) -in @([IO.Path]::GetFullPath($snapshotPath),[IO.Path]::GetFullPath($ledgerPath)) }).Count) {
            throw 'M12 overlap persisted evidence path is already referenced.'
        }
    }
    $temporarySnapshot="$snapshotPath.$([guid]::NewGuid().ToString('N')).tmp"
    $temporaryLedger="$ledgerPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $usedBytes=0L
        foreach ($source in $latestSource) {
            foreach ($path in @($source.captures)) {
                if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Existing persisted evidence disappeared before overlap capture.' }
                $usedBytes += [long](Get-Item -LiteralPath $path).Length
            }
        }
        $remaining=67108864L-$usedBytes
        if ($remaining -le 0) { throw 'Current-run persisted metric evidence exceeded its aggregate size bound.' }
        if ($ExportSamples) {
            $snapshot=& $ExportSamples $runStart $EndUtc $temporarySnapshot $remaining
        } else {
            $snapshot=Export-GeordiPersistedMetricSamples -StartUtc $runStart -EndUtc $EndUtc -Path $temporarySnapshot `
                -MaximumBytes $remaining -AllowEmpty
        }
        if (!$snapshot -or [long]$snapshot.Bytes -lt 0 -or [long]$snapshot.Bytes -gt $remaining) {
            throw 'M12 overlap persisted metric export returned invalid bounded metadata.'
        }
        $identityAfter=Get-GeordiPersistedMetricSourceIdentity -Phase $Phase -RepositoryRoot $RepositoryRoot -ResolveIdentity $ResolveIdentity
        if ([string]$identityAfter.sourceContainerId -cne [string]$identity.sourceContainerId) {
            throw 'VictoriaMetrics identity changed during overlap evidence acquisition.'
        }
        $ledger=[ordered]@{phase=$Phase;occurrenceId=$occurrenceId;intervalStartUtc=$runStart.ToString('o');
            intervalEndUtc=$EndUtc.ToString('o');source='victoriametrics-export';complete=$true;runStartBound=$true;
            series=[long]$snapshot.Series;samples=[long]$snapshot.Samples;bytes=[long]$snapshot.Bytes}
        Add-GeordiPersistedMetricArtifactBinding -Ledger $ledger -Source 'victoriametrics-export' `
            -SourceIdentity ([ordered]@{sourceService='victoriametrics';sourceContainerId=[string]$identity.sourceContainerId}) `
            -SnapshotTemporaryPath $temporarySnapshot -Bytes ([long]$snapshot.Bytes)
        [IO.File]::WriteAllText($temporaryLedger,(ConvertTo-Json -InputObject $ledger -Depth 5 -Compress),[Text.UTF8Encoding]::new($false))
        $ledgerBytes=[long](Get-Item -LiteralPath $temporaryLedger).Length
        if ($usedBytes+[long]$snapshot.Bytes+$ledgerBytes -gt 67108864L) {
            throw 'Current-run persisted metric evidence exceeded its aggregate size bound.'
        }
        $publishedSnapshot=Complete-GeordiPersistedMetricSnapshotFile -TemporaryPath $temporarySnapshot `
            -SnapshotPath $snapshotPath -Bytes ([long]$snapshot.Bytes) -CreateNew
        [IO.File]::Move($temporaryLedger,$ledgerPath)
        $captures=@($ledgerPath)
        if ($publishedSnapshot) { $captures=@($publishedSnapshot,$ledgerPath) }
        $manifestPath=Join-Path $root 'manifest.json'
        $null=Update-GeordiM19ManifestAtomic -ManifestPath $manifestPath -ExpectedRunId $runId -Mutation {
            param($latest)
            $sources=@($latest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
            if ($sources.Count -gt 1) { throw 'M12 overlap persisted VictoriaMetrics source is duplicated.' }
            if ($sources.Count -eq 0) {
                $latest.additionalSources+=@{channel='victoriametrics';control='geordi.security.authentication.attempts';captures=@()}
                $sources=@($latest.additionalSources | Where-Object { [string]$_.channel -ceq 'victoriametrics' })
            }
            foreach ($path in $captures) {
                if (@($sources[0].captures | Where-Object { [IO.Path]::GetFullPath([string]$_) -ceq [IO.Path]::GetFullPath([string]$path) }).Count) {
                    throw 'M12 overlap persisted metric artifact is already registered.'
                }
            }
            $sources[0].captures=@(@($sources[0].captures)+$captures)
            if ($snapshot.PositiveControl) { $sources[0].control=[string]$snapshot.PositiveMetricName }
            $total=0L
            foreach ($path in @($sources[0].captures)) {
                if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'M12 overlap persisted metric artifact disappeared during publication.' }
                $total += [long](Get-Item -LiteralPath $path).Length
            }
            if ($total -gt 67108864L) { throw 'Current-run persisted metric evidence exceeded its aggregate size bound.' }
            $latest.persistedMetricEvidenceBytes=$total
        }
        $publishedManifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $root
        $publishedSource=@($publishedManifest.additionalSources|Where-Object{[string]$_.channel -ceq 'victoriametrics'})
        if($publishedSource.Count -ne 1){throw 'M12 overlap persisted metric publication is missing its unique manifest source.'}
        $publishedLedger=[IO.File]::ReadAllText($ledgerPath)|ConvertFrom-Json -AsHashtable -ErrorAction Stop
        [void](Assert-GeordiPersistedMetricLedgerArtifact -Ledger $publishedLedger -LedgerPath $ledgerPath -Captures ([string[]]$publishedSource[0].captures))
        return [pscustomobject]@{Phase=$Phase;OccurrenceId=$occurrenceId;SourceContainerId=[string]$identity.sourceContainerId;
            LedgerPath=$ledgerPath;SnapshotPath=$publishedSnapshot;Bytes=[long]$snapshot.Bytes;Series=[long]$snapshot.Series;Samples=[long]$snapshot.Samples}
    } catch {
        if (Test-Path -LiteralPath $temporarySnapshot) { Remove-Item -LiteralPath $temporarySnapshot -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $temporaryLedger) { Remove-Item -LiteralPath $temporaryLedger -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Begin-GeordiM12OverlapBackendHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,[scriptblock] $TestFollowerProcess,
        [scriptblock] $TestProcessIdentity,[scriptblock] $StopProcess,[Parameter(Mandatory)][string] $Reason)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    Assert-GeordiM12OverlapNoIncompleteHandoffs -Manifest $manifest -Services @('backend')
    $identity=@(& $ResolveIdentity 'backend')
    if ($identity.Count -ne 1) { throw 'M12 overlap backend identity is missing or ambiguous before handoff.' }
    $testFollower=$TestFollowerProcess
    if (!$testFollower) { $testFollower={param($record) Test-GeordiM11TransferFollowerProcess -FollowerRecord $record} }
    $null=Assert-GeordiM11TransferActiveGeneration -Manifest $manifest -Service backend -Identity $identity[0] `
        -TestFollowerProcess $testFollower -RepositoryRoot $root
    return Begin-GeordiCaptureHandoff -CaptureRoot $CaptureRoot -Service backend -Reason $Reason `
        -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess
}

function Complete-GeordiM12OverlapBackendHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $HandoffId,[Parameter(Mandatory)][scriptblock] $Replace,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,[Parameter(Mandatory)][scriptblock] $WaitReadiness,
        [scriptblock] $StartFollower,[scriptblock] $TestProcessIdentity,[scriptblock] $StopProcess,
        [string] $Reason='m12-overlap-backend-replacement',[string] $DockerPath=(Get-Command docker.exe -ErrorAction Stop).Source,
        [string] $PowerShellPath=(Get-Process -Id $PID).Path,
        [string] $WorkerPath=(Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1'))
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    if (!$manifest.captureHandoffs.Contains($HandoffId) -or
            [string]$manifest.captureHandoffs[$HandoffId].logicalService -cne 'backend' -or
            [string]$manifest.captureHandoffs[$HandoffId].status -cne 'old-sealed') {
        throw 'M12 overlap backend replacement has no sealed exact-generation handoff.'
    }
    $oldId=[string]$manifest.captureHandoffs[$HandoffId].oldContainerId
    $identityResolver={
        param([string] $service)
        if ($service -cne 'backend') { throw 'M12 overlap requested an unexpected replacement service.' }
        $matches=@(& $ResolveIdentity 'backend')
        if ($matches.Count -ne 1) { throw 'M12 overlap replacement backend identity is missing or ambiguous.' }
        $identity=$matches[0]
        Assert-GeordiCaptureContainerIdentity -Identity $identity -Service backend
        if ([string]$identity.Id -cnotmatch '^[a-f0-9]{64}$' -or !$identity.Running -or
                [IO.Path]::GetFullPath([string]$identity.WorkingDirectory) -cne $root -or [string]$identity.Id -ceq $oldId) {
            throw 'M12 overlap replacement backend is not a distinct owned running container.'
        }
        return $identity
    }.GetNewClosure()
    $startFollowerOnly={
        param($stdout,$stderr,$processRecord,$dockerArguments,$target)
        if ($StartFollower) {
            $started=@(& $StartFollower $stdout $stderr $processRecord $dockerArguments $target)
        } else {
            $started=@(Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath `
                -DockerPath $DockerPath -DockerArguments $dockerArguments -WorkingDirectory $root `
                -StandardOutputPath $stdout -StandardErrorPath $stderr -ProcessRecordPath $processRecord -TargetMetadata $target)
        }
        if ($started.Count -ne 1 -or !$started[0]) { throw 'M12 overlap backend follower startup returned an invalid process identity.' }
        return $started[0]
    }.GetNewClosure()
    $afterFollowerValidated={param($target,$process,$generationId) $null=& $WaitReadiness $target}.GetNewClosure()
    $generationId=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $CaptureRoot -Service backend -HandoffId $HandoffId `
        -RepositoryRoot $root -Replace $Replace -GetContainerIdentity $identityResolver -StartFollower $startFollowerOnly `
        -AfterFollowerValidated $afterFollowerValidated -StopProcess $StopProcess -Reason $Reason -DockerPath $DockerPath `
        -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath
    $completed=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $handoff=$completed.captureHandoffs[$HandoffId]
    $record=Get-GeordiCaptureGenerationRecord -Manifest $completed -Service backend -GenerationId $generationId
    if (!$record -or [string]$record.terminalStatus -cne 'capturing' -or [string]$record.handoffId -cne $HandoffId -or
            [string]$handoff.status -cne 'complete' -or [string]$handoff.oldContainerId -cne $oldId -or
            [string]$handoff.newContainerId -cne [string]$record.containerId) {
        throw 'M12 overlap backend handoff did not publish its exact active follower generation.'
    }
    return [pscustomobject]@{HandoffId=$HandoffId;GenerationId=[string]$generationId;OldContainerId=$oldId;
        NewContainerId=[string]$record.containerId;Status=[string]$handoff.status}
}

function Invoke-GeordiM12OverlapGenerationResetSequence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $IncomingVictoriaMetricsId,
        [Parameter(Mandatory)][scriptblock] $CaptureResetEvidence,
        [Parameter(Mandatory)][scriptblock] $BeginBackendHandoff,
        [Parameter(Mandatory)][scriptblock] $StopTrafficFixture,
        [Parameter(Mandatory)][scriptblock] $AssertResetRemovalPreconditions,
        [Parameter(Mandatory)][scriptblock] $RemoveResetContainers,
        [Parameter(Mandatory)][scriptblock] $ReplaceCollectorFirst,
        [Parameter(Mandatory)][scriptblock] $RemoveDedicatedVolumes,
        [Parameter(Mandatory)][scriptblock] $StartProvider,
        [Parameter(Mandatory)][scriptblock] $ReplaceCollectorSecond,
        [Parameter(Mandatory)][scriptblock] $CompleteBackendHandoff,
        [Parameter(Mandatory)][scriptblock] $StartTrafficFixture)
    $resetEvidence=& $CaptureResetEvidence $IncomingVictoriaMetricsId
    if (!$resetEvidence -or [string]$resetEvidence.SourceContainerId -cne $IncomingVictoriaMetricsId) {
        throw 'M12 overlap reset evidence is not bound to the incoming VictoriaMetrics identity.'
    }
    $backendHandoffId=[string](& $BeginBackendHandoff)
    if ([string]::IsNullOrWhiteSpace($backendHandoffId)) { throw 'M12 overlap backend reset handoff was not created.' }
    & $StopTrafficFixture
    & $AssertResetRemovalPreconditions $backendHandoffId
    & $RemoveResetContainers
    $collectorFirst=& $ReplaceCollectorFirst
    if (!$collectorFirst -or [string]::IsNullOrWhiteSpace([string]$collectorFirst.NewContainerId) -or
            [string]$collectorFirst.NewContainerId -ceq [string]$collectorFirst.OldContainerId) {
        throw 'M12 overlap first Collector replacement did not produce a distinct identity.'
    }
    & $RemoveDedicatedVolumes
    $newVictoriaMetrics=& $StartProvider $IncomingVictoriaMetricsId
    if (!$newVictoriaMetrics -or [string]::IsNullOrWhiteSpace([string]$newVictoriaMetrics.Id) -or
            [string]$newVictoriaMetrics.Id -ceq $IncomingVictoriaMetricsId) {
        throw 'M12 overlap provider reset did not produce a distinct VictoriaMetrics identity.'
    }
    $collectorSecond=& $ReplaceCollectorSecond
    if (!$collectorSecond -or [string]::IsNullOrWhiteSpace([string]$collectorSecond.NewContainerId) -or
            [string]$collectorSecond.NewContainerId -ceq [string]$collectorFirst.NewContainerId) {
        throw 'M12 overlap second Collector replacement did not produce a distinct identity.'
    }
    $backendFirst=& $CompleteBackendHandoff $backendHandoffId
    if (!$backendFirst -or [string]$backendFirst.HandoffId -cne $backendHandoffId -or
            [string]$backendFirst.OldContainerId -notmatch '^[a-f0-9]{64}$' -or
            [string]$backendFirst.NewContainerId -notmatch '^[a-f0-9]{64}$' -or
            [string]$backendFirst.NewContainerId -ceq [string]$backendFirst.OldContainerId -or
            [string]$backendFirst.Status -cne 'complete') {
        throw 'M12 overlap first backend replacement did not complete its exact handoff.'
    }
    & $StartTrafficFixture
    return [pscustomobject]@{ResetEvidence=$resetEvidence;VictoriaMetricsBeforeId=$IncomingVictoriaMetricsId;
        VictoriaMetricsAfterId=[string]$newVictoriaMetrics.Id;CollectorFirst=$collectorFirst;CollectorSecond=$collectorSecond;
        BackendFirst=$backendFirst;BackendHandoffId=$backendHandoffId}
}

function Assert-GeordiM12OverlapFinalEntryState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,[Parameter(Mandatory)][scriptblock] $InspectVolume,
        [Parameter(Mandatory)][string] $ExpectedVictoriaMetricsId,
        [scriptblock] $TestFollowerProcess)
    $state=Assert-GeordiM12OverlapEntryState -CaptureRoot $CaptureRoot -RepositoryRoot $RepositoryRoot `
        -ResolveIdentity $ResolveIdentity -InspectVolume $InspectVolume `
        -TestFollowerProcess $TestFollowerProcess
    if ([string]$state.VictoriaMetrics.Id -cne $ExpectedVictoriaMetricsId) {
        throw 'M12 overlap final VictoriaMetrics identity differs from the active persisted-evidence source.'
    }
    return $state
}

function Assert-GeordiM12OverlapResetRemovalPreconditions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,
        [Parameter(Mandatory)][string] $BackendHandoffId,
        [Parameter(Mandatory)][string] $ExpectedBackendId,
        [Parameter(Mandatory)][string] $ExpectedCollectorId,
        [Parameter(Mandatory)][string] $ExpectedVictoriaMetricsId,
        [Parameter(Mandatory)][scriptblock] $ResolveIdentity,
        [Parameter(Mandatory)][scriptblock] $InspectVolume)
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    Assert-GeordiM12OverlapNoIncompleteHandoffs -Manifest $manifest -Services @('otel-collector')
    if (!$manifest.captureHandoffs.Contains($BackendHandoffId)) {
        throw 'M12 overlap reset has no registered backend handoff before container removal.'
    }
    $handoff=$manifest.captureHandoffs[$BackendHandoffId]
    if ([string]$handoff.logicalService -cne 'backend' -or [string]$handoff.status -cne 'old-sealed' -or
            [string]$handoff.oldContainerId -cne $ExpectedBackendId) {
        throw 'M12 overlap reset backend handoff does not seal the authenticated incoming backend.'
    }
    $oldGeneration=Get-GeordiCaptureGenerationRecord -Manifest $manifest -Service backend -GenerationId ([string]$handoff.oldGenerationId)
    if ([string]$oldGeneration.containerId -cne $ExpectedBackendId -or [string]$oldGeneration.terminalStatus -cne 'sealed') {
        throw 'M12 overlap reset backend generation is not sealed for the exact incoming container.'
    }
    foreach ($expected in @(
        [pscustomobject]@{Service='backend';Id=$ExpectedBackendId},
        [pscustomobject]@{Service='otel-collector';Id=$ExpectedCollectorId},
        [pscustomobject]@{Service='victoriametrics';Id=$ExpectedVictoriaMetricsId}
    )) {
        $identity=& $ResolveIdentity $expected.Service
        if (!$identity -or [string]$identity.Id -cne $expected.Id -or [string]$identity.Service -cne $expected.Service -or
                [string]$identity.Project -cne 'geordi' -or $identity.Running -isnot [bool] -or !$identity.Running) {
            throw 'M12 overlap reset identity changed after entry authentication and before removal.'
        }
    }
    $allowlist=Get-GeordiM12DedicatedFixtureVolumeAllowlist
    foreach ($logical in $allowlist.Keys) {
        $name=[string]$allowlist[$logical]
        $matches=@(& $InspectVolume $name)
        if ($matches.Count -ne 1) { throw 'M12 overlap reset volume is absent or ambiguous immediately before removal.' }
        Assert-GeordiM12OverlapOwnedVolume -Volume $matches[0] -Name $name -LogicalName ([string]$logical) -Kind 'dedicated'
    }
}
