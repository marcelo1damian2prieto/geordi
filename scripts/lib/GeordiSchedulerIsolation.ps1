function ConvertTo-GeordiDockerCreatedUtc {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object] $Value)

    if ($null -eq $Value) { throw 'Docker creation timestamp is missing or invalid.' }

    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) {
        switch ($Value.Kind) {
            ([DateTimeKind]::Utc) {
                return [DateTimeOffset]::new($Value, [TimeSpan]::Zero)
            }
            ([DateTimeKind]::Local) {
                return [DateTimeOffset]::new($Value.ToUniversalTime(), [TimeSpan]::Zero)
            }
            default { throw 'Docker creation timestamp has no explicit time zone.' }
        }
    }

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw 'Docker creation timestamp is missing or invalid.'
    }

    $match = [regex]::Match([string]$Value,
        '^(?<date>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(?<fraction>\d{1,9}))?(?<zone>Z|[+-]\d{2}:\d{2})$')
    if (!$match.Success) { throw 'Docker creation timestamp is malformed.' }

    $normalized = $match.Groups['date'].Value
    if ($match.Groups['fraction'].Success) {
        $fraction = $match.Groups['fraction'].Value
        if ($fraction.Length -gt 7) { $fraction = $fraction.Substring(0, 7) }
        else { $fraction = $fraction.PadRight(7, '0') }
        $normalized += '.' + $fraction
    }
    $normalized += $match.Groups['zone'].Value

    try {
        return [DateTimeOffset]::Parse($normalized, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None).ToUniversalTime()
    } catch {
        throw 'Docker creation timestamp is malformed.'
    }
}

function Get-GeordiM14DockerResourceInventory {
    $ids = @(& docker ps -aq --filter 'label=com.docker.compose.project=geordi')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Geordi Compose containers for M14 ownership.' }
    $containers = [Collections.Generic.List[object]]::new()
    foreach ($id in @($ids | Where-Object { ![string]::IsNullOrWhiteSpace([string]$_) })) {
        $inspection = & docker inspect ([string]$id) 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to verify a Geordi container identity for M14 ownership.' }
        $container = @($inspection | ConvertFrom-Json)[0]
        $labels = $container.Config.Labels
        $mountNames = @($container.Mounts | Where-Object { $_.Type -eq 'volume' } | ForEach-Object { [string]$_.Name })
        $stateProperty = $container.PSObject.Properties['State']
        $running = $null -ne $stateProperty -and [bool]$stateProperty.Value.Running
        $healthProperty = if ($null -ne $stateProperty -and $stateProperty.Value) { $stateProperty.Value.PSObject.Properties['Health'] } else { $null }
        $healthy = if ($null -ne $healthProperty -and $healthProperty.Value) { [string]$healthProperty.Value.Status -ceq 'healthy' } else { $running }
        $containers.Add([pscustomobject]@{
            Id = [string]$container.Id
            Project = [string]$labels.'com.docker.compose.project'
            Service = [string]$labels.'com.docker.compose.service'
            WorkingDirectory = [string]$labels.'com.docker.compose.project.working_dir'
            CreatedUtc = ConvertTo-GeordiDockerCreatedUtc -Value $container.Created
            Mounts = $mountNames
            Running = $running
            Healthy = $healthy
        })
    }

    $listedVolumes = @(& docker volume ls --format '{{.Name}}')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate Docker volumes for M14 ownership.' }
    $volumes = [Collections.Generic.List[object]]::new()
    foreach ($name in @('geordi_m14-alert-lifecycle-data','geordi_m14-victoriametrics-data')) {
        if ($name -notin $listedVolumes) { continue }
        $inspection = & docker volume inspect $name 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Unable to verify dedicated M14 volume '$name'." }
        $volume = @($inspection | ConvertFrom-Json)[0]
        $volumes.Add([pscustomobject]@{
            Name = [string]$volume.Name
            Project = [string]$volume.Labels.'com.docker.compose.project'
            LogicalName = [string]$volume.Labels.'com.docker.compose.volume'
            CreatedUtc = ConvertTo-GeordiDockerCreatedUtc -Value $volume.CreatedAt
        })
    }
    [pscustomobject]@{ Containers = @($containers); Volumes = @($volumes) }
}

function Get-GeordiProcessEnvironmentSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Names)

    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $Names) {
        $present = $environment.Contains($name)
        [pscustomobject]@{
            Name = $name
            Present = $present
            Value = if ($present) { [string]$environment[$name] } else { $null }
        }
    }
}

function Restore-GeordiProcessEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]] $Snapshot)

    foreach ($entry in $Snapshot) {
        $path = 'Env:{0}' -f $entry.Name
        if (!$entry.Present) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop }
            if (Test-Path -LiteralPath $path) { throw "Unable to restore absent process environment variable '$($entry.Name)'." }
            continue
        }

        Set-Item -LiteralPath $path -Value ([string]$entry.Value) -ErrorAction Stop
        if (!(Test-Path -LiteralPath $path)) { throw "Unable to restore process environment variable '$($entry.Name)'." }
        $restored = Get-Item -LiteralPath $path -ErrorAction Stop
        if ([string]$restored.Value -cne [string]$entry.Value) {
            throw "Process environment variable '$($entry.Name)' was not restored exactly."
        }
    }
}

function Invoke-GeordiWithProcessEnvironmentRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Names,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    $snapshot = Get-GeordiProcessEnvironmentSnapshot $Names
    try { & $Action } finally { Restore-GeordiProcessEnvironment $snapshot }
}

function New-GeordiM14FixtureOwnershipState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    [pscustomobject]@{
        RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        ResetStarted = $false
        ResetCompleted = $false
        ResetContainersAbsent = $false
        ResetVolumesAbsent = $false
        ResetFailureStage = $null
        ResetFailureMessage = $null
        StartupAttempted = $false
        StartupStartedUtc = $null
        BaselineContainerIds = @()
        BaselineStoppedContainers = @()
    }
}

function Invoke-GeordiM14FixtureLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ownership,
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][scriptblock] $Cleanup
    )

    $primaryError = $null
    try {
        & $Action
    } catch {
        $primaryError = $_
        throw
    } finally {
        if ($Ownership.ResetCompleted -and $Ownership.ResetVolumesAbsent -and $Ownership.StartupAttempted) {
            try { & $Cleanup $Ownership } catch {
                if ($null -eq $primaryError) { throw }
                Write-Warning 'M14 owned-fixture cleanup failed while preserving the original smoke failure.'
            }
        }
    }
}

function Get-GeordiM14OwnedResourcePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ownership,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ContainerInventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $VolumeInventory
    )

    if (!$Ownership.ResetCompleted -or !$Ownership.ResetVolumesAbsent -or !$Ownership.StartupAttempted -or
            $null -eq $Ownership.StartupStartedUtc) {
        throw 'M14 teardown ownership has not been established.'
    }

    $services = @('backend','victoriametrics','otel-collector','webhook-receiver-a','webhook-receiver-b')
    $protectedVolumes = @('geordi_m19-alert-lifecycle-data','geordi_m19-victoriametrics-data')
    $attemptStart = [DateTimeOffset]$Ownership.StartupStartedUtc
    $minimumCreatedUtc = [DateTimeOffset]::new(
        $attemptStart.UtcTicks - ($attemptStart.UtcTicks % [TimeSpan]::TicksPerSecond),
        [TimeSpan]::Zero)
    $ownedContainers = [Collections.Generic.List[object]]::new()
    foreach ($container in $ContainerInventory) {
        if ($container.Project -cne 'geordi' -or $container.Service -notin $services) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$container.Id) -or
                [IO.Path]::GetFullPath([string]$container.WorkingDirectory) -cne $Ownership.RepositoryRoot -or
                [DateTimeOffset]$container.CreatedUtc -lt $minimumCreatedUtc -or
                [string]$container.Id -cin @($Ownership.BaselineContainerIds)) {
            throw 'M14 teardown encountered a service container whose ownership cannot be proven.'
        }
        if (@($container.Mounts | Where-Object { $_ -in $protectedVolumes }).Count -gt 0) {
            throw 'M14 teardown refused a container mounting a protected M19 volume.'
        }
        $ownedContainers.Add($container)
    }

    $expectedVolumes = @{
        'geordi_m14-alert-lifecycle-data' = 'm14-alert-lifecycle-data'
        'geordi_m14-victoriametrics-data' = 'm14-victoriametrics-data'
    }
    $ownedVolumes = [Collections.Generic.List[object]]::new()
    foreach ($volume in $VolumeInventory) {
        if ($volume.Name -notin $expectedVolumes.Keys) { continue }
        if ($volume.Project -cne 'geordi' -or $volume.LogicalName -cne $expectedVolumes[$volume.Name] -or
                [DateTimeOffset]$volume.CreatedUtc -lt $minimumCreatedUtc) {
            throw "M14 teardown refused volume '$($volume.Name)' because current-attempt ownership was not proven."
        }
        if ($volume.Name -in $protectedVolumes) { throw 'M14 teardown refused a protected M19 volume.' }
        $ownedVolumes.Add($volume)
    }

    [pscustomobject]@{ Containers = @($ownedContainers); Volumes = @($ownedVolumes) }
}

function Assert-GeordiM14ResetVolumeOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $RenderedVolumes,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ExistingVolumes
    )

    $expected = @{
        'm14-alert-lifecycle-data' = 'geordi_m14-alert-lifecycle-data'
        'm14-victoriametrics-data' = 'geordi_m14-victoriametrics-data'
    }
    foreach ($logical in $expected.Keys) {
        $property = $RenderedVolumes.PSObject.Properties[$logical]
        if ($null -eq $property -or [string]$property.Value.name -cne $expected[$logical]) {
            throw "Refusing reset for unexpected rendered M14 volume '$logical'."
        }
    }
    foreach ($volume in $ExistingVolumes) {
        if ($volume.Project -cne 'geordi' -or $expected[$volume.LogicalName] -cne $volume.Name) {
            throw "Refusing reset for non-M14 volume '$($volume.Name)'."
        }
    }
    return $expected
}

function Invoke-GeordiM14FixtureReset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ownership,
        [Parameter(Mandatory)] $RenderedVolumes,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ExistingContainers,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ExistingVolumes,
        [Parameter(Mandatory)][scriptblock] $CaptureGeneration,
        [Parameter(Mandatory)][scriptblock] $RemoveContainerIds,
        [Parameter(Mandatory)][scriptblock] $RemoveVolume,
        [Parameter(Mandatory)][scriptblock] $GetInventory
    )

    $expected = Assert-GeordiM14ResetVolumeOwnership -RenderedVolumes $RenderedVolumes -ExistingVolumes $ExistingVolumes
    $resetServices = @('backend','victoriametrics','otel-collector','webhook-receiver-a','webhook-receiver-b')
    $priorContainers = @($ExistingContainers | Where-Object { $_.Project -ceq 'geordi' -and $_.Service -in $resetServices })
    foreach ($container in $priorContainers) {
        if ([IO.Path]::GetFullPath([string]$container.WorkingDirectory) -cne $Ownership.RepositoryRoot) {
            throw 'Refusing M14 reset for a Geordi service container owned by a different checkout.'
        }
    }

    $Ownership.ResetStarted = $true
    $Ownership.ResetFailureStage = 'capture-baseline'
    $Ownership.ResetFailureMessage = $null
    $Ownership.BaselineContainerIds = @(@($Ownership.BaselineContainerIds) + @($priorContainers | ForEach-Object { [string]$_.Id }) | Select-Object -Unique)

    try {
        & $CaptureGeneration $resetServices

        $Ownership.ResetFailureStage = 'remove-baseline-containers'
        if ($priorContainers.Count -gt 0) {
            $ids = @($priorContainers | ForEach-Object { [string]$_.Id })
            & $RemoveContainerIds $ids
        }
        $afterContainers = & $GetInventory
        if (@($afterContainers.Containers | Where-Object { $_.Project -ceq 'geordi' -and $_.Service -in $resetServices }).Count -gt 0) {
            throw 'M14 fixture reset did not remove all prior fixture service containers.'
        }
        $Ownership.ResetContainersAbsent = $true

        $Ownership.ResetFailureStage = 'remove-dedicated-volumes'
        foreach ($logical in $expected.Keys) {
            $name = $expected[$logical]
            if (@($ExistingVolumes | Where-Object { $_.Name -ceq $name }).Count -gt 0) { & $RemoveVolume $name }
        }
        $afterVolumes = & $GetInventory
        if (@($afterVolumes.Volumes | Where-Object { $_.Name -in @($expected.Values) }).Count -gt 0) {
            throw 'M14 fixture reset did not remove all prior M14 volumes.'
        }

        $Ownership.ResetCompleted = $true
        $Ownership.ResetVolumesAbsent = $true
        $Ownership.ResetFailureStage = $null
        $Ownership.ResetFailureMessage = $null
    } catch {
        $Ownership.ResetFailureMessage = [string]$_.Exception.Message
        $stage = [string]$Ownership.ResetFailureStage
        throw "M14 fixture reset failed at stage '$stage'. No fixture startup was attempted; rerun only after reviewing the exact failure. Detail: $($Ownership.ResetFailureMessage)"
    }
}

function Invoke-GeordiM14OwnedResourceCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ownership,
        [Parameter(Mandatory)][scriptblock] $GetInventory,
        [Parameter(Mandatory)][scriptblock] $CaptureGeneration,
        [Parameter(Mandatory)][scriptblock] $RemoveContainerIds,
        [Parameter(Mandatory)][scriptblock] $RemoveVolume
    )

    $inventory = & $GetInventory
    $plan = Get-GeordiM14OwnedResourcePlan -Ownership $Ownership -ContainerInventory $inventory.Containers -VolumeInventory $inventory.Volumes
    if ($plan.Containers.Count -gt 0) {
        $services = @($plan.Containers | Select-Object -ExpandProperty Service -Unique)
        & $CaptureGeneration $services
        $ids = @($plan.Containers | Select-Object -ExpandProperty Id)
        & $RemoveContainerIds $ids
    }
    foreach ($volume in $plan.Volumes) { & $RemoveVolume $volume.Name }
}

function Assert-GeordiM14SchedulingDisabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuration)

    $backendProperty = $Configuration.services.PSObject.Properties['backend']
    if ($null -eq $backendProperty -or $null -eq $backendProperty.Value) {
        throw 'M14 Compose configuration does not define the backend service.'
    }
    $environmentProperty = $backendProperty.Value.environment.PSObject.Properties['GEORDI_SCHEDULING_ALERT_ENABLED']
    if ($null -eq $environmentProperty -or [string]$environmentProperty.Value -cne 'false') {
        throw 'M14 rendered backend scheduling setting is not explicitly false.'
    }
}

function Assert-GeordiM14ProtectedVolumeIsolation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuration)

    $protectedSources = @(
        'm19-alert-lifecycle-data', 'm19-victoriametrics-data',
        'geordi_m19-alert-lifecycle-data', 'geordi_m19-victoriametrics-data'
    )
    $services = $Configuration.services
    $volumes = $Configuration.volumes
    if ($null -eq $services -or $null -eq $volumes) {
        throw 'M14 rendered Compose configuration is missing service or volume definitions.'
    }

    foreach ($serviceName in @('backend', 'victoriametrics', 'webhook-receiver-a', 'webhook-receiver-b')) {
        $serviceProperty = $services.PSObject.Properties[$serviceName]
        if ($null -eq $serviceProperty -or $null -eq $serviceProperty.Value) {
            throw "M14 rendered Compose configuration is missing service '$serviceName'."
        }
        $mountsProperty = $serviceProperty.Value.PSObject.Properties['volumes']
        $mounts = if ($null -eq $mountsProperty) { @() } else { @($mountsProperty.Value) }
        foreach ($mount in $mounts) {
            $source = [string]$mount.source
            if ($source -in $protectedSources) {
                throw "M14 fixture service '$serviceName' mounts a protected M19 volume."
            }
            if ([string]$mount.type -cne 'volume') { continue }

            $volumeProperty = $volumes.PSObject.Properties[$source]
            if ([string]::IsNullOrWhiteSpace($source) -or $null -eq $volumeProperty) {
                throw "M14 fixture service '$serviceName' has an unresolved named volume."
            }
            $resolvedName = [string]$volumeProperty.Value.name
            if ([string]::IsNullOrWhiteSpace($resolvedName)) {
                throw "M14 fixture service '$serviceName' has a volume without a resolved Docker identity."
            }
            if ($resolvedName -in $protectedSources) {
                throw "M14 fixture service '$serviceName' resolves to a protected M19 volume."
            }
        }
    }

    $expectedMounts = @(
        @{ Service = 'backend'; Source = 'm14-alert-lifecycle-data'; Name = 'geordi_m14-alert-lifecycle-data'; Target = '/var/lib/geordi/alerts' },
        @{ Service = 'victoriametrics'; Source = 'm14-victoriametrics-data'; Name = 'geordi_m14-victoriametrics-data'; Target = '/victoria-metrics-data' }
    )
    foreach ($expected in $expectedMounts) {
        $service = $services.PSObject.Properties[$expected.Service].Value
        $mounts = @($service.volumes | Where-Object {
            [string]$_.type -ceq 'volume' -and [string]$_.target -ceq $expected.Target
        })
        $readOnlyProperty = if ($mounts.Count -eq 1) { $mounts[0].PSObject.Properties['read_only'] } else { $null }
        $readOnly = $null -ne $readOnlyProperty -and [bool]$readOnlyProperty.Value
        if ($mounts.Count -ne 1 -or [string]$mounts[0].source -cne $expected.Source -or
                $readOnly -or
                [string]$volumes.PSObject.Properties[$expected.Source].Value.name -cne $expected.Name) {
            throw "M14 '$($expected.Service)' does not use its dedicated writable persistence volume."
        }
    }
}

function Get-GeordiM14MutationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuration)

    $services = $Configuration.services
    if ($null -eq $services) { throw 'M14 rendered Compose configuration has no service graph.' }

    $recreate = @('victoriametrics','otel-collector','backend')
    $create = @('webhook-receiver-a','webhook-receiver-b')
    $requiredExisting = @('burn-demo','frontend','oidc-fixture','loki','tempo','webhook-receiver','demo-downstream')
    $notRequired = @('demo','m12-burn-demo')
    foreach ($name in @($recreate + $create + $requiredExisting + $notRequired)) {
        $serviceProperty = $services.PSObject.Properties[$name]
        if ($null -eq $serviceProperty -or $null -eq $serviceProperty.Value) {
            throw "M14 rendered service graph is missing '$name'."
        }
    }

    $mutation = @($recreate + $create | Sort-Object -Unique)
    foreach ($serviceProperty in @($services.PSObject.Properties)) {
        $serviceName = [string]$serviceProperty.Name
        $service = $serviceProperty.Value
        $dependenciesProperty = $service.PSObject.Properties['depends_on']
        $dependencies = if ($null -eq $dependenciesProperty) { $null } else { $dependenciesProperty.Value }
        if ($null -eq $dependencies) { continue }
        foreach ($dependencyProperty in @($dependencies.PSObject.Properties)) {
            $dependencyName = [string]$dependencyProperty.Name
            $dependency = $dependencyProperty.Value
            if ($dependency -is [bool]) { continue }
            $restartProperty = $dependency.PSObject.Properties['restart']
            $restartEnabled = $null -ne $restartProperty -and [bool]$restartProperty.Value
            if ($restartEnabled -and $dependencyName -in $recreate -and $serviceName -notin $mutation) {
                throw "M14 recreation of '$dependencyName' can restart unrelated dependent '$serviceName'."
            }
        }
    }

    [pscustomobject]@{
        Recreate = $recreate
        Create = $create
        RequiredExisting = $requiredExisting
        NotRequired = $notRequired
        MutationSet = $mutation
        ExistingStartGroups = @(
            [pscustomobject]@{ Services=@('loki','tempo','webhook-receiver','oidc-fixture'); Phase='prerequisites' },
            [pscustomobject]@{ Services=@('demo-downstream','burn-demo','frontend'); Phase='post-backend' }
        )
        Commands = @(
            [pscustomobject]@{ Services=$create; ForceRecreate=$false; NoDeps=$true },
            [pscustomobject]@{ Services=@('victoriametrics'); ForceRecreate=$true; NoDeps=$true },
            [pscustomobject]@{ Services=@('otel-collector'); ForceRecreate=$true; NoDeps=$true },
            [pscustomobject]@{ Services=@('backend'); ForceRecreate=$true; NoDeps=$true }
        )
    }
}

function Assert-GeordiM14MutationPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ServiceInventory,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $required = @($Plan.RequiredExisting + $Plan.Recreate)
    $optional = @($Plan.Create + $Plan.NotRequired)

    foreach ($service in $required) {
        $matches = @($ServiceInventory | Where-Object { [string]$_.Project -ceq 'geordi' -and [string]$_.Service -ceq $service })
        if ($matches.Count -ne 1) {
            throw "M14 service '$service' must have exactly one existing container before reset; found $($matches.Count)."
        }
        if ([IO.Path]::GetFullPath([string]$matches[0].WorkingDirectory) -cne $root) {
            throw "M14 service '$service' belongs to a different checkout; refusing mutation."
        }
    }

    foreach ($service in $optional) {
        $matches = @($ServiceInventory | Where-Object { [string]$_.Project -ceq 'geordi' -and [string]$_.Service -ceq $service })
        if ($matches.Count -gt 1) {
            throw "M14 optional service '$service' has multiple containers; ownership is ambiguous."
        }
        foreach ($container in $matches) {
            if ([IO.Path]::GetFullPath([string]$container.WorkingDirectory) -cne $root) {
                throw "M14 optional service '$service' belongs to a different checkout; refusing mutation."
            }
        }
    }
}

function Get-GeordiM14RenderedComposeConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    [Environment]::SetEnvironmentVariable('GEORDI_SCHEDULING_ALERT_ENABLED', 'false', 'Process')
    $output = & docker compose --project-directory $RepositoryRoot config --format json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to render the M14 Compose configuration.' }
    $configuration = ($output -join "`n") | ConvertFrom-Json
    Assert-GeordiM14SchedulingDisabled $configuration
    Assert-GeordiM14ProtectedVolumeIsolation $configuration
    $null = Get-GeordiM14MutationPlan -Configuration $configuration
    return $configuration
}

function Get-GeordiRouteADiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(100,599)][int] $HttpStatus, [AllowNull()] $Response)

    function Get-ResponseFieldState($Object, [string] $Name) {
        if ($null -eq $Object) { return [pscustomobject]@{ Presence = 'null'; Value = $null } }
        if ($Object -is [System.Collections.IDictionary]) {
            if (!$Object.Contains($Name)) { return [pscustomobject]@{ Presence = 'missing'; Value = $null } }
            $value = $Object[$Name]
        } else {
            $property = $Object.PSObject.Properties[$Name]
            if ($null -eq $property) { return [pscustomobject]@{ Presence = 'missing'; Value = $null } }
            $value = $property.Value
        }
        if ($null -eq $value) { return [pscustomobject]@{ Presence = 'null'; Value = $null } }
        return [pscustomobject]@{ Presence = 'populated'; Value = $value }
    }

    function Get-NestedResponseFieldState($Object, [string] $ParentName, [string] $Name) {
        $parent = Get-ResponseFieldState $Object $ParentName
        if ($parent.Presence -ne 'populated') {
            return [pscustomobject]@{ Presence = $parent.Presence; Value = $null }
        }
        return Get-ResponseFieldState $parent.Value $Name
    }

    function Get-AllowlistedToken($Field, [string[]] $Allowed) {
        if ($Field.Presence -ne 'populated') { return $Field.Presence }
        $value = [string]$Field.Value
        if ($value -cin $Allowed) { return $value }
        return 'other'
    }

    $statusField = Get-NestedResponseFieldState $Response 'triggeringEvaluation' 'status'
    $reasonField = Get-NestedResponseFieldState $Response 'triggeringEvaluation' 'reason'
    $stateField = Get-NestedResponseFieldState $Response 'current' 'state'
    $transition = Get-ResponseFieldState $Response 'transition'
    $typeField = Get-NestedResponseFieldState $Response 'transition' 'type'

    $evaluationStatus = Get-AllowlistedToken $statusField @('CONDITION_MET','CONDITION_NOT_MET','UNAVAILABLE')
    $evaluationReason = Get-AllowlistedToken $reasonField @(
        'DISABLED','NO_TRAFFIC','MISSING_REQUEST_COUNT','MISSING_ERROR_COUNT','INVALID_TELEMETRY',
        'METRICS_UNAVAILABLE','ZERO_ALLOWED_BAD_RATIO','MULTIWINDOW_EVIDENCE_UNAVAILABLE')
    $currentState = Get-AllowlistedToken $stateField @('INACTIVE','FIRING')
    $transitionType = Get-AllowlistedToken $typeField @('ALERT_STARTED','ALERT_RESOLVED')
    $transitionPresence = $transition.Presence
    $isStarted = $HttpStatus -ge 200 -and $HttpStatus -lt 300 -and
        $transitionPresence -eq 'populated' -and $transitionType -ceq 'ALERT_STARTED'
    $line = 'M14 route_a_lifecycle http_status={0} evaluation_status={1} evaluation_reason={2} current_state={3} transition_presence={4} transition_type={5}' -f `
        $HttpStatus,$evaluationStatus,$evaluationReason,$currentState,$transitionPresence,$transitionType
    [pscustomobject]@{ IsStarted = $isStarted; Line = $line }
}
