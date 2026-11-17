[CmdletBinding()]
param(
    [string] $ManifestPath,
    [switch] $Independent,
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$inspectionRoot = if ([string]::IsNullOrWhiteSpace($RootPath)) { $repositoryRoot } else { $RootPath }
$modulePath = Join-Path $PSScriptRoot 'lib/GeordiPublishableArtifacts.psm1'

try {
    if (!$Independent -and (!$ManifestPath -or !(Test-Path -LiteralPath $ManifestPath -PathType Leaf))) {
        throw 'Artifact evidence manifest missing.'
    }
    if (!(Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'Artifact inspection module missing.' }
    Import-Module $modulePath -Force -ErrorAction Stop
    $mode = if ([string]::IsNullOrWhiteSpace($RootPath)) { 'Production' } else { 'SelfTest' }

    if ($Independent) {
        $expectedInventory = Get-GeordiPublishableArtifactInventory -RootPath $inspectionRoot -Mode $mode
    } else {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
        if (!$manifest.captures -or !$manifest.captures.ContainsKey('ci-artifacts')) {
            throw 'Artifact captures missing.'
        }
        $inventoryCaptures = @($manifest.captures['ci-artifacts'])
        if ($inventoryCaptures.Count -lt 2) { throw 'Artifact captures missing.' }
        $inventoryFiles = @($inventoryCaptures | Where-Object {
            [IO.Path]::GetFileName([string]$_) -ceq 'publishable-artifact-inventory.json'
        })
        if ($inventoryFiles.Count -ne 1) { throw 'Artifact inventory control missing.' }
        $inventoryFile = [IO.Path]::GetFullPath([string]$inventoryFiles[0])
        $manifestRoot = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath))).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $manifestRootPrefix = $manifestRoot + [IO.Path]::DirectorySeparatorChar
        $manifestRootItem = Get-Item -LiteralPath $manifestRoot -Force
        $manifestItem = Get-Item -LiteralPath ([IO.Path]::GetFullPath($ManifestPath)) -Force
        $inventoryItem = Get-Item -LiteralPath $inventoryFile -Force
        if (($manifestRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [IO.Path]::GetDirectoryName($inventoryFile) -cne $manifestRoot -or
            !$inventoryFile.StartsWith($manifestRootPrefix,[StringComparison]::OrdinalIgnoreCase) -or
            ($inventoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Artifact inventory path invalid.'
        }
        $expectedInventory = Get-Content -LiteralPath $inventoryFile -Raw | ConvertFrom-Json -AsHashtable

        $root = [IO.Path]::GetFullPath($inspectionRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $expectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($expectedInventory.files)) {
            $relative = ([string]$entry.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if (!$full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
                !$expectedPaths.Add($full)) {
                throw 'Artifact inventory path invalid.'
            }
        }
        $capturedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($pathValue in $inventoryCaptures) {
            $full = [IO.Path]::GetFullPath([string]$pathValue)
            if ($full -ceq $inventoryFile) { continue }
            if (!$capturedPaths.Add($full)) { throw 'Artifact capture inventory duplicated a path.' }
        }
        if ($capturedPaths.Count -ne $expectedPaths.Count -or
            @($expectedPaths | Where-Object { !$capturedPaths.Contains($_) }).Count -gt 0) {
            throw 'Artifact capture inventory does not match the declared inventory.'
        }
    }

    $validatedInventory = Test-GeordiPublishableArtifactInventory -RootPath $inspectionRoot -ExpectedInventory $expectedInventory -Mode $mode
    $validatedInventory = Test-GeordiPublishableArtifactContent -RootPath $inspectionRoot -Inventory $validatedInventory -Mode $mode

    Write-Output ("artifact_files={0} archives={1} archive_entries={2} result=PASS" -f
        $validatedInventory.fileCount,$validatedInventory.archiveCount,$validatedInventory.archiveEntryCount)
} catch {
    throw 'Publishable credential artifact validation failed; private captures withheld.'
} finally {
    Remove-Module GeordiPublishableArtifacts -ErrorAction SilentlyContinue
}
