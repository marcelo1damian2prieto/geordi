[CmdletBinding()]
param([ValidateSet('CallbackAbsent','Ordering','WrongFollower','ReadinessFailure','CleanupFailure')][string] $Case='CallbackAbsent')

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiCaptureGenerations.ps1')

function Assert-PostFollowerReadiness([bool] $Condition,[string] $Message) {
    if (!$Condition) { throw "Post-follower readiness regression failed: $Message" }
}

function New-PostFollowerRoot {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('geordi-post-follower-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $now=[DateTimeOffset]::UtcNow.ToString('o')
    $manifest=[ordered]@{version=2;root=$root;runId='synthetic-post-follower';startedUtc=$now;captureStartedUtc=$now;
        captureGenerations=@{};captureHandoffs=@{};generationCaptures=@{};captures=@()}
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 32 -Compress),[Text.UTF8Encoding]::new($false))
    return $root
}

function Remove-PostFollowerRoot([string] $Root) {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}

function New-PostFollowerIdentity([string] $Id) {
    return [pscustomobject]@{Id=$Id;Project='geordi';Service='backend';WorkingDirectory=(Get-Location).Path;
        CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Running=$true}
}

$script:postFollowerState=$null
function Stop-GeordiCaptureProcessTree {
    param([Parameter(Mandatory)][int] $ProcessId)
    $script:postFollowerState.CleanupCount++
    if ($script:postFollowerState.CleanupFails) { throw [InvalidOperationException]::new('SYNTHETIC_CLEANUP_PRIVATE_DETAIL') }
    $script:postFollowerState.Alive[[string]$ProcessId]=$false
}

function Invoke-PostFollowerCase([string] $SelectedCase) {
    $root=New-PostFollowerRoot
    $state=[pscustomobject]@{Pid=81000;Alive=@{};Events=[Collections.Generic.List[string]]::new();
        ReadinessCount=0;CleanupCount=0;CleanupFails=($SelectedCase -ceq 'CleanupFailure')}
    $script:postFollowerState=$state
    try {
        $oldIdentity=New-PostFollowerIdentity ('a'*64)
        $start={
            param($stdout,$stderr,$processRecord,$arguments,$target)
            $state.Pid++
            $startUtc=[DateTimeOffset]::UtcNow.ToString('o')
            $containerId=if($SelectedCase -ceq 'WrongFollower' -and [string]$target.containerId -cne ('a'*64)){ 'f'*64 } else { [string]$target.containerId }
            $record=[ordered]@{id=$state.Pid;name='synthetic-follower';startUtc=$startUtc;containerId=$containerId;
                service=[string]$target.service;project=[string]$target.project;createdUtc=[string]$target.createdUtc}
            [IO.File]::WriteAllText($processRecord,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($stdout,"capture-$containerId`n",[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($stderr,'',[Text.UTF8Encoding]::new($false))
            $state.Alive[[string]$state.Pid]=$true
            $state.Events.Add('start-follower')
            return [pscustomobject]@{id=$state.Pid;name='synthetic-follower';startUtc=$startUtc}
        }.GetNewClosure()
        $testProcess={param($record)[bool]$state.Alive[[string]$record.id]}.GetNewClosure()
        $stopProcess={param($record)$state.Alive[[string]$record.id]=$false}.GetNewClosure()
        $oldGeneration=Start-GeordiCaptureGeneration -CaptureRoot $root -Service backend -ContainerIdentity $oldIdentity `
            -DockerPath 'synthetic-docker' -PowerShellPath 'synthetic-pwsh' -WorkerPath 'synthetic-worker' `
            -WorkingDirectory (Get-Location).Path -StartFollower $start
        $handoff=Begin-GeordiCaptureHandoff -CaptureRoot $root -Service backend -Reason 'post-follower-test' `
            -TestProcessIdentity $testProcess -StopProcess $stopProcess
        $state.Events.Clear()
        $oldRecord=Get-GeordiCaptureGenerationRecord (Get-GeordiCaptureGenerationManifest $root) backend $oldGeneration
        $oldRecordSnapshot=ConvertTo-Json -InputObject $oldRecord -Depth 32 -Compress
        $oldCaptureHash=(Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash

        $replace={ $state.Events.Add('replace') }.GetNewClosure()
        $resolve={
            param([string] $service)
            $state.Events.Add('resolve-new')
            return New-PostFollowerIdentity ('b'*64)
        }.GetNewClosure()
        $readiness={
            param($identity,$process,$generationId)
            $manifest=Get-GeordiCaptureGenerationManifest $root
            $record=Get-GeordiCaptureGenerationRecord $manifest backend $generationId
            if (!$record -or [int]$record.followerProcess.id -ne [int]$process.id -or
                    [string]$record.containerId -cne [string]$identity.containerId) {
                throw ("READINESS_RAN_BEFORE_VALIDATED_FOLLOWER_PUBLICATION record={0} process={1} binding={2}" -f
                    [bool]$record,([bool]$record -and [int]$record.followerProcess.id -eq [int]$process.id),
                    ([bool]$record -and [string]$record.containerId -ceq [string]$identity.containerId))
            }
            $state.Events.Add('follower-binding-validated')
            $state.ReadinessCount++
            $state.Events.Add('after-follower-validated')
            if ($SelectedCase -in @('ReadinessFailure','CleanupFailure')) { throw 'READINESS_FAILURE' }
        }.GetNewClosure()

        $failure=$null
        try {
            $arguments=@{CaptureRoot=$root;Service='backend';HandoffId=$handoff;RepositoryRoot=(Get-Location).Path;
                Replace=$replace;GetContainerIdentity=$resolve;StartFollower=$start;Reason='post-follower-test'}
            if ($SelectedCase -ne 'CallbackAbsent') { $arguments.AfterFollowerValidated=$readiness }
            $newGeneration=Invoke-GeordiCaptureHandoffReplacement @arguments
        } catch { $failure=$_ }

        $manifest=Get-GeordiCaptureGenerationManifest $root
        $handoffRecord=$manifest.captureHandoffs[$handoff]
        $newRecords=@($manifest.captureGenerations.backend | Where-Object { [string]$_.containerId -ceq ('b'*64) })
        if ($SelectedCase -eq 'CallbackAbsent') {
            Assert-PostFollowerReadiness ($null -eq $failure -and $handoffRecord.status -ceq 'complete' -and
                $newRecords.Count -eq 1 -and $state.ReadinessCount -eq 0) 'callback-absent behavior changed'
            Write-Output 'shared_readiness_callback_absent=PASS'
            return
        }
        if ($SelectedCase -eq 'Ordering') {
            if ($null -ne $failure) { throw $failure }
            $state.Events.Add('handoff-complete')
            $expected=@('replace','resolve-new','start-follower','follower-binding-validated','after-follower-validated','handoff-complete')
            Assert-PostFollowerReadiness (($state.Events -join ',') -ceq ($expected -join ',')) 'observable lifecycle event order differs'
            Assert-PostFollowerReadiness ($handoffRecord.status -ceq 'complete' -and $newRecords.Count -eq 1 -and
                $newRecords[0].terminalStatus -ceq 'capturing') 'successful callback did not precede completed active handoff'
            Assert-PostFollowerReadiness ((ConvertTo-Json -InputObject (Get-GeordiCaptureGenerationRecord $manifest backend $oldGeneration) -Depth 32 -Compress) -ceq $oldRecordSnapshot -and
                (Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash -ceq $oldCaptureHash) 'callback path mutated sealed old history'
            Write-Output 'shared_readiness_ordering=PASS replace>resolve>start>binding>callback>complete history=immutable'
            return
        }
        if ($SelectedCase -eq 'WrongFollower') {
            Assert-PostFollowerReadiness ($null -ne $failure -and $state.ReadinessCount -eq 0 -and
                $state.CleanupCount -ge 1 -and $handoffRecord.status -cne 'complete' -and
                @($newRecords | Where-Object terminalStatus -ceq 'capturing').Count -eq 0) `
                'wrong follower reached readiness, escaped cleanup, or was accepted'
            Write-Output 'shared_readiness_wrong_follower=PASS callback_count=0 cleanup=attempted handoff=incomplete generation=not_active'
            return
        }
        Assert-PostFollowerReadiness ($null -ne $failure -and $failure.Exception.Message -ceq 'READINESS_FAILURE' -and
            $state.ReadinessCount -eq 1 -and $handoffRecord.status -cne 'complete' -and
            @($newRecords | Where-Object terminalStatus -ceq 'capturing').Count -eq 0 -and $state.CleanupCount -ge 1) `
            'readiness failure was not primary, did not clean up, or completed the handoff'
        Assert-PostFollowerReadiness ((ConvertTo-Json -InputObject (Get-GeordiCaptureGenerationRecord $manifest backend $oldGeneration) -Depth 32 -Compress) -ceq $oldRecordSnapshot -and
            (Get-FileHash -LiteralPath $oldRecord.capturePath -Algorithm SHA256).Hash -ceq $oldCaptureHash) 'readiness failure mutated sealed old history'
        if ($SelectedCase -eq 'CleanupFailure') {
            Assert-PostFollowerReadiness (!$failure.Exception.Message.Contains('SYNTHETIC_CLEANUP_PRIVATE_DETAIL') -and
                $failure.Exception.Data.Contains('FollowerCleanupFailure') -and
                [string]$failure.Exception.Data['FollowerCleanupFailure'] -ceq 'System.InvalidOperationException') `
                'cleanup failure masked the readiness error or leaked cleanup message text'
            Write-Output 'shared_readiness_cleanup_failure=PASS primary=READINESS_FAILURE secondary=exception_type_only'
        } else {
            Assert-PostFollowerReadiness (!$failure.Exception.Data.Contains('FollowerCleanupFailure')) 'successful cleanup was marked as failed'
            Write-Output 'shared_readiness_failure=PASS primary=preserved cleanup=attempted handoff=incomplete history=immutable'
        }
    } finally { Remove-PostFollowerRoot $root }
}

Invoke-PostFollowerCase $Case
