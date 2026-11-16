[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Helper','Culture','Inventory')]
    [string] $Case
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiSchedulerIsolation.ps1')

function Assert-TimestampRegression([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M14 ownership timestamp regression failed: $Message" }
}

function Get-TestUtc([string] $Value) {
    return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None).ToUniversalTime()
}

function Assert-UtcEqual([DateTimeOffset] $Actual, [DateTimeOffset] $Expected, [string] $Message) {
    Assert-TimestampRegression ($Actual.Offset -eq [TimeSpan]::Zero -and $Actual.Ticks -eq $Expected.Ticks) $Message
}

switch ($Case) {
    'Helper' {
        $expected = Get-TestUtc '2026-09-30T19:58:41.1234567Z'
        foreach ($value in @(
                '2026-09-30T19:58:41Z',
                '2026-09-30T19:58:41.1234567Z',
                '2026-09-30T19:58:41.123456789Z',
                '2026-09-30T16:58:41.123456789-03:00')) {
            $actual = ConvertTo-GeordiDockerCreatedUtc -Value $value
            Assert-TimestampRegression ($actual -is [DateTimeOffset]) 'string input did not return DateTimeOffset'
            $caseExpected = $expected
            if ($value -ceq '2026-09-30T19:58:41Z') { $caseExpected = Get-TestUtc '2026-09-30T19:58:41Z' }
            Assert-UtcEqual $actual $caseExpected `
                'RFC3339 instant or nanosecond normalization was incorrect'
        }

        $offsetInput = [DateTimeOffset]::Parse('2026-09-30T16:58:41.1234567-03:00',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
        Assert-UtcEqual (ConvertTo-GeordiDockerCreatedUtc -Value $offsetInput) $expected `
            'DateTimeOffset input was not converted directly to UTC'

        $utcInput = [DateTime]::new(2026,9,30,19,58,41,[DateTimeKind]::Utc).AddTicks(1234567)
        Assert-UtcEqual (ConvertTo-GeordiDockerCreatedUtc -Value $utcInput) $expected 'UTC DateTime input changed its instant'

        $localInput = [DateTime]::new(2026,9,30,16,58,41,[DateTimeKind]::Local).AddTicks(1234567)
        $localExpected = [DateTimeOffset]::new($localInput.ToUniversalTime(), [TimeSpan]::Zero)
        Assert-UtcEqual (ConvertTo-GeordiDockerCreatedUtc -Value $localInput) $localExpected `
            'Local DateTime input did not follow its explicit Kind'

        foreach ($invalid in @($null, '', 'not-a-docker-timestamp', '2026-09-30T19:58:41')) {
            $rejected = $false
            try { $null = ConvertTo-GeordiDockerCreatedUtc -Value $invalid } catch { $rejected = $true }
            Assert-TimestampRegression $rejected 'null, empty, malformed, or timezone-free input was accepted'
        }
        $unspecifiedRejected = $false
        try { $null = ConvertTo-GeordiDockerCreatedUtc -Value ([DateTime]::new(2026,9,30,19,58,41,[DateTimeKind]::Unspecified)) }
        catch { $unspecifiedRejected = $true }
        Assert-TimestampRegression $unspecifiedRejected 'DateTimeKind.Unspecified was silently interpreted as local time'

        $privateInput = 'private-value-not-for-errors'
        $privateInputRejected = $false
        $privateInputError = ''
        try { $null = ConvertTo-GeordiDockerCreatedUtc -Value $privateInput }
        catch { $privateInputRejected = $true; $privateInputError = $_.Exception.Message }
        Assert-TimestampRegression $privateInputRejected 'malformed private test input was accepted'
        Assert-TimestampRegression ($privateInputError -notmatch [regex]::Escape($privateInput)) `
            'error included the supplied timestamp value'
        Write-Output 'timestamp_helper=PASS docker_z=PASS offset=PASS nanoseconds=PASS datetime=PASS datetimeoffset=PASS malformed=FAIL_CLOSED'
    }
    'Culture' {
        $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        $originalUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            $expected = Get-TestUtc '2026-09-30T19:58:41.1234567Z'
            $jsonDate = ('{"Created":"2026-09-30T19:58:41.1234567Z"}' | ConvertFrom-Json).Created
            Assert-TimestampRegression ($jsonDate -is [DateTime] -and $jsonDate.Kind -eq [DateTimeKind]::Utc) `
                'PowerShell no longer materializes the Docker Z sample as UTC DateTime'
            foreach ($cultureName in @('en-US','es-AR','fr-FR')) {
                $culture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                [Threading.Thread]::CurrentThread.CurrentCulture = $culture
                [Threading.Thread]::CurrentThread.CurrentUICulture = $culture
                Assert-UtcEqual (ConvertTo-GeordiDockerCreatedUtc -Value $jsonDate) $expected `
                    "typed Docker timestamp changed under $cultureName culture"
                Assert-UtcEqual (ConvertTo-GeordiDockerCreatedUtc -Value '2026-09-30T16:58:41.123456789-03:00') $expected `
                    "raw Docker timestamp changed under $cultureName culture"
            }
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
            [Threading.Thread]::CurrentThread.CurrentUICulture = $originalUiCulture
        }
        Write-Output 'timestamp_culture_independence=PASS cultures=en-US,es-AR,fr-FR'
    }
    'Inventory' {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:dockerMockCalls = [Collections.Generic.List[string]]::new()
        $script:dockerMockCultures = [Collections.Generic.List[string]]::new()
        $containerPayloads = @{
            'synthetic-backend' = @{
                Id='synthetic-backend'; Created='2026-09-30T19:58:41.1234567Z'
                Config=@{ Labels=@{
                    'com.docker.compose.project'='geordi'
                    'com.docker.compose.service'='backend'
                    'com.docker.compose.project.working_dir'=$repositoryRoot
                } }
                Mounts=@(@{Type='volume';Name='geordi_m19-alert-lifecycle-data'},@{Type='volume';Name='geordi_m19-victoriametrics-data'})
            }
            'synthetic-victoriametrics' = @{
                Id='synthetic-victoriametrics'; Created='2026-09-30T16:58:43.123456789-03:00'
                Config=@{ Labels=@{
                    'com.docker.compose.project'='geordi'
                    'com.docker.compose.service'='victoriametrics'
                    'com.docker.compose.project.working_dir'=$repositoryRoot
                } }
                Mounts=@(@{Type='volume';Name='geordi_m19-victoriametrics-data'})
            }
        }
        $volumePayloads = @{
            'geordi_m14-alert-lifecycle-data' = @{
                Name='geordi_m14-alert-lifecycle-data'; CreatedAt='2026-09-30T19:58:42.1234567Z'
                Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m14-alert-lifecycle-data'}
            }
            'geordi_m14-victoriametrics-data' = @{
                Name='geordi_m14-victoriametrics-data'; CreatedAt='2026-09-30T16:58:44.123456789-03:00'
                Labels=@{'com.docker.compose.project'='geordi';'com.docker.compose.volume'='m14-victoriametrics-data'}
            }
        }
        function docker {
            param([Parameter(ValueFromRemainingArguments=$true)][string[]] $DockerArgs)
            $commandKey = $DockerArgs -join ' '
            $script:dockerMockCalls.Add($commandKey)
            $script:dockerMockCultures.Add([Threading.Thread]::CurrentThread.CurrentCulture.Name)
            $global:LASTEXITCODE = 0
            if ($DockerArgs[0] -ceq 'ps') { return @('synthetic-backend','synthetic-victoriametrics') }
            if ($DockerArgs[0] -ceq 'inspect') {
                $id = $DockerArgs[1]
                return ConvertTo-Json -InputObject $containerPayloads[$id] -Depth 8 -Compress
            }
            if ($DockerArgs[0] -ceq 'volume' -and $DockerArgs[1] -ceq 'ls') {
                return @('geordi_m14-alert-lifecycle-data','geordi_m14-victoriametrics-data',
                    'geordi_m19-alert-lifecycle-data','geordi_m19-victoriametrics-data')
            }
            if ($DockerArgs[0] -ceq 'volume' -and $DockerArgs[1] -ceq 'inspect') {
                $name = $DockerArgs[2]
                return ConvertTo-Json -InputObject $volumePayloads[$name] -Depth 8 -Compress
            }
            $global:LASTEXITCODE = 1
            throw 'Unexpected synthetic Docker command.'
        }

        $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        $originalUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            $localizedCulture = [Globalization.CultureInfo]::GetCultureInfo('es-AR')
            [Threading.Thread]::CurrentThread.CurrentCulture = $localizedCulture
            [Threading.Thread]::CurrentThread.CurrentUICulture = $localizedCulture
            $inventory = Get-GeordiM14DockerResourceInventory
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
            [Threading.Thread]::CurrentThread.CurrentUICulture = $originalUiCulture
        }
        Assert-TimestampRegression ($script:dockerMockCalls.Count -gt 0) 'synthetic Docker command mock was not used'
        Assert-TimestampRegression (@($script:dockerMockCultures | Where-Object { $_ -cne 'es-AR' }).Count -eq 0) `
            'ownership inventory Docker parsing was not exercised under es-AR culture'
        Assert-TimestampRegression ($inventory.Containers.Count -eq 2 -and $inventory.Volumes.Count -eq 2) `
            'synthetic inventory did not parse container and dedicated-volume JSON'
        Assert-UtcEqual $inventory.Containers[0].CreatedUtc (Get-TestUtc '2026-09-30T19:58:41.1234567Z') `
            'container Created timestamp did not normalize correctly'
        Assert-UtcEqual $inventory.Containers[1].CreatedUtc (Get-TestUtc '2026-09-30T19:58:43.1234567Z') `
            'container offset/nanosecond timestamp did not normalize correctly'
        Assert-UtcEqual $inventory.Volumes[0].CreatedUtc (Get-TestUtc '2026-09-30T19:58:42.1234567Z') `
            'volume CreatedAt timestamp did not normalize correctly'
        Assert-UtcEqual $inventory.Volumes[1].CreatedUtc (Get-TestUtc '2026-09-30T19:58:44.1234567Z') `
            'volume offset/nanosecond timestamp did not normalize correctly'
        Assert-TimestampRegression (@($script:dockerMockCalls | Where-Object { $_ -match 'volume inspect geordi_m19-' }).Count -eq 0) `
            'protected M19 volume was included in the M14 volume inventory'

        $renderedVolumes = '{"m14-alert-lifecycle-data":{"name":"geordi_m14-alert-lifecycle-data"},"m14-victoriametrics-data":{"name":"geordi_m14-victoriametrics-data"}}' | ConvertFrom-Json
        $existingVolumes = Assert-GeordiM14ResetVolumeOwnership -RenderedVolumes $renderedVolumes -ExistingVolumes $inventory.Volumes
        Assert-TimestampRegression ($existingVolumes.Count -eq 2) 'dedicated M14 volume ownership was not accepted'

        $start = Get-TestUtc '2026-09-30T19:58:50Z'
        $ownership = [pscustomobject]@{
            RepositoryRoot=$repositoryRoot; ResetCompleted=$true; ResetVolumesAbsent=$true
            StartupAttempted=$true; StartupStartedUtc=$start; BaselineContainerIds=@()
        }
        $afterContainer = [pscustomobject]@{
            Id='new-backend';Project='geordi';Service='backend';WorkingDirectory=$repositoryRoot
            CreatedUtc=$start.AddSeconds(1);Mounts=@()
        }
        $afterVolumes = @(
            [pscustomobject]@{Name='geordi_m14-alert-lifecycle-data';Project='geordi';LogicalName='m14-alert-lifecycle-data';CreatedUtc=$start.AddSeconds(1)},
            [pscustomobject]@{Name='geordi_m14-victoriametrics-data';Project='geordi';LogicalName='m14-victoriametrics-data';CreatedUtc=$start.AddSeconds(1)}
        )
        $plan = Get-GeordiM14OwnedResourcePlan -Ownership $ownership -ContainerInventory @($afterContainer) -VolumeInventory $afterVolumes
        Assert-TimestampRegression ($plan.Containers.Count -eq 1 -and $plan.Volumes.Count -eq 2) `
            'post-invocation resources were not eligible when all ownership criteria passed'

        $beforeContainer = $afterContainer.PSObject.Copy()
        $beforeContainer.Id='old-backend';$beforeContainer.CreatedUtc=$start.AddSeconds(-1)
        $oldContainerRejected=$false
        try { $null=Get-GeordiM14OwnedResourcePlan -Ownership $ownership -ContainerInventory @($beforeContainer) -VolumeInventory @() }
        catch { $oldContainerRejected=$true }
        Assert-TimestampRegression $oldContainerRejected 'pre-invocation container was accepted as owned'

        $oldVolume=$afterVolumes[0].PSObject.Copy();$oldVolume.CreatedUtc=$start.AddSeconds(-1)
        $oldVolumeRejected=$false
        try { $null=Get-GeordiM14OwnedResourcePlan -Ownership $ownership -ContainerInventory @() -VolumeInventory @($oldVolume) }
        catch { $oldVolumeRejected=$true }
        Assert-TimestampRegression $oldVolumeRejected 'pre-invocation volume was accepted as owned'

        $protectedContainer=$afterContainer.PSObject.Copy();$protectedContainer.Mounts=@('geordi_m19-alert-lifecycle-data')
        $protectedRejected=$false
        try { $null=Get-GeordiM14OwnedResourcePlan -Ownership $ownership -ContainerInventory @($protectedContainer) -VolumeInventory @() }
        catch { $protectedRejected=$true }
        Assert-TimestampRegression $protectedRejected 'protected-volume teardown guard was weakened'

        Write-Output 'synthetic_ownership_inventory=PASS culture=es-AR container_and_volume_json=PASS m14_volumes=PASS protected_exclusion=PASS cutoff=PASS'
    }
}
