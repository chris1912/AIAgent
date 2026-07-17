# Deterministic fake agy CLI for offline tests.
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
if ($null -eq $Rest) { $Rest = @() }
$joined = ($Rest -join ' ')

function Write-MmoFakeArgv {
    param([string[]]$ArgsIn)
    $path = $env:MMO_FAKE_ARGV_PATH
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $argvObj = [pscustomobject]@{
        count = @($ArgsIn).Count
        argc = @($ArgsIn).Count
        args = @($ArgsIn)
        argv = @($ArgsIn)
        joined = ($ArgsIn -join ' ')
        recorded_at = [datetime]::UtcNow.ToString('o')
    }
    $dir = Split-Path -Parent -Path $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, (($argvObj | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine))
}

function Test-MmoFakeModelMatch {
    param([string]$JoinedArgs, [string]$NeedleList)
    if ([string]::IsNullOrWhiteSpace($NeedleList)) { return $false }
    foreach ($n in ($NeedleList -split ';')) {
        $t = $n.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($JoinedArgs -like ('*' + $t + '*')) { return $true }
    }
    return $false
}

Write-MmoFakeArgv -ArgsIn @($Rest)

if ($Rest -contains '--version' -or $Rest -contains 'version') {
    Write-Output '1.0.0-fake'
    exit 0
}

if ($Rest -contains 'models') {
    Write-Output 'Gemini 3.5 Flash (Medium)'
    Write-Output 'Gemini 3.5 Flash (High)'
    Write-Output 'Gemini 3.5 Flash (Low)'
    Write-Output 'Gemini 3.1 Pro (Low)'
    Write-Output 'Gemini 3.1 Pro (High)'
    Write-Output 'Claude Sonnet 4.6 (Thinking)'
    Write-Output 'Claude Opus 4.6 (Thinking)'
    Write-Output 'GPT-OSS 120B (Medium)'
    exit 0
}

if ($env:MMO_FAKE_AGY_MODE -eq 'quota' -or (
        -not [string]::IsNullOrWhiteSpace($env:MMO_FAKE_AGY_QUOTA_MODELS) -and
        (Test-MmoFakeModelMatch -JoinedArgs $joined -NeedleList $env:MMO_FAKE_AGY_QUOTA_MODELS)
    )) {
    [Console]::Error.WriteLine('Error: quota exhausted for selected model')
    exit 2
}
if ($env:MMO_FAKE_AGY_MODE -eq 'auth') {
    [Console]::Error.WriteLine('Error: authentication required')
    exit 3
}
if ($env:MMO_FAKE_AGY_MODE -eq 'model_unavailable' -or (
        -not [string]::IsNullOrWhiteSpace($env:MMO_FAKE_AGY_UNAVAILABLE_MODELS) -and
        (Test-MmoFakeModelMatch -JoinedArgs $joined -NeedleList $env:MMO_FAKE_AGY_UNAVAILABLE_MODELS)
    )) {
    [Console]::Error.WriteLine('Error: model unavailable: selected model')
    exit 4
}
if ($env:MMO_FAKE_AGY_MODE -eq 'network') {
    [Console]::Error.WriteLine('Error: network error: could not resolve host')
    exit 5
}

if ($env:MMO_FAKE_SLEEP_MS) {
    $ms = 0
    [void][int]::TryParse($env:MMO_FAKE_SLEEP_MS, [ref]$ms)
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
}

Write-Output "fake-agy ok args=$joined"
for ($i = 0; $i -lt $Rest.Count; $i++) {
    if ($Rest[$i] -eq '--print' -and ($i + 1) -lt $Rest.Count) {
        Write-Output ("fake-agy print-arg-length=" + $Rest[$i + 1].Length)
    }
}
exit 0
