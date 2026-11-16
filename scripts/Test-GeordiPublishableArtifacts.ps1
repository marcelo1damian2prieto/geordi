[CmdletBinding()]
param([string] $ManifestPath, [switch] $Independent)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

try {
    if (!$Independent -and (!$ManifestPath -or !(Test-Path -LiteralPath $ManifestPath -PathType Leaf))) {
        throw 'Artifact evidence manifest missing.'
    }
    $manifest = if ($Independent) { $null } else { Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable }
    $roots = @(
        'backend/target/surefire-reports','backend/target/pmd.xml',
        'backend/target/spotbugsXml.xml','backend/target/geordi-backend-0.1.0-SNAPSHOT.jar',
        'backend/target/geordi-backend-0.1.0-SNAPSHOT-security-telemetry.jar',
        'backend/.ci-artifact/application.jar','backend/.ci-artifact/security-telemetry.jar',
        'backend/target/verified-artifact.properties','frontend/dist')
    $files = [Collections.Generic.List[string]]::new()
    foreach ($relative in $roots) {
        $path = Join-Path $repositoryRoot $relative
        if (!(Test-Path -LiteralPath $path)) {
            if ($relative -in @('backend/.ci-artifact/application.jar','backend/.ci-artifact/security-telemetry.jar')) { continue }
            throw 'Required publishable artifact path missing.'
        }
        $item = Get-Item -LiteralPath $path
        if ($item.PSIsContainer) {
            foreach ($file in Get-ChildItem -LiteralPath $path -File -Recurse) { $files.Add($file.FullName) }
        } else { $files.Add($item.FullName) }
    }
    $failsafeRoot = Join-Path $repositoryRoot 'backend/target/failsafe-reports'
    if (Test-Path -LiteralPath $failsafeRoot) {
        foreach ($file in Get-ChildItem -LiteralPath $failsafeRoot -File -Recurse) { $files.Add($file.FullName) }
    }
    $expectedHashes = @{}
    if ($Independent) {
        foreach ($path in $files) {
            $relative = $path.Substring($repositoryRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\','/')
            $expectedHashes[$relative] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } else {
        $inventoryCaptures = @($manifest.captures['ci-artifacts'])
        if ($inventoryCaptures.Count -lt 2) { throw 'Artifact captures missing.' }
        $inventoryFile = @($inventoryCaptures | Where-Object { (Split-Path $_ -Leaf) -eq 'publishable-artifact-inventory.json' })
        if ($inventoryFile.Count -ne 1) { throw 'Artifact inventory control missing.' }
        $captured = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $inventoryCaptures) {
            if ((Split-Path $path -Leaf) -eq 'publishable-artifact-inventory.json') { continue }
            [void]$captured.Add([IO.Path]::GetFullPath([string]$path))
        }
        $actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $files) { [void]$actual.Add([IO.Path]::GetFullPath($path)) }
        if ($captured.Count -ne $actual.Count -or @($actual | Where-Object { !$captured.Contains($_) }).Count -gt 0) {
            throw 'Artifact capture inventory does not match all publishable paths.'
        }
        $inventoryFile = [string]$inventoryFile[0]
        $inventory = Get-Content -LiteralPath $inventoryFile -Raw | ConvertFrom-Json
        foreach ($entry in @($inventory.files)) { $expectedHashes[[string]$entry.path] = [string]$entry.sha256 }
        if ($expectedHashes.Count -ne $files.Count) { throw 'Artifact digest inventory is incomplete.' }
    }
    $archives = @($files | Where-Object { [IO.Path]::GetExtension($_) -in @('.jar','.zip') })
    $entryCount = 0
    foreach ($path in $archives) {
        $archive = [IO.Compression.ZipFile]::OpenRead($path)
        try {
            $entryCount += $archive.Entries.Count
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName -match '(?i)(oidc-fixture|\.runtime/m19|(^|/)[^/]+\.(key|pem|p12|pfx)$|io/geordi/test/oidc/)') {
                    throw 'Publishable archive contains private or fixture implementation material.'
                }
            }
        } finally { $archive.Dispose() }
    }
    foreach ($path in $files) {
        $relative = $path.Substring($repositoryRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\','/')
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if (!$expectedHashes.ContainsKey($relative) -or $expectedHashes[$relative] -cne $actualHash) {
            throw 'Publishable artifact changed after the credential scan.'
        }
    }
    if (!$Independent -and ($inventory.artifactInventory -cne 'complete' -or [int]$inventory.fileCount -ne $files.Count -or
            [int]$inventory.archiveCount -ne $archives.Count -or [int]$inventory.archiveEntryCount -ne $entryCount)) {
        throw 'Publishable artifact inventory is incomplete or changed after scanning.'
    }
    Write-Output ("artifact_files={0} archives={1} archive_entries={2} result=PASS" -f $files.Count,$archives.Count,$entryCount)
} catch {
    throw 'Publishable credential artifact validation failed; private captures withheld.'
}
