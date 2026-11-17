[CmdletBinding()]
param([switch] $SelfTest, [switch] $M12Only, [switch] $RouteAOnly,
    [switch] $NullParentOnly, [switch] $MissingParentOnly,
    [switch] $M14PreflightFailureOnly, [switch] $M14PartialAcquisitionOnly, [switch] $M14NormalCleanupOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiSchedulerIsolation.ps1')

function Assert-SchedulerIsolation([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "Scheduler isolation self-test failed: $Message" }
}

function Assert-ProcessEnvironmentState([string] $Name, [bool] $Present, [AllowNull()][string] $Value) {
    $path = 'Env:{0}' -f $Name
    $actualPresent = Test-Path -LiteralPath $path
    Assert-SchedulerIsolation ($actualPresent -eq $Present) "environment presence for '$Name' was not restored"
    if ($Present) {
        $actualValue = [string](Get-Item -LiteralPath $path -ErrorAction Stop).Value
        Assert-SchedulerIsolation ($actualValue -ceq $Value) "environment value for '$Name' was not restored"
    }
}

function Assert-EnvironmentSnapshotThroughProvider([object[]] $Snapshot) {
    foreach ($entry in $Snapshot) {
        $path = 'Env:{0}' -f $entry.Name
        $present = Test-Path -LiteralPath $path
        Assert-SchedulerIsolation ($present -eq $entry.Present) "provider presence for '$($entry.Name)' differs after rendering"
        if ($entry.Present) {
            $value = [string](Get-Item -LiteralPath $path -ErrorAction Stop).Value
            Assert-SchedulerIsolation ($value -ceq [string]$entry.Value) "provider value for '$($entry.Name)' differs after rendering"
        }
    }
}

function Assert-RouteANegativeTransition {
    param([string] $Name, [string] $Presence, [string] $Type, [Parameter(Mandatory)] $Response)
    $diagnostic = Get-GeordiRouteADiagnostic -HttpStatus 200 -Response $Response
    Assert-SchedulerIsolation (!$diagnostic.IsStarted) "Route-A '$Name' transition was accepted"
    Assert-SchedulerIsolation ($diagnostic.Line -match "transition_presence=$Presence transition_type=$Type") `
        "Route-A '$Name' transition fields were not reported accurately"
}

function New-RouteAParentFixture {
    param([switch] $NullParents)

    $source = [ordered]@{ transition = $null }
    if ($NullParents) {
        $source.triggeringEvaluation = $null
        $source.current = $null
    }
    $expectedParentPresence = [bool]$NullParents
    foreach ($name in @('triggeringEvaluation','current')) {
        Assert-SchedulerIsolation ($source.Contains($name) -eq $expectedParentPresence) `
            "Route-A source fixture parent presence for '$name' is incorrect"
        if ($expectedParentPresence) {
            Assert-SchedulerIsolation ($null -eq $source[$name]) "Route-A source fixture parent '$name' is not null"
        }
    }

    $json = ConvertTo-Json -InputObject $source -Compress
    $roundTrip = ConvertFrom-Json -InputObject $json -AsHashtable
    foreach ($name in @('triggeringEvaluation','current')) {
        Assert-SchedulerIsolation ($roundTrip.Contains($name) -eq $expectedParentPresence) `
            "Route-A round-trip parent presence for '$name' is incorrect"
        if ($expectedParentPresence) {
            Assert-SchedulerIsolation ($null -eq $roundTrip[$name]) "Route-A round-trip parent '$name' is not null"
        }
    }
    return $roundTrip
}

function Test-RouteAParentDiagnostic {
    param([switch] $NullParents)

    $response = New-RouteAParentFixture -NullParents:$NullParents
    $diagnostic = Get-GeordiRouteADiagnostic -HttpStatus 202 -Response $response
    Assert-SchedulerIsolation (!$diagnostic.IsStarted) 'Route-A without a started transition was accepted'
    if ($NullParents) {
        Assert-SchedulerIsolation ($diagnostic.Line -match 'evaluation_status=null evaluation_reason=null current_state=null transition_presence=null transition_type=null') `
            'Route-A explicitly null parent fields were not represented accurately'
    } else {
        Assert-SchedulerIsolation ($diagnostic.Line -match 'evaluation_status=missing evaluation_reason=missing current_state=missing transition_presence=null transition_type=null') `
            'Route-A absent parent fields were not represented accurately'
    }
}

function New-M14OwnedResourceFixture {
    param([Parameter(Mandatory)] $Ownership)

    $start = [DateTimeOffset]$Ownership.StartupStartedUtc
    [pscustomobject]@{
        Containers = @(
            [pscustomobject]@{ Id='owned-backend-id'; Project='geordi'; Service='backend'; WorkingDirectory=$Ownership.RepositoryRoot; CreatedUtc=$start.AddSeconds(1); Mounts=@() },
            [pscustomobject]@{ Id='preserved-oidc-id'; Project='geordi'; Service='oidc-fixture'; WorkingDirectory=$Ownership.RepositoryRoot; CreatedUtc=$start.AddSeconds(1); Mounts=@() }
        )
        Volumes = @(
            [pscustomobject]@{ Name='geordi_m14-alert-lifecycle-data'; Project='geordi'; LogicalName='m14-alert-lifecycle-data'; CreatedUtc=$start.AddSeconds(1) },
            [pscustomobject]@{ Name='geordi_m19-alert-lifecycle-data'; Project='geordi'; LogicalName='m19-alert-lifecycle-data'; CreatedUtc=$start.AddSeconds(1) }
        )
    }
}

function Test-M14PreflightFailureRegression {
    $names = @('GEORDI_TEST_M14_ABSENT','GEORDI_TEST_M14_EMPTY','GEORDI_TEST_M14_VALUE')
    Remove-Item -LiteralPath ('Env:{0}' -f $names[0]) -ErrorAction SilentlyContinue
    Set-Item -LiteralPath ('Env:{0}' -f $names[1]) -Value '' -ErrorAction Stop
    Set-Item -LiteralPath ('Env:{0}' -f $names[2]) -Value 'caller-original' -ErrorAction Stop
    $before = Get-GeordiProcessEnvironmentSnapshot $names
    $ownership = New-GeordiM14FixtureOwnershipState -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
    $effects = [pscustomobject]@{ ComposeUp=0; Capture=0; ComposeRm=0; VolumeRm=0 }
    $caught = [pscustomobject]@{ Message=$null }
    Invoke-GeordiWithProcessEnvironmentRestore -Names $names -Action {
        try {
            Invoke-GeordiM14FixtureLifecycle -Ownership $ownership -Action {
                Set-Item -LiteralPath 'Env:GEORDI_TEST_M14_ABSENT' -Value 'changed' -ErrorAction Stop
                Set-Item -LiteralPath 'Env:GEORDI_TEST_M14_EMPTY' -Value 'changed' -ErrorAction Stop
                Set-Item -LiteralPath 'Env:GEORDI_TEST_M14_VALUE' -Value 'changed' -ErrorAction Stop
                throw 'synthetic M14 Compose preflight failure'
                $effects.ComposeUp++
            } -Cleanup {
                $effects.Capture++; $effects.ComposeRm++; $effects.VolumeRm++
            }
        } catch { $caught.Message = $_.Exception.Message }
    }
    Assert-SchedulerIsolation ($caught.Message -ceq 'synthetic M14 Compose preflight failure') 'preflight failure was not preserved'
    Assert-SchedulerIsolation ($effects.ComposeUp -eq 0) 'Compose up ran after a failed preflight'
    Assert-SchedulerIsolation (($effects.Capture + $effects.ComposeRm + $effects.VolumeRm) -eq 0) 'preflight failure invoked fixture teardown'
    Assert-EnvironmentSnapshotThroughProvider $before
}

function Test-M14PartialAcquisitionRegression {
    $ownership = New-GeordiM14FixtureOwnershipState -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
    $renderedVolumes = [pscustomobject]@{
        'm14-alert-lifecycle-data' = [pscustomobject]@{ name='geordi_m14-alert-lifecycle-data' }
        'm14-victoriametrics-data' = [pscustomobject]@{ name='geordi_m14-victoriametrics-data' }
    }
    $priorContainers = @([pscustomobject]@{
        Id='prior-backend-id'; Project='geordi'; Service='backend'; WorkingDirectory=$ownership.RepositoryRoot
    })
    $priorVolumes = @([pscustomobject]@{ Name='geordi_m14-alert-lifecycle-data'; Project='geordi'; LogicalName='m14-alert-lifecycle-data' })
    $resetEvents = [Collections.Generic.List[string]]::new()
    $resetFailure = $null
    try {
        Invoke-GeordiM14FixtureLifecycle -Ownership $ownership -Action {
            Invoke-GeordiM14FixtureReset -Ownership $ownership -RenderedVolumes $renderedVolumes `
                -ExistingContainers $priorContainers -ExistingVolumes $priorVolumes `
                -CaptureGeneration { param($services) $resetEvents.Add('capture') } `
                -RemoveContainerIds { param($ids) $resetEvents.Add('remove-container:' + ($ids -join ',')); throw 'synthetic M14 partial reset failure' } `
                -RemoveVolume { param($name) $resetEvents.Add('remove-volume:' + $name) } `
                -GetInventory { [pscustomobject]@{ Containers=@(); Volumes=@($priorVolumes) } }
        } -Cleanup { $resetEvents.Add('teardown') }
    } catch { $resetFailure = $_ }
    Assert-SchedulerIsolation ($resetFailure.Exception.Message -match "failed at stage 'remove-baseline-containers'.*synthetic M14 partial reset failure") 'partial reset failure stage/detail was not reported'
    Assert-SchedulerIsolation ($ownership.ResetStarted -and $ownership.ResetFailureStage -ceq 'remove-baseline-containers' -and
        $ownership.ResetFailureMessage -ceq 'synthetic M14 partial reset failure') 'partial reset state was not retained for safe recovery'
    Assert-SchedulerIsolation (!$ownership.ResetCompleted -and !$ownership.ResetVolumesAbsent -and !$ownership.ResetContainersAbsent) 'partial reset marked fixture ownership complete'
    Assert-SchedulerIsolation (($resetEvents -join '|') -ceq 'capture|remove-container:prior-backend-id') 'partial reset invoked an ineligible removal or teardown operation'

    $validVolumeMap = Assert-GeordiM14ResetVolumeOwnership -RenderedVolumes $renderedVolumes -ExistingVolumes $priorVolumes
    Assert-SchedulerIsolation ($validVolumeMap['m14-alert-lifecycle-data'] -ceq 'geordi_m14-alert-lifecycle-data') 'valid logical/physical M14 volume mapping was rejected'
    $wrongVolumeRejected = $false
    try { Assert-GeordiM14ResetVolumeOwnership -RenderedVolumes $renderedVolumes -ExistingVolumes @([pscustomobject]@{ Name='foreign-volume'; Project='geordi'; LogicalName='m14-alert-lifecycle-data' }) } catch { $wrongVolumeRejected = $true }
    Assert-SchedulerIsolation $wrongVolumeRejected 'reset accepted a volume with a non-M14 physical identity'

    $successfulResetOwnership = New-GeordiM14FixtureOwnershipState -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
    $successfulResetEvents = [Collections.Generic.List[string]]::new()
    $inventoryRead = [pscustomobject]@{ Count=0 }
    Invoke-GeordiM14FixtureReset -Ownership $successfulResetOwnership -RenderedVolumes $renderedVolumes `
        -ExistingContainers $priorContainers -ExistingVolumes $priorVolumes `
        -CaptureGeneration { param($services) $successfulResetEvents.Add('capture') } `
        -RemoveContainerIds { param($ids) $successfulResetEvents.Add('remove-container:' + ($ids -join ',')) } `
        -RemoveVolume { param($name) $successfulResetEvents.Add('remove-volume:' + $name) } `
        -GetInventory {
            $inventoryRead.Count++
            if ($inventoryRead.Count -eq 1) { return [pscustomobject]@{ Containers=@(); Volumes=$priorVolumes } }
            return [pscustomobject]@{ Containers=@(); Volumes=@() }
        }
    Assert-SchedulerIsolation ($successfulResetOwnership.ResetCompleted -and $successfulResetOwnership.ResetVolumesAbsent) 'successful reset did not establish the fixture ownership boundary'
    Assert-SchedulerIsolation (($successfulResetEvents -join '|') -ceq 'capture|remove-container:prior-backend-id|remove-volume:geordi_m14-alert-lifecycle-data') 'successful reset changed the existing dedicated-fixture cleanup order'

    $reportedFailure = $null
    try {
        try { throw [InvalidOperationException]::new('synthetic M14 primary failure') }
        catch {
            Write-Error 'sanitized test diagnostic' -ErrorAction Continue
            throw
        }
    } catch { $reportedFailure = $_ }
    Assert-SchedulerIsolation ($reportedFailure.Exception -is [InvalidOperationException] -and $reportedFailure.Exception.Message -ceq 'synthetic M14 primary failure') `
        'smoke failure reporting replaced the original exception'

    $cleanupResult = [Collections.Generic.List[string]]::new()
    $ownership = New-GeordiM14FixtureOwnershipState -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
    $ownership.ResetCompleted = $true
    $ownership.ResetVolumesAbsent = $true
    $ownership.StartupAttempted = $true
    $ownership.StartupStartedUtc = [DateTimeOffset]::UtcNow
    $inventory = New-M14OwnedResourceFixture $ownership
    $startupFailure = $null
    try {
        Invoke-GeordiM14FixtureLifecycle -Ownership $ownership -Action {
            throw 'synthetic M14 partial Compose startup failure'
        } -Cleanup {
            param($state)
            Invoke-GeordiM14OwnedResourceCleanup -Ownership $state -GetInventory { $inventory } `
                -CaptureGeneration { param($services) $cleanupResult.Add('capture:' + ($services -join ',')) } `
                -RemoveContainerIds { param($ids) $cleanupResult.Add('remove-container:' + ($ids -join ',')) } `
                -RemoveVolume { param($name) $cleanupResult.Add('remove-volume:' + $name) }
        }
    } catch { $startupFailure = $_ }
    Assert-SchedulerIsolation ($startupFailure.Exception.Message -ceq 'synthetic M14 partial Compose startup failure') 'partial startup failure was not preserved'
    Assert-SchedulerIsolation (($cleanupResult -join '|') -ceq 'capture:backend|remove-container:owned-backend-id|remove-volume:geordi_m14-alert-lifecycle-data') 'partial startup cleanup did not use only current-attempt resource identities or ordered capture before removal'

    $cleanupFailureEvents = [Collections.Generic.List[string]]::new()
    $cleanupFailure = $null
    try {
        Invoke-GeordiM14FixtureLifecycle -Ownership $ownership -Action { throw 'synthetic primary startup failure' } -Cleanup {
            param($state)
            Invoke-GeordiM14OwnedResourceCleanup -Ownership $state -GetInventory { $inventory } `
                -CaptureGeneration { param($services) $cleanupFailureEvents.Add('capture'); throw 'synthetic cleanup capture failure' } `
                -RemoveContainerIds { param($ids) $cleanupFailureEvents.Add('remove-container') } `
                -RemoveVolume { param($name) $cleanupFailureEvents.Add('remove-volume') }
        }
    } catch { $cleanupFailure = $_ }
    Assert-SchedulerIsolation ($cleanupFailure.Exception.Message -ceq 'synthetic primary startup failure') 'cleanup failure hid the original startup error'
    Assert-SchedulerIsolation (($cleanupFailureEvents -join '|') -ceq 'capture') 'cleanup continued destructive operations after evidence capture failed'

    $emptyPlan = Get-GeordiM14OwnedResourcePlan -Ownership $ownership -ContainerInventory @() -VolumeInventory @()
    Assert-SchedulerIsolation ($emptyPlan.Containers.Count -eq 0 -and $emptyPlan.Volumes.Count -eq 0) 'empty partial-start inventory was not accepted as an empty cleanup plan'
    $secondPrecision = [DateTimeOffset]::new($ownership.StartupStartedUtc.UtcDateTime.Year,$ownership.StartupStartedUtc.UtcDateTime.Month,
        $ownership.StartupStartedUtc.UtcDateTime.Day,$ownership.StartupStartedUtc.UtcDateTime.Hour,$ownership.StartupStartedUtc.UtcDateTime.Minute,
        $ownership.StartupStartedUtc.UtcDateTime.Second,[TimeSpan]::Zero)
    $volumeOnlyEvents = [Collections.Generic.List[string]]::new()
    Invoke-GeordiM14OwnedResourceCleanup -Ownership $ownership `
        -GetInventory { [pscustomobject]@{ Containers=@(); Volumes=@([pscustomobject]@{ Name='geordi_m14-victoriametrics-data'; Project='geordi'; LogicalName='m14-victoriametrics-data'; CreatedUtc=$secondPrecision }) } } `
        -CaptureGeneration { param($services) throw 'volume-only acquisition must not request a container capture' } `
        -RemoveContainerIds { param($ids) throw 'volume-only acquisition has no containers to remove' } `
        -RemoveVolume { param($name) $volumeOnlyEvents.Add($name) }
    Assert-SchedulerIsolation (($volumeOnlyEvents -join '|') -ceq 'geordi_m14-victoriametrics-data') 'volume-only partial startup was not eligible for teardown'
    $containerOnlyEvents = [Collections.Generic.List[string]]::new()
    Invoke-GeordiM14OwnedResourceCleanup -Ownership $ownership `
        -GetInventory { [pscustomobject]@{ Containers=@([pscustomobject]@{ Id='owned-backend-id'; Project='geordi'; Service='backend'; WorkingDirectory=$ownership.RepositoryRoot; CreatedUtc=$secondPrecision; Mounts=@() }); Volumes=@() } } `
        -CaptureGeneration { param($services) $containerOnlyEvents.Add('capture:' + ($services -join ',')) } `
        -RemoveContainerIds { param($ids) $containerOnlyEvents.Add('remove:' + ($ids -join ',')) } `
        -RemoveVolume { param($name) throw 'container-only acquisition has no volumes to remove' }
    Assert-SchedulerIsolation (($containerOnlyEvents -join '|') -ceq 'capture:backend|remove:owned-backend-id') 'container-only partial startup was not eligible for teardown'
}

function Test-M14NormalCleanupRegression {
    $ownership = New-GeordiM14FixtureOwnershipState -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
    $ownership.ResetCompleted = $true
    $ownership.ResetVolumesAbsent = $true
    $ownership.StartupAttempted = $true
    $ownership.StartupStartedUtc = [DateTimeOffset]::UtcNow
    $inventory = New-M14OwnedResourceFixture $ownership
    $cleanupResult = [Collections.Generic.List[string]]::new()
    Invoke-GeordiM14FixtureLifecycle -Ownership $ownership -Action {} -Cleanup {
        param($state)
        Invoke-GeordiM14OwnedResourceCleanup -Ownership $state -GetInventory { $inventory } `
            -CaptureGeneration { param($services) $cleanupResult.Add('capture:' + ($services -join ',')) } `
            -RemoveContainerIds { param($ids) $cleanupResult.Add('remove-container:' + ($ids -join ',')) } `
            -RemoveVolume { param($name) $cleanupResult.Add('remove-volume:' + $name) }
    }
    Assert-SchedulerIsolation (($cleanupResult -join '|') -ceq 'capture:backend|remove-container:owned-backend-id|remove-volume:geordi_m14-alert-lifecycle-data') 'normal teardown did not preserve its existing sequence or exact ownership boundary'
}

if (!$SelfTest) { throw 'Use -SelfTest to run scheduler isolation regressions.' }

$temporaryNames = @('GEORDI_TEST_ENV_UNSET', 'GEORDI_TEST_ENV_EMPTY', 'GEORDI_TEST_ENV_VALUE')
$temporaryOriginal = Get-GeordiProcessEnvironmentSnapshot $temporaryNames
$composeNames = @('COMPOSE_FILE', 'GEORDI_SCHEDULING_ALERT_ENABLED',
    'GEORDI_M13_WEBHOOK_TOKEN_A', 'GEORDI_M13_WEBHOOK_TOKEN_B')
$composeOriginal = Get-GeordiProcessEnvironmentSnapshot $composeNames
$root = Split-Path -Parent $PSScriptRoot

try {
    if ($M14PreflightFailureOnly) {
        Test-M14PreflightFailureRegression
        Write-Host 'PASS: M14 preflight failure preserves environment and invokes no fixture teardown.'
        return
    }
    if ($M14PartialAcquisitionOnly) {
        $script:TestM14ResetCalls = 0; $script:TestM14ResetCleanupCalls = 0; $script:TestM14ResetUpCalls = 0
        Test-M14PartialAcquisitionRegression
        Write-Host 'PASS: M14 partial reset/startup ownership and teardown regression.'
        return
    }
    if ($M14NormalCleanupOnly) {
        Test-M14NormalCleanupRegression
        Write-Host 'PASS: M14 normal fixture cleanup ownership regression.'
        return
    }
    if ($NullParentOnly) {
        Test-RouteAParentDiagnostic -NullParents
        Write-Host 'PASS: Route-A explicit null-parent regression.'
        return
    }
    if ($MissingParentOnly) {
        Test-RouteAParentDiagnostic
        Write-Host 'PASS: Route-A missing-parent regression.'
        return
    }
    if ($RouteAOnly) {
        $resolvedResponse = [pscustomobject]@{
            triggeringEvaluation = [pscustomobject]@{ status = 'CONDITION_MET'; reason = $null }
            current = [pscustomobject]@{ state = 'INACTIVE' }
            transition = [pscustomobject]@{ type = 'ALERT_RESOLVED' }
        }
        Assert-RouteANegativeTransition -Name 'different' -Presence 'populated' -Type 'ALERT_RESOLVED' -Response $resolvedResponse
        Write-Host 'PASS: Route-A ALERT_RESOLVED negative regression.'
        return
    }

    Remove-Item -LiteralPath ('Env:{0}' -f $temporaryNames[0]) -ErrorAction SilentlyContinue
    Set-Item -LiteralPath ('Env:{0}' -f $temporaryNames[1]) -Value '' -ErrorAction Stop
    Set-Item -LiteralPath ('Env:{0}' -f $temporaryNames[2]) -Value 'caller-value' -ErrorAction Stop
    Assert-ProcessEnvironmentState $temporaryNames[0] $false $null
    Assert-ProcessEnvironmentState $temporaryNames[1] $true ''
    Assert-ProcessEnvironmentState $temporaryNames[2] $true 'caller-value'

    foreach ($shouldFail in @($false, $true)) {
        $failed = $false
        try {
            Invoke-GeordiWithProcessEnvironmentRestore -Names $temporaryNames -Action {
                foreach ($name in $temporaryNames) {
                    Set-Item -LiteralPath ('Env:{0}' -f $name) -Value 'smoke-value' -ErrorAction Stop
                }
                if ($shouldFail) { throw 'self-test failure sentinel' }
            }
        } catch {
            if (!$shouldFail) { throw }
            $failed = $true
        }
        Assert-SchedulerIsolation ($failed -eq $shouldFail) 'expected pass/fail action result was not preserved'
        Assert-ProcessEnvironmentState $temporaryNames[0] $false $null
        Assert-ProcessEnvironmentState $temporaryNames[1] $true ''
        Assert-ProcessEnvironmentState $temporaryNames[2] $true 'caller-value'
    }
    if ($M12Only) {
        Write-Host 'PASS: combined M12 process-environment restoration regression.'
        return
    }

    $m12ComposeFiles = @((Join-Path $root 'compose.yaml'), (Join-Path $root 'compose.m19.yaml'),
        (Join-Path $root 'compose.m12.yaml'), (Join-Path $root 'compose.m12-overlap.yaml')) -join [IO.Path]::PathSeparator
    Set-Item -LiteralPath 'Env:COMPOSE_FILE' -Value $m12ComposeFiles -ErrorAction Stop
    Set-Item -LiteralPath 'Env:GEORDI_SCHEDULING_ALERT_ENABLED' -Value 'true' -ErrorAction Stop
    $m12Output = & docker compose --project-directory $root config --format json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'M12 Compose configuration self-test could not render.' }
    $m12Configuration = ($m12Output -join "`n") | ConvertFrom-Json
    Assert-SchedulerIsolation ([string]$m12Configuration.services.backend.environment.GEORDI_SCHEDULING_ALERT_ENABLED -ceq 'true') `
        'normal M12 scheduler enablement no longer renders true'

    $m12Source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-alert-scheduling-overlap.ps1'))
    foreach ($required in @(
            "'COMPOSE_FILE', 'GEORDI_SCHEDULING_ALERT_ENABLED', 'GEORDI_SCHEDULING_ALERT_INTERVAL'",
            '$env:GEORDI_SCHEDULING_ALERT_ENABLED = ''true''',
            "__control/arm", "__control/status", "__control/release",
            'OPERATOR request expected 403', 'EVALUATOR request expected 409',
            'one transition, matched disposition, and one delivery')) {
        Assert-SchedulerIsolation ($m12Source.Contains($required)) "M12 barrier/overlap contract marker '$required' changed or is missing"
    }
    Assert-SchedulerIsolation ($m12Source -notmatch '(?m)^\s*exit\s+') 'M12 must not bypass process environment restoration with exit'

    if (!$M12Only) {
    $m14ComposeFiles = @((Join-Path $root 'compose.yaml'), (Join-Path $root 'compose.m19.yaml'),
        (Join-Path $root 'compose.m14.yaml')) -join [IO.Path]::PathSeparator
    Set-Item -LiteralPath 'Env:GEORDI_M13_WEBHOOK_TOKEN_A' -Value 'self-test-only-a' -ErrorAction Stop
    Set-Item -LiteralPath 'Env:GEORDI_M13_WEBHOOK_TOKEN_B' -Value 'self-test-only-b' -ErrorAction Stop
    Set-Item -LiteralPath 'Env:COMPOSE_FILE' -Value $m14ComposeFiles -ErrorAction Stop
    foreach ($inherited in @('true', 'false', $null)) {
        if ($null -eq $inherited) {
            Remove-Item -LiteralPath 'Env:GEORDI_SCHEDULING_ALERT_ENABLED' -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath 'Env:GEORDI_SCHEDULING_ALERT_ENABLED' -Value $inherited -ErrorAction Stop
        }
        $beforeRender = Get-GeordiProcessEnvironmentSnapshot @('COMPOSE_FILE','GEORDI_SCHEDULING_ALERT_ENABLED')
        $configuration = Invoke-GeordiWithProcessEnvironmentRestore -Names @('COMPOSE_FILE','GEORDI_SCHEDULING_ALERT_ENABLED') -Action {
            Get-GeordiM14RenderedComposeConfiguration -RepositoryRoot $root
        }
        Assert-EnvironmentSnapshotThroughProvider $beforeRender
        Assert-GeordiM14SchedulingDisabled $configuration
        $renderedSetting = [string]$configuration.services.backend.environment.GEORDI_SCHEDULING_ALERT_ENABLED
        Assert-SchedulerIsolation ($renderedSetting -ceq 'false') "M14 rendered scheduler value for inherited '$inherited' was not false"
    }

    Set-Item -LiteralPath 'Env:GEORDI_SCHEDULING_ALERT_ENABLED' -Value 'true' -ErrorAction Stop
    $missingComposeFile = Join-Path ([IO.Path]::GetTempPath()) ('geordi-missing-compose-' + [guid]::NewGuid().ToString('N') + '.yaml')
    Set-Item -LiteralPath 'Env:COMPOSE_FILE' -Value $missingComposeFile -ErrorAction Stop
    $beforeFailedRender = Get-GeordiProcessEnvironmentSnapshot @('COMPOSE_FILE','GEORDI_SCHEDULING_ALERT_ENABLED')
    $composeFailureObserved = $false
    try {
        Invoke-GeordiWithProcessEnvironmentRestore -Names @('COMPOSE_FILE','GEORDI_SCHEDULING_ALERT_ENABLED') -Action {
            Get-GeordiM14RenderedComposeConfiguration -RepositoryRoot $root
        }
    } catch { $composeFailureObserved = $true }
    Assert-SchedulerIsolation $composeFailureObserved 'invalid Compose input unexpectedly rendered successfully'
    Assert-EnvironmentSnapshotThroughProvider $beforeFailedRender

    $rejectEnabled = $false
    try {
        Assert-GeordiM14SchedulingDisabled ([pscustomobject]@{ services = [pscustomobject]@{
            backend = [pscustomobject]@{ environment = [pscustomobject]@{ GEORDI_SCHEDULING_ALERT_ENABLED = 'true' } }
        } })
    } catch { $rejectEnabled = $true }
    Assert-SchedulerIsolation $rejectEnabled 'rendered scheduling=true was not rejected'

    $m14Source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-alert-history.ps1'))
    Assert-SchedulerIsolation ($m14Source.Contains("if (\$SkipM19Capture) {") -and
        $m14Source.Contains('$script:GeordiPrivateTokenSentinelOverride = { param($Token) }')) `
        'capture-free M14 mode does not disable the authentication helper M19 sentinel fallback'
    Assert-SchedulerIsolation ($m14Source.Contains('if ($SkipM19Capture) { return }') -and
        $m14Source.Contains('if (-not $SkipM19Capture) {')) `
        'capture-free M14 mode does not guard private sentinel and capture-root access'
    Assert-SchedulerIsolation ($m14Source.Contains("'COMPOSE_FILE', 'GEORDI_SCHEDULING_ALERT_ENABLED', 'GEORDI_M13_WEBHOOK_TOKEN_A', 'GEORDI_M13_WEBHOOK_TOKEN_B'")) `
        'M14 caller environment snapshot omits a variable changed by the script'
    Assert-SchedulerIsolation ($m14Source.IndexOf('Get-GeordiM14RenderedComposeConfiguration', [StringComparison]::Ordinal) -lt
        $m14Source.IndexOf('Reset-M14Fixture $root', [StringComparison]::Ordinal)) 'M14 must validate rendered scheduling before fixture reset'
    Assert-SchedulerIsolation ($m14Source.Contains('$started.transition.type -ne ''ALERT_STARTED''')) `
        'M14 Route-A semantic assertion was weakened'
    Assert-SchedulerIsolation ($m14Source.Contains('$response.StatusCode -lt 200 -or $response.StatusCode -ge 300')) `
        'M14 lifecycle API 2xx acceptance changed'

    $started = [pscustomobject]@{
        triggeringEvaluation = [pscustomobject]@{ status = 'CONDITION_MET'; reason = $null; policyName = 'secret-sentinel' }
        current = [pscustomobject]@{ state = 'INACTIVE' }
        transition = [pscustomobject]@{ type = 'ALERT_STARTED'; policyId = 'private-id' }
        credential = 'secret-sentinel'
    }
    $startedDiagnostic = Get-GeordiRouteADiagnostic -HttpStatus 201 -Response $started
    Assert-SchedulerIsolation $startedDiagnostic.IsStarted 'successful 2xx ALERT_STARTED no longer passes'
    Assert-SchedulerIsolation ($startedDiagnostic.Line -match 'http_status=201 evaluation_status=CONDITION_MET evaluation_reason=null current_state=INACTIVE transition_presence=populated transition_type=ALERT_STARTED') `
        'Route-A diagnostic did not emit allowlisted fields'
    Assert-SchedulerIsolation ($startedDiagnostic.Line -notmatch 'secret-sentinel|private-id|credential|policyName') `
        'Route-A diagnostic leaked an unallowlisted response field'

    foreach ($transitionCase in @(
            @{ Name='missing'; Presence='missing'; Type='missing'; Response=[pscustomobject]@{ triggeringEvaluation=$started.triggeringEvaluation; current=$started.current } },
            @{ Name='null'; Presence='null'; Type='null'; Response=[pscustomobject]@{ triggeringEvaluation=$started.triggeringEvaluation; current=$started.current; transition=$null } },
            @{ Name='different'; Presence='populated'; Type='ALERT_RESOLVED'; Response=[pscustomobject]@{ triggeringEvaluation=$started.triggeringEvaluation; current=$started.current; transition=[pscustomobject]@{ type='ALERT_RESOLVED' } } })) {
        Assert-RouteANegativeTransition -Name $transitionCase.Name -Presence $transitionCase.Presence `
            -Type $transitionCase.Type -Response $transitionCase.Response
    }
    Test-RouteAParentDiagnostic -NullParents
    Test-RouteAParentDiagnostic
    $absentFields = Get-GeordiRouteADiagnostic -HttpStatus 200 -Response ([pscustomobject]@{})
    Assert-SchedulerIsolation ($absentFields.Line -match 'evaluation_status=missing evaluation_reason=missing current_state=missing transition_presence=missing transition_type=missing') `
        'Route-A absent fields were not represented accurately'
    Assert-SchedulerIsolation (!(Get-GeordiRouteADiagnostic -HttpStatus 300 -Response $started).IsStarted) `
        'Route-A diagnostic accepted a non-2xx status'
    }

    if ($M12Only) { Write-Host 'PASS: combined M12 scheduler environment isolation regression.' }
    else { Write-Host 'PASS: M12/M14 process isolation, rendered scheduling, Route-A diagnostics, and privacy regressions.' }
} finally {
    Restore-GeordiProcessEnvironment $temporaryOriginal
    Restore-GeordiProcessEnvironment $composeOriginal
}
