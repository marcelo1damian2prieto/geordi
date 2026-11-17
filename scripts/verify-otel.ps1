[CmdletBinding()]
param(
    [ValidateRange(10, 300)]
    [int] $TimeoutSeconds = 90,

    [ValidateRange(1, 100)]
    [int] $RequestCount = 10,

    [string] $BackendBaseUrl,
    [string] $CollectorHealthUrl = "http://127.0.0.1:13133/",
    [string] $CollectorMetricsUrl = "http://127.0.0.1:8888/metrics",
    [string] $VictoriaMetricsBaseUrl = "http://127.0.0.1:8428",
    [switch] $SelfTest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')
if ([string]::IsNullOrWhiteSpace($BackendBaseUrl)) { $BackendBaseUrl = Get-GeordiApplicationBaseUrl }

function Invoke-TextRequest {
    param([Parameter(Mandatory)][string] $Uri)

    $response = Invoke-GeordiScriptRequest -Uri $Uri -TimeoutSeconds 5
    if ($response.StatusCode -ne 200) { throw "GET $Uri returned HTTP $($response.StatusCode)." }
    return [string] $response.Content
}

function Wait-ForHttp200 {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    while ((Get-Date) -lt $Deadline) {
        try {
            [void] (Invoke-TextRequest -Uri $Uri)
            Write-Host "PASS: $Name is ready at $Uri"
            return
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "Timed out waiting for $Name at $Uri."
}

function Get-CounterTotal {
    param(
        [Parameter(Mandatory)][string] $Metrics,
        [Parameter(Mandatory)][string] $Name
    )

    $sum = 0.0
    $matched = $false
    foreach ($line in ($Metrics -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#") -or $trimmed.Length -eq 0) {
            continue
        }
        if ($trimmed -notmatch "^$([regex]::Escape($Name))(?:\{(?<labels>[^}]*)\})?\s+(?<value>[-+0-9.eE]+)(?:\s+\d+)?$") {
            continue
        }
        $sum += [double]::Parse($Matches.value, [Globalization.CultureInfo]::InvariantCulture)
        $matched = $true
    }
    # OpenTelemetry counters with a zero value may be absent until their first update.
    # Treating absence as zero permits a clean baseline while positive flow counters
    # are still required to appear and increase below.
    return $sum
}

function Get-Snapshot {
    $metrics = Invoke-TextRequest -Uri $CollectorMetricsUrl

    return @{
        # Counters are summed across all matching receiver/exporter label series, so
        # smoke evidence remains independent of Collector label naming.
        AcceptedSpans = Get-CounterTotal $metrics "otelcol_receiver_accepted_spans"
        AcceptedMetricPoints = Get-CounterTotal $metrics "otelcol_receiver_accepted_metric_points"
        RefusedSpans = Get-CounterTotal $metrics "otelcol_receiver_refused_spans"
        RefusedMetricPoints = Get-CounterTotal $metrics "otelcol_receiver_refused_metric_points"
        SentSpans = Get-CounterTotal $metrics "otelcol_exporter_sent_spans"
        SentMetricPoints = Get-CounterTotal $metrics "otelcol_exporter_sent_metric_points"
        FailedSpans = Get-CounterTotal $metrics "otelcol_exporter_send_failed_spans"
        FailedMetricPoints = Get-CounterTotal $metrics "otelcol_exporter_send_failed_metric_points"
    }
}

function Get-CollectorLogs {
    $output = & docker compose logs --no-color otel-collector 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read logs for Compose service 'otel-collector': $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

function Get-PlatformVersion {
    # /api/platform is protected by observability:read. Read the version from
    # the running artifact rather than bypassing authorization in the smoke.
    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ("geordi-otel-" + [guid]::NewGuid().ToString('N'))
    $jarPath = Join-Path $tempDirectory 'application.jar'
    $archive = $null
    $jarStream = $null
    $entryStream = $null
    $reader = $null
    try {
        New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null
        $copyOutput = & docker compose cp "backend:/app/application.jar" $jarPath 2>&1
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $jarPath -PathType Leaf)) {
            throw "Could not copy the running backend JAR: $($copyOutput -join [Environment]::NewLine)"
        }

        $jarInfo = Get-Item -LiteralPath $jarPath -ErrorAction Stop
        if ($jarInfo.Length -eq 0) {
            throw 'The copied running backend JAR is empty (0 bytes).'
        }

        Add-Type -AssemblyName System.IO.Compression
        $jarStream = [IO.File]::OpenRead($jarPath)
        $archive = [IO.Compression.ZipArchive]::new($jarStream, [IO.Compression.ZipArchiveMode]::Read, $false)

        # Do not assume a fixed Spring Boot archive prefix. Locate the metadata
        # by its path suffix and report the actual archive contents on mismatch.
        $buildInfoEntries = @(
            $archive.Entries | Where-Object {
                $_.FullName -match '(^|/)META-INF/build-info[.]properties

function Get-SeriesAttribute {
    param([Parameter(Mandatory)][object] $Series, [Parameter(Mandatory)][string] $Name)
    foreach ($candidate in @($Name, ($Name -replace '\.', '_'))) {
        if ($Series -is [System.Collections.IDictionary] -and $Series.Contains($candidate)) {
            return [string]$Series[$candidate]
        }
        $property = $Series.PSObject.Properties[$candidate]
        if ($null -ne $property) { return [string]$property.Value }
    }
    return $null
}

function Get-JvmMetricSelector {
    return '{__name__=~"jvm[.].*"}'
}

function Get-BackendJvmIdentitySelector {
    param([Parameter(Mandatory)][string] $Version)
    $escapedVersion = $Version.Replace('\\','\\\\').Replace('"','\\"')
    return (Get-JvmMetricSelector).TrimEnd('}') + ',"service.name"="geordi-backend","service.namespace"="geordi","service.version"="' +
        $escapedVersion + '","geordi.telemetry.origin"="platform","geordi.platform.component"="backend","deployment.environment.name"="development","service.instance.id"!=""}'
}

function Test-BackendJvmIdentity {
    param([Parameter(Mandatory)][object[]] $Series, [Parameter(Mandatory)][string] $Version)
    foreach ($item in $Series) {
        $name = Get-SeriesAttribute $item '__name__'
        if ($name -notmatch '^jvm\.') { continue }
        $expected = [ordered]@{
            'service.name' = 'geordi-backend'
            'service.namespace' = 'geordi'
            'service.version' = $Version
            'geordi.telemetry.origin' = 'platform'
            'geordi.platform.component' = 'backend'
            'deployment.environment.name' = 'development'
        }
        $matchesIdentity = $true
        foreach ($attribute in $expected.GetEnumerator()) {
            if ((Get-SeriesAttribute $item $attribute.Key) -cne [string]$attribute.Value) {
                $matchesIdentity = $false
                break
            }
        }
        if ($matchesIdentity -and -not [string]::IsNullOrWhiteSpace((Get-SeriesAttribute $item 'service.instance.id'))) {
            return $true
        }
    }
    return $false
}

if ($SelfTest) {
    $validIdentity = @(@{
        '__name__'='jvm.memory.used'; service_name='geordi-backend'; service_namespace='geordi'
        service_version='test-version'; geordi_telemetry_origin='platform'; geordi_platform_component='backend'
        deployment_environment_name='development'; service_instance_id='instance-test'
    })
    if (-not (Test-BackendJvmIdentity -Series $validIdentity -Version 'test-version')) {
        throw 'Persisted backend identity positive self-test failed.'
    }
    $missingInstance = @($validIdentity[0].Clone())
    $missingInstance[0].Remove('service_instance_id')
    if (Test-BackendJvmIdentity -Series $missingInstance -Version 'test-version') {
        throw 'Persisted backend identity accepted a missing service instance ID.'
    }
    if (Test-BackendJvmIdentity -Series $validIdentity -Version 'wrong-version') {
        throw 'Persisted backend identity accepted a service version mismatch.'
    }
    $jvmSelector = Get-JvmMetricSelector
    if ($jvmSelector -cne '{__name__=~"jvm[.].*"}' -or $jvmSelector.Contains('\') -or
            'jvm.memory.used' -notmatch '^jvm[.].*' -or 'jvmmemory.used' -match '^jvm[.].*') {
        throw 'JVM selector syntax or literal-prefix semantics self-test failed.'
    }
    $identitySelector = Get-BackendJvmIdentitySelector -Version 'test-version'
    foreach ($requiredPredicate in @('"service.name"="geordi-backend"','"service.namespace"="geordi"',
            '"service.version"="test-version"','"geordi.telemetry.origin"="platform"',
            '"geordi.platform.component"="backend"','"deployment.environment.name"="development"',
            '"service.instance.id"!=""')) {
        if (!$identitySelector.Contains($requiredPredicate)) { throw 'JVM identity selector omitted a required predicate.' }
    }
    if ($identitySelector.Contains('\\')) { throw 'JVM identity selector contains ambiguous backslash escaping.' }
    $encodedSelector = [Uri]::EscapeDataString($jvmSelector)
    if ([Uri]::UnescapeDataString($encodedSelector) -cne $jvmSelector -or $encodedSelector.Contains('%255C')) {
        throw 'JVM selector URI encoding changed or double-escaped the expression.'
    }
    Write-Output 'otel_persisted_identity_self_test=PASS cases=7 selector=jvm[.].* literal_prefix=PASS no_double_escape=PASS predicates=PASS'
    return
}

function Assert-NoIncrease {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][double] $Before,
        [Parameter(Mandatory)][double] $After
    )

    if ($After -ne $Before) {
        throw "$Name increased from $Before to $After."
    }
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is required to inspect the otel-collector Compose service."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "Collector readiness" $CollectorHealthUrl $deadline

    $platformVersion = Get-PlatformVersion
    $before = Get-Snapshot
    $identityWindowStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    1..$RequestCount | ForEach-Object {
        [void] (Invoke-TextRequest -Uri "$BackendBaseUrl/api/platform")
    }
    Write-Host "Generated $RequestCount backend requests."

    $after = $null
    do {
        Start-Sleep -Seconds 2
        $after = Get-Snapshot
        $spanFlow = $after.AcceptedSpans -gt $before.AcceptedSpans -and
            $after.SentSpans -gt $before.SentSpans
        $metricFlow = $after.AcceptedMetricPoints -gt $before.AcceptedMetricPoints -and
            $after.SentMetricPoints -gt $before.SentMetricPoints
    } while ((-not ($spanFlow -and $metricFlow)) -and (Get-Date) -lt $deadline)

    if (-not $spanFlow) {
        throw "Collector span acceptance/export did not increase before timeout."
    }
    if (-not $metricFlow) {
        throw "Collector metric-point acceptance/export did not increase before timeout."
    }

    Assert-NoIncrease "refused spans" $before.RefusedSpans $after.RefusedSpans
    Assert-NoIncrease "refused metric points" $before.RefusedMetricPoints $after.RefusedMetricPoints
    Assert-NoIncrease "failed span exports" $before.FailedSpans $after.FailedSpans
    Assert-NoIncrease "failed metric-point exports" $before.FailedMetricPoints $after.FailedMetricPoints

    $logs = Get-CollectorLogs
    # Basic debug verbosity emits aggregate signal summaries without resource or
    # point attributes. The ordered traces/metrics/logs gates validate persisted
    # resource identity.
    $requiredPatterns = [ordered]@{
        "basic trace exporter summary" = '"resource spans"\s*:\s*[1-9]\d*'
        "basic metrics exporter summary" = '"resource metrics"\s*:\s*[1-9]\d*'
    }
    foreach ($entry in $requiredPatterns.GetEnumerator()) {
        if ($logs -notmatch $entry.Value) {
            throw "Collector debug output did not contain $($entry.Key)."
        }
    }

    $seriesSelector = [Uri]::EscapeDataString((Get-JvmMetricSelector))
    $identitySelector = Get-BackendJvmIdentitySelector -Version $platformVersion
    $identityQuery = [Uri]::EscapeDataString('count(count_over_time(' + $identitySelector + '[90s]))')
    $identityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    $identityVerified = $false
    do {
        try {
            $identityEnd = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $seriesUri = "$($VictoriaMetricsBaseUrl.TrimEnd('/'))/api/v1/series?match%5B%5D=$seriesSelector&start=$identityWindowStart&end=$identityEnd"
            $seriesPayload = Invoke-RestMethod -Uri $seriesUri -Method Get -TimeoutSec 5
            $queryUri = "$($VictoriaMetricsBaseUrl.TrimEnd('/'))/api/v1/query?query=$identityQuery"
            $queryPayload = Invoke-RestMethod -Uri $queryUri -Method Get -TimeoutSec 5
            $currentRunIdentity = @($queryPayload.data.result | Where-Object { [double]$_.value[1] -gt 0 }).Count -gt 0
            $identityVerified = ([string]$seriesPayload.status -ceq 'success' -and
                [string]$queryPayload.status -ceq 'success' -and $currentRunIdentity -and
                (Test-BackendJvmIdentity -Series @($seriesPayload.data) -Version $platformVersion))
        } catch { $identityVerified = $false }
        if (-not $identityVerified) { Start-Sleep -Milliseconds 500 }
    } while (-not $identityVerified -and [DateTimeOffset]::UtcNow -lt $identityDeadline)
    if (-not $identityVerified) {
        throw 'Persisted backend JVM Resource identity did not match the platform API version.'
    }

    Write-Host "PASS: spans accepted/exported increased by $($after.AcceptedSpans - $before.AcceptedSpans)/$($after.SentSpans - $before.SentSpans)."
    Write-Host "PASS: metric points accepted/exported increased by $($after.AcceptedMetricPoints - $before.AcceptedMetricPoints)/$($after.SentMetricPoints - $before.SentMetricPoints)."
    Write-Host "PASS: refused and send-failed counters did not increase."
    Write-Host "PASS: Collector debug exporter emitted non-empty basic trace and metrics summaries."
    Write-Host "PASS: persisted backend JVM identity, instance ID, component, and platform API version match."
    exit 0
}
catch {
    Write-Error "OpenTelemetry smoke verification failed: $($_.Exception.Message)"
    exit 1
}

            }
        )
        if ($buildInfoEntries.Count -eq 0) {
            $diagnosticEntries = @(
                $archive.Entries |
                    Where-Object { $_.FullName -match '(?i)build-info|(^|/)META-INF/' } |
                    Select-Object -First 20 -ExpandProperty FullName
            )
            $entrySummary = if ($diagnosticEntries.Count -gt 0) {
                $diagnosticEntries -join ', '
            } else {
                '<no build-info or META-INF entries found>'
            }
            $diagnostic = ("The copied running backend JAR ({0} bytes, {1} entries) has no " +
                "META-INF/build-info.properties entry. Relevant entries: {2}") -f
                $jarInfo.Length, $archive.Entries.Count, $entrySummary
            throw $diagnostic
        }
        if ($buildInfoEntries.Count -gt 1) {
            $entryNames = ($buildInfoEntries | ForEach-Object { $_.FullName }) -join ', '
            throw "The copied running backend JAR contains multiple build-info.properties entries: $entryNames"
        }

        $entry = $buildInfoEntries[0]
        $entryStream = $entry.Open()
        $reader = [IO.StreamReader]::new($entryStream)
        $properties = $reader.ReadToEnd()
        $versionMatch = [regex]::Match($properties, '(?m)^build[.]version=(?<version>[^\r\n]+)

function Get-SeriesAttribute {
    param([Parameter(Mandatory)][object] $Series, [Parameter(Mandatory)][string] $Name)
    foreach ($candidate in @($Name, ($Name -replace '\.', '_'))) {
        if ($Series -is [System.Collections.IDictionary] -and $Series.Contains($candidate)) {
            return [string]$Series[$candidate]
        }
        $property = $Series.PSObject.Properties[$candidate]
        if ($null -ne $property) { return [string]$property.Value }
    }
    return $null
}

function Get-JvmMetricSelector {
    return '{__name__=~"jvm[.].*"}'
}

function Get-BackendJvmIdentitySelector {
    param([Parameter(Mandatory)][string] $Version)
    $escapedVersion = $Version.Replace('\\','\\\\').Replace('"','\\"')
    return (Get-JvmMetricSelector).TrimEnd('}') + ',"service.name"="geordi-backend","service.namespace"="geordi","service.version"="' +
        $escapedVersion + '","geordi.telemetry.origin"="platform","geordi.platform.component"="backend","deployment.environment.name"="development","service.instance.id"!=""}'
}

function Test-BackendJvmIdentity {
    param([Parameter(Mandatory)][object[]] $Series, [Parameter(Mandatory)][string] $Version)
    foreach ($item in $Series) {
        $name = Get-SeriesAttribute $item '__name__'
        if ($name -notmatch '^jvm\.') { continue }
        $expected = [ordered]@{
            'service.name' = 'geordi-backend'
            'service.namespace' = 'geordi'
            'service.version' = $Version
            'geordi.telemetry.origin' = 'platform'
            'geordi.platform.component' = 'backend'
            'deployment.environment.name' = 'development'
        }
        $matchesIdentity = $true
        foreach ($attribute in $expected.GetEnumerator()) {
            if ((Get-SeriesAttribute $item $attribute.Key) -cne [string]$attribute.Value) {
                $matchesIdentity = $false
                break
            }
        }
        if ($matchesIdentity -and -not [string]::IsNullOrWhiteSpace((Get-SeriesAttribute $item 'service.instance.id'))) {
            return $true
        }
    }
    return $false
}

if ($SelfTest) {
    $validIdentity = @(@{
        '__name__'='jvm.memory.used'; service_name='geordi-backend'; service_namespace='geordi'
        service_version='test-version'; geordi_telemetry_origin='platform'; geordi_platform_component='backend'
        deployment_environment_name='development'; service_instance_id='instance-test'
    })
    if (-not (Test-BackendJvmIdentity -Series $validIdentity -Version 'test-version')) {
        throw 'Persisted backend identity positive self-test failed.'
    }
    $missingInstance = @($validIdentity[0].Clone())
    $missingInstance[0].Remove('service_instance_id')
    if (Test-BackendJvmIdentity -Series $missingInstance -Version 'test-version') {
        throw 'Persisted backend identity accepted a missing service instance ID.'
    }
    if (Test-BackendJvmIdentity -Series $validIdentity -Version 'wrong-version') {
        throw 'Persisted backend identity accepted a service version mismatch.'
    }
    $jvmSelector = Get-JvmMetricSelector
    if ($jvmSelector -cne '{__name__=~"jvm[.].*"}' -or $jvmSelector.Contains('\') -or
            'jvm.memory.used' -notmatch '^jvm[.].*' -or 'jvmmemory.used' -match '^jvm[.].*') {
        throw 'JVM selector syntax or literal-prefix semantics self-test failed.'
    }
    $identitySelector = Get-BackendJvmIdentitySelector -Version 'test-version'
    foreach ($requiredPredicate in @('"service.name"="geordi-backend"','"service.namespace"="geordi"',
            '"service.version"="test-version"','"geordi.telemetry.origin"="platform"',
            '"geordi.platform.component"="backend"','"deployment.environment.name"="development"',
            '"service.instance.id"!=""')) {
        if (!$identitySelector.Contains($requiredPredicate)) { throw 'JVM identity selector omitted a required predicate.' }
    }
    if ($identitySelector.Contains('\\')) { throw 'JVM identity selector contains ambiguous backslash escaping.' }
    $encodedSelector = [Uri]::EscapeDataString($jvmSelector)
    if ([Uri]::UnescapeDataString($encodedSelector) -cne $jvmSelector -or $encodedSelector.Contains('%255C')) {
        throw 'JVM selector URI encoding changed or double-escaped the expression.'
    }
    Write-Output 'otel_persisted_identity_self_test=PASS cases=7 selector=jvm[.].* literal_prefix=PASS no_double_escape=PASS predicates=PASS'
    return
}

function Assert-NoIncrease {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][double] $Before,
        [Parameter(Mandatory)][double] $After
    )

    if ($After -ne $Before) {
        throw "$Name increased from $Before to $After."
    }
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is required to inspect the otel-collector Compose service."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "Collector readiness" $CollectorHealthUrl $deadline

    $platformVersion = Get-PlatformVersion
    $before = Get-Snapshot
    $identityWindowStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    1..$RequestCount | ForEach-Object {
        [void] (Invoke-TextRequest -Uri "$BackendBaseUrl/api/platform")
    }
    Write-Host "Generated $RequestCount backend requests."

    $after = $null
    do {
        Start-Sleep -Seconds 2
        $after = Get-Snapshot
        $spanFlow = $after.AcceptedSpans -gt $before.AcceptedSpans -and
            $after.SentSpans -gt $before.SentSpans
        $metricFlow = $after.AcceptedMetricPoints -gt $before.AcceptedMetricPoints -and
            $after.SentMetricPoints -gt $before.SentMetricPoints
    } while ((-not ($spanFlow -and $metricFlow)) -and (Get-Date) -lt $deadline)

    if (-not $spanFlow) {
        throw "Collector span acceptance/export did not increase before timeout."
    }
    if (-not $metricFlow) {
        throw "Collector metric-point acceptance/export did not increase before timeout."
    }

    Assert-NoIncrease "refused spans" $before.RefusedSpans $after.RefusedSpans
    Assert-NoIncrease "refused metric points" $before.RefusedMetricPoints $after.RefusedMetricPoints
    Assert-NoIncrease "failed span exports" $before.FailedSpans $after.FailedSpans
    Assert-NoIncrease "failed metric-point exports" $before.FailedMetricPoints $after.FailedMetricPoints

    $logs = Get-CollectorLogs
    # Basic debug verbosity emits aggregate signal summaries without resource or
    # point attributes. The ordered traces/metrics/logs gates validate persisted
    # resource identity.
    $requiredPatterns = [ordered]@{
        "basic trace exporter summary" = '"resource spans"\s*:\s*[1-9]\d*'
        "basic metrics exporter summary" = '"resource metrics"\s*:\s*[1-9]\d*'
    }
    foreach ($entry in $requiredPatterns.GetEnumerator()) {
        if ($logs -notmatch $entry.Value) {
            throw "Collector debug output did not contain $($entry.Key)."
        }
    }

    $seriesSelector = [Uri]::EscapeDataString((Get-JvmMetricSelector))
    $identitySelector = Get-BackendJvmIdentitySelector -Version $platformVersion
    $identityQuery = [Uri]::EscapeDataString('count(count_over_time(' + $identitySelector + '[90s]))')
    $identityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    $identityVerified = $false
    do {
        try {
            $identityEnd = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $seriesUri = "$($VictoriaMetricsBaseUrl.TrimEnd('/'))/api/v1/series?match%5B%5D=$seriesSelector&start=$identityWindowStart&end=$identityEnd"
            $seriesPayload = Invoke-RestMethod -Uri $seriesUri -Method Get -TimeoutSec 5
            $queryUri = "$($VictoriaMetricsBaseUrl.TrimEnd('/'))/api/v1/query?query=$identityQuery"
            $queryPayload = Invoke-RestMethod -Uri $queryUri -Method Get -TimeoutSec 5
            $currentRunIdentity = @($queryPayload.data.result | Where-Object { [double]$_.value[1] -gt 0 }).Count -gt 0
            $identityVerified = ([string]$seriesPayload.status -ceq 'success' -and
                [string]$queryPayload.status -ceq 'success' -and $currentRunIdentity -and
                (Test-BackendJvmIdentity -Series @($seriesPayload.data) -Version $platformVersion))
        } catch { $identityVerified = $false }
        if (-not $identityVerified) { Start-Sleep -Milliseconds 500 }
    } while (-not $identityVerified -and [DateTimeOffset]::UtcNow -lt $identityDeadline)
    if (-not $identityVerified) {
        throw 'Persisted backend JVM Resource identity did not match the platform API version.'
    }

    Write-Host "PASS: spans accepted/exported increased by $($after.AcceptedSpans - $before.AcceptedSpans)/$($after.SentSpans - $before.SentSpans)."
    Write-Host "PASS: metric points accepted/exported increased by $($after.AcceptedMetricPoints - $before.AcceptedMetricPoints)/$($after.SentMetricPoints - $before.SentMetricPoints)."
    Write-Host "PASS: refused and send-failed counters did not increase."
    Write-Host "PASS: Collector debug exporter emitted non-empty basic trace and metrics summaries."
    Write-Host "PASS: persisted backend JVM identity, instance ID, component, and platform API version match."
    exit 0
}
catch {
    Write-Error "OpenTelemetry smoke verification failed: $($_.Exception.Message)"
    exit 1
}
)
        if (!$versionMatch.Success -or [string]::IsNullOrWhiteSpace($versionMatch.Groups['version'].Value)) {
            $diagnostic = ("Entry '{0}' exists in the copied running backend JAR but does not contain " +
                "a non-empty build.version property.") -f $entry.FullName
            throw $diagnostic
        }
        return $versionMatch.Groups['version'].Value.Trim()
    } catch {
        throw "Could not determine the running backend platform version: $($_.Exception.Message)"
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($entryStream) { $entryStream.Dispose() }
        if ($archive) { $archive.Dispose() }
        if ($jarStream) { $jarStream.Dispose() }
        if (Test-Path -LiteralPath $tempDirectory) {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force
        }
    }
}

function Get-SeriesAttribute {
    param([Parameter(Mandatory)][object] $Series, [Parameter(Mandatory)][string] $Name)
    foreach ($candidate in @($Name, ($Name -replace '\.', '_'))) {
        if ($Series -is [System.Collections.IDictionary] -and $Series.Contains($candidate)) {
            return [string]$Series[$candidate]
        }
        $property = $Series.PSObject.Properties[$candidate]
        if ($null -ne $property) { return [string]$property.Value }
    }
    return $null
}

function Get-JvmMetricSelector {
    return '{__name__=~"jvm[.].*"}'
}

function Get-BackendJvmIdentitySelector {
    param([Parameter(Mandatory)][string] $Version)
    $escapedVersion = $Version.Replace('\\','\\\\').Replace('"','\\"')
    return (Get-JvmMetricSelector).TrimEnd('}') + ',"service.name"="geordi-backend","service.namespace"="geordi","service.version"="' +
        $escapedVersion + '","geordi.telemetry.origin"="platform","geordi.platform.component"="backend","deployment.environment.name"="development","service.instance.id"!=""}'
}

function Test-BackendJvmIdentity {
    param([Parameter(Mandatory)][object[]] $Series, [Parameter(Mandatory)][string] $Version)
    foreach ($item in $Series) {
        $name = Get-SeriesAttribute $item '__name__'
        if ($name -notmatch '^jvm\.') { continue }
        $expected = [ordered]@{
            'service.name' = 'geordi-backend'
            'service.namespace' = 'geordi'
            'service.version' = $Version
            'geordi.telemetry.origin' = 'platform'
            'geordi.platform.component' = 'backend'
            'deployment.environment.name' = 'development'
        }
        $matchesIdentity = $true
        foreach ($attribute in $expected.GetEnumerator()) {
            if ((Get-SeriesAttribute $item $attribute.Key) -cne [string]$attribute.Value) {
                $matchesIdentity = $false
                break
            }
        }
        if ($matchesIdentity -and -not [string]::IsNullOrWhiteSpace((Get-SeriesAttribute $item 'service.instance.id'))) {
            return $true
        }
    }
    return $false
}

if ($SelfTest) {
    $validIdentity = @(@{
        '__name__'='jvm.memory.used'; service_name='geordi-backend'; service_namespace='geordi'
        service_version='test-version'; geordi_telemetry_origin='platform'; geordi_platform_component='backend'
        deployment_environment_name='development'; service_instance_id='instance-test'
    })
    if (-not (Test-BackendJvmIdentity -Series $validIdentity -Version 'test-version')) {
        throw 'Persisted backend identity positive self-test failed.'
    }
    $missingInstance = @($validIdentity[0].Clone())
    $missingInstance[0].Remove('service_instance_id')
    if (Test-BackendJvmIdentity -Series $missingInstance -Version 'test-version') {
        throw 'Persisted backend identity accepted a missing service instance ID.'
    }
    if (Test-BackendJvmIdentity -Series $validIdentity -Version 'wrong-version') {
        throw 'Persisted backend identity accepted a service version mismatch.'
    }
    $jvmSelector = Get-JvmMetricSelector
    if ($jvmSelector -cne '{__name__=~"jvm[.].*"}' -or $jvmSelector.Contains('\') -or
            'jvm.memory.used' -notmatch '^jvm[.].*' -or 'jvmmemory.used' -match '^jvm[.].*') {
        throw 'JVM selector syntax or literal-prefix semantics self-test failed.'
    }
    $identitySelector = Get-BackendJvmIdentitySelector -Version 'test-version'
    foreach ($requiredPredicate in @('"service.name"="geordi-backend"','"service.namespace"="geordi"',
            '"service.version"="test-version"','"geordi.telemetry.origin"="platform"',
            '"geordi.platform.component"="backend"','"deployment.environment.name"="development"',
            '"service.instance.id"!=""')) {
        if (!$identitySelector.Contains($requiredPredicate)) { throw 'JVM identity selector omitted a required predicate.' }
    }
    if ($identitySelector.Contains('\\')) { throw 'JVM identity selector contains ambiguous backslash escaping.' }
    $encodedSelector = [Uri]::EscapeDataString($jvmSelector)
    if ([Uri]::UnescapeDataString($encodedSelector) -cne $jvmSelector -or $encodedSelector.Contains('%255C')) {
        throw 'JVM selector URI encoding changed or double-escaped the expression.'
    }
    Write-Output 'otel_persisted_identity_self_test=PASS cases=7 selector=jvm[.].* literal_prefix=PASS no_double_escape=PASS predicates=PASS'
    return
}

function Assert-NoIncrease {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][double] $Before,
        [Parameter(Mandatory)][double] $After
    )

    if ($After -ne $Before) {
        throw "$Name increased from $Before to $After."
    }
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker is required to inspect the otel-collector Compose service."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Wait-ForHttp200 "backend readiness" "$BackendBaseUrl/actuator/health/readiness" $deadline
    Wait-ForHttp200 "Collector readiness" $CollectorHealthUrl $deadline

    $platformVersion = Get-PlatformVersion
    $before = Get-Snapshot
    $identityWindowStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    1..$RequestCount | ForEach-Object {
        [void] (Invoke-TextRequest -Uri "$BackendBaseUrl/api/platform")
    }
    Write-Host "Generated $RequestCount backend requests."

    $after = $null
    do {
        Start-Sleep -Seconds 2
        $after = Get-Snapshot
        $spanFlow = $after.AcceptedSpans -gt $before.AcceptedSpans -and
            $after.SentSpans -gt $before.SentSpans
        $metricFlow = $after.AcceptedMetricPoints -gt $before.AcceptedMetricPoints -and
            $after.SentMetricPoints -gt $before.SentMetricPoints
    } while ((-not ($spanFlow -and $metricFlow)) -and (Get-Date) -lt $deadline)

    if (-not $spanFlow) {
        throw "Collector span acceptance/export did not increase before timeout."
    }
    if (-not $metricFlow) {
        throw "Collector metric-point acceptance/export did not increase before timeout."
    }

    Assert-NoIncrease "refused spans" $before.RefusedSpans $after.RefusedSpans
    Assert-NoIncrease "refused metric points" $before.RefusedMetricPoints $after.RefusedMetricPoints
    Assert-NoIncrease "failed span exports" $before.FailedSpans $after.FailedSpans
    Assert-NoIncrease "failed metric-point exports" $before.FailedMetricPoints $after.FailedMetricPoints

    $logs = Get-CollectorLogs
    # Basic debug verbosity emits aggregate signal summaries without resource or
    # point attributes. The ordered traces/metrics/logs gates validate persisted
    # resource identity.
    $requiredPatterns = [ordered]@{
        "basic trace exporter summary" = '"resource spans"\s*:\s*[1-9]\d*'
        "basic metrics exporter summary" = '"resource metrics"\s*:\s*[1-9]\d*'
    }
    foreach ($entry in $requiredPatterns.GetEnumerator()) {
        if ($logs -notmatch $entry.Value) {
            throw "Collector debug output did not contain $($entry.Key)."
        }
    }

    $seriesSelector = [Uri]::EscapeDataString((Get-JvmMetricSelector))
    $identitySelector = Get-BackendJvmIdentitySelector -Version $platformVersion
    $identityQuery = [Uri]::EscapeDataString('count(count_over_time(' + $identitySelector + '[90s]))')
    $identityDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    $identityVerified = $false
    do {
        try {
            $identityEnd = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $seriesUri = "$($VictoriaMetricsBaseUrl.TrimEnd('/'))/api/v1/series?match%5B%5D=$seriesSelector&start=$identityWindowStart&end=$identityEnd"
            $seriesPayload = Invoke-RestMethod -Uri $seriesUri -Method Get -TimeoutSec 5
            $queryUri = "$($VictoriaMetricsBaseUrl.TrimEnd('/'))/api/v1/query?query=$identityQuery"
            $queryPayload = Invoke-RestMethod -Uri $queryUri -Method Get -TimeoutSec 5
            $currentRunIdentity = @($queryPayload.data.result | Where-Object { [double]$_.value[1] -gt 0 }).Count -gt 0
            $identityVerified = ([string]$seriesPayload.status -ceq 'success' -and
                [string]$queryPayload.status -ceq 'success' -and $currentRunIdentity -and
                (Test-BackendJvmIdentity -Series @($seriesPayload.data) -Version $platformVersion))
        } catch { $identityVerified = $false }
        if (-not $identityVerified) { Start-Sleep -Milliseconds 500 }
    } while (-not $identityVerified -and [DateTimeOffset]::UtcNow -lt $identityDeadline)
    if (-not $identityVerified) {
        throw 'Persisted backend JVM Resource identity did not match the platform API version.'
    }

    Write-Host "PASS: spans accepted/exported increased by $($after.AcceptedSpans - $before.AcceptedSpans)/$($after.SentSpans - $before.SentSpans)."
    Write-Host "PASS: metric points accepted/exported increased by $($after.AcceptedMetricPoints - $before.AcceptedMetricPoints)/$($after.SentMetricPoints - $before.SentMetricPoints)."
    Write-Host "PASS: refused and send-failed counters did not increase."
    Write-Host "PASS: Collector debug exporter emitted non-empty basic trace and metrics summaries."
    Write-Host "PASS: persisted backend JVM identity, instance ID, component, and platform API version match."
    exit 0
}
catch {
    Write-Error "OpenTelemetry smoke verification failed: $($_.Exception.Message)"
    exit 1
}
