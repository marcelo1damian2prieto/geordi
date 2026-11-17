. (Join-Path $PSScriptRoot 'GeordiM12CollectorReplacement.ps1')

function Get-GeordiM12OverlapComposeArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $CollectorReplacementOverlay,[switch] $IsolationOverlay)
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $arguments=[Collections.Generic.List[string]]::new()
    $files=[Collections.Generic.List[string]]::new()
    foreach($file in @('compose.yaml','compose.m19.yaml','compose.m12.yaml','compose.m12-overlap.yaml')){
        $files.Add($file)
    }
    if($CollectorReplacementOverlay){$files.Add('compose.m12-collector-replacement.yaml')}
    if($IsolationOverlay){$files.Add('compose.m12-overlap-isolation.yaml')}
    foreach($file in $files){$arguments.Add('--file');$arguments.Add((Join-Path $root $file))}
    $arguments.Add('--project-directory');$arguments.Add($root)
    return $arguments.ToArray()
}

function Get-GeordiM12OverlapComposeConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $CollectorReplacementOverlay,[switch] $IsolationOverlay,
        [scriptblock] $InvokeCompose)
    $arguments=Get-GeordiM12OverlapComposeArguments -RepositoryRoot $RepositoryRoot `
        -CollectorReplacementOverlay:$CollectorReplacementOverlay -IsolationOverlay:$IsolationOverlay
    if($InvokeCompose){
        $result=& $InvokeCompose $arguments
    }else{
        $output=& docker compose @arguments config --format json 2>$null
        $result=[pscustomobject]@{ExitCode=$LASTEXITCODE;Output=@($output)}
    }
    if(!$result -or $null -eq $result.PSObject.Properties['ExitCode'] -or [int]$result.ExitCode -ne 0){
        throw 'M12 overlap Compose configuration rendering failed.'
    }
    $lines=@($result.Output)
    if(!$lines.Count -or [string]::IsNullOrWhiteSpace(($lines -join "`n"))){
        throw 'M12 overlap Compose configuration was not valid JSON.'
    }
    try{return (($lines -join "`n")|ConvertFrom-Json -AsHashtable -ErrorAction Stop)}
    catch{throw 'M12 overlap Compose configuration was not valid JSON.'}
}

function Get-GeordiM12OverlapIsolationEdges {
    return @(
        [pscustomobject]@{service='backend';dependency='otel-collector'},
        [pscustomobject]@{service='backend';dependency='victoriametrics'},
        [pscustomobject]@{service='otel-collector';dependency='victoriametrics'},
        [pscustomobject]@{service='demo';dependency='otel-collector'},
        [pscustomobject]@{service='demo-downstream';dependency='otel-collector'},
        [pscustomobject]@{service='burn-demo';dependency='otel-collector'},
        [pscustomobject]@{service='m12-burn-demo';dependency='otel-collector'}
    )
}

function ConvertTo-GeordiM12OverlapCanonicalValue {
    param([AllowNull()][object] $Value)
    if($null -eq $Value){return $null}
    if($Value -is [System.Collections.IDictionary]){
        $ordered=[ordered]@{}
        foreach($key in @($Value.Keys|Sort-Object -CaseSensitive)){
            $ordered[[string]$key]=ConvertTo-GeordiM12OverlapCanonicalValue $Value[$key]
        }
        return $ordered
    }
    if($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]){
        $items=[Collections.Generic.List[object]]::new()
        foreach($item in $Value){$items.Add((ConvertTo-GeordiM12OverlapCanonicalValue $item))}
        return ,$items.ToArray()
    }
    return $Value
}

function ConvertTo-GeordiM12OverlapCanonicalJson {
    param([AllowNull()][object] $Value)
    return ConvertTo-Json -InputObject (ConvertTo-GeordiM12OverlapCanonicalValue $Value) -Depth 100 -Compress
}

function Copy-GeordiM12OverlapConfiguration {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Configuration)
    return (ConvertTo-Json -InputObject $Configuration -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
}

function Get-GeordiM12OverlapRestartDependents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][string[]] $Dependencies)
    $edges=[Collections.Generic.List[object]]::new()
    foreach($serviceName in @($Configuration.services.Keys)){
        $service=$Configuration.services[$serviceName]
        if($service -isnot [System.Collections.IDictionary] -or !$service.Contains('depends_on')){continue}
        foreach($dependencyName in @($service.depends_on.Keys)){
            if($dependencyName -notin $Dependencies){continue}
            $edge=$service.depends_on[$dependencyName]
            if($edge -isnot [System.Collections.IDictionary]){throw 'M12 overlap dependency is not a rendered long-form object.'}
            if($edge.Contains('restart')){
                if($edge.restart -isnot [bool]){throw 'M12 overlap dependency restart value is not boolean.'}
                if($edge.restart){$edges.Add([pscustomobject]@{dependency=[string]$dependencyName;service=[string]$serviceName;condition=[string]$edge.condition})}
            }
        }
    }
    return ,@($edges.ToArray())
}

function Assert-GeordiM12OverlapIsolationConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $NormalConfiguration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $IsolatedConfiguration)
    foreach($name in @('services','volumes','networks')){
        if(!$NormalConfiguration.Contains($name) -or !$IsolatedConfiguration.Contains($name)){
            throw "M12 overlap configuration omitted '$name'."
        }
    }
    $normalServices=$NormalConfiguration.services;$isolatedServices=$IsolatedConfiguration.services
    if((@($normalServices.Keys|Sort-Object -CaseSensitive)-join "`n") -cne (@($isolatedServices.Keys|Sort-Object -CaseSensitive)-join "`n")){
        throw 'M12 overlap isolation changed the service inventory.'
    }
    $edges=Get-GeordiM12OverlapIsolationEdges
    $normalized=Copy-GeordiM12OverlapConfiguration $NormalConfiguration
    foreach($edge in $edges){
        if(!$normalServices.Contains($edge.service) -or !$isolatedServices.Contains($edge.service) -or
                !$normalServices[$edge.service].Contains('depends_on') -or !$isolatedServices[$edge.service].Contains('depends_on') -or
                !$normalServices[$edge.service].depends_on.Contains($edge.dependency) -or
                !$isolatedServices[$edge.service].depends_on.Contains($edge.dependency)){
            throw "M12 overlap isolation omitted dependency '$($edge.service)->$($edge.dependency)'."
        }
        $normalEdge=$normalServices[$edge.service].depends_on[$edge.dependency]
        $isolatedEdge=$isolatedServices[$edge.service].depends_on[$edge.dependency]
        if($normalEdge -isnot [System.Collections.IDictionary] -or $isolatedEdge -isnot [System.Collections.IDictionary] -or
                !$normalEdge.Contains('restart') -or $normalEdge.restart -isnot [bool] -or !$normalEdge.restart -or
                ($isolatedEdge.Contains('restart') -and ($isolatedEdge.restart -isnot [bool] -or $isolatedEdge.restart))){
            throw "M12 overlap restart edge '$($edge.service)->$($edge.dependency)' is not isolated from true to false."
        }
        [void]$normalized.services[$edge.service].depends_on[$edge.dependency].Remove('restart')
    }
    if((ConvertTo-GeordiM12OverlapCanonicalJson $normalized) -cne
            (ConvertTo-GeordiM12OverlapCanonicalJson $IsolatedConfiguration)){
        throw 'M12 overlap isolation changed configuration beyond the seven approved restart properties.'
    }
    $remaining=Get-GeordiM12OverlapRestartDependents -Configuration $IsolatedConfiguration `
        -Dependencies @('otel-collector','victoriametrics','backend','m12-burn-demo','m12-query-gate')
    if($remaining.Count){throw 'M12 overlap isolation leaves reverse restart propagation from a mutation target.'}
    return ,@($edges)
}

function Get-GeordiM12OverlapCollectorReplacementArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot,[Parameter(Mandatory)][string[]] $AcceptedArguments)
    $expected=@(Get-GeordiM12CollectorReplacementArguments -RepositoryRoot $RepositoryRoot)
    if($AcceptedArguments.Count -ne $expected.Count){throw 'Accepted M12 Collector replacement arguments changed unexpectedly.'}
    for($index=0;$index -lt $expected.Count;$index++){
        if([string]$AcceptedArguments[$index] -cne [string]$expected[$index]){
            throw 'Accepted M12 Collector replacement argument scope changed unexpectedly.'
        }
    }
    $expectedTail=@('up','-d','--no-deps','--force-recreate','otel-collector')
    if(@($AcceptedArguments | Select-Object -Last $expectedTail.Count)-join "`n" -cne ($expectedTail -join "`n")){
        throw 'Accepted M12 Collector replacement is not service-scoped.'
    }
    $actual=[Collections.Generic.List[string]]::new()
    foreach($argument in (Get-GeordiM12OverlapComposeArguments -RepositoryRoot $RepositoryRoot -CollectorReplacementOverlay -IsolationOverlay)){
        $actual.Add([string]$argument)
    }
    foreach($argument in $expectedTail){$actual.Add($argument)}
    return $actual.ToArray()
}

function Invoke-GeordiM12OverlapCollectorReplacement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $CaptureRoot,[Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][scriptblock] $RenderComposeConfiguration,[Parameter(Mandatory)][scriptblock] $InvokeCompose,
        [Parameter(Mandatory)][scriptblock] $ResolveContainerIdentity,[Parameter(Mandatory)][scriptblock] $WaitForReadiness,
        [scriptblock] $StartFollower,[scriptblock] $TestProcessIdentity,[scriptblock] $StopProcess,
        [string] $DockerPath=(Get-Command docker.exe -ErrorAction Stop).Source,
        [string] $PowerShellPath=(Get-Process -Id $PID).Path,
        [string] $WorkerPath=(Join-Path $PSScriptRoot 'Start-GeordiLogFollowerWorker.ps1'))
    $root=[IO.Path]::GetFullPath($RepositoryRoot)
    $argumentsBuilder=${function:Get-GeordiM12OverlapCollectorReplacementArguments}
    $scopedInvoker={
        param([string[]] $AcceptedArguments,[string] $Phase)
        $actual=& $argumentsBuilder -RepositoryRoot $root -AcceptedArguments $AcceptedArguments
        & $InvokeCompose $actual $Phase
    }.GetNewClosure()
    $orderedFollower={
        param([string] $Stdout,[string] $Stderr,[string] $ProcessRecord,[string[]] $DockerArguments,$Target)
        if($StartFollower){$process=& $StartFollower $Stdout $Stderr $ProcessRecord $DockerArguments $Target}
        else{
            $process=Invoke-GeordiBoundedLogFollowerStart -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath `
                -DockerPath $DockerPath -DockerArguments $DockerArguments -WorkingDirectory $root `
                -StandardOutputPath $Stdout -StandardErrorPath $Stderr -ProcessRecordPath $ProcessRecord -TargetMetadata $Target
        }
        if(!$process -or [int]$process.id -le 0 -or [string]::IsNullOrWhiteSpace([string]$process.name) -or
                [string]::IsNullOrWhiteSpace([string]$process.startUtc)){
            throw 'M12 overlap Collector follower did not return a valid local startup identity.'
        }
        return $process
    }.GetNewClosure()
    $afterFollowerValidated={param($target,$process,$generationId) $null=& $WaitForReadiness $target $process $generationId}.GetNewClosure()
    return Invoke-GeordiM12CollectorControlledReplacement -CaptureRoot $CaptureRoot -RepositoryRoot $root `
        -RenderComposeConfiguration $RenderComposeConfiguration -InvokeCompose $scopedInvoker `
        -ResolveContainerIdentity $ResolveContainerIdentity -StartFollower $orderedFollower `
        -TestProcessIdentity $TestProcessIdentity -StopProcess $StopProcess -DockerPath $DockerPath `
        -PowerShellPath $PowerShellPath -WorkerPath $WorkerPath -AfterFollowerValidated $afterFollowerValidated
}

function Invoke-GeordiM12OverlapCollectorStartupSequence {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $FirstReplacement,[Parameter(Mandatory)][scriptblock] $ReplaceCollector,
        [Parameter(Mandatory)][scriptblock] $StartProviderServices,[Parameter(Mandatory)][scriptblock] $StartBackendAndTrafficFixture)
    $first=$FirstReplacement
    if(!$first -or [string]::IsNullOrWhiteSpace([string]$first.NewContainerId) -or [string]::IsNullOrWhiteSpace([string]$first.GenerationId)){
        throw 'M12 overlap reset Collector handoff did not return a generation identity.'
    }
    & $StartProviderServices
    $second=& $ReplaceCollector 'overlap-exercise'
    if(!$second -or [string]::IsNullOrWhiteSpace([string]$second.NewContainerId) -or [string]::IsNullOrWhiteSpace([string]$second.GenerationId) -or
            [string]$first.NewContainerId -ceq [string]$second.NewContainerId -or [string]$first.GenerationId -ceq [string]$second.GenerationId){
        throw 'M12 overlap Collector lifecycle did not produce two distinct sequential generations.'
    }
    & $StartBackendAndTrafficFixture
    return [pscustomobject]@{First=$first;Second=$second;FinalCollectorContainerId=[string]$second.NewContainerId;
        FinalCollectorGenerationId=[string]$second.GenerationId}
}
