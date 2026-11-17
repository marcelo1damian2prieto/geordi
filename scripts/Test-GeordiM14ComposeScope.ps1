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
        Assert-M14ComposeScope ((@($plan.ExistingStartGroups[0].Services) -join ',') -ceq 'loki,tempo,webhook-receiver,oidc-fixture' -and
            (@($plan.ExistingStartGroups[1].Services) -join ',') -ceq 'demo-downstream,burn-demo,frontend') `
            'pre-existing service startup order does not respect M14 dependency boundaries'
        Assert-M14ComposeScope (@($plan.Commands | Where-Object { $_.ForceRecreate -and $_.Services.Count -gt 1 }).Count -eq 0) `
            'force-recreate is broader than one semantically changed service'
        Write-Output 'm14_compose_mutation_scope=PASS recreate=backend,victoriametrics,otel-collector create=webhook-receiver-a,webhook-receiver-b frontend=preserved'
    }
    'Dependencies' {
        $plan = Get-GeordiM14MutationPlan -Configuration $configuration
        # Static preflight accepts stopped containers but requires unique identities
        # from this checkout. No Docker daemon or running service is needed here.
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $inventory = @($plan.RequiredExisting + $plan.Recreate | ForEach-Object {
            [pscustomobject]@{
                Project='geordi'; Service=$_; WorkingDirectory=$repositoryRoot
                Running=$false; Healthy=$false
            }
        })
        Assert-GeordiM14MutationPreflight -Plan $plan -ServiceInventory $inventory -RepositoryRoot $repositoryRoot
        $foreignInventory = @($inventory | ForEach-Object {
            $copy = [pscustomobject]@{
                Project=$_.Project; Service=$_.Service; WorkingDirectory=$_.WorkingDirectory
                Running=$_.Running; Healthy=$_.Healthy
            }
            if ($copy.Service -ceq 'frontend') { $copy.WorkingDirectory = (Join-Path $repositoryRoot '..\other-geordi-checkout') }
            $copy
        })
        $foreignRejected = $false
        try { Assert-GeordiM14MutationPreflight -Plan $plan -ServiceInventory $foreignInventory -RepositoryRoot $repositoryRoot }
        catch { $foreignRejected = $true }
        Assert-M14ComposeScope $foreignRejected 'a required service from a different checkout was accepted'
        Set-Dependency 'frontend' 'backend' $true
        $propagationRejected = $false
        try { $null = Get-GeordiM14MutationPlan -Configuration $configuration } catch { $propagationRejected = $true }
        Assert-M14ComposeScope $propagationRejected 'restart propagation to an unrelated dependent was accepted'
        Set-Dependency 'frontend' 'backend' $false
        $missing = @($inventory | Where-Object Service -ne 'oidc-fixture')
        $missingRejected = $false
        try { Assert-GeordiM14MutationPreflight -Plan $plan -ServiceInventory $missing -RepositoryRoot $repositoryRoot } catch { $missingRejected = $true }
        Assert-M14ComposeScope $missingRejected 'a missing required pre-existing dependency was accepted'
        Write-Output 'm14_dependency_propagation=PASS restart_edges=blocked missing_dependency=fail_closed'
    }
}
