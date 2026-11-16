[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Import', 'VerifyPresent', 'Remove', 'VerifyAbsent')]
    [string] $Action,
    [string] $CertificatePath,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Fa-f0-9]{40}$')]
    [string] $ExpectedThumbprint,
    [Parameter(Mandatory)]
    [string] $ExpectedSubject
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GeordiTlsTrust.psm1') -Force
try {
    Invoke-GeordiTlsStoreAction -Action $Action -CertificatePath $CertificatePath `
        -ExpectedThumbprint $ExpectedThumbprint -ExpectedSubject $ExpectedSubject
    exit 0
}
catch {
    [Console]::Error.WriteLine("LOCALMACHINE_TRUST_ACTION_FAILED: $($_.Exception.GetType().Name)")
    exit 1
}
