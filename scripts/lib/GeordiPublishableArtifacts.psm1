Set-StrictMode -Version Latest

$script:GeordiArtifactForbiddenEntryPattern = '(?i)(oidc-fixture|\.runtime/m19|(^|/)[^/]+\.(key|pem|p12|pfx)$|io/geordi/test/oidc/)'
$script:GeordiArtifactMaximumArchiveEntries = 131072

function Resolve-GeordiArtifactRoot {
    param([Parameter(Mandatory)][string] $RootPath)

    $fullRoot = [IO.Path]::GetFullPath($RootPath)
    if (!(Test-Path -LiteralPath $fullRoot -PathType Container)) {
        throw 'root_path_rejected'
    }
    $rootItem = Get-Item -LiteralPath $fullRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'root_path_rejected'
    }
    return $fullRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Get-GeordiArtifactRelativePath {
    param([Parameter(Mandatory)][string] $Root,[Parameter(Mandatory)][string] $FullPath)

    $full = [IO.Path]::GetFullPath($FullPath)
    $prefix = $Root + [IO.Path]::DirectorySeparatorChar
    if (!$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'root_path_rejected'
    }
    $relative = $full.Substring($prefix.Length).Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or
        $relative -match '(^|/)\.\.?(/|$)' -or $relative -match '^[A-Za-z]:') {
        throw 'inventory_invalid'
    }
    return $relative
}

function Assert-GeordiArtifactPathChain {
    param([Parameter(Mandatory)][string] $Root,[Parameter(Mandatory)][string] $FullPath)

    $relative = Get-GeordiArtifactRelativePath -Root $Root -FullPath $FullPath
    $current = $Root
    foreach ($segment in @($relative.Split('/'))) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'root_path_rejected'
            }
        }
    }
}

function Get-GeordiArtifactFilesUnderDirectory {
    param([Parameter(Mandatory)][string] $Root,[Parameter(Mandatory)][string] $DirectoryPath)

    $files = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($DirectoryPath)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentFull = [IO.Path]::GetFullPath($current)
        [void](Get-GeordiArtifactRelativePath -Root $Root -FullPath $currentFull)
        foreach ($entryPath in [IO.Directory]::EnumerateFileSystemEntries($currentFull)) {
            $attributes = [IO.File]::GetAttributes($entryPath)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'root_path_rejected'
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($entryPath)
            } else {
                [void](Get-GeordiArtifactRelativePath -Root $Root -FullPath $entryPath)
                $files.Add([IO.Path]::GetFullPath($entryPath))
            }
        }
    }
    return $files.ToArray()
}

function Get-GeordiArtifactSha256 {
    param([Parameter(Mandatory)][string] $Path)

    $before = Get-Item -LiteralPath $Path -Force
    if (($before.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'root_path_rejected'
    }
    $initialLength = [long]$before.Length
    $initialWriteTicks = $before.LastWriteTimeUtc.Ticks
    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = $sha.ComputeHash($stream)
        if ($stream.Length -ne $initialLength) {
            throw 'artifact_digest_mismatch'
        }
    } finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
    $after = Get-Item -LiteralPath $Path -Force
    if (($after.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [long]$after.Length -ne $initialLength -or
        $after.LastWriteTimeUtc.Ticks -ne $initialWriteTicks) {
        throw 'artifact_digest_mismatch'
    }
    return ([BitConverter]::ToString($digest)).Replace('-','').ToLowerInvariant()
}

function Get-GeordiArtifactArchiveEntryCount {
    param([Parameter(Mandatory)][string] $Path)

    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        return [long]$archive.Entries.Count
    } catch {
        throw 'archive_invalid'
    } finally {
        if ($archive) { $archive.Dispose() }
    }
}

function Get-GeordiPublishableArtifactInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [ValidateSet('Production','SelfTest')][string] $Mode = 'Production'
    )

    try {
        $root = Resolve-GeordiArtifactRoot -RootPath $RootPath
        $definitions = @(
            @{ path='backend/target/surefire-reports'; required=$true; directory=$true },
            @{ path='backend/target/pmd.xml'; required=$true; directory=$false },
            @{ path='backend/target/spotbugsXml.xml'; required=$true; directory=$false },
            @{ path='backend/target/geordi-backend-0.1.0-SNAPSHOT.jar'; required=$true; directory=$false },
            @{ path='backend/target/geordi-backend-0.1.0-SNAPSHOT-security-telemetry.jar'; required=$true; directory=$false },
            @{ path='backend/.ci-artifact/application.jar'; required=$false; directory=$false },
            @{ path='backend/.ci-artifact/security-telemetry.jar'; required=$false; directory=$false },
            @{ path='backend/target/verified-artifact.properties'; required=$true; directory=$false },
            @{ path='frontend/dist'; required=$true; directory=$true },
            @{ path='backend/target/failsafe-reports'; required=$false; directory=$true }
        )
        $allFiles = [Collections.Generic.List[string]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($definition in $definitions) {
            $candidate = [IO.Path]::GetFullPath((Join-Path $root ([string]$definition.path)))
            [void](Get-GeordiArtifactRelativePath -Root $root -FullPath $candidate)
            Assert-GeordiArtifactPathChain -Root $root -FullPath $candidate
            if (!(Test-Path -LiteralPath $candidate)) {
                if ($definition.required) { throw 'artifact_missing' }
                continue
            }
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'root_path_rejected'
            }
            if ([bool]$item.PSIsContainer -ne [bool]$definition.directory) {
                throw 'inventory_invalid'
            }
            $found = if ($definition.directory) {
                @(Get-GeordiArtifactFilesUnderDirectory -Root $root -DirectoryPath $candidate)
            } else {
                @($candidate)
            }
            foreach ($file in $found) {
                $relative = Get-GeordiArtifactRelativePath -Root $root -FullPath $file
                if (!$seen.Add($relative)) { throw 'inventory_invalid' }
                $allFiles.Add($file)
            }
        }

        $entries = [Collections.Generic.List[object]]::new()
        $archiveCount = 0
        $archiveEntryCount = 0L
        foreach ($file in @($allFiles.ToArray() | Sort-Object)) {
            $relative = Get-GeordiArtifactRelativePath -Root $root -FullPath $file
            $digest = Get-GeordiArtifactSha256 -Path $file
            $extension = [IO.Path]::GetExtension($file)
            if ($extension -in @('.jar','.zip')) {
                $archiveCount++
                $archiveEntryCount += Get-GeordiArtifactArchiveEntryCount -Path $file
                if ($archiveEntryCount -gt $script:GeordiArtifactMaximumArchiveEntries) {
                    throw 'scan_limit_exceeded'
                }
            }
            $entries.Add([ordered]@{ path=$relative; sha256=$digest })
        }
        return [ordered]@{
            artifactInventory='complete'
            fileCount=$entries.Count
            archiveCount=$archiveCount
            archiveEntryCount=$archiveEntryCount
            files=@($entries.ToArray())
        }
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -in @('artifact_missing','inventory_invalid','artifact_digest_mismatch','archive_invalid',
                'root_path_rejected','scan_limit_exceeded')) { throw $message }
        throw 'artifact_validation_failed'
    }
}

function Test-GeordiPublishableArtifactInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)][object] $ExpectedInventory,
        [ValidateSet('Production','SelfTest')][string] $Mode = 'Production'
    )

    try {
        $expected = if ($ExpectedInventory -is [System.Collections.IDictionary]) {
            $ExpectedInventory
        } else {
            ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $ExpectedInventory -Depth 16 -Compress) -AsHashtable
        }
        if ($expected.artifactInventory -cne 'complete' -or $null -eq $expected.files -or
            [int]$expected.fileCount -ne @($expected.files).Count) {
            throw 'inventory_invalid'
        }
        $expectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in @($expected.files)) {
            $path = [string]$entry.path
            if ([string]::IsNullOrWhiteSpace($path) -or $path.StartsWith('/') -or $path.Contains([char]92) -or
                $path.Contains([char]0) -or $path -match '(^|/)\.\.?(/|$)' -or $path -match '//' -or
                $path.EndsWith('/') -or $path -match '^[A-Za-z]:' -or
                [string]$entry.sha256 -notmatch '^[0-9a-f]{64}$' -or !$expectedPaths.Add($path)) {
                throw 'inventory_invalid'
            }
        }
        $actual = Get-GeordiPublishableArtifactInventory -RootPath $RootPath -Mode $Mode
        if ([int]$actual.fileCount -ne [int]$expected.fileCount -or
            [int]$actual.archiveCount -ne [int]$expected.archiveCount -or
            [long]$actual.archiveEntryCount -ne [long]$expected.archiveEntryCount -or
            @($actual.files).Count -ne @($expected.files).Count) {
            throw 'inventory_invalid'
        }
        $expectedByPath = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($entry in @($expected.files)) { $expectedByPath.Add([string]$entry.path,[string]$entry.sha256) }
        foreach ($entry in @($actual.files)) {
            if (!$expectedByPath.ContainsKey([string]$entry.path) -or
                $expectedByPath[[string]$entry.path] -cne [string]$entry.sha256) {
                throw 'artifact_digest_mismatch'
            }
        }
        return $actual
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -in @('artifact_missing','inventory_invalid','artifact_digest_mismatch','archive_invalid',
                'root_path_rejected','scan_limit_exceeded')) { throw $message }
        throw 'artifact_validation_failed'
    }
}

function Test-GeordiPublishableArtifactContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)][object] $Inventory,
        [ValidateSet('Production','SelfTest')][string] $Mode = 'Production'
    )

    try {
        $root = Resolve-GeordiArtifactRoot -RootPath $RootPath
        $before = Test-GeordiPublishableArtifactInventory -RootPath $root -ExpectedInventory $Inventory -Mode $Mode
        $entryCount = 0L
        foreach ($entry in @($before.files)) {
            $relative = [string]$entry.path
            if ([IO.Path]::GetExtension($relative) -notin @('.jar','.zip')) { continue }
            $path = [IO.Path]::GetFullPath((Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            [void](Get-GeordiArtifactRelativePath -Root $root -FullPath $path)
            $archive = $null
            try {
                $archive = [IO.Compression.ZipFile]::OpenRead($path)
                foreach ($archiveEntry in $archive.Entries) {
                    $entryCount++
                    if ($entryCount -gt $script:GeordiArtifactMaximumArchiveEntries) { throw 'scan_limit_exceeded' }
                    $name = ([string]$archiveEntry.FullName).Replace('\','/')
                    $unixEntryType = (([long]$archiveEntry.ExternalAttributes -shr 16) -band 0xF000)
                    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains([char]0) -or $name.StartsWith('/') -or
                        $name -match '^[A-Za-z]:' -or $name -match '(^|/)\.\.?(/|$)' -or
                        $unixEntryType -eq 0xA000 -or $name -match $script:GeordiArtifactForbiddenEntryPattern) {
                        throw 'forbidden_material_detected'
                    }
                }
            } catch {
                if ([string]$_.Exception.Message -in @('scan_limit_exceeded','forbidden_material_detected')) { throw }
                throw 'archive_invalid'
            } finally {
                if ($archive) { $archive.Dispose() }
            }
        }
        if ($entryCount -ne [long]$before.archiveEntryCount) { throw 'inventory_invalid' }
        $after = Test-GeordiPublishableArtifactInventory -RootPath $root -ExpectedInventory $Inventory -Mode $Mode
        if ((ConvertTo-Json -InputObject $before -Depth 16 -Compress) -cne
            (ConvertTo-Json -InputObject $after -Depth 16 -Compress)) {
            throw 'artifact_digest_mismatch'
        }
        return $after
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -in @('artifact_missing','inventory_invalid','artifact_digest_mismatch','archive_invalid',
                'forbidden_material_detected','root_path_rejected','scan_limit_exceeded')) { throw $message }
        throw 'artifact_validation_failed'
    }
}

Export-ModuleMember -Function Get-GeordiPublishableArtifactInventory,Test-GeordiPublishableArtifactInventory,Test-GeordiPublishableArtifactContent
 -or !$expectedPaths.Add($path)) {
                throw 'inventory_invalid'
            }
        }
        $actual = Get-GeordiPublishableArtifactInventory -RootPath $RootPath -Mode $Mode
        if ([int]$actual.fileCount -ne [int]$expected.fileCount -or
            [int]$actual.archiveCount -ne [int]$expected.archiveCount -or
            [long]$actual.archiveEntryCount -ne [long]$expected.archiveEntryCount -or
            @($actual.files).Count -ne @($expected.files).Count) {
            throw 'inventory_invalid'
        }
        $expectedByPath = @{}
        foreach ($entry in @($expected.files)) { $expectedByPath[[string]$entry.path] = [string]$entry.sha256 }
        foreach ($entry in @($actual.files)) {
            if (!$expectedByPath.ContainsKey([string]$entry.path) -or
                $expectedByPath[[string]$entry.path] -cne [string]$entry.sha256) {
                throw 'artifact_digest_mismatch'
            }
        }
        return $actual
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -in @('artifact_missing','inventory_invalid','artifact_digest_mismatch','archive_invalid',
                'root_path_rejected','scan_limit_exceeded')) { throw $message }
        throw 'artifact_validation_failed'
    }
}

function Test-GeordiPublishableArtifactContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)][object] $Inventory,
        [ValidateSet('Production','SelfTest')][string] $Mode = 'Production'
    )

    try {
        $root = Resolve-GeordiArtifactRoot -RootPath $RootPath
        $before = Test-GeordiPublishableArtifactInventory -RootPath $root -ExpectedInventory $Inventory -Mode $Mode
        $entryCount = 0L
        foreach ($entry in @($before.files)) {
            $relative = [string]$entry.path
            if ([IO.Path]::GetExtension($relative) -notin @('.jar','.zip')) { continue }
            $path = [IO.Path]::GetFullPath((Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            [void](Get-GeordiArtifactRelativePath -Root $root -FullPath $path)
            $archive = $null
            try {
                $archive = [IO.Compression.ZipFile]::OpenRead($path)
                foreach ($archiveEntry in $archive.Entries) {
                    $entryCount++
                    if ($entryCount -gt $script:GeordiArtifactMaximumArchiveEntries) { throw 'scan_limit_exceeded' }
                    $name = ([string]$archiveEntry.FullName).Replace('\','/')
                    $unixEntryType = (([long]$archiveEntry.ExternalAttributes -shr 16) -band 0xF000)
                    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains([char]0) -or $name.StartsWith('/') -or
                        $name -match '^[A-Za-z]:' -or $name -match '(^|/)\.\.?(/|$)' -or
                        $unixEntryType -eq 0xA000 -or $name -match $script:GeordiArtifactForbiddenEntryPattern) {
                        throw 'forbidden_material_detected'
                    }
                }
            } catch {
                if ([string]$_.Exception.Message -in @('scan_limit_exceeded','forbidden_material_detected')) { throw }
                throw 'archive_invalid'
            } finally {
                if ($archive) { $archive.Dispose() }
            }
        }
        if ($entryCount -ne [long]$before.archiveEntryCount) { throw 'inventory_invalid' }
        $after = Test-GeordiPublishableArtifactInventory -RootPath $root -ExpectedInventory $Inventory -Mode $Mode
        if ((ConvertTo-Json -InputObject $before -Depth 16 -Compress) -cne
            (ConvertTo-Json -InputObject $after -Depth 16 -Compress)) {
            throw 'artifact_digest_mismatch'
        }
        return $after
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -in @('artifact_missing','inventory_invalid','artifact_digest_mismatch','archive_invalid',
                'forbidden_material_detected','root_path_rejected','scan_limit_exceeded')) { throw $message }
        throw 'artifact_validation_failed'
    }
}

Export-ModuleMember -Function Get-GeordiPublishableArtifactInventory,Test-GeordiPublishableArtifactInventory,Test-GeordiPublishableArtifactContent
