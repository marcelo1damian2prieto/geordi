[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiM11BackendReplacement.ps1')

function Assert-M11VmIsolation([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M11 VictoriaMetrics propagation isolation failed: $Message" }
}

function Get-M11ComposeConfiguration([string] $Root, [switch] $Isolated) {
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('--project-directory')
    $arguments.Add($Root)
    foreach ($file in @('compose.yaml', 'compose.m19.yaml', 'compose.m11.yaml')) {
        $arguments.Add('--file')
        $arguments.Add((Join-Path $Root $file))
    }
    if ($Isolated) {
        $arguments.Add('--file')
        $arguments.Add((Join-Path $Root 'compose.m11-victoriametrics-isolation.yaml'))
    }
    $arguments.Add('config')
    $arguments.Add('--format')
    $arguments.Add('json')
    $output = & docker compose @arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'M11 Compose config-only rendering failed.' }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Get-M11VmRestartDependents([System.Collections.IDictionary] $Configuration) {
    $dependents = [Collections.Generic.List[string]]::new()
    foreach ($serviceName in @($Configuration.services.Keys | Sort-Object -CaseSensitive)) {
        $service = $Configuration.services[$serviceName]
        if (!$service.Contains('depends_on') -or !$service.depends_on.Contains('victoriametrics')) { continue }
        $dependency = $service.depends_on['victoriametrics']
        if ($dependency -isnot [System.Collections.IDictionary]) {
            throw 'Rendered VictoriaMetrics dependency is not a long-form object.'
        }
        if ($dependency.Contains('restart')) {
            if ($dependency.restart -isnot [bool]) {
                throw 'Rendered VictoriaMetrics dependency restart is not a boolean.'
            }
            if ($dependency.restart) { $dependents.Add([string]$serviceName) }
        }
    }
    return $dependents.ToArray()
}

function Get-M11EffectiveVmRestart([System.Collections.IDictionary] $Dependency) {
    if (!$Dependency.Contains('restart')) { return $false }
    if ($Dependency.restart -isnot [bool]) {
        throw 'Rendered VictoriaMetrics dependency restart is not a boolean.'
    }
    return [bool]$Dependency.restart
}

function Assert-M11NoVmRestartPropagation([System.Collections.IDictionary] $Configuration) {
    $dependents = @(Get-M11VmRestartDependents $Configuration)
    if ($dependents.Count -ne 0) { throw 'VictoriaMetrics restart propagation remains enabled.' }
}

function ConvertTo-M11CanonicalValue([AllowNull()][object] $Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            $result[[string]$key] = ConvertTo-M11CanonicalValue $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-M11CanonicalValue $item)) }
        return ,$items.ToArray()
    }
    return $Value
}

function ConvertTo-M11CanonicalJson([AllowNull()][object] $Value) {
    return ConvertTo-Json -InputObject (ConvertTo-M11CanonicalValue $Value) -Depth 100 -Compress
}

function Copy-M11Configuration([System.Collections.IDictionary] $Configuration) {
    return (ConvertTo-Json -InputObject $Configuration -Depth 100 -Compress | ConvertFrom-Json -AsHashtable)
}

function Set-M11VmRestart([System.Collections.IDictionary] $Configuration, [string] $ServiceName, [bool] $Value) {
    $edge = $Configuration.services[$ServiceName].depends_on['victoriametrics']
    if ($Value) { $edge.restart = $true }
    else { [void]$edge.Remove('restart') }
}

function Test-M11NegativePropagation([System.Collections.IDictionary] $Isolated, [string] $ServiceName) {
    $negative = Copy-M11Configuration $Isolated
    Set-M11VmRestart $negative $ServiceName $true
    $rejected = $false
    try { Assert-M11NoVmRestartPropagation $negative }
    catch { $rejected = $true }
    Assert-M11VmIsolation $rejected "$ServiceName single-edge negative control was not rejected"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$normal = Get-M11ComposeConfiguration -Root $root
Write-Output 'm11_vm_normal_render=PASS'
$isolated = Get-M11ComposeConfiguration -Root $root -Isolated
Write-Output 'm11_vm_isolated_render=PASS'

$normalEdges = @(Get-M11VmRestartDependents $normal)
Assert-M11VmIsolation ($normalEdges.Count -eq 2 -and (@($normalEdges | Sort-Object) -join ',') -ceq 'backend,otel-collector') `
    'normal M11 topology must retain exactly two VictoriaMetrics restart dependents'
Write-Output 'm11_vm_normal_propagation=PASS dependents=2'

$isolatedEdges = @(Get-M11VmRestartDependents $isolated)
Assert-M11VmIsolation ($isolatedEdges.Count -eq 0) 'isolated M11 topology must have zero VictoriaMetrics restart dependents'
Write-Output 'm11_vm_isolated_propagation=PASS dependents=0'

foreach ($serviceName in @('backend', 'otel-collector')) {
    $normalDependencies = $normal.services[$serviceName].depends_on
    $isolatedDependencies = $isolated.services[$serviceName].depends_on
    Assert-M11VmIsolation ($normalDependencies.Contains('victoriametrics') -and $isolatedDependencies.Contains('victoriametrics')) `
        "$serviceName VictoriaMetrics dependency was removed"
    $normalEdge = $normalDependencies['victoriametrics']
    $isolatedEdge = $isolatedDependencies['victoriametrics']
    Assert-M11VmIsolation (!(Get-M11EffectiveVmRestart $isolatedEdge)) "$serviceName restart propagation is not false"
    foreach ($property in @('condition', 'required')) {
        $normalHas = $normalEdge.Contains($property)
        $isolatedHas = $isolatedEdge.Contains($property)
        Assert-M11VmIsolation ($normalHas -eq $isolatedHas) "$serviceName dependency $property presence changed"
        if ($normalHas) {
            Assert-M11VmIsolation ((ConvertTo-M11CanonicalJson $normalEdge[$property]) -ceq (ConvertTo-M11CanonicalJson $isolatedEdge[$property])) `
                "$serviceName dependency $property changed"
        }
    }
}
Write-Output 'm11_vm_dependencies_and_conditions=PASS'

$normalized = Copy-M11Configuration $normal
Set-M11VmRestart $normalized 'backend' $false
Set-M11VmRestart $normalized 'otel-collector' $false
Assert-M11VmIsolation ((ConvertTo-M11CanonicalJson $normalized) -ceq (ConvertTo-M11CanonicalJson $isolated)) `
    'effective configuration contains semantic drift beyond the two intended restart values'
Write-Output 'm11_vm_bounded_semantic_diff=PASS'

$protectedVolumes = @('geordi_m19-alert-lifecycle-data', 'geordi_m19-victoriametrics-data')
foreach ($serviceName in @('backend', 'otel-collector', 'victoriametrics')) {
    Assert-M11VmIsolation ((ConvertTo-M11CanonicalJson $normal.services[$serviceName].volumes) -ceq `
        (ConvertTo-M11CanonicalJson $isolated.services[$serviceName].volumes)) "$serviceName volume mounts changed"
}
Assert-M11VmIsolation ((ConvertTo-M11CanonicalJson $normal.volumes) -ceq (ConvertTo-M11CanonicalJson $isolated.volumes)) `
    'top-level M11 volume mappings changed'
foreach ($volumeName in $protectedVolumes) {
    foreach ($configuration in @($normal, $isolated)) {
        if ($configuration.volumes.Contains($volumeName)) {
            $normalMapping = $normal.volumes[$volumeName]
            $isolatedMapping = $isolated.volumes[$volumeName]
            Assert-M11VmIsolation ((ConvertTo-M11CanonicalJson $normalMapping) -ceq (ConvertTo-M11CanonicalJson $isolatedMapping)) `
                "$volumeName mapping changed"
        }
    }
}
Assert-M11VmIsolation (!(Select-String -LiteralPath (Join-Path $root 'compose.m11-victoriametrics-isolation.yaml') `
    -Pattern '^volumes\s*:' -Quiet)) 'isolation overlay defines top-level volume mappings'
Write-Output 'm11_vm_protected_and_dedicated_volumes=PASS'

$securityFields = @('environment', 'volumes', 'secrets', 'configs', 'networks', 'labels', 'ports', 'healthcheck', 'command',
    'entrypoint', 'user', 'privileged', 'read_only', 'security_opt', 'cap_add', 'cap_drop')
foreach ($serviceName in @('backend', 'otel-collector')) {
    foreach ($field in $securityFields) {
        $normalHas = $normal.services[$serviceName].Contains($field)
        $isolatedHas = $isolated.services[$serviceName].Contains($field)
        Assert-M11VmIsolation ($normalHas -eq $isolatedHas) "$serviceName security/config field $field presence changed"
        if ($normalHas) {
            Assert-M11VmIsolation ((ConvertTo-M11CanonicalJson $normal.services[$serviceName][$field]) -ceq `
                (ConvertTo-M11CanonicalJson $isolated.services[$serviceName][$field])) "$serviceName security/config field $field changed"
        }
    }
}
Assert-M11VmIsolation ((ConvertTo-M11CanonicalJson $normal.services['victoriametrics']) -ceq `
    (ConvertTo-M11CanonicalJson $isolated.services['victoriametrics'])) 'VictoriaMetrics effective configuration changed'
Write-Output 'm11_vm_security_equivalence=PASS'

Test-M11NegativePropagation $isolated 'backend'
Write-Output 'm11_vm_negative_backend_edge=PASS'
Test-M11NegativePropagation $isolated 'otel-collector'
Write-Output 'm11_vm_negative_collector_edge=PASS'

$expectedComposeFiles = @('compose.yaml', 'compose.m19.yaml', 'compose.m11.yaml', 'compose.m11-victoriametrics-isolation.yaml') |
    ForEach-Object { [IO.Path]::GetFullPath((Join-Path $root $_)) }
$syntheticArgv = [Collections.Generic.List[string]]::new()
$syntheticArgv.Add('docker')
$syntheticArgv.Add('compose')
$syntheticArgv.AddRange([string[]](Get-GeordiM11ControlledReplacementComposeArguments -RepositoryRoot $root))
$targetServices = @('backend', 'victoriametrics')
$actualFiles = [Collections.Generic.List[string]]::new()
for ($index = 2; $index -lt $syntheticArgv.Count; $index++) {
    if ($syntheticArgv[$index] -ceq '--file') {
        $index++
        if ($index -ge $syntheticArgv.Count) { throw 'Synthetic argv has an incomplete --file option.' }
        $actualFiles.Add([IO.Path]::GetFullPath($syntheticArgv[$index]))
    }
}
Assert-M11VmIsolation ((@($actualFiles) -join "`n") -ceq (@($expectedComposeFiles) -join "`n")) 'synthetic argv has missing or extra Compose files'
Assert-M11VmIsolation ($syntheticArgv.Contains('--project-directory') -and $syntheticArgv[$syntheticArgv.IndexOf('--project-directory') + 1] -ceq $root) `
    'synthetic argv lost the repository project directory'
Assert-M11VmIsolation ($targetServices.Count -eq 2 -and (@($targetServices | Sort-Object) -join ',') -ceq 'backend,victoriametrics') `
    'synthetic target scope is not the intended joint M11 fixture'
Assert-M11VmIsolation (@($syntheticArgv | Where-Object { $_ -in @('down', 'prune', 'rm', 'stop', 'volume', '--remove-orphans') }).Count -eq 0) `
    'synthetic argv contains a destructive project-wide or volume operation'
$m11Entry = Get-Content -LiteralPath (Join-Path $root 'scripts/verify-notification-delivery.ps1') -Raw
Assert-M11VmIsolation ($m11Entry.Contains('Get-GeordiM11ControlledReplacementComposeArguments') -and
    $m11Entry.Contains('Invoke-GeordiM11BackendGenerationReplacement')) 'controlled production M11 replacement does not use the overlay and generation lifecycle'
$composeAssignmentPattern = '(?m)^\s*\$env:COMPOSE_FILE\s*=\s*.*compose\.m11\.yaml'
$overlayAssignmentPattern = '(?m)^\s*\$env:COMPOSE_FILE\s*=\s*.*compose\.m11-victoriametrics-isolation\.yaml'
$validComposeAssignment = '    $env:COMPOSE_FILE = Join-Path $root ''compose.m11.yaml'''
$wrongComposeAssignment = '    $env:OTHER_COMPOSE_FILE = Join-Path $root ''compose.m11.yaml'''
$originalComposeFilePresent = Test-Path -LiteralPath Env:COMPOSE_FILE
$originalComposeFile = $env:COMPOSE_FILE
try {
    Remove-Item -LiteralPath Env:COMPOSE_FILE -ErrorAction SilentlyContinue
    Assert-M11VmIsolation ($validComposeAssignment -match $composeAssignmentPattern) 'literal source contract rejected COMPOSE_FILE assignment when ambient variable is absent'
    Assert-M11VmIsolation ($wrongComposeAssignment -notmatch $composeAssignmentPattern) 'literal source contract accepted a different environment variable when ambient COMPOSE_FILE was absent'
    $env:COMPOSE_FILE = 'synthetic-nonempty-value'
    Assert-M11VmIsolation ($validComposeAssignment -match $composeAssignmentPattern) 'literal source contract changed with a nonempty ambient COMPOSE_FILE'
    Assert-M11VmIsolation ($wrongComposeAssignment -notmatch $composeAssignmentPattern) 'literal source contract accepted a different variable with a nonempty ambient COMPOSE_FILE'
} finally {
    if ($originalComposeFilePresent) { Set-Item -LiteralPath Env:COMPOSE_FILE -Value $originalComposeFile }
    else { Remove-Item -LiteralPath Env:COMPOSE_FILE -ErrorAction SilentlyContinue }
}
Assert-M11VmIsolation ($m11Entry -match $composeAssignmentPattern -and $m11Entry -notmatch $overlayAssignmentPattern) `
    'isolation overlay leaked into ambient M11 startup configuration'
foreach ($file in @('compose.m10.yaml', 'compose.m12.yaml', 'compose.m13.yaml', 'compose.m14.yaml', 'compose.m12-collector-replacement.yaml')) {
    Assert-M11VmIsolation (!(Select-String -LiteralPath (Join-Path $root $file) -Pattern 'compose\.m11-victoriametrics-isolation\.yaml' -Quiet)) `
        "$file references the M11-only overlay"
}
Write-Output 'm11_vm_future_command_scope=PASS overlay_m11_only=true runtime_not_invoked=true'
