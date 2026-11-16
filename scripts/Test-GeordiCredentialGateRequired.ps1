[CmdletBinding()]
param(
    [string] $ManifestPath,
    [string] $SummaryPath = (Join-Path $PSScriptRoot '..\backend\target\.m19-evidence-gate-summary.txt'),
    [switch] $DiagnosticFailure
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeRoot = Join-Path $repositoryRoot '.runtime/m19'
$pointerPath = Join-Path (Join-Path $repositoryRoot '.runtime') 'm19-capture-root.txt'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$stage = 'manifest'

try {
    if (!$ManifestPath -and !(Test-Path -LiteralPath $pointerPath -PathType Leaf)) { throw 'Evidence root pointer missing.' }
    $captureRoot = if ($ManifestPath) {
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath))
    } else { [IO.Path]::GetFullPath([IO.File]::ReadAllText($pointerPath).Trim()) }
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($captureRoot) -cne $expectedParent -or
            (Split-Path $captureRoot -Leaf) -notmatch '^geordi-m19-capture-[A-Za-z0-9-]+-[0-9a-f]{32}$') {
        throw 'Evidence root pointer invalid.'
    }
    $stage = 'root validation'
    $rootItem = Get-Item -LiteralPath $captureRoot -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Evidence root must be private and non-redirected.' }
    $manifestPath = if ($ManifestPath) { [IO.Path]::GetFullPath($ManifestPath) } else { Join-Path $captureRoot 'manifest.json' }
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Evidence manifest missing.' }
    $stage = 'manifest path validation'
    if ([IO.Path]::GetDirectoryName($manifestPath) -cne $captureRoot) { throw 'Evidence manifest escaped its private root.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $stage = 'manifest schema validation'
    if ($manifest.version -ne 2 -or $manifest.root -cne $captureRoot -or !$manifest.completedUtc -or
            @($manifest.sentinels).Count -eq 0 -or !$manifest.captures -or !$manifest.controls -or
            !$manifest.captureMetadata -or !$manifest.captureMetadata.ContainsKey('otel') -or
            !$manifest.captureMetadata.ContainsKey('collector')) {
        throw 'Evidence manifest malformed or incomplete.'
    }
    $stage = 'accepted attempt validation'
    if (!$manifest.acceptedAttemptId -or !$manifest.attempts -or
            !$manifest.attempts.ContainsKey([string]$manifest.acceptedAttemptId) -or
            @($manifest.attempts.Values | Where-Object { [string]$_.status -ceq 'completed' }).Count -ne 1) {
        throw 'Evidence manifest must identify exactly one completed Finalize attempt.'
    }
    $acceptedAttempt = $manifest.attempts[[string]$manifest.acceptedAttemptId]
    $expectedAttemptRoot = Join-Path (Join-Path $captureRoot 'finalize-attempts') ([string]$manifest.acceptedAttemptId)
    if ([string]$acceptedAttempt.attemptId -cne [string]$manifest.acceptedAttemptId -or
            [string]$acceptedAttempt.status -cne 'completed' -or
            [string]$acceptedAttempt.completedUtc -cne [string]$manifest.completedUtc -or
            [IO.Path]::GetFullPath([string]$acceptedAttempt.root) -cne [IO.Path]::GetFullPath($expectedAttemptRoot) -or
            !$acceptedAttempt.phases.Contains('manifest') -or
            [string]$acceptedAttempt.phases.manifest.status -cne 'PASS') {
        throw 'Accepted Finalize attempt metadata is inconsistent.'
    }
    foreach ($requiredPhase in @('tempo-search','tempo-detail','loki','victoriametrics','artifact-scan','manifest')) {
        if (!$acceptedAttempt.phases.Contains($requiredPhase) -or
                [string]$acceptedAttempt.phases[$requiredPhase].status -cne 'PASS') {
            throw 'Accepted Finalize attempt is missing a required successful phase.'
        }
    }
    foreach ($field in @('controls','captures','captureMetadata')) {
        if ((ConvertTo-Json -InputObject $acceptedAttempt.channels[$field] -Depth 24 -Compress) -cne
                (ConvertTo-Json -InputObject $manifest[$field] -Depth 24 -Compress)) {
            throw 'Accepted Finalize channel state does not match the published manifest.'
        }
    }
    $acceptedSourcesJson = ConvertTo-Json -InputObject @($acceptedAttempt.additionalSources) -Depth 24 -Compress
    $publishedSourcesJson = ConvertTo-Json -InputObject @($manifest.additionalSources) -Depth 24 -Compress
    $sourceChannels = @($manifest.additionalSources | ForEach-Object { [string]$_.channel })
    if ($acceptedSourcesJson -cne $publishedSourcesJson -or
            @($sourceChannels | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
        throw 'Accepted persisted-source metadata is duplicated or differs from its published attempt.'
    }
    $requiredChannels = @('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo','ci-artifacts')
    foreach ($channel in $requiredChannels) {
        $stage = "channel inventory validation ($channel)"
        if (!$manifest.captures.ContainsKey($channel) -or !$manifest.controls.ContainsKey($channel) -or
                @($manifest.captures[$channel]).Count -eq 0 -or $manifest.controls[$channel].Length -lt 8) {
            throw 'Required channel or positive control missing.'
        }
    }
    $privateChannels = @('browser','nginx-access','nginx-error','backend','problems','otel','collector','tempo')
    $stage = 'private capture paths'
    foreach ($channel in $privateChannels) {
        foreach ($path in @($manifest.captures[$channel])) {
            $full = [IO.Path]::GetFullPath([string]$path)
            if (![IO.Path]::IsPathRooted([string]$path) -or
                    !($full.StartsWith($captureRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))) {
                throw 'Runtime capture escaped its private root.'
            }
        }
    }
    $stage = 'persisted capture paths'
    foreach ($source in @($manifest.additionalSources)) {
        foreach ($path in @($source.captures)) {
            $full = [IO.Path]::GetFullPath([string]$path)
            if (!$full.StartsWith($captureRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Persisted-source capture escaped its private root.'
            }
        }
    }

    $stage = 'runtime scanner'
    $scannerOutput = @(& (Join-Path $PSScriptRoot 'Test-GeordiCredentialLeaks.ps1') -ManifestPath $manifestPath)
    $expectedScannedChannels = @($requiredChannels) + @('loki','victoriametrics')
    $scannedChannels = [Collections.Generic.List[string]]::new()
    foreach ($line in $scannerOutput) {
        if ([string]$line -notmatch '^channel=([a-z-]+) positive_control=True raw_matches=0 encoded_matches=0 result=PASS$') {
            throw 'Runtime credential scanner failed.'
        }
        $scannedChannels.Add($Matches[1])
    }
    if ($scannedChannels.Count -ne $expectedScannedChannels.Count -or
            @($expectedScannedChannels | Where-Object { $scannedChannels -cnotcontains $_ }).Count -gt 0 -or
            @($scannedChannels | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
        throw 'Runtime credential scanner channel inventory was incomplete.'
    }
    $stage = 'persisted sources'
    $persistedOutput = @(& (Join-Path $PSScriptRoot 'Test-GeordiPersistedCredentialEvidence.ps1') -ManifestPath $manifestPath)
    if ($persistedOutput.Count -ne 2) { throw 'Persisted-source validation failed.' }
    [IO.File]::WriteAllLines($SummaryPath, [string[]]@($scannerOutput) + [string[]]@($persistedOutput), [Text.UTF8Encoding]::new($false))
    $stopwatch.Stop()
    Write-Output ($scannerOutput + $persistedOutput)
    Write-Output ("required_credential_gate_seconds={0:N2} result=PASS" -f $stopwatch.Elapsed.TotalSeconds)
} catch {
    if ($DiagnosticFailure) { throw "Required M19 credential evidence gate failed at stage=$stage." }
    throw 'Required M19 credential evidence gate failed; private captures withheld.'
}
