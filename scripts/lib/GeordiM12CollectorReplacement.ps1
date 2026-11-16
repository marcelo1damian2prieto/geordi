. (Join-Path $PSScriptRoot 'GeordiCaptureGenerations.ps1')

function Get-GeordiM12CollectorComposeArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot,[switch] $ReplacementOverlay)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $arguments=[Collections.Generic.List[string]]::new()
    foreach ($file in @('compose.yaml','compose.m19.yaml','compose.m12.yaml')) {
        $arguments.Add('--file')
        $arguments.Add((Join-Path $root $file))
    }
    if ($ReplacementOverlay) {
        $arguments.Add('--file')
        $arguments.Add((Join-Path $root 'compose.m12-collector-replacement.yaml'))
    }
    $arguments.Add('--project-directory')
    $arguments.Add($root)
    return $arguments.ToArray()
}

function Get-GeordiM12CollectorReplacementArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)
    $arguments=[Collections.Generic.List[string]]::new()
    $composeArguments=Get-GeordiM12CollectorComposeArguments -RepositoryRoot $RepositoryRoot -ReplacementOverlay
    foreach ($argument in $composeArguments) {
        $arguments.Add([string]$argument)
    }
    foreach ($argument in @('up','-d','--no-deps','--force-recreate','otel-collector')) { $arguments.Add($argument) }
    return $arguments.ToArray()
}

function ConvertTo-GeordiM12CanonicalValue {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered=[ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            $ordered[[string]$key]=ConvertTo-GeordiM12CanonicalValue $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items=[Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-GeordiM12CanonicalValue $item)) }
        return ,$items.ToArray()
    }
    return $Value
}

function ConvertTo-GeordiM12CanonicalJson {
    param([AllowNull()][object] $Value)
    return ConvertTo-Json -InputObject (ConvertTo-GeordiM12CanonicalValue $Value) -Depth 100 -Compress
}

function Get-GeordiM12ServiceComparableConfiguration {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Service)
    $copy=[ordered]@{}
    foreach ($key in @($Service.Keys)) {
        if ([string]$key -cne 'depends_on') { $copy[[string]$key]=$Service[$key]; continue }
        $dependencies=[ordered]@{}
        foreach ($dependency in @($Service.depends_on.Keys | Sort-Object -CaseSensitive)) {
            $edge=[ordered]@{}
            foreach ($edgeKey in @($Service.depends_on[$dependency].Keys)) {
                if ([string]$dependency -ceq 'otel-collector' -and [string]$edgeKey -ceq 'restart') { continue }
                $edge[[string]$edgeKey]=$Service.depends_on[$dependency][$edgeKey]
            }
            $dependencies[[string]$dependency]=$edge
        }
        $copy.depends_on=$dependencies
    }
    return $copy
}

function Get-GeordiM12EffectiveDependencyRestart {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Dependency)
    if ($Dependency -isnot [System.Collections.IDictionary]) {
        throw 'M12 Compose dependency entry is not a rendered long-form object.'
    }
    if (!$Dependency.Contains('restart')) { return $false }
    if ($Dependency['restart'] -isnot [bool]) {
        throw 'M12 Compose dependency restart value is not a rendered boolean.'
    }
    return [bool]$Dependency['restart']
}

function Assert-GeordiM12CollectorReplacementConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $NormalConfiguration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $ReplacementConfiguration)
    foreach ($name in @('services','volumes','networks')) {
        if ((ConvertTo-GeordiM12CanonicalJson $NormalConfiguration[$name]) -cne
                (ConvertTo-GeordiM12CanonicalJson $ReplacementConfiguration[$name])) {
            if ($name -ne 'services') { throw 'M12 Collector replacement changed shared volumes or networks.' }
        }
    }
    $normalServices=$NormalConfiguration.services
    $replacementServices=$ReplacementConfiguration.services
    if (@($normalServices.Keys | Sort-Object -CaseSensitive) -join "`n" -cne
            (@($replacementServices.Keys | Sort-Object -CaseSensitive) -join "`n")) {
        throw 'M12 Collector replacement changed the service inventory.'
    }
    if (!$normalServices.Contains('otel-collector') -or !$replacementServices.Contains('otel-collector')) {
        throw 'M12 Collector replacement configuration omitted the Collector service.'
    }
    if ((ConvertTo-GeordiM12CanonicalJson $normalServices['otel-collector']) -cne
            (ConvertTo-GeordiM12CanonicalJson $replacementServices['otel-collector'])) {
        throw 'M12 Collector replacement changed the Collector configuration.'
    }

    $dependentEdges=[Collections.Generic.List[string]]::new()
    foreach ($serviceName in @($normalServices.Keys)) {
        $normalService=$normalServices[$serviceName]
        $replacementService=$replacementServices[$serviceName]
        if ($normalService -isnot [System.Collections.IDictionary] -or $replacementService -isnot [System.Collections.IDictionary]) {
            throw 'M12 Compose service configuration is not a rendered object.'
        }
        $normalDependencies=if ($normalService.Contains('depends_on')) {$normalService.depends_on}else{@{}}
        $replacementDependencies=if ($replacementService.Contains('depends_on')) {$replacementService.depends_on}else{@{}}
        if ($normalDependencies -isnot [System.Collections.IDictionary] -or $replacementDependencies -isnot [System.Collections.IDictionary]) {
            throw 'M12 Compose dependency map is not a rendered object.'
        }
        if (@($normalDependencies.Keys | Sort-Object -CaseSensitive) -join "`n" -cne
                (@($replacementDependencies.Keys | Sort-Object -CaseSensitive) -join "`n")) {
            throw 'M12 Collector replacement changed a dependency relationship.'
        }
        foreach ($dependencyName in @($normalDependencies.Keys)) {
            $normalEdge=$normalDependencies[$dependencyName]
            $replacementEdge=$replacementDependencies[$dependencyName]
            if ([string]$dependencyName -ceq 'otel-collector') {
                $normalRestart=Get-GeordiM12EffectiveDependencyRestart $normalEdge
                $replacementRestart=Get-GeordiM12EffectiveDependencyRestart $replacementEdge
                if ((ConvertTo-GeordiM12CanonicalJson $normalEdge.condition) -cne
                        (ConvertTo-GeordiM12CanonicalJson $replacementEdge.condition)) {
                    throw 'M12 Collector replacement changed a dependent readiness condition.'
                }
                foreach ($key in @($normalEdge.Keys | Where-Object { $_ -cne 'restart' })) {
                    if ((ConvertTo-GeordiM12CanonicalJson $normalEdge[$key]) -cne
                            (ConvertTo-GeordiM12CanonicalJson $replacementEdge[$key])) {
                        throw 'M12 Collector replacement changed dependent edge semantics.'
                    }
                }
                if ($normalRestart) { $dependentEdges.Add([string]$serviceName) }
                if ($replacementRestart) {
                    throw 'M12 Collector replacement leaves a restart propagation edge enabled.'
                }
            } elseif ($normalEdge -isnot [System.Collections.IDictionary] -or $replacementEdge -isnot [System.Collections.IDictionary] -or
                    (ConvertTo-GeordiM12CanonicalJson $normalEdge) -cne
                    (ConvertTo-GeordiM12CanonicalJson $replacementEdge)) {
                throw 'M12 Collector replacement changed an unrelated dependency edge.'
            }
        }
        if ((ConvertTo-GeordiM12CanonicalJson (Get-GeordiM12ServiceComparableConfiguration $normalService)) -cne
                (ConvertTo-GeordiM12CanonicalJson (Get-GeordiM12ServiceComparableConfiguration $replacementService))) {
            throw 'M12 Collector replacement changed service configuration outside restart isolation.'
        }
    }
    if ($dependentEdges.Count -eq 0) { throw 'Normal M12 configuration has no Collector restart-propagation edges to isolate.' }

    $collector=$replacementServices['otel-collector']
    foreach ($volume in @($collector.volumes)) {
        if ([string]$volume.source -match 'm19-alert-lifecycle-data|m19-victoriametrics-data' -or
                [string]$volume.target -match 'm19-alert-lifecycle-data|m19-victoriametrics-data') {
            throw 'M12 Collector replacement mounts a protected M19 volume.'
        }
    }
    return @($dependentEdges.ToArray() | Sort-Object -Unique)
}

function Get-GeordiM12LegacyResetCaptureServices {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Services)
    return @($Services | Where-Object { $_ -cne 'otel-collector' })
}

function Invoke-GeordiM12CollectorControlledReplacement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $RenderComposeConfiguration,
        [Parameter(Mandatory)][scriptblock] $InvokeCompose,[Parameter(Mandatory)][scriptblock] $ResolveContainerIdentity,
        [scriptblock] $WaitForReadiness,[scriptblock] $StartFollower,[scriptblock] $TestProcessIdentity,
        [scriptblock] $StopProcess,[string] $DockerPath=(Get-Command docker.exe -ErrorAction Stop).Source,
        [string] $PowerShellPath=(Get-Process -Id $PID).Path,
        [string] $WorkerPath=(Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1'),
        [scriptblock] $AfterFollowerValidated)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $normal=& $RenderComposeConfiguration $root $false
    $replacement=& $RenderComposeConfiguration $root $true
    $null=Assert-GeordiM12CollectorReplacementConfiguration -NormalConfiguration $normal -ReplacementConfiguration $replacement

    $oldIdentity=& $ResolveContainerIdentity 'otel-collector'
    Assert-GeordiCaptureContainerIdentity -Identity $oldIdentity -Service 'otel-collector'
    if ([IO.Path]::GetFullPath([string]$oldIdentity.WorkingDirectory) -cne $root -or
            ($oldIdentity.PSObject.Properties.Name -contains 'Running' -and !$oldIdentity.Running)) {
        throw 'M12 Collector identity is outside the active candidate checkout.'
    }
    $manifest=Get-GeordiCaptureGenerationManifest $CaptureRoot
    $records=if ($manifest.captureGenerations.ContainsKey('otel-collector')) {@($manifest.captureGenerations['otel-collector'])}else{@()}
    $active=@($records | Where-Object { [string]$_.terminalStatus -ceq 'capturing' })
    if ($active.Count -ne 1 -or [string]$active[0].containerId -cne [string]$oldIdentity.Id -or !$active[0].followerProcess) {
        throw 'M12 Collector has no unique active generation bound to its current container.'
    }

    $handoffId=Begin-GeordiCaptureHandoff -CaptureRoot $CaptureRoot -Service 'otel-collector' `
        -Reason 'm12-fresh-victoriametrics-provider-boundary' -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess
    $arguments=Get-GeordiM12CollectorReplacementArguments -RepositoryRoot $root
    $replace={
        & $InvokeCompose $arguments 'M12 Collector controlled replacement'
        if ($WaitForReadiness) { & $WaitForReadiness }
    }.GetNewClosure()
    $getNewIdentity={
        param([string] $service)
        $identity=& $ResolveContainerIdentity $service
        Assert-GeordiCaptureContainerIdentity -Identity $identity -Service 'otel-collector'
        if ([string]$identity.Id -ceq [string]$oldIdentity.Id) { throw 'M12 Collector replacement reused the old container identity.' }
        return $identity
    }.GetNewClosure()
    $newGenerationId=Invoke-GeordiCaptureHandoffReplacement -CaptureRoot $CaptureRoot -Service 'otel-collector' `
        -HandoffId $handoffId -RepositoryRoot $root -Replace $replace -GetContainerIdentity $getNewIdentity `
        -StartFollower $StartFollower -AfterFollowerValidated $AfterFollowerValidated -StopProcess $StopProcess `
        -DockerPath $DockerPath -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath

    $completed=Get-GeordiCaptureGenerationManifest $CaptureRoot
    $handoff=$completed.captureHandoffs[$handoffId]
    $newRecord=Get-GeordiCaptureGenerationRecord $completed 'otel-collector' $newGenerationId
    if (!$newRecord -or [string]$newRecord.terminalStatus -cne 'capturing' -or
            [string]$newRecord.handoffId -cne $handoffId -or [string]$handoff.status -cne 'complete' -or
            [string]$handoff.newContainerId -cne [string]$newRecord.containerId -or
            [string]$newRecord.containerId -ceq [string]$oldIdentity.Id) {
        throw 'M12 Collector generation handoff did not publish a distinct active replacement.'
    }
    return [pscustomobject]@{HandoffId=$handoffId;OldContainerId=[string]$oldIdentity.Id;
        NewContainerId=[string]$newRecord.containerId;GenerationId=[string]$newGenerationId;Status=[string]$handoff.status}
}
