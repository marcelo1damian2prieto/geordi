[CmdletBinding()]
param([string] $ConfigPath = (Join-Path $PSScriptRoot '..\otel\otel-collector-config.yaml'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw 'Collector security configuration is missing.'
}
$yaml = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
if ($yaml -notmatch '(?m)^  debug:\r?\n    verbosity: basic\r?$') {
    throw 'Collector debug exporter must use basic verbosity to avoid logging telemetry payload values.'
}
if ($yaml -notmatch '(?ms)^  attributes/security:\s*\r?\n(?<processor>.*?)(?=^  [A-Za-z0-9_/-]+:|\z)') {
    throw 'Collector security sanitizer processor is missing.'
}
$processor = $Matches.processor
foreach ($attribute in @(
        'url.full', 'url.query', 'url.path', 'http.target', 'http.url',
        'http.request.header.authorization', 'http.request.header.cookie',
        'http.response.header.set-cookie', 'exception.message', 'exception.stacktrace')) {
    if ($processor -notmatch "(?m)^\s*- \{key: $([regex]::Escape($attribute)), action: delete\}\s*$") {
        throw 'Collector security sanitizer deletion rules are incomplete.'
    }
}

if ($yaml -notmatch '(?ms)^  pipelines:\s*\r?\n(?<pipelines>.*)$') {
    throw 'Collector service pipelines are missing.'
}
$pipelines = $Matches.pipelines
foreach ($pipeline in @('traces', 'metrics', 'logs')) {
    $pattern = "(?ms)^    ${pipeline}:\s*\r?\n(?<body>.*?)(?=^    [A-Za-z0-9_-]+:\s*\r?\n|\z)"
    if ($pipelines -notmatch $pattern -or $Matches.body -notmatch '(?m)^      processors:\s*\[[^\r\n]*\battributes/security\b') {
        throw "Collector $pipeline pipeline is missing attributes/security before export."
    }
}

Write-Output 'Collector sanitizer configuration passed: traces, metrics and logs use attributes/security.'
