# Deterministic fake grok CLI for offline tests.
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
if ($null -eq $Rest) { $Rest = @() }
$joined = ($Rest -join ' ')

# Optional argv capture for escaping/regression tests.
if (-not [string]::IsNullOrWhiteSpace($env:MMO_FAKE_ARGV_PATH)) {
    $argvObj = [pscustomobject]@{
        argv = @($Rest)
        args = @($Rest)
        argc = @($Rest).Count
        count = @($Rest).Count
        joined = $joined
        recorded_at = [datetime]::UtcNow.ToString('o')
    }
    $json = $argvObj | ConvertTo-Json -Compress -Depth 5
    $dir = Split-Path -Parent -Path $env:MMO_FAKE_ARGV_PATH
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($env:MMO_FAKE_ARGV_PATH, $json + [Environment]::NewLine)
}

if ($Rest -contains 'version' -or $Rest -contains '--version' -or $Rest -contains '-v') {
    Write-Output 'grok 0.0.0-fake'
    exit 0
}

if ($Rest -contains 'models') {
    Write-Output 'You are logged in with grok.com.'
    Write-Output ''
    Write-Output 'Default model: grok-4.5'
    Write-Output ''
    Write-Output 'Available models:'
    Write-Output '  * grok-4.5 (default)'
    exit 0
}

if ($env:MMO_FAKE_GROK_MODE -eq 'quota' -or $env:MMO_FAKE_GROK_MODE -eq 'quota_always') {
    [Console]::Error.WriteLine('error: insufficient_quota: rate limit exceeded for model')
    exit 2
}
if ($env:MMO_FAKE_GROK_MODE -eq 'auth') {
    [Console]::Error.WriteLine('error: unauthorized: not logged in')
    exit 3
}
if ($env:MMO_FAKE_GROK_MODE -eq 'model_unavailable') {
    [Console]::Error.WriteLine('error: model not found: grok-missing')
    exit 4
}
if ($env:MMO_FAKE_GROK_MODE -eq 'task_fail') {
    Write-Output 'attempted work'
    [Console]::Error.WriteLine('task failed: assertion mismatch')
    exit 1
}
if ($env:MMO_FAKE_GROK_MODE -eq 'hang_with_child') {
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300'
    ) -PassThru -WindowStyle Hidden
    if (-not [string]::IsNullOrWhiteSpace($env:MMO_FAKE_CHILD_PID_PATH)) {
        $cdir = Split-Path -Parent -Path $env:MMO_FAKE_CHILD_PID_PATH
        if ($cdir -and -not (Test-Path -LiteralPath $cdir)) {
            New-Item -ItemType Directory -Path $cdir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($env:MMO_FAKE_CHILD_PID_PATH, [string]$child.Id)
    }
    Start-Sleep -Seconds 300
    exit 0
}
if ($env:MMO_FAKE_GROK_MODE -eq 'hang') {
    Start-Sleep -Seconds 300
    exit 0
}

# Optional delay to allow concurrent-worker overlap tests.
if ($env:MMO_FAKE_SLEEP_MS) {
    $ms = 0
    [void][int]::TryParse($env:MMO_FAKE_SLEEP_MS, [ref]$ms)
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
}

# Default success path for --single / --prompt-file style calls
Write-Output "fake-grok ok args=$joined"
if ($joined -match '--always-approve') {
    Write-Output 'fake-grok always-approve observed'
}
exit 0
