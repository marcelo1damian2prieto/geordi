Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'GeordiCaptureStart.ps1')
. (Join-Path $PSScriptRoot 'GeordiFinalizeAttempts.ps1')
. (Join-Path $PSScriptRoot 'GeordiUtcTimestamp.ps1')

function Get-GeordiCaptureGenerationChannel {
    param([Parameter(Mandatory)][string] $Service)
    switch ($Service) {
        'frontend' { return @('nginx-access') }
        'backend' { return @('backend') }
        'otel-collector' { return @('otel','collector') }
        'oidc-fixture' { return @('backend') }
        'webhook-receiver-a' { return @('backend') }
        'webhook-receiver-b' { return @('backend') }
        default { throw 'Capture service has no credential-scanner channel mapping.' }
    }
}

function Get-GeordiM14EventIdentityServices {
    param([Parameter(Mandatory)][string[]] $RequestedLogServices)
    $services=[Collections.Generic.List[string]]::new()
    foreach ($service in @($RequestedLogServices + 'victoriametrics')) {
        if ($service -notin $services) { $services.Add([string]$service) }
    }
    return @($services.ToArray())
}

function Assert-GeordiCaptureContainerIdentity {
    param([Parameter(Mandatory)] $Identity,[Parameter(Mandatory)][string] $Service)
    foreach ($name in @('Id','Project','Service','WorkingDirectory','CreatedUtc')) {
        if ([string]::IsNullOrWhiteSpace([string]$Identity.$name)) { throw 'Capture container identity is incomplete.' }
    }
    if ([string]$Identity.Project -cne 'geordi' -or [string]$Identity.Service -cne $Service -or
            [string]$Identity.Id -notmatch '^[a-f0-9]{12,64}$') {
        throw 'Capture container identity does not match its logical service.'
    }
    $created=[DateTimeOffset]::Parse([string]$Identity.CreatedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if ($created.Offset -ne [TimeSpan]::Zero) { throw 'Capture container creation identity is not UTC.' }
}

function Get-GeordiDockerCaptureIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ContainerId,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $RepositoryRoot)
    $inspection=& docker inspect $ContainerId 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Capture container identity inspection failed.' }
    $container=@($inspection | ConvertFrom-Json -ErrorAction Stop)[0]
    $labels=$container.Config.Labels
    $identity=[pscustomobject]@{
        Id=[string]$container.Id
        Project=[string]$labels.'com.docker.compose.project'
        Service=[string]$labels.'com.docker.compose.service'
        WorkingDirectory=[string]$labels.'com.docker.compose.project.working_dir'
        CreatedUtc=([DateTimeOffset]::Parse([string]$container.Created,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o'))
        Running=[bool]$container.State.Running
    }
    Assert-GeordiCaptureContainerIdentity $identity $Service
    if ([IO.Path]::GetFullPath($identity.WorkingDirectory) -cne [IO.Path]::GetFullPath($RepositoryRoot) -or !$identity.Running) {
        throw 'Capture container is not the running generation owned by this checkout.'
    }
    return $identity
}

function Get-GeordiCaptureGenerationManifest {
    param([Parameter(Mandatory)][string] $CaptureRoot)
    $root=[IO.Path]::GetFullPath($CaptureRoot)
    $manifestPath=Join-Path $root 'manifest.json'
    $manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($manifest.version -ne 2 -or [IO.Path]::GetFullPath([string]$manifest.root) -cne $root -or
            [string]::IsNullOrWhiteSpace([string]$manifest.runId) -or [string]::IsNullOrWhiteSpace([string]$manifest.captureStartedUtc)) {
        throw 'Capture generation manifest identity is invalid.'
    }
    if (!$manifest.ContainsKey('captureGenerations')) { $manifest.captureGenerations=@{} }
    if (!$manifest.ContainsKey('captureHandoffs')) { $manifest.captureHandoffs=@{} }
    return $manifest
}

function Set-GeordiCaptureGenerationMutation {
    param([Parameter(Mandatory)][string] $ManifestPath,[Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][scriptblock] $Mutation)
    return Update-GeordiM19ManifestAtomic -ManifestPath $ManifestPath -ExpectedRunId $RunId -Mutation $Mutation
}

function Get-GeordiCaptureGenerationRecord {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $GenerationId)
    if (!$Manifest.captureGenerations.ContainsKey($Service)) { return $null }
    return @($Manifest.captureGenerations[$Service] | Where-Object { [string]$_.generationId -ceq $GenerationId })[0]
}

function Start-GeordiCaptureGeneration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)] $ContainerIdentity,[Parameter(Mandatory)][string] $DockerPath,
        [Parameter(Mandatory)][string] $PowerShellPath,[Parameter(Mandatory)][string] $WorkerPath,
        [Parameter(Mandatory)][string] $WorkingDirectory,[AllowEmptyString()][string] $HandoffId,
        [string] $Reason='initial-candidate-capture',[ValidateRange(1,120)][int] $MaximumGapSeconds=120,
        [scriptblock] $StartFollower,[scriptblock] $AfterFollowerValidated,[scriptblock] $StopProcess)
    Assert-GeordiCaptureContainerIdentity $ContainerIdentity $Service
    $captureRoot=[IO.Path]::GetFullPath($CaptureRoot)
    $manifestPath=Join-Path $captureRoot 'manifest.json'
    $manifest=Get-GeordiCaptureGenerationManifest $captureRoot
    $existingRecords=if($manifest.captureGenerations.ContainsKey($Service)){@($manifest.captureGenerations[$Service])}else{@()}
    $existing=@($existingRecords | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
    if ($existing.Count -gt 0) { throw 'A capture generation is already active for this service.' }
    $pending=$null
    if (![string]::IsNullOrEmpty($HandoffId)) {
        if (!$manifest.captureHandoffs.ContainsKey($HandoffId)) { throw 'Capture handoff identity is missing.' }
        $pending=$manifest.captureHandoffs[$HandoffId]
        if ([string]$pending.logicalService -cne $Service -or [string]$pending.status -cne 'old-sealed') { throw 'Capture handoff is not ready for a new generation.' }
        $old=Get-GeordiCaptureGenerationRecord $manifest $Service ([string]$pending.oldGenerationId)
        if (!$old -or [string]$old.terminalStatus -cne 'sealed' -or [string]$old.containerId -ceq [string]$ContainerIdentity.Id) {
            throw 'Replacement container identity does not prove a new generation.'
        }
    }
    $generationId=[guid]::NewGuid().ToString('N')
    $directory=Join-Path (Join-Path $captureRoot 'container-generations') $Service
    [void][IO.Directory]::CreateDirectory($directory)
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Capture generation directory was redirected.' }
    $capturePath=Join-Path $directory "$generationId.log"
    $stderrPath=Join-Path $directory "$generationId.stderr.log"
    $processPath=Join-Path $directory "$generationId.process.json"
    foreach ($path in @($capturePath,$stderrPath)) {
        $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$stream.Dispose()
    }
    $startedUtc=[DateTimeOffset]::UtcNow
    $diagnosticInvocationId=[Environment]::GetEnvironmentVariable('GEORDI_M19_DIAGNOSTIC_INVOCATION_ID','Process')
    if ($diagnosticInvocationId -and $diagnosticInvocationId -notmatch '^[0-9a-f]{32}$') { throw 'Capture invocation identity is invalid.' }
    $generation=[ordered]@{
        generationId=$generationId;candidateId=[string]$manifest.runId;runId=[string]$manifest.runId
        diagnosticInvocationId=$diagnosticInvocationId;logicalService=$Service;containerId=[string]$ContainerIdentity.Id
        composeProject=[string]$ContainerIdentity.Project;workingDirectory=[string]$ContainerIdentity.WorkingDirectory
        containerCreatedUtc=([DateTimeOffset]$ContainerIdentity.CreatedUtc).ToUniversalTime().ToString('o')
        capturePath=$capturePath;captureFileIdentity=[IO.Path]::GetFileName($capturePath)
        stderrCapturePath=$stderrPath;stderrFileIdentity=[IO.Path]::GetFileName($stderrPath)
        processRecordPath=$processPath;followerProcess=$null;captureStartedUtc=$startedUtc.ToString('o')
        captureEndedUtc=$null;byteCount=$null;sha256=$null;stderrByteCount=$null;stderrSha256=$null;terminalStatus='capturing'
        handoffId=$HandoffId;replacementReason=$Reason
    }
    $manifest=Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId ([string]$manifest.runId) -Mutation {
        param($latest)
        if (!$latest.ContainsKey('captureGenerations')) { $latest.captureGenerations=@{} }
        if (!$latest.captureGenerations.ContainsKey($Service)) { $latest.captureGenerations[$Service]=@() }
        if (@($latest.captureGenerations[$Service] | Where-Object { [string]$_.terminalStatus -ceq 'capturing' }).Count -gt 0) {
            throw 'A concurrent capture generation is already active.'
        }
        $latest.captureGenerations[$Service]=@(@($latest.captureGenerations[$Service])+$generation)
    }
    $callbackFailure=$null
    $process=$null
    try {
        $target=[ordered]@{ containerId=[string]$ContainerIdentity.Id;service=$Service;project=[string]$ContainerIdentity.Project;createdUtc=$generation.containerCreatedUtc }
        $args=@('logs','--follow','--timestamps','--since',$startedUtc.ToString('o'),[string]$ContainerIdentity.Id)
        if ($StartFollower) {
            $process=& $StartFollower $capturePath $stderrPath $processPath $args $target
        } else {
            $process=Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath `
                -DockerPath $DockerPath -DockerArguments $args -WorkingDirectory $WorkingDirectory `
                -StandardOutputPath $capturePath -StandardErrorPath $stderrPath -ProcessRecordPath $processPath `
                -TargetMetadata $target
        }
        if (!$process -or [int]$process.id -le 0 -or [string]::IsNullOrWhiteSpace([string]$process.name) -or
                [string]::IsNullOrWhiteSpace([string]$process.startUtc) -or !(Test-Path -LiteralPath $processPath -PathType Leaf)) {
            throw 'Capture follower did not return an exact process identity.'
        }
        $diskProcess=[IO.File]::ReadAllText($processPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $diskStartUtc=if($diskProcess.startUtc -is [DateTime]){([DateTimeOffset]$diskProcess.startUtc).ToUniversalTime()}else{
            [DateTimeOffset]::Parse([string]$diskProcess.startUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
        $processStartUtc=[DateTimeOffset]::Parse([string]$process.startUtc,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ([int]$diskProcess.id -ne [int]$process.id -or [string]$diskProcess.name -cne [string]$process.name -or
                $diskStartUtc.UtcTicks -ne $processStartUtc.UtcTicks -or
                [string]$diskProcess.containerId -cne [string]$ContainerIdentity.Id -or
                [string]$diskProcess.service -cne $Service -or [string]$diskProcess.project -cne [string]$ContainerIdentity.Project) {
            throw 'Capture follower process record is not bound to its container generation.'
        }
        $generation.followerProcess=[ordered]@{ id=[int]$process.id;name=[string]$process.name;startUtc=[string]$process.startUtc }
        $generation.captureStartedUtc=([DateTimeOffset]$process.startUtc).ToUniversalTime().ToString('o')
        $generation.terminalStatus='capturing'
        $manifest=Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId ([string]$manifest.runId) -Mutation {
            param($latest)
            $record=Get-GeordiCaptureGenerationRecord $latest $Service $generationId
            if (!$record -or [string]$record.terminalStatus -cne 'capturing' -or [string]$record.containerId -cne [string]$ContainerIdentity.Id) {
                throw 'Capture generation changed before follower identity publication.'
            }
            $record.followerProcess=$generation.followerProcess
            $record.captureStartedUtc=$generation.captureStartedUtc
        }
        if ($AfterFollowerValidated) {
            try { $null=& $AfterFollowerValidated $target $process $generationId }
            catch { $callbackFailure=$_; throw }
        }
        if ($pending) {
            $replacementStarted=[DateTimeOffset]$generation.captureStartedUtc
            $oldEnded=[DateTimeOffset]$pending.oldCaptureEndedUtc
            $gapTicks=($replacementStarted-$oldEnded).Ticks
            $gapMs=[long][Math]::Floor([double]$gapTicks/[TimeSpan]::TicksPerMillisecond)
            if ($gapMs -lt 0 -or $gapMs -gt ($MaximumGapSeconds*1000L)) { throw 'Capture handoff transition exceeded its bound.' }
            $manifest=Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId ([string]$manifest.runId) -Mutation {
                param($latest)
                $handoff=$latest.captureHandoffs[$HandoffId]
                if ([string]$handoff.status -cne 'old-sealed') { throw 'Capture handoff lifecycle changed before completion.' }
                $handoff.newGenerationId=$generationId;$handoff.newContainerId=[string]$ContainerIdentity.Id
                $handoff.newCaptureStartedUtc=$replacementStarted.ToString('o');$handoff.gapDurationMilliseconds=$gapMs
                $handoff.maximumGapMilliseconds=[long]$MaximumGapSeconds*1000L
                $handoff.gapState='bounded-transition';$handoff.status='complete';$handoff.completedUtc=[DateTimeOffset]::UtcNow.ToString('o')
            }
        }
        return $generationId
    } catch {
        $failure=$_
        $cleanupProcess=if($generation.followerProcess){[pscustomobject]$generation.followerProcess}else{$process}
        if ($cleanupProcess -and [int]$cleanupProcess.id -gt 0) {
            try {
                if ($StopProcess) { & $StopProcess $cleanupProcess }
                else { Stop-GeordiCaptureProcessTree -ProcessId ([int]$cleanupProcess.id) }
            }
            catch {
                try { $failure.Exception.Data['FollowerCleanupFailure']=[string]$_.Exception.GetType().FullName } catch { }
            }
        }
        try {
            Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId ([string]$manifest.runId) -Mutation {
                param($latest)
                $record=Get-GeordiCaptureGenerationRecord $latest $Service $generationId
                if ($record -and [string]$record.terminalStatus -ceq 'capturing') { $record.terminalStatus='incomplete-start';$record.captureEndedUtc=[DateTimeOffset]::UtcNow.ToString('o') }
                if ($HandoffId -and $latest.captureHandoffs.ContainsKey($HandoffId)) { $latest.captureHandoffs[$HandoffId].status='incomplete-new-generation' }
            } | Out-Null
        } catch { }
        if ($callbackFailure) { throw $callbackFailure }
        throw 'Generation-aware log follower startup or publication failed; handoff remains incomplete.'
    }
}

function Seal-GeordiCaptureGenerationCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $GenerationId,[long] $MaximumBytes=536870912L,
        [scriptblock] $TestProcessIdentity,[scriptblock] $StopProcess)
    $manifest=Get-GeordiCaptureGenerationManifest $CaptureRoot
    $record=Get-GeordiCaptureGenerationRecord $manifest $Service $GenerationId
    if (!$record -or [string]$record.terminalStatus -cne 'capturing' -or !$record.followerProcess) { throw 'Active capture generation cannot be sealed.' }
    $diskRecord=[IO.File]::ReadAllText([string]$record.processRecordPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ([int]$diskRecord.id -ne [int]$record.followerProcess.id -or [string]$diskRecord.containerId -cne [string]$record.containerId -or
            [string]$diskRecord.service -cne $Service -or [string]$diskRecord.project -cne [string]$record.composeProject -or
            [string]$diskRecord.name -cne [string]$record.followerProcess.name -or [string]$diskRecord.startUtc -cne [string]$record.followerProcess.startUtc) {
        throw 'Follower process record does not match the exact captured container generation.'
    }
    if ($TestProcessIdentity) {
        if (-not (& $TestProcessIdentity $diskRecord)) { throw 'Follower process identity cannot be proven before generation sealing.' }
    } else {
        $process=Get-Process -Id ([int]$diskRecord.id) -ErrorAction SilentlyContinue
        if (!$process -or $process.ProcessName -cne [string]$diskRecord.name -or
                $process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$diskRecord.startUtc).UtcTicks) {
            throw 'Follower process identity cannot be proven before generation sealing.'
        }
    }
    if ($StopProcess) { & $StopProcess $diskRecord } else { Stop-GeordiCaptureProcessTree -ProcessId ([int]$diskRecord.id) }
    if (!$StopProcess -and (Get-Process -Id ([int]$diskRecord.id) -ErrorAction SilentlyContinue)) { throw 'Follower remained active after bounded seal.' }
    foreach ($streamPath in @([string]$record.capturePath,[string]$record.stderrCapturePath)) {
        if (!(Test-Path -LiteralPath $streamPath -PathType Leaf)) { throw 'A declared generation stream is missing.' }
    }
    $item=Get-Item -LiteralPath ([string]$record.capturePath) -Force
    if ($item.Length -gt $MaximumBytes) { throw 'Sealed generation stdout exceeded its bound.' }
    $stderrItem=Get-Item -LiteralPath ([string]$record.stderrCapturePath) -Force
    if ($stderrItem.Length -gt $MaximumBytes -or ([long]$item.Length+[long]$stderrItem.Length) -gt $MaximumBytes) {
        throw 'Sealed generation stderr capture exceeded its bound.'
    }
    $endedUtc=[DateTimeOffset]::UtcNow
    $hash=(Get-FileHash -LiteralPath ([string]$record.capturePath) -Algorithm SHA256).Hash.ToLowerInvariant()
    $stderrHash=(Get-FileHash -LiteralPath ([string]$record.stderrCapturePath) -Algorithm SHA256).Hash.ToLowerInvariant()
    $item.IsReadOnly=$true
    $stderrItem.IsReadOnly=$true
    $runId=[string]$manifest.runId
    $manifestPath=Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'manifest.json'
    $manifest=Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId $runId -Mutation {
        param($latest)
        $current=Get-GeordiCaptureGenerationRecord $latest $Service $GenerationId
        if (!$current -or [string]$current.terminalStatus -cne 'capturing' -or [string]$current.containerId -cne [string]$record.containerId) {
            throw 'Capture generation changed before sealing publication.'
        }
        $current.captureEndedUtc=$endedUtc.ToString('o');$current.byteCount=[long]$item.Length
        $current.sha256=$hash;$current.stderrByteCount=[long]$stderrItem.Length;$current.stderrSha256=$stderrHash;$current.terminalStatus='sealed'
        if (!$latest.ContainsKey('generationCaptures')) { $latest.generationCaptures=@{} }
        foreach ($channel in Get-GeordiCaptureGenerationChannel $Service) {
            if (!$latest.generationCaptures.ContainsKey($channel)) { $latest.generationCaptures[$channel]=@() }
            if ([string]$current.capturePath -in @($latest.generationCaptures[$channel])) { throw 'Capture generation path was already registered.' }
            $capturePaths=@()
            if ([long]$current.byteCount -gt 0) { $capturePaths += [string]$current.capturePath }
            if ([long]$current.stderrByteCount -gt 0) { $capturePaths += [string]$current.stderrCapturePath }
            foreach ($capturePath in $capturePaths) {
                if ($capturePath -in @($latest.generationCaptures[$channel])) { throw 'Capture generation path was already registered.' }
            }
            $latest.generationCaptures[$channel]=@(@($latest.generationCaptures[$channel])+$capturePaths)
        }
    }
    return $manifest.captureGenerations[$Service] | Where-Object { [string]$_.generationId -ceq $GenerationId } | Select-Object -First 1
}

function Seal-GeordiCaptureGeneration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $GenerationId,[long] $MaximumBytes=536870912L,
        [scriptblock] $TestProcessIdentity,[scriptblock] $StopProcess)
    try {
        return Seal-GeordiCaptureGenerationCore -CaptureRoot $CaptureRoot -Service $Service -GenerationId $GenerationId `
            -MaximumBytes $MaximumBytes -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess
    } catch {
        $manifest=Get-GeordiCaptureGenerationManifest $CaptureRoot
        $manifestPath=Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'manifest.json'
        try {
            Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId ([string]$manifest.runId) -Mutation {
                param($latest)
                $record=Get-GeordiCaptureGenerationRecord $latest $Service $GenerationId
                if ($record -and [string]$record.terminalStatus -ceq 'capturing') {
                    $record.terminalStatus='sealing-failed'
                    $record.captureEndedUtc=[DateTimeOffset]::UtcNow.ToString('o')
                    $record.sealFailureRecorded=$true
                }
                foreach ($handoffId in @($latest.captureHandoffs.Keys)) {
                    $handoff=$latest.captureHandoffs[$handoffId]
                    if ([string]$handoff.logicalService -ceq $Service -and [string]$handoff.oldGenerationId -ceq $GenerationId -and
                            [string]$handoff.status -ceq 'in_progress') {
                        $handoff.status='incomplete-old-seal'
                        $handoff.failurePhase='old-generation-sealing'
                    }
                }
            } | Out-Null
        } catch { throw 'Capture generation sealing failed and its failure state could not be published.' }
        throw 'Capture generation sealing failed; the generation remains incomplete and cannot be accepted.'
    }
}

function Invoke-GeordiCaptureHandoffReplacement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $HandoffId,[Parameter(Mandatory)][scriptblock] $Replace,
        [Parameter(Mandatory)][scriptblock] $GetContainerIdentity,[Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $Reason='controlled-container-replacement',[scriptblock] $StartFollower,[scriptblock] $AfterFollowerValidated,
        [scriptblock] $StopProcess,
        [string] $DockerPath=(Get-Command docker.exe -ErrorAction Stop).Source,
        [string] $PowerShellPath=(Get-Process -Id $PID).Path,
        [string] $WorkerPath=(Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1'))
    $manifest=Get-GeordiCaptureGenerationManifest $CaptureRoot
    if (!$manifest.captureHandoffs.ContainsKey($HandoffId) -or [string]$manifest.captureHandoffs[$HandoffId].logicalService -cne $Service -or
            [string]$manifest.captureHandoffs[$HandoffId].status -cne 'old-sealed') {
        throw 'Container replacement has no sealed generation handoff authorization.'
    }
    try {
        $null = & $Replace
        $identity=& $GetContainerIdentity $Service
        return Start-GeordiCaptureGeneration -CaptureRoot $CaptureRoot -Service $Service -ContainerIdentity $identity `
            -DockerPath $DockerPath -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath `
            -WorkingDirectory $RepositoryRoot -HandoffId $HandoffId -Reason $Reason -StartFollower $StartFollower `
            -AfterFollowerValidated $AfterFollowerValidated -StopProcess $StopProcess
    } catch {
        $failure=$_
        try {
            $manifestPath=Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'manifest.json'
            Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId ([string]$manifest.runId) -Mutation {
                param($latest)
                $handoff=$latest.captureHandoffs[$HandoffId]
                if ([string]$handoff.status -ceq 'old-sealed') { $handoff.status='incomplete-replacement';$handoff.failurePhase='replacement-or-new-capture' }
            } | Out-Null
        } catch { }
        throw $failure
    }
}

function Begin-GeordiCaptureHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $Reason,[scriptblock] $TestProcessIdentity,[scriptblock] $StopProcess)
    $manifest=Get-GeordiCaptureGenerationManifest $CaptureRoot
    $serviceRecords=if($manifest.captureGenerations.ContainsKey($Service)){@($manifest.captureGenerations[$Service])}else{@()}
    $active=@($serviceRecords | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
    if ($active.Count -gt 1) { throw 'Capture handoff found ambiguous active generations.' }
    if ($active.Count -eq 1) { $old=$active[0];$alreadySealed=$false }
    else {
        $sealed=@($serviceRecords | Where-Object { [string]$_.terminalStatus -ceq 'sealed' } |
            Sort-Object { [DateTimeOffset]$_.captureEndedUtc })
        if ($sealed.Count -eq 0) { throw 'Capture handoff has no proven old container generation.' }
        $old=$sealed[-1];$alreadySealed=$true
    }
    $handoffId=[guid]::NewGuid().ToString('N')
    $runId=[string]$manifest.runId
    $manifestPath=Join-Path ([IO.Path]::GetFullPath($CaptureRoot)) 'manifest.json'
    $oldCaptureEndedUtc=$null
    if ($alreadySealed) {
        $oldCaptureEndedUtc=(ConvertTo-GeordiCaptureUtcInstant -Value $old.captureEndedUtc -Field 'oldGeneration.captureEndedUtc').ToString('o')
    }
    $manifest=Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId $runId -Mutation {
        param($latest)
        if (!$latest.ContainsKey('captureHandoffs')) { $latest.captureHandoffs=@{} }
        if ($latest.captureHandoffs.ContainsKey($handoffId)) { throw 'Capture handoff identity collision.' }
        $latest.captureHandoffs[$handoffId]=[ordered]@{handoffId=$handoffId;logicalService=$Service;oldGenerationId=[string]$old.generationId;
            oldContainerId=[string]$old.containerId;replacementReason=$Reason;status=$(if($alreadySealed){'old-sealed'}else{'in_progress'});
            oldCaptureEndedUtc=$(if($alreadySealed){$oldCaptureEndedUtc}else{$null});startedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    }
    if ($alreadySealed) { return $handoffId }
    $sealed=Seal-GeordiCaptureGeneration -CaptureRoot $CaptureRoot -Service $Service -GenerationId ([string]$old.generationId) `
        -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess
    $ended=[DateTimeOffset]$sealed.captureEndedUtc
    Set-GeordiCaptureGenerationMutation -ManifestPath $manifestPath -RunId $runId -Mutation {
        param($latest)
        $handoff=$latest.captureHandoffs[$handoffId]
        if ([string]$handoff.status -cne 'in_progress' -or [string]$handoff.oldGenerationId -cne [string]$sealed.generationId) {
            throw 'Capture handoff identity changed after old-generation seal.'
        }
        $handoff.oldCaptureEndedUtc=$ended.ToString('o');$handoff.status='old-sealed'
    } | Out-Null
    return $handoffId
}

function Get-GeordiCurrentCaptureContainerIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Service,[Parameter(Mandatory)][string] $RepositoryRoot)
    $ids=@(& docker ps -q --filter 'label=com.docker.compose.project=geordi' --filter "label=com.docker.compose.service=$Service")
    if ($LASTEXITCODE -ne 0) { throw 'Capture service container inventory failed.' }
    $ids=@($ids | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_) })
    if ($ids.Count -ne 1) { throw 'Capture service does not have exactly one running container generation.' }
    return Get-GeordiDockerCaptureIdentity -ContainerId ([string]$ids[0]) -Service $Service -RepositoryRoot $RepositoryRoot
}

function Start-GeordiCurrentCaptureGeneration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $RepositoryRoot,[AllowEmptyString()][string] $HandoffId,
        [string] $Reason='initial-candidate-capture',[ValidateRange(1,120)][int] $MaximumGapSeconds=120)
    $identity=Get-GeordiCurrentCaptureContainerIdentity -Service $Service -RepositoryRoot $RepositoryRoot
    return Start-GeordiCaptureGeneration -CaptureRoot $CaptureRoot -Service $Service -ContainerIdentity $identity `
        -DockerPath (Get-Command docker.exe -ErrorAction Stop).Source -PowerShellPath (Get-Process -Id $PID).Path `
        -WorkerPath (Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1') -WorkingDirectory $RepositoryRoot `
        -HandoffId $HandoffId -Reason $Reason -MaximumGapSeconds $MaximumGapSeconds
}

function Get-GeordiActiveCaptureGenerationIds {
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string[]] $Services)
    $manifest=Get-GeordiCaptureGenerationManifest $CaptureRoot
    $active=[ordered]@{}
    foreach ($service in $Services) {
        $serviceRecords=if($manifest.captureGenerations.ContainsKey($service)){@($manifest.captureGenerations[$service])}else{@()}
        $records=@($serviceRecords | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
        if ($records.Count -ne 1) { throw 'Capture handoff requires one active generation for each selected service.' }
        $active[$service]=[string]$records[0].generationId
    }
    return $active
}

function Get-GeordiCaptureGenerationPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,[Parameter(Mandatory)][string] $Service)
    if (!$Manifest.captureGenerations.ContainsKey($Service)) { throw 'Required service capture generations are missing.' }
    $paths=[Collections.Generic.List[string]]::new()
    foreach ($generation in @($Manifest.captureGenerations[$Service])) {
        if ([string]$generation.terminalStatus -cne 'sealed') { throw 'Required service capture generation is not sealed.' }
        if ([long]$generation.byteCount -gt 0) { $paths.Add([string]$generation.capturePath) }
        if ([long]$generation.stderrByteCount -gt 0) { $paths.Add([string]$generation.stderrCapturePath) }
    }
    if ($paths.Count -eq 0) { throw 'Required service capture generation inventory is empty.' }
    return @($paths.ToArray())
}

function Get-GeordiCaptureChannelPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,[Parameter(Mandatory)][string] $Channel)
    $paths=[Collections.Generic.List[string]]::new()
    if ($Manifest.Contains('generationCaptures') -and $Manifest.generationCaptures.ContainsKey($Channel)) {
        foreach ($path in @($Manifest.generationCaptures[$Channel])) { $paths.Add([IO.Path]::GetFullPath([string]$path)) }
    }
    if ($Manifest.Contains('generationCaptureEvents')) {
        foreach ($event in @($Manifest.generationCaptureEvents.Values | Sort-Object -Property @{Expression={ [DateTimeOffset]$_.capturedUtc }},@{Expression={ [string]$_.occurrenceId }})) {
            foreach ($file in @($event.files)) {
                $mappedChannels = switch ([string]$file.service) {
                    'frontend' { @('nginx-access') }
                    { $_ -in @('backend','oidc-fixture','webhook-receiver','webhook-receiver-a','webhook-receiver-b') } { @('backend') }
                    'otel-collector' { @('otel','collector') }
                    default { @() }
                }
                if ($Channel -in $mappedChannels) { $paths.Add([IO.Path]::GetFullPath([string]$file.path)) }
            }
        }
    }
    $unique=[Collections.Generic.List[string]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $paths) { if ($seen.Add($path)) { $unique.Add($path) } }
    return @($unique.ToArray())
}

function Get-GeordiActiveCaptureGenerationRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,[Parameter(Mandatory)][string] $Service)
    $records=if($Manifest.captureGenerations.ContainsKey($Service)){@($Manifest.captureGenerations[$Service])}else{@()}
    $active=@($records | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
    if ($active.Count -ne 1) { throw 'Service does not have exactly one active capture generation.' }
    return $active[0]
}

function Get-GeordiPendingCaptureHandoffId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,[Parameter(Mandatory)][string] $Service)
    $pending=@($Manifest.captureHandoffs.Keys | Where-Object {
        [string]$Manifest.captureHandoffs[$_].logicalService -ceq $Service -and [string]$Manifest.captureHandoffs[$_].status -ceq 'old-sealed'
    })
    if ($pending.Count -ne 1) { throw 'Service replacement does not have exactly one sealed capture handoff.' }
    return [string]$pending[0]
}

function Invoke-GeordiFinalizeCaptureRestoration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $Service,
        [Parameter(Mandatory)][string] $RepositoryRoot,[Parameter(Mandatory)][scriptblock] $Replace,
        [Parameter(Mandatory)][scriptblock] $GetContainerIdentity,[scriptblock] $StartFollower,
        [string] $Reason='restore-m19-runtime-after-m14')
    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $pending=@($manifest.captureHandoffs.Keys | Where-Object {
        [string]$manifest.captureHandoffs[$_].logicalService -ceq $Service -and
        [string]$manifest.captureHandoffs[$_].status -ceq 'old-sealed'
    })
    if ($pending.Count -gt 1) { throw 'M19 restoration found ambiguous pending capture handoffs.' }
    $handoffId=if($pending.Count -eq 1){[string]$pending[0]}else{
        Begin-GeordiCaptureHandoff -CaptureRoot $CaptureRoot -Service $Service -Reason $Reason
    }
    $generationId=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $CaptureRoot -Service $Service -HandoffId $handoffId `
        -RepositoryRoot $RepositoryRoot -Replace $Replace -GetContainerIdentity $GetContainerIdentity `
        -StartFollower $StartFollower -Reason $Reason
    return [pscustomobject]@{HandoffId=$handoffId;GenerationId=$generationId}
}

function Set-GeordiFinalizeGenerationEvidenceState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Evidence,[Parameter(Mandatory)][System.Collections.IDictionary] $Manifest)
    $Evidence.generationCaptures=$Manifest.generationCaptures
    $Evidence.captureGenerations=$Manifest.captureGenerations
    $Evidence.captureHandoffs=$Manifest.captureHandoffs
}

function Begin-GeordiCaptureHandoffs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string[]] $Services,
        [Parameter(Mandatory)][string] $Reason)
    $handoffs=[ordered]@{}
    foreach ($service in $Services) { $handoffs[$service]=Begin-GeordiCaptureHandoff -CaptureRoot $CaptureRoot -Service $service -Reason $Reason }
    return $handoffs
}

function Assert-GeordiCaptureHandoffCoverage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest)
    if ($Manifest.ContainsKey('captureGenerations')) { Assert-GeordiCaptureGenerationManifest -Manifest $Manifest }
    foreach ($service in @($Manifest.captureGenerations.Keys)) {
        if (@($Manifest.captureGenerations[$service] | Where-Object { [string]$_.terminalStatus -in @('incomplete-start','capturing','sealing-failed') }).Count -gt 0) {
            throw 'Capture handoff coverage contains an unsealed generation.'
        }
    }
    if ($Manifest.Contains('captures')) {
        foreach ($service in @($Manifest.captureGenerations.Keys)) {
            foreach ($channel in Get-GeordiCaptureGenerationChannel ([string]$service)) {
                if (!$Manifest.captures.ContainsKey($channel) -or @($Manifest.captures[$channel]).Count -eq 0) { continue }
                foreach ($record in @($Manifest.captureGenerations[$service])) {
                    if ([long]$record.byteCount -gt 0 -and [string]$record.capturePath -notin @($Manifest.captures[$channel])) {
                        throw 'Credential scanner channel omitted a sealed container generation.'
                    }
                    if ([long]$record.stderrByteCount -gt 0 -and [string]$record.stderrCapturePath -notin @($Manifest.captures[$channel])) {
                        throw 'Credential scanner channel omitted a sealed generation stderr source.'
                    }
                }
                $paths=@($Manifest.captures[$channel] | ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
                if (@($paths | Select-Object -Unique).Count -ne $paths.Count) { throw 'Credential scanner channel double-counted a physical generation.' }
            }
        }
        if ($Manifest.Contains('generationCaptureEvents')) {
            foreach ($event in @($Manifest.generationCaptureEvents.Values)) {
                foreach ($file in @($event.files)) {
                    $channel = switch ([string]$file.service) {
                        'frontend' { 'nginx-access' }
                        { $_ -in @('backend','oidc-fixture','webhook-receiver','webhook-receiver-a','webhook-receiver-b') } { 'backend' }
                        'otel-collector' { 'otel' }
                        default { $null }
                    }
                    if ($channel -and $Manifest.captures.ContainsKey($channel) -and @($Manifest.captures[$channel]).Count -gt 0 -and
                            [string]$file.path -notin @($Manifest.captures[$channel])) {
                        throw 'Credential scanner channel omitted an immutable M14 generation event file.'
                    }
                }
            }
        }
    }
}

function Assert-GeordiCaptureGenerationManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Manifest)
    $seenPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($service in @($Manifest.captureGenerations.Keys)) {
        $previous=$null
        $seenContainers=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($record in @($Manifest.captureGenerations[$service])) {
            if ([string]$record.logicalService -cne [string]$service -or [string]$record.terminalStatus -cne 'sealed' -or
                    [string]$record.generationId -notmatch '^[0-9a-f]{32}$' -or [string]$record.containerId -notmatch '^[a-f0-9]{12,64}$' -or
                    [string]$record.candidateId -cne [string]$Manifest.runId -or [string]$record.runId -cne [string]$Manifest.runId -or
                    [string]$record.composeProject -cne 'geordi' -or !$record.followerProcess -or !$seenContainers.Add([string]$record.containerId)) {
                throw 'Capture generation manifest is incomplete or ambiguous.'
            }
            $start=ConvertTo-GeordiCaptureUtcInstant -Value $record.captureStartedUtc -Field 'generation.captureStartedUtc'
            $end=ConvertTo-GeordiCaptureUtcInstant -Value $record.captureEndedUtc -Field 'generation.captureEndedUtc'
            if ($end.UtcTicks -lt $start.UtcTicks) { throw 'Capture generation interval is invalid.' }
            $root=[IO.Path]::GetFullPath([string]$Manifest.root)
            $path=[IO.Path]::GetFullPath([string]$record.capturePath)
            $processPath=[IO.Path]::GetFullPath([string]$record.processRecordPath)
            if (!$path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
                    !$processPath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
                    [IO.Path]::GetFileName($path) -cne [string]$record.captureFileIdentity -or !$seenPaths.Add($path) -or
                    !(Test-Path -LiteralPath $path -PathType Leaf) -or !(Test-Path -LiteralPath $processPath -PathType Leaf)) {
                throw 'Capture generation path is missing, duplicated or misidentified.'
            }
            $processRecord=[IO.File]::ReadAllText($processPath) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ([int]$processRecord.id -ne [int]$record.followerProcess.id -or [string]$processRecord.name -cne [string]$record.followerProcess.name -or
                    [string]$processRecord.startUtc -cne [string]$record.followerProcess.startUtc -or
                    [string]$processRecord.containerId -cne [string]$record.containerId -or [string]$processRecord.service -cne [string]$service -or
                    [string]$processRecord.project -cne [string]$record.composeProject) { throw 'Sealed follower record does not prove its container generation.' }
            $item=Get-Item -LiteralPath $path -Force
            if ($item.Length -ne [long]$record.byteCount -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$record.sha256) {
                throw 'Capture generation integrity verification failed.'
            }
            $stderrPath=[IO.Path]::GetFullPath([string]$record.stderrCapturePath)
            if (!$stderrPath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
                    [IO.Path]::GetFileName($stderrPath) -cne [string]$record.stderrFileIdentity -or !$seenPaths.Add($stderrPath) -or
                    !(Test-Path -LiteralPath $stderrPath -PathType Leaf)) {
                throw 'Capture generation stderr identity is invalid.'
            }
            $stderrItem=Get-Item -LiteralPath $stderrPath -Force
            if ($stderrItem.Length -ne [long]$record.stderrByteCount -or
                    (Get-FileHash -LiteralPath $stderrPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$record.stderrSha256) {
                throw 'Capture generation stderr integrity verification failed.'
            }
            foreach ($channel in Get-GeordiCaptureGenerationChannel ([string]$service)) {
                if (!$Manifest.generationCaptures.ContainsKey($channel) -or
                        ([long]$record.byteCount -gt 0 -and [string]$record.capturePath -notin @($Manifest.generationCaptures[$channel])) -or
                        ([long]$record.stderrByteCount -gt 0 -and [string]$record.stderrCapturePath -notin @($Manifest.generationCaptures[$channel]))) {
                    throw 'A sealed capture generation is absent from its logical credential channel.'
                }
            }
            if ($previous) {
                $handoffId=[string]$record.handoffId
                if (!$handoffId -or !$Manifest.captureHandoffs.ContainsKey($handoffId)) { throw 'A replacement capture generation has no ordered handoff.' }
                $handoff=$Manifest.captureHandoffs[$handoffId]
                if ([string]$handoff.oldGenerationId -cne [string]$previous.generationId -or
                        [string]$handoff.newGenerationId -cne [string]$record.generationId) {
                    throw 'Capture generation order does not match its handoff relationship.'
                }
            }
            $previous=$record
        }
    }
    $completedBoundaries=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($handoffId in @($Manifest.captureHandoffs.Keys)) {
        $handoff=$Manifest.captureHandoffs[$handoffId]
        if ([string]$handoff.status -cne 'complete' -or [string]$handoff.handoffId -cne [string]$handoffId -or
                [string]$handoff.gapState -cne 'bounded-transition' -or
                !$Manifest.captureGenerations.ContainsKey([string]$handoff.logicalService)) { throw 'Capture handoff is incomplete or has an unexplained gap.' }
        $old=Get-GeordiCaptureGenerationRecord $Manifest ([string]$handoff.logicalService) ([string]$handoff.oldGenerationId)
        $new=Get-GeordiCaptureGenerationRecord $Manifest ([string]$handoff.logicalService) ([string]$handoff.newGenerationId)
        if (!$old -or !$new -or [string]$old.terminalStatus -cne 'sealed' -or [string]$new.terminalStatus -cne 'sealed' -or
                [string]$old.containerId -cne [string]$handoff.oldContainerId -or [string]$new.containerId -cne [string]$handoff.newContainerId -or
                [string]$old.containerId -ceq [string]$new.containerId) { throw 'Capture handoff does not bind distinct sealed container generations.' }
        $boundaryKey=[string]::Join([char]0,[string[]]@([string]$handoff.logicalService,[string]$handoff.oldGenerationId,[string]$handoff.newGenerationId))
        if (!$completedBoundaries.Add($boundaryKey)) { throw 'Duplicate completed capture handoff boundary.' }
        $serviceGenerations=@($Manifest.captureGenerations[[string]$handoff.logicalService])
        $newIndex=-1
        for($index=0;$index -lt $serviceGenerations.Count;$index++){
            if([string]$serviceGenerations[$index].generationId -ceq [string]$new.generationId){$newIndex=$index;break}
        }
        if($newIndex -le 0 -or [string]$new.handoffId -cne [string]$handoffId -or
                [string]$serviceGenerations[$newIndex-1].generationId -cne [string]$old.generationId){
            throw 'Completed capture handoff is not the authoritative incoming handoff from the immediate predecessor.'
        }
        $oldStarted=ConvertTo-GeordiCaptureUtcInstant -Value $old.captureStartedUtc -Field 'oldGeneration.captureStartedUtc'
        $handoffStarted=ConvertTo-GeordiCaptureUtcInstant -Value $handoff.startedUtc -Field 'handoff.startedUtc'
        $oldEnded=ConvertTo-GeordiCaptureUtcInstant -Value $old.captureEndedUtc -Field 'oldGeneration.captureEndedUtc'
        $newStarted=ConvertTo-GeordiCaptureUtcInstant -Value $new.captureStartedUtc -Field 'newGeneration.captureStartedUtc'
        $recordedOldEnded=ConvertTo-GeordiCaptureUtcInstant -Value $handoff.oldCaptureEndedUtc -Field 'handoff.oldCaptureEndedUtc'
        $recordedNewStarted=ConvertTo-GeordiCaptureUtcInstant -Value $handoff.newCaptureStartedUtc -Field 'handoff.newCaptureStartedUtc'
        $handoffCompleted=ConvertTo-GeordiCaptureUtcInstant -Value $handoff.completedUtc -Field 'handoff.completedUtc'
        if ($oldStarted.UtcTicks -gt $handoffStarted.UtcTicks -or
                $handoffStarted.UtcTicks -gt $newStarted.UtcTicks -or
                $newStarted.UtcTicks -gt $handoffCompleted.UtcTicks -or
                $oldEnded.UtcTicks -gt $newStarted.UtcTicks -or
                $oldEnded.UtcTicks -ne $recordedOldEnded.UtcTicks -or
                $newStarted.UtcTicks -ne $recordedNewStarted.UtcTicks) {
            throw 'Capture handoff timestamps do not match generation chronology.'
        }
        $gapTicks=$newStarted.UtcTicks-$oldEnded.UtcTicks
        if ($gapTicks -lt 0) { throw 'Capture generation overlap is not supported by this handoff contract.' }
        $actualGapMilliseconds=[long][Math]::Floor([double]$gapTicks/[TimeSpan]::TicksPerMillisecond)
        $declaredGapMilliseconds=[long]$handoff.gapDurationMilliseconds
        $maximumGapMilliseconds=[long]$handoff.maximumGapMilliseconds
        if ($maximumGapMilliseconds -le 0 -or $declaredGapMilliseconds -ne $actualGapMilliseconds -or
                $actualGapMilliseconds -gt $maximumGapMilliseconds) {
            throw 'Capture handoff declared gap does not match the recomputed bounded interval.'
        }
    }
}
