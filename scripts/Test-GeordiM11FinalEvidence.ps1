[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to exercise immutable M11 final metric evidence publication.' }
. (Join-Path $PSScriptRoot 'lib/GeordiPersistedMetricEvidence.ps1')

function Assert-M11Final([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw "M11 final evidence regression failed: $Message" }
}
function Get-Sha256([string] $Path) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path)))
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('geordi-m11-final-evidence-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $snapshotDirectory = Join-Path $root 'victoriametrics-generations'
    [void][IO.Directory]::CreateDirectory($snapshotDirectory)
    $snapshotPath = Join-Path $snapshotDirectory 'm11-final.jsonl'
    $ledgerPath = Join-Path $snapshotDirectory 'm11-final.snapshot.json'
    $captureStarted = [DateTimeOffset]::UtcNow.AddSeconds(-2)
    $completed = [DateTimeOffset]::UtcNow.AddSeconds(1)
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $control = 'geordi.security.authentication.attempts_total'
    $sample = @{ metric = @{ '__name__' = $control; 'service.name' = 'geordi-backend'; 'geordi.telemetry.origin' = 'platform' };
        values = @('1'); timestamps = @($stamp) } | ConvertTo-Json -Compress -Depth 8
    $lokiPath = Join-Path $root 'loki.json'
    $loki = @{ status = 'success'; data = @{ result = @(@{stream = @{app='geordi-backend'}; values=@(@('1','geordi.security.authentication.attempts'))}) } } |
        ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllText($lokiPath, $loki, [Text.UTF8Encoding]::new($false))

    $manifest = [ordered]@{ captureStartedUtc = $captureStarted.ToString('o'); completedUtc = $completed.ToString('o');
        additionalSources = @(@{channel='loki';control='geordi.security.authentication.attempts';captures=@($lokiPath)},
            @{channel='victoriametrics';control=$control;captures=@()}); persistedMetricEvidenceBytes=0 }
    Assert-GeordiPersistedMetricPhaseAvailable -Phase 'm11-final' -SnapshotPath $snapshotPath -LedgerPath $ledgerPath -Manifest $manifest

    $snapshotTemporary = "$snapshotPath.first.tmp"
    $ledgerTemporary = "$ledgerPath.first.tmp"
    [IO.File]::WriteAllText($snapshotTemporary, $sample, [Text.UTF8Encoding]::new($false))
    $snapshotBytes = [long](Get-Item -LiteralPath $snapshotTemporary).Length
    [void](Complete-GeordiPersistedMetricSnapshotFile -TemporaryPath $snapshotTemporary -SnapshotPath $snapshotPath -Bytes $snapshotBytes -CreateNew)
    $ledger = @{intervalStartUtc=$captureStarted.ToString('o');intervalEndUtc=$completed.ToString('o');source='victoriametrics-export';complete=$true;
        runStartBound=$true;series=1;samples=1;bytes=$snapshotBytes}
    Add-GeordiPersistedMetricArtifactBinding -Ledger $ledger -Source 'victoriametrics-export' `
        -SourceIdentity @{sourceService='victoriametrics';sourceContainerId=('b' * 64)} -SnapshotTemporaryPath $snapshotPath -Bytes $snapshotBytes
    [IO.File]::WriteAllText($ledgerTemporary, ($ledger | ConvertTo-Json -Compress -Depth 5), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($ledgerTemporary, $ledgerPath)
    $manifest.additionalSources[1].captures = @($snapshotPath, $ledgerPath)
    $manifest.persistedMetricEvidenceBytes = [long](Get-Item -LiteralPath $snapshotPath).Length + [long](Get-Item -LiteralPath $ledgerPath).Length
    Write-Output 'm11_final_first_publication=PASS create_new_snapshot=true create_new_ledger=true'

    $snapshotHashBefore = Get-Sha256 $snapshotPath
    $ledgerHashBefore = Get-Sha256 $ledgerPath
    $snapshotLengthBefore = [long](Get-Item -LiteralPath $snapshotPath).Length
    $ledgerLengthBefore = [long](Get-Item -LiteralPath $ledgerPath).Length
    $referencesBefore = ConvertTo-Json -InputObject @($manifest.additionalSources[1].captures) -Compress
    $secondRejected = $false
    try { Assert-GeordiPersistedMetricPhaseAvailable -Phase 'm11-final' -SnapshotPath $snapshotPath -LedgerPath $ledgerPath -Manifest $manifest }
    catch { $secondRejected = $_.Exception.Message -like '*already*' }
    Assert-M11Final $secondRejected 'second authoritative publication was not rejected'
    $priorEvidenceUnchanged = (Get-Sha256 $snapshotPath) -ceq $snapshotHashBefore -and
        (Get-Sha256 $ledgerPath) -ceq $ledgerHashBefore -and
        [long](Get-Item -LiteralPath $snapshotPath).Length -eq $snapshotLengthBefore -and
        [long](Get-Item -LiteralPath $ledgerPath).Length -eq $ledgerLengthBefore -and
        (ConvertTo-Json -InputObject @($manifest.additionalSources[1].captures) -Compress) -ceq $referencesBefore
    Assert-M11Final $priorEvidenceUnchanged 'rejected second publication changed prior evidence or manifest references'
    Write-Output 'm11_final_second_publication=PASS historical_hashes_bytes_and_manifest_references_unchanged=true'

    $manifestOnlyPath = Join-Path $snapshotDirectory 'manifest-only.jsonl'
    $manifestOnlyLedger = Join-Path $snapshotDirectory 'manifest-only.snapshot.json'
    $manifestOnly = @{additionalSources=@(@{channel='victoriametrics';captures=@($manifestOnlyPath)})}
    $manifestReferenceRejected = $false
    try { Assert-GeordiPersistedMetricPhaseAvailable -Phase 'm11-final' -SnapshotPath $manifestOnlyPath -LedgerPath $manifestOnlyLedger -Manifest $manifestOnly }
    catch { $manifestReferenceRejected = $_.Exception.Message -like '*referenced*' }
    Assert-M11Final $manifestReferenceRejected 'manifest-referenced destination was not rejected before publication'
    Assert-M11Final (!(Test-Path -LiteralPath $manifestOnlyPath) -and !(Test-Path -LiteralPath $manifestOnlyLedger)) 'manifest-reference preflight created evidence files'
    Write-Output 'm11_final_manifest_reference_preflight=PASS'

    $occupiedPath = Join-Path $snapshotDirectory 'occupied.jsonl'
    $occupiedLedger = Join-Path $snapshotDirectory 'occupied.snapshot.json'
    [IO.File]::WriteAllText($occupiedPath, 'preserve', [Text.UTF8Encoding]::new($false))
    $occupiedHash = Get-Sha256 $occupiedPath
    $occupiedRejected = $false
    try { Assert-GeordiPersistedMetricPhaseAvailable -Phase 'm11-final' -SnapshotPath $occupiedPath -LedgerPath $occupiedLedger -Manifest @{additionalSources=@()} }
    catch { $occupiedRejected = $_.Exception.Message -like '*occupied*' }
    Assert-M11Final ($occupiedRejected -and (Get-Sha256 $occupiedPath) -ceq $occupiedHash -and !(Test-Path -LiteralPath $occupiedLedger)) `
        'physically occupied destination was not rejected immutably'
    Write-Output 'm11_final_physical_path_preflight=PASS'

    $sourcePath = Join-Path $PSScriptRoot 'verify-notification-delivery.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
    Assert-M11Final ($parseErrors.Count -eq 0) 'M11 production script did not parse for the AST contract'
    $captureCalls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match 'Capture-GeordiM19Generation\.ps1' -and $node.Extent.Text -match '-Phase\s+m11-final' }, $true))
    Assert-M11Final ($captureCalls.Count -eq 1) 'normal M11 path must contain exactly one authoritative m11-final capture call'
    $cleanupFunction = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Remove-M11Fixture' }, $true))[0]
    Assert-M11Final ($null -ne $cleanupFunction -and @($cleanupFunction.Body.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match 'Capture-GeordiM19Generation\.ps1' }, $true)).Count -eq 0) 'M11 cleanup performs evidence capture'

    $text = [IO.File]::ReadAllText($sourcePath)
    $captureAt = $text.IndexOf("-Phase m11-final -Services backend,victoriametrics -SkipLogSnapshot", [StringComparison]::Ordinal)
    $secretAssertionAt = $text.IndexOf("Notification secret leaked through runtime logs.", [StringComparison]::Ordinal)
    $successAt = $text.IndexOf("Write-Host 'PASS: atomic STARTED/RESOLVED", [StringComparison]::Ordinal)
    $exitAt = $text.IndexOf('    exit 0', $successAt, [StringComparison]::Ordinal)
    $finallyAt = $text.IndexOf('finally {', $successAt, [StringComparison]::Ordinal)
    Assert-M11Final ($captureAt -gt $secretAssertionAt -and $captureAt -lt $successAt -and $successAt -lt $exitAt -and $exitAt -lt $finallyAt) `
        'authoritative M11 final capture is not after success assertions and before successful exit/cleanup'
    Write-Output 'm11_final_ast_contract=PASS single_success_path_call=true cleanup_capture=false success_order=true'

    $validatorManifest = Join-Path $root 'manifest.json'
    [IO.File]::WriteAllText($validatorManifest, (ConvertTo-Json -InputObject $manifest -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot 'Test-GeordiPersistedCredentialEvidence.ps1') -ManifestPath $validatorManifest
    Write-Output 'm11_final_persisted_evidence_validator=PASS'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $expected = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $expected -or (Split-Path $resolved -Leaf) -notmatch '^geordi-m11-final-evidence-[0-9a-f]{32}$') {
        throw 'Unsafe M11 final evidence self-test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    if (Test-Path -LiteralPath $resolved) { throw 'M11 final evidence self-test cleanup did not remove its synthetic root.' }
    Write-Output 'm11_final_synthetic_cleanup=PASS'
}
