[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'lib/GeordiCredentialGateOrchestration.ps1')

$result = Invoke-GeordiM19EvidenceGates `
    -Finalize { & (Join-Path $PSScriptRoot 'New-GeordiCredentialEvidence.ps1') -Action Finalize } `
    -CredentialScan { & (Join-Path $PSScriptRoot 'Test-GeordiCredentialGateRequired.ps1') } `
    -ArtifactScan { & (Join-Path $PSScriptRoot 'Test-GeordiPublishableArtifacts.ps1') -Independent }

foreach ($phase in @('finalize','credentialScan','artifactScan')) {
    foreach ($line in @($result.Output[$phase])) { Write-Output $line }
}
Write-Output ("m19_evidence_gates finalize={0} credential_scan={1} artifact_scan={2}" -f
    $result.Status.finalize,$result.Status.credentialScan,$result.Status.artifactScan)
if (@($result.Status.Values | Where-Object { $_ -ne 'PASS' }).Count -gt 0) {
    throw 'M19 evidence gates failed; private diagnostics withheld.'
}
