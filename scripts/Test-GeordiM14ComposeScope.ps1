[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Mutation','Dependencies')][string] $Case)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiSchedulerIsolation.ps1')

function Assert-M14ComposeScope([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M14 Compose scope regression failed: $Message" }
}

$serviceNames = @('backend','victoriametrics','otel-collector','frontend','burn-demo',
    'webhook-receiver-a','webhook-receiver-b','oidc-fixture','loki','tempo','webhook-receiver',
    'demo-downstream','demo','m12-burn-demo')
$services = [ordered]@{}
foreach ($name in $serviceNames) { $services[$name] = [pscustomobject]@{ depends_on=[pscustomobject]@{} } }
function Set-Dependency([string] $Service, [string] $Dependency, [bool] $Restart) {
    $value = [pscustomobject]@{ restart=$Restart; condition='service_started' }
    Add-Member -InputObject $services[$Service].depends_on -MemberType NoteProperty -Name $Dependency -Value $value -Force
}
Set-Dependency 'otel-collector' 'victoriametrics' $false
Set-Dependency 'otel-collector' 'tempo' $false
Set-Dependency 'otel-collector' 'loki' $false
foreach ($dependency in @('otel-collector','victoriametrics','tempo','loki','webhook-receiver','webhook-receiver-a','webhook-receiver-b','oidc-fixture')) {
    Set-Dependency 'backend' $dependency $false
}
Set-Dependency 'frontend' 'backend' $false
foreach ($service in @('demo','burn-demo','m12-burn-demo','demo-downstream')) { Set-Dependency $service 'otel-collector' $false }
$configuration = [pscustomobject]@{ services=[pscustomobject]$services }

switch ($Case) {
    'Mutation' {
        $plan = Get-GeordiM14MutationPlan -Configuration $configuration
        Assert-M14ComposeScope ((@($plan.Recreate | Sort-Object) -join ',') -ceq 'backend,otel-collector,victoriametrics') `
            'only backend, VictoriaMetrics and Collector may be force-recreated'
        Assert-M14ComposeScope ((@($plan.Create | Sort-Object) -join ',') -ceq 'webhook-receiver-a,webhook-receiver-b') `
            'M14 receivers must be created explicitly'
        Assert-M14ComposeScope ('frontend' -notin $plan.MutationSet -and 'burn-demo' -notin $plan.MutationSet -and
            'oidc-fixture' -notin $plan.MutationSet) 'frontend, burn-demo or OIDC entered the mutation set'
        Assert-M14ComposeScope ($plan.Commands.Count -eq 4 -and @($plan.Commands | Where-Object { !$_.NoDeps }).Count -eq 0) `
            'startup commands are not explicit and dependency-bounded'
        Assert-M14ComposeScope (@($plan.Commands | Where-Object { $_.ForceRecreate -and $_.Services.Count -gt 1 }).Count -eq 0) `
            'force-recreate is broader than one semantically changed service'
        Write-Output 'm14_compose_mutation_scope=PASS recreate=backend,victoriametrics,otel-collector create=webhook-receiver-a,webhook-receiver-b frontend=preserved'
    }
    'Dependencies' {
        $plan = Get-GeordiM14MutationPlan -Configuration $configuration
        foreach ($name in $plan.RequiredExisting) {
            # This assertion exercises the exact fail-closed preflight contract without Docker.
            $inventory = @($plan.RequiredExisting + $plan.Recreate | ForEach-Object { [pscustomobject]@{ Service=$_; Running=$true; Healthy=$true } })
            Assert-GeordiM14MutationPreflight -Plan $plan -ServiceInventory $inventory
            break
        }
        Set-Dependency 'frontend' 'backend' $true
        $propagationRejected = $false
        try { $null = Get-GeordiM14MutationPlan -Configuration $configuration } catch { $propagationRejected = $true }
        Assert-M14ComposeScope $propagationRejected 'restart propagation to an unrelated dependent was accepted'
        Set-Dependency 'frontend' 'backend' $false
        $missing = @($inventory | Where-Object Service -ne 'oidc-fixture')
        $missingRejected = $false
        try { Assert-GeordiM14MutationPreflight -Plan $plan -ServiceInventory $missing } catch { $missingRejected = $true }
        Assert-M14ComposeScope $missingRejected 'a missing required pre-existing dependency was accepted'
        Write-Output 'm14_dependency_propagation=PASS restart_edges=blocked missing_dependency=fail_closed'
    }
}
