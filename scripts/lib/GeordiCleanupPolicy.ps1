function Resolve-GeordiM19CleanupOutcome {
    [CmdletBinding()]
    param([int] $PrimaryExitCode, [int] $CleanupExitCode)

    $effectiveExitCode = if ($PrimaryExitCode -ne 0) { $PrimaryExitCode } else { $CleanupExitCode }
    [pscustomobject]@{
        PrimaryExitCode = $PrimaryExitCode
        CleanupExitCode = $CleanupExitCode
        EffectiveExitCode = $effectiveExitCode
        OriginalFailurePreserved = ($PrimaryExitCode -ne 0 -and $effectiveExitCode -eq $PrimaryExitCode)
    }
}

function Set-GeordiM19CleanupComposeInterpolation {
    [CmdletBinding()]
    param()

    $previous = @{}
    $fallbacks = @{
        GEORDI_M13_WEBHOOK_TOKEN_A = 'm19-cleanup-interpolation-only-a'
        GEORDI_M13_WEBHOOK_TOKEN_B = 'm19-cleanup-interpolation-only-b'
    }
    foreach ($name in $fallbacks.Keys) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        $previous[$name] = $value
        if ([string]::IsNullOrWhiteSpace($value)) {
            [Environment]::SetEnvironmentVariable($name, $fallbacks[$name], 'Process')
        }
    }
    return $previous
}

function Restore-GeordiM19CleanupComposeInterpolation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Previous)

    foreach ($name in @('GEORDI_M13_WEBHOOK_TOKEN_A','GEORDI_M13_WEBHOOK_TOKEN_B')) {
        [Environment]::SetEnvironmentVariable($name, $Previous[$name], 'Process')
    }
}
