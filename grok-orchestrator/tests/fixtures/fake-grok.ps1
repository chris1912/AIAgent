# Deterministic fake grok CLI for offline tests (grok-orchestrator).
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
if ($null -eq $Rest) { $Rest = @() }
$joined = ($Rest -join ' ')

# Optional argv capture for escaping/regression tests.
$argvPath = $env:GO_FAKE_ARGV_PATH
if ([string]::IsNullOrWhiteSpace($argvPath)) { $argvPath = $env:MMO_FAKE_ARGV_PATH }
if (-not [string]::IsNullOrWhiteSpace($argvPath)) {
    $argvObj = [pscustomobject]@{
        argv = @($Rest)
        args = @($Rest)
        argc = @($Rest).Count
        count = @($Rest).Count
        joined = $joined
        recorded_at = [datetime]::UtcNow.ToString('o')
    }
    $json = $argvObj | ConvertTo-Json -Compress -Depth 5
    $dir = Split-Path -Parent -Path $argvPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($argvPath, $json + [Environment]::NewLine)
}

if ($Rest -contains 'version' -or $Rest -contains '--version' -or $Rest -contains '-v') {
    Write-Output 'grok 0.0.0-fake'
    exit 0
}

if ($Rest -contains 'models') {
    $modelsMode = $env:GO_FAKE_MODELS
    if ([string]::IsNullOrWhiteSpace($modelsMode)) {
        Write-Output 'You are logged in with grok.com.'
        Write-Output ''
        Write-Output 'Default model: grok-4.5'
        Write-Output ''
        Write-Output 'Available models:'
        Write-Output '  * grok-4.5 (default)'
        if ($env:GO_FAKE_INCLUDE_COMPOSER -eq '1') {
            Write-Output '  * grok-composer-2.5-fast'
        }
        exit 0
    }
    if ($modelsMode -eq 'empty') {
        Write-Output 'Available models:'
        exit 0
    }
    if ($modelsMode -eq 'with_composer') {
        Write-Output 'You are logged in with grok.com.'
        Write-Output 'Default model: grok-4.5'
        Write-Output 'Available models:'
        Write-Output '  * grok-4.5 (default)'
        Write-Output '  * grok-composer-2.5-fast'
        exit 0
    }
}

$mode = $env:GO_FAKE_GROK_MODE
if ([string]::IsNullOrWhiteSpace($mode)) { $mode = $env:MMO_FAKE_GROK_MODE }

if ($mode -eq 'quota' -or $mode -eq 'quota_always') {
    [Console]::Error.WriteLine('error: insufficient_quota: rate limit exceeded for model')
    exit 2
}
if ($mode -eq 'quota_once') {
    $marker = $env:GO_FAKE_QUOTA_ONCE_MARKER
    if ([string]::IsNullOrWhiteSpace($marker)) {
        $marker = Join-Path ([System.IO.Path]::GetTempPath()) 'go-fake-quota-once.marker'
    }
    if (-not (Test-Path -LiteralPath $marker)) {
        [System.IO.File]::WriteAllText($marker, 'used')
        [Console]::Error.WriteLine('error: insufficient_quota: rate limit exceeded for model')
        exit 2
    }
    Write-Output "fake-grok ok after-quota args=$joined"
    exit 0
}
if ($mode -eq 'auth') {
    [Console]::Error.WriteLine('error: unauthorized: not logged in')
    exit 3
}
if ($mode -eq 'model_unavailable') {
    [Console]::Error.WriteLine('error: model not found: grok-missing')
    exit 4
}
if ($mode -eq 'task_fail') {
    Write-Output 'attempted work'
    [Console]::Error.WriteLine('task failed: assertion mismatch')
    exit 1
}
if ($mode -eq 'hang_with_child') {
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300'
    ) -PassThru -WindowStyle Hidden
    $childPidPath = $env:GO_FAKE_CHILD_PID_PATH
    if ([string]::IsNullOrWhiteSpace($childPidPath)) { $childPidPath = $env:MMO_FAKE_CHILD_PID_PATH }
    if (-not [string]::IsNullOrWhiteSpace($childPidPath)) {
        $cdir = Split-Path -Parent -Path $childPidPath
        if ($cdir -and -not (Test-Path -LiteralPath $cdir)) {
            New-Item -ItemType Directory -Path $cdir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($childPidPath, [string]$child.Id)
    }
    Start-Sleep -Seconds 300
    exit 0
}
if ($mode -eq 'hang') {
    Start-Sleep -Seconds 300
    exit 0
}

if ($env:GO_FAKE_SLEEP_MS) {
    $ms = 0
    [void][int]::TryParse($env:GO_FAKE_SLEEP_MS, [ref]$ms)
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
}

Write-Output "fake-grok ok args=$joined"
if ($joined -match '--always-approve') {
    Write-Output 'fake-grok always-approve observed'
}
exit 0
