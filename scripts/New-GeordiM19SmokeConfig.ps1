[CmdletBinding()]
param([string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

$ErrorActionPreference = 'Stop'
$runtimeDirectory = Join-Path $RepositoryRoot '.runtime/m19'
if (!(Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
    throw 'M19 runtime directory is missing; create TLS material before the smoke configuration.'
}

$sourcePath = Join-Path $RepositoryRoot 'deploy/slos/slos.yaml'
$targetPath = Join-Path $runtimeDirectory 'slos.yaml'
$policySourcePath = Join-Path $RepositoryRoot 'deploy/alerts/alert-policies.yaml'
$policyTargetPath = Join-Path $runtimeDirectory 'alert-policies.yaml'
$identityPath = Join-Path $runtimeDirectory 'm18-service-name'
$policyIdPath = Join-Path $runtimeDirectory 'm18-policy-id'
$source = [IO.File]::ReadAllText($sourcePath)
$policySource = [IO.File]::ReadAllText($policySourcePath)
$fixedIdentity = 'name: geordi-m18-multiwindow-service'
if ([regex]::Matches($source, [regex]::Escape($fixedIdentity)).Count -ne 1) {
    throw 'M19 multiwindow fixture identity template is not unique.'
}
$fixedPolicyId = 'id: m18-multiwindow-burn-alert'
if ([regex]::Matches($policySource, [regex]::Escape($fixedPolicyId)).Count -ne 1) {
    throw 'M19 multiwindow fixture policy template is not unique.'
}

$suffix = [guid]::NewGuid().ToString('N')
$serviceName = 'geordi-m18-multiwindow-' + $suffix
$policyId = 'm18-multiwindow-burn-' + $suffix
$runtimeConfig = $source.Replace($fixedIdentity, "name: $serviceName")
$runtimePolicies = $policySource.Replace($fixedPolicyId, "id: $policyId")
[IO.File]::WriteAllText($targetPath, $runtimeConfig, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($policyTargetPath, $runtimePolicies, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($identityPath, $serviceName, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($policyIdPath, $policyId, [Text.UTF8Encoding]::new($false))
Write-Output 'Run-scoped M19 SLO and alert smoke configuration created; no fixture identity was printed.'
