[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [ValidateRange(1,120)][int] $TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/GeordiAuthentication.ps1')
Test-GeordiRuntimePreflight -RepositoryRoot $RepositoryRoot -TimeoutSeconds $TimeoutSeconds
