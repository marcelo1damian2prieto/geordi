[CmdletBinding()]
param([switch] $SelfTest)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SelfTest) { throw 'Use -SelfTest to validate bounded cleanup outcome rules.' }
. (Join-Path $PSScriptRoot 'lib/GeordiCleanupPolicy.ps1')
. (Join-Path $PSScriptRoot 'lib/GeordiFinalizeAttempts.ps1')

$cases = @(
    @{ primary=0; cleanup=0; expected=0; preserved=$false },
    @{ primary=0; cleanup=1; expected=1; preserved=$false },
    @{ primary=1; cleanup=0; expected=1; preserved=$true },
    @{ primary=7; cleanup=1; expected=7; preserved=$true })
foreach ($case in $cases) {
    $result = Resolve-GeordiM19CleanupOutcome -PrimaryExitCode $case.primary -CleanupExitCode $case.cleanup
    if ($result.EffectiveExitCode -ne $case.expected -or $result.OriginalFailurePreserved -ne $case.preserved) {
        throw 'Cleanup result policy did not preserve the primary test outcome.'
    }
}
$cleanupSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Complete-GeordiM19Cleanup.ps1') -Raw
if ($cleanupSource -match '(?i)down[^\r\n]*-v(?:olumes)?\b') { throw 'Cleanup must preserve named M19 volumes.' }
if ($cleanupSource -notmatch 'if \(!\$BestEffort -and \$outcome\.EffectiveExitCode -ne 0\)') {
    throw 'Strict successful-path cleanup must fail the primary job.'
}
if ($cleanupSource -notmatch "'m19-capture-root\.txt'" -or
        $cleanupSource -notmatch '\$captureRoot -and !\(Test-Path -LiteralPath \$captureRoot\) -and !\(Test-Path -LiteralPath \$runtimeRoot\)' -or
        $cleanupSource -notmatch 'private capture cleanup blocked') {
    throw 'Capture recovery pointer must survive TLS cleanup and remain until captures are removed.'
}
if ($cleanupSource -notmatch "'m19-ca-thumbprint\.txt'" -or
        $cleanupSource -notmatch 'Cert:\\LocalMachine\\Root' -or
        $cleanupSource.IndexOf('Get-ChildItem Cert:\LocalMachine\Root') -gt
        $cleanupSource.IndexOf('Remove-Item -LiteralPath $publicThumbprintPath')) {
    throw 'Cleanup must query the exact retained CA thumbprint before deleting its public metadata.'
}
$tlsSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-GeordiTestTls.ps1') -Raw
if ($tlsSource -notmatch "m19-ca-thumbprint\.txt" -or
        $tlsSource -notmatch '\$publicThumbprintPath,\s*\$thumbprint') {
    throw 'LocalMachine bootstrap must retain the public thumbprint outside runtime TLS material.'
}
$evidenceSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-GeordiCredentialEvidence.ps1') -Raw
if ($evidenceSource -notmatch "'m19-capture-root\.txt'") { throw 'Evidence writer and cleanup recovery pointer disagree.' }
$ciSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\.gitlab-ci.yml') -Raw
if ($ciSource -notmatch '\.runtime/m19-capture-root\.txt' -or $ciSource -match '\.runtime/m19/capture-root\.txt') {
    throw 'CI browser evidence path does not match the private evidence root pointer.'
}
if ($cleanupSource.IndexOf('private capture cleanup blocked') -gt
        $cleanupSource.IndexOf('try { $dockerInventory = Get-GeordiDockerInventoryBounded }') -or
        $cleanupSource -notmatch '\.WaitForExit\(20000\)') {
    throw 'Private captures must be deleted before potentially slow Docker status checks.'
}
if ($cleanupSource -notmatch 'previous cleanup attempt may have removed captures' -or
        $cleanupSource -notmatch '\$captureRoot = \$candidate') {
    throw 'Cleanup must safely resume when a prior attempt removed captures but left the recovery pointer.'
}

if ($cleanupSource -match '(?i)down[^\r\n]*-v(?:olumes)?\b') { throw 'Cleanup must preserve named M19 volumes.' }
foreach ($volume in @('geordi_m19-alert-lifecycle-data','geordi_m19-victoriametrics-data')) {
    if ($cleanupSource -notmatch [regex]::Escape($volume)) { throw "Protected volume inventory is missing: $volume" }
}
if ($cleanupSource -notmatch 'Set-GeordiM19CleanupComposeInterpolation' -or
        $cleanupSource -notmatch 'Restore-GeordiM19CleanupComposeInterpolation') {
    throw 'Compose teardown must scope and restore interpolation placeholders.'
}
if ($cleanupSource -notmatch 'Get-ChildItem -LiteralPath \$captureRoot -File -Filter .+process\.json.+-Recurse' -or
        $cleanupSource -notmatch 'Remove-GeordiM19FinalizeAttempts -CaptureRoot \$captureRoot') {
    throw 'Cleanup must discover process records and remove every isolated Finalize attempt.'
}
$attemptTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('geordi-cleanup-attempt-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    $tempoSegmentRoot=Join-Path $attemptTestRoot 'finalize-attempts/00000000000000000000000000000001/tempo-segments'
    [void][IO.Directory]::CreateDirectory($tempoSegmentRoot)
    [IO.File]::WriteAllText((Join-Path $tempoSegmentRoot 'tempo-segment-0001.bin'),'synthetic-segment')
    $failedLokiAttempt=Join-Path $attemptTestRoot 'finalize-attempts/00000000000000000000000000000002'
    [void][IO.Directory]::CreateDirectory($failedLokiAttempt)
    [IO.File]::WriteAllText((Join-Path $failedLokiAttempt 'loki-query.json'),'private-response-fixture')
    [IO.File]::WriteAllText((Join-Path $failedLokiAttempt 'loki-validation.json'),'sanitized-validation-fixture')
    Remove-GeordiM19FinalizeAttempts -CaptureRoot $attemptTestRoot
    if ((Test-Path -LiteralPath (Join-Path $attemptTestRoot 'finalize-attempts')) -or
            (Test-Path -LiteralPath (Join-Path $attemptTestRoot 'finalize-attempts/00000000000000000000000000000001/tempo-segments/tempo-segment-0001.bin')) -or
            (Test-Path -LiteralPath (Join-Path $failedLokiAttempt 'loki-query.json')) -or
            (Test-Path -LiteralPath (Join-Path $failedLokiAttempt 'loki-validation.json'))) {
        throw 'Cleanup self-test left attempt-scoped Tempo or private Loki evidence behind.'
    }
} finally {
    if (Test-Path -LiteralPath $attemptTestRoot) { Remove-Item -LiteralPath $attemptTestRoot -Recurse -Force }
}

$root = Split-Path -Parent $PSScriptRoot
$composeFiles = @('--project-directory',$root,'--file',(Join-Path $root 'compose.yaml'),
    '--file',(Join-Path $root 'compose.m19.yaml'),'--file',(Join-Path $root 'compose.m14.yaml'))
$docker = (Get-Command docker.exe -ErrorAction Stop).Source
$originalA = [Environment]::GetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_A','Process')
$originalB = [Environment]::GetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_B','Process')
try {
    [Environment]::SetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_A',$null,'Process')
    [Environment]::SetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_B',$null,'Process')
    $previous = Set-GeordiM19CleanupComposeInterpolation
    try {
        if ($env:GEORDI_M13_WEBHOOK_TOKEN_A -cne 'm19-cleanup-interpolation-only-a' -or
                $env:GEORDI_M13_WEBHOOK_TOKEN_B -cne 'm19-cleanup-interpolation-only-b') {
            throw 'Absent M13 cleanup interpolation variables did not receive synthetic values.'
        }
        & $docker compose @composeFiles config --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Compose cleanup overlay did not render with absent M13 variables.' }
    } finally { Restore-GeordiM19CleanupComposeInterpolation -Previous $previous }
    if ($env:GEORDI_M13_WEBHOOK_TOKEN_A -or $env:GEORDI_M13_WEBHOOK_TOKEN_B) {
        throw 'Synthetic cleanup values remained in the process environment after restoration.'
    }

    [Environment]::SetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_A','selftest-existing-a','Process')
    [Environment]::SetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_B','selftest-existing-b','Process')
    $previous = Set-GeordiM19CleanupComposeInterpolation
    try {
        if ($env:GEORDI_M13_WEBHOOK_TOKEN_A -cne 'selftest-existing-a' -or
                $env:GEORDI_M13_WEBHOOK_TOKEN_B -cne 'selftest-existing-b') {
            throw 'Existing M13 values were overwritten by cleanup interpolation.'
        }
        & $docker compose @composeFiles config --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Compose cleanup overlay did not render with existing M13 variables.' }
    } finally { Restore-GeordiM19CleanupComposeInterpolation -Previous $previous }
} finally {
    [Environment]::SetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_A',$originalA,'Process')
    [Environment]::SetEnvironmentVariable('GEORDI_M13_WEBHOOK_TOKEN_B',$originalB,'Process')
}

Write-Output 'cleanup_case=4_primary_cleanup_combinations result=PASS interpolation_absent=PASS interpolation_existing=PASS placeholders_restored=PASS attempts=removed volumes=preserved capture_retry=preserved exact_thumbprint_postcheck=PASS'
