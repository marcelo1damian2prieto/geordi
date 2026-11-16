function Invoke-GeordiM19EvidenceGates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Finalize,
        [Parameter(Mandatory)][scriptblock] $CredentialScan,
        [Parameter(Mandatory)][scriptblock] $ArtifactScan
    )

    $status = [ordered]@{ finalize='PASS'; credentialScan='PASS'; artifactScan='PASS' }
    $output = @{}
    foreach ($phase in @(
            @{ name='finalize'; action=$Finalize },
            @{ name='credentialScan'; action=$CredentialScan },
            @{ name='artifactScan'; action=$ArtifactScan })) {
        try { $output[$phase.name] = @(& $phase.action) }
        catch { $status[$phase.name] = 'FAIL' }
    }
    return [pscustomobject]@{ Status=$status; Output=$output }
}
