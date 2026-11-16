. (Join-Path $PSScriptRoot 'GeordiCaptureGenerations.ps1')

function Invoke-GeordiM10BackendControlledReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CaptureRoot,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $InvokeCompose,
        [Parameter(Mandatory)][scriptblock] $RemoveFixtureVolume,
        [Parameter(Mandatory)][scriptblock] $ResolveContainerIdentity,
        [scriptblock] $StartFollower,
        [scriptblock] $TestProcessIdentity,
        [scriptblock] $StopProcess,
        [string] $DockerPath=(Get-Command docker.exe -ErrorAction Stop).Source,
        [string] $PowerShellPath=(Get-Process -Id $PID).Path,
        [string] $WorkerPath=(Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1')
    )
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $oldIdentity=& $ResolveContainerIdentity 'backend'
    Assert-GeordiCaptureContainerIdentity -Identity $oldIdentity -Service 'backend'
    if ([IO.Path]::GetFullPath([string]$oldIdentity.WorkingDirectory) -cne $root -or
            ($oldIdentity.PSObject.Properties.Name -contains 'Running' -and !$oldIdentity.Running)) {
        throw 'M10 backend identity is outside the active candidate checkout.'
    }

    $manifest=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $records=if($manifest.captureGenerations.ContainsKey('backend')){@($manifest.captureGenerations.backend)}else{@()}
    $active=@($records | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
    if($active.Count -ne 1 -or [string]$active[0].containerId -cne [string]$oldIdentity.Id -or !$active[0].followerProcess){
        throw 'M10 backend has no unique active generation bound to its current container.'
    }

    $handoffId=Begin-GeordiCaptureHandoff -CaptureRoot $CaptureRoot -Service 'backend' `
        -Reason 'm10-dedicated-lifecycle-volume-reset' -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess
    $replace={
        $removeArguments=@('rm','-sf','backend')
        & $InvokeCompose $removeArguments 'M10 backend removal'
        & $RemoveFixtureVolume
        $recreateArguments=@('up','-d','--force-recreate','backend')
        & $InvokeCompose $recreateArguments 'M10 backend force recreation'
    }.GetNewClosure()
    $getNewIdentity={
        param([string]$service)
        if($service -cne 'backend'){throw 'M10 replacement requested an unexpected logical service.'}
        $identity=& $ResolveContainerIdentity $service
        Assert-GeordiCaptureContainerIdentity -Identity $identity -Service 'backend'
        if([IO.Path]::GetFullPath([string]$identity.WorkingDirectory) -cne $root -or
                ($identity.PSObject.Properties.Name -contains 'Running' -and !$identity.Running)){
            throw 'M10 replacement backend is outside the active candidate checkout.'
        }
        if([string]$identity.Id -ceq [string]$oldIdentity.Id){throw 'M10 backend replacement reused the old container identity.'}
        return $identity
    }.GetNewClosure()
    $generationId=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $CaptureRoot -Service 'backend' `
        -HandoffId $handoffId -RepositoryRoot $root -Replace $replace -GetContainerIdentity $getNewIdentity `
        -StartFollower $StartFollower -DockerPath $DockerPath -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath

    $completed=Get-GeordiCaptureGenerationManifest -CaptureRoot $CaptureRoot
    $handoff=$completed.captureHandoffs[$handoffId]
    $newRecord=Get-GeordiCaptureGenerationRecord -Manifest $completed -Service 'backend' -GenerationId $generationId
    if(!$newRecord -or [string]$newRecord.terminalStatus -cne 'capturing' -or
            [string]$newRecord.handoffId -cne $handoffId -or [string]$handoff.status -cne 'complete' -or
            [string]$handoff.newContainerId -cne [string]$newRecord.containerId -or
            [string]$newRecord.containerId -ceq [string]$oldIdentity.Id){
        throw 'M10 backend generation handoff did not publish a distinct active replacement.'
    }
    return [pscustomobject]@{HandoffId=$handoffId;OldGenerationId=[string]$active[0].generationId;
        NewGenerationId=[string]$generationId;OldContainerId=[string]$oldIdentity.Id;NewContainerId=[string]$newRecord.containerId}
}
