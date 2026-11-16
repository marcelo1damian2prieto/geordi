[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'lib/GeordiSchedulerIsolation.ps1')

function Assert-ProtectedVolumeTest([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M14 protected-volume regression failed: $Message" }
}

function Copy-RenderedConfiguration($Configuration) {
    return ($Configuration | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Assert-ProtectedMountRejected($Configuration, [string] $Service, [string] $Source, [string] $Target, [bool] $ReadOnly) {
    $copy = Copy-RenderedConfiguration $Configuration
    $copy.services.$Service.volumes += [pscustomobject]@{
        type = 'volume'; source = $Source; target = $Target; read_only = $ReadOnly
    }
    $rejected = $false
    try { Assert-GeordiM14ProtectedVolumeIsolation $copy } catch { $rejected = $true }
    Assert-ProtectedVolumeTest $rejected "protected volume '$Source' was accepted on '$Service' (readOnly=$ReadOnly)"
}

$environmentNames = @('COMPOSE_FILE', 'GEORDI_SCHEDULING_ALERT_ENABLED', 'GEORDI_M13_WEBHOOK_TOKEN_A', 'GEORDI_M13_WEBHOOK_TOKEN_B')
$environmentSnapshot = @(Get-GeordiProcessEnvironmentSnapshot -Names $environmentNames)
try {
    $m14ComposeFiles = @((Join-Path $root 'compose.yaml'), (Join-Path $root 'compose.m19.yaml'),
        (Join-Path $root 'compose.m14.yaml')) -join [IO.Path]::PathSeparator
    Set-Item -LiteralPath 'Env:COMPOSE_FILE' -Value $m14ComposeFiles -ErrorAction Stop
    Set-Item -LiteralPath 'Env:GEORDI_SCHEDULING_ALERT_ENABLED' -Value 'false' -ErrorAction Stop
    Set-Item -LiteralPath 'Env:GEORDI_M13_WEBHOOK_TOKEN_A' -Value 'preflight-only-placeholder-a' -ErrorAction Stop
    Set-Item -LiteralPath 'Env:GEORDI_M13_WEBHOOK_TOKEN_B' -Value 'preflight-only-placeholder-b' -ErrorAction Stop
    $m14 = Get-GeordiM14RenderedComposeConfiguration -RepositoryRoot $root
    Assert-GeordiM14SchedulingDisabled $m14
    Assert-GeordiM14ProtectedVolumeIsolation $m14
    Assert-ProtectedVolumeTest (
        [string]$m14.services.backend.environment.SPRING_DATASOURCE_URL -ceq
            'jdbc:h2:file:/var/lib/geordi/alerts/lifecycle;DB_CLOSE_ON_EXIT=FALSE'
    ) 'M14 datasource did not remain on the dedicated lifecycle persistence path'
    Assert-ProtectedVolumeTest (
        [string]$m14.volumes.PSObject.Properties['m14-alert-lifecycle-data'].Value.name -ceq 'geordi_m14-alert-lifecycle-data' -and
        [string]$m14.volumes.PSObject.Properties['m14-victoriametrics-data'].Value.name -ceq 'geordi_m14-victoriametrics-data'
    ) 'rendered M14 dedicated volume identities changed'
    Write-Output 'm14_rendered_config=PASS scheduler=disabled lifecycle=dedicated victoria_metrics=dedicated protected_mounts=none'

    Assert-ProtectedMountRejected $m14 'backend' 'm19-alert-lifecycle-data' '/var/lib/geordi/alerts-m19' $false
    Write-Output 'm14_protected_lifecycle_mount=FAIL_CLOSED'
    Assert-ProtectedMountRejected $m14 'victoriametrics' 'm19-victoriametrics-data' '/victoria-metrics-data' $false
    Write-Output 'm14_protected_victoriametrics_mount=FAIL_CLOSED'
    Assert-ProtectedMountRejected $m14 'backend' 'm19-alert-lifecycle-data' '/var/lib/geordi/alerts-m19' $true
    Write-Output 'm14_readonly_protected_mount=FAIL_CLOSED'

    $inheritedMerge = Copy-RenderedConfiguration $m14
    $inheritedMerge.services.backend.volumes += [pscustomobject]@{
        type = 'volume'; source = 'm19-alert-lifecycle-data'; target = '/var/lib/geordi/alerts-m19'; read_only = $false
    }
    $inheritedRejected = $false
    try { Assert-GeordiM14ProtectedVolumeIsolation $inheritedMerge } catch { $inheritedRejected = $true }
    Assert-ProtectedVolumeTest $inheritedRejected 'a protected mount inherited through Compose merge was not rejected from the rendered model'
    Write-Output 'm14_inherited_protected_mount=FAIL_CLOSED'

    $resolvedAlias = Copy-RenderedConfiguration $m14
    $resolvedAlias.volumes | Add-Member -NotePropertyName 'm14-alias-for-protected-volume' `
        -NotePropertyValue ([pscustomobject]@{ name = 'geordi_m19-alert-lifecycle-data' })
    $resolvedAlias.services.backend.volumes += [pscustomobject]@{
        type = 'volume'; source = 'm14-alias-for-protected-volume'; target = '/synthetic/inherited'; read_only = $false
    }
    $resolvedAliasRejected = $false
    try { Assert-GeordiM14ProtectedVolumeIsolation $resolvedAlias } catch { $resolvedAliasRejected = $true }
    Assert-ProtectedVolumeTest $resolvedAliasRejected 'a logical source resolving indirectly to a protected Docker volume was accepted'
    Write-Output 'm14_resolved_protected_alias=FAIL_CLOSED'

    $requiredBackendTargets = @('/etc/geordi/slos.yaml', '/etc/geordi/alert-policies.yaml',
        '/etc/geordi/alert-routing.yaml', '/etc/geordi/alert-policies.m13.yaml',
        '/etc/geordi/alert-routing.m13.yaml', '/run/m19/client-secret',
        '/run/m19/truststore.p12', '/run/m19/truststore.password')
    $renderedBackendTargets = @($m14.services.backend.volumes | ForEach-Object { [string]$_.target })
    foreach ($target in $requiredBackendTargets) {
        Assert-ProtectedVolumeTest ($target -in $renderedBackendTargets) "M14 overlay dropped required non-protected backend mount '$target'"
    }
    Write-Output 'm14_required_mounts=PASS nonprotected_configuration_and_tls_preserved'

    $m14Source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-alert-history.ps1'))
    $renderIndex = $m14Source.IndexOf('Get-GeordiM14RenderedComposeConfiguration', [StringComparison]::Ordinal)
    $allocationIndex = $m14Source.IndexOf('New-GeordiDiagnosticSentinelSource', [StringComparison]::Ordinal)
    $resetIndex = $m14Source.IndexOf('Reset-M14Fixture $root', [StringComparison]::Ordinal)
    Assert-ProtectedVolumeTest ($renderIndex -ge 0 -and $renderIndex -lt $allocationIndex -and $renderIndex -lt $resetIndex) `
        'protected-volume rendering assertion does not precede evidence allocation and fixture reset'
    Write-Output 'm14_preflight_order=PASS before_diagnostic_evidence_and_fixture_reset'

    $ownership = [pscustomobject]@{
        ResetCompleted = $true; ResetVolumesAbsent = $true; StartupAttempted = $true
        StartupStartedUtc = [DateTimeOffset]::UtcNow; BaselineContainerIds = @()
        RepositoryRoot = $root
    }
    $protectedContainer = [pscustomobject]@{
        Id = 'synthetic-backend'; Project = 'geordi'; Service = 'backend'; WorkingDirectory = $root
        CreatedUtc = [DateTimeOffset]::UtcNow; Mounts = @('geordi_m19-alert-lifecycle-data')
    }
    $ownershipRejected = $false
    try { Get-GeordiM14OwnedResourcePlan -Ownership $ownership -ContainerInventory @($protectedContainer) -VolumeInventory @() | Out-Null }
    catch { $ownershipRejected = $true }
    Assert-ProtectedVolumeTest $ownershipRejected 'existing teardown ownership guard stopped rejecting protected volume mounts'
    Write-Output 'm14_ownership_guard=PASS protected_mount_rejected'

    $m19ComposeFiles = @((Join-Path $root 'compose.yaml'), (Join-Path $root 'compose.m19.yaml')) -join [IO.Path]::PathSeparator
    Set-Item -LiteralPath 'Env:COMPOSE_FILE' -Value $m19ComposeFiles -ErrorAction Stop
    Remove-Item -LiteralPath 'Env:GEORDI_M13_WEBHOOK_TOKEN_A' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'Env:GEORDI_M13_WEBHOOK_TOKEN_B' -ErrorAction SilentlyContinue
    $m19Output = & docker compose --project-directory $root config --format json
    if ($LASTEXITCODE -ne 0) { throw 'M19 normal runtime Compose configuration did not render.' }
    $m19 = ($m19Output -join "`n") | ConvertFrom-Json
    $m19BackendMount = @($m19.services.backend.volumes | Where-Object {
        [string]$_.type -ceq 'volume' -and [string]$_.target -ceq '/var/lib/geordi/alerts-m19'
    })
    $m19VmMount = @($m19.services.victoriametrics.volumes | Where-Object {
        [string]$_.type -ceq 'volume' -and [string]$_.target -ceq '/victoria-metrics-data'
    })
    Assert-ProtectedVolumeTest ($m19BackendMount.Count -eq 1 -and
        [string]$m19BackendMount[0].source -ceq 'm19-alert-lifecycle-data' -and
        [string]$m19.volumes.PSObject.Properties['m19-alert-lifecycle-data'].Value.name -ceq 'geordi_m19-alert-lifecycle-data' -and
        [string]$m19.services.backend.environment.SPRING_DATASOURCE_URL -like 'jdbc:h2:file:/var/lib/geordi/alerts-m19/*') `
        'normal M19 lifecycle persistence no longer uses its protected volume'
    Assert-ProtectedVolumeTest ($m19VmMount.Count -eq 1 -and
        [string]$m19VmMount[0].source -ceq 'm19-victoriametrics-data' -and
        [string]$m19.volumes.PSObject.Properties['m19-victoriametrics-data'].Value.name -ceq 'geordi_m19-victoriametrics-data') `
        'normal M19 VictoriaMetrics persistence no longer uses its protected volume'
    Write-Output 'm19_normal_runtime_config=PASS protected_persistence_preserved'
} finally {
    Restore-GeordiProcessEnvironment $environmentSnapshot
}

$schedulerFile = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib/GeordiSchedulerIsolation.ps1'))
$ownershipStart = $schedulerFile.IndexOf('function Get-GeordiM14OwnedResourcePlan', [StringComparison]::Ordinal)
$protectedGuard = $schedulerFile.IndexOf('$container.Mounts | Where-Object { $_ -in $protectedVolumes }', [StringComparison]::Ordinal)
Assert-ProtectedVolumeTest ($ownershipStart -ge 0 -and $protectedGuard -gt $ownershipStart) 'existing resource ownership protected-volume guard is missing'
Write-Output 'm14_protected_volume_regression=PASS'
