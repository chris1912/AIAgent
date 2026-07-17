# Launch two or more provider workers concurrently with isolated cwds and durable results.
# Authored 2026-07-17 revision 1.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,

    # JSON array of worker specs. Example:
    # [
    #   {"worker_id":"w-grok","provider":"grok","executable":"...","model":"grok-4.5",
    #    "reasoning_tier":"highest","prompt":"...","cwd":"...","timeout_seconds":60},
    #   {"worker_id":"w-agy","provider":"agy", ...}
    # ]
    [Parameter(Mandatory = $true)]
    [string]$WorkersJson,

    [switch]$DryBuildOnly
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path -LiteralPath $RunDirectory)) {
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
}
$RunDirectory = (Resolve-Path -LiteralPath $RunDirectory).Path
$workersRoot = Join-Path $RunDirectory 'workers'
New-Item -ItemType Directory -Path $workersRoot -Force | Out-Null

$specs = $null
if (Test-Path -LiteralPath $WorkersJson) {
    $specs = Get-Content -LiteralPath $WorkersJson -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    $specs = $WorkersJson | ConvertFrom-Json
}
$specList = @($specs)
if ($specList.Count -lt 1) {
    throw 'WorkersJson must contain at least one worker specification.'
}

# Isolation: concurrent writers must not share the same writable cwd.
$cwdGroups = @{}
foreach ($s in $specList) {
    $cwd = [string]$s.cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        throw "Worker '$($s.worker_id)' is missing cwd."
    }
    $resolved = $cwd
    if (Test-Path -LiteralPath $cwd) {
        $resolved = (Resolve-Path -LiteralPath $cwd).Path
    }
    $key = $resolved.ToLowerInvariant()
    if (-not $cwdGroups.ContainsKey($key)) {
        $cwdGroups[$key] = @()
    }
    $cwdGroups[$key] += [string]$s.worker_id
}
foreach ($key in $cwdGroups.Keys) {
    $group = @($cwdGroups[$key])
    if ($group.Count -gt 1) {
        throw "Concurrent writers must not share a cwd. Overlap on '$key' by workers: $($group -join ', '). Allocate separate worktrees or directories."
    }
}

$invokeScript = Join-Path $PSScriptRoot 'Invoke-Provider.ps1'
$jobs = @()
$plan = @()

foreach ($s in $specList) {
    $workerId = [string]$s.worker_id
    if ([string]::IsNullOrWhiteSpace($workerId)) { throw 'Each worker requires worker_id.' }
    $provider = [string]$s.provider
    $tier = if ($s.reasoning_tier) { [string]$s.reasoning_tier } else { 'highest' }
    if ($tier -notin @('highest', 'second_highest')) {
        throw "Worker '$workerId' requested forbidden reasoning_tier '$tier'."
    }
    $model = if ($s.model) { [string]$s.model } else { '' }
    $effort = if ($s.reasoning_effort) { [string]$s.reasoning_effort } else { '' }
    Assert-MmoInvocationPolicy -Model $model -ReasoningEffort $effort -ReasoningTier $tier

    $prompt = if ($s.prompt) { [string]$s.prompt } else { '' }
    $promptFile = if ($s.prompt_file) { [string]$s.prompt_file } else { '' }
    $exe = if ($s.executable) { [string]$s.executable } else { '' }
    $cwd = [string]$s.cwd
    $timeout = if ($s.timeout_seconds) { [int]$s.timeout_seconds } else { 3600 }

    $argList = @(
        '-NoProfile', '-NonInteractive', '-File', $invokeScript,
        '-Provider', $provider,
        '-RunDirectory', $RunDirectory,
        '-WorkerId', $workerId,
        '-Cwd', $cwd,
        '-ReasoningTier', $tier,
        '-TimeoutSeconds', "$timeout"
    )
    if (-not [string]::IsNullOrWhiteSpace($exe)) { $argList += @('-Executable', $exe) }
    if (-not [string]::IsNullOrWhiteSpace($model)) { $argList += @('-Model', $model) }
    if (-not [string]::IsNullOrWhiteSpace($effort)) { $argList += @('-ReasoningEffort', $effort) }
    if (-not [string]::IsNullOrWhiteSpace($promptFile)) {
        $argList += @('-PromptFile', $promptFile)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($prompt)) {
        $argList += @('-Prompt', $prompt)
    }
    else {
        throw "Worker '$workerId' needs prompt or prompt_file."
    }
    # Default retains Grok --always-approve; opt out only when worker spec sets no_always_approve.
    $noAlways = $false
    if ($null -ne $s.no_always_approve) {
        $noAlways = [System.Convert]::ToBoolean($s.no_always_approve)
    }
    elseif ($null -ne $s.NoAlwaysApprove) {
        $noAlways = [System.Convert]::ToBoolean($s.NoAlwaysApprove)
    }
    if ($noAlways) {
        $argList += '-NoAlwaysApprove'
    }
    if ($DryBuildOnly) { $argList += '-DryBuildOnly' }

    $plan += [pscustomobject]@{
        worker_id = $workerId
        provider = $provider
        model = $model
        reasoning_tier = $tier
        cwd = $cwd
        no_always_approve = $noAlways
        args = $argList
    }

    # Optional per-worker env map, e.g. {"MMO_FAKE_AGY_MODE":"quota","MMO_FAKE_SLEEP_MS":"400"}
    $envMap = @{}
    if ($null -ne $s.env) {
        $s.env.PSObject.Properties | ForEach-Object { $envMap[$_.Name] = [string]$_.Value }
    }

    $job = Start-Job -ScriptBlock {
        param($ArgList, $OutPath, $EnvPairs)
        foreach ($key in $EnvPairs.Keys) {
            Set-Item -Path ("Env:" + $key) -Value $EnvPairs[$key]
        }
        $raw = & powershell.exe @ArgList 2>&1 | Out-String
        $code = $LASTEXITCODE
        [System.IO.File]::WriteAllText($OutPath, $raw)
        return [pscustomobject]@{ exit_code = $code; output_path = $OutPath }
    } -ArgumentList @($argList, (Join-Path $workersRoot ($workerId + '.launch.log')), $envMap)

    $jobs += [pscustomobject]@{
        worker_id = $workerId
        provider = $provider
        job = $job
        started_at = [datetime]::UtcNow.ToString('o')
    }
}

# Persist launch plan and PID index as jobs start producing worker PID files.
Write-MmoJson -LiteralPath (Join-Path $RunDirectory 'concurrent-plan.json') -InputObject ([pscustomobject]@{
    dry_run = [bool]$DryBuildOnly
    worker_count = $specList.Count
    workers = $plan
    launched_at = [datetime]::UtcNow.ToString('o')
})

$completed = @()
foreach ($entry in $jobs) {
    $null = Wait-Job -Job $entry.job
    $jobResult = Receive-Job -Job $entry.job
    Remove-Job -Job $entry.job -Force -ErrorAction SilentlyContinue

    $resultPath = Join-Path $workersRoot (Join-Path $entry.worker_id 'result.json')
    $pidPath = Join-Path $workersRoot (Join-Path $entry.worker_id 'WORKER_PID.txt')
    $normalized = $null
    if (Test-Path -LiteralPath $resultPath) {
        $normalized = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $completed += [pscustomobject]@{
        worker_id = $entry.worker_id
        provider = $entry.provider
        job_exit_code = $(if ($jobResult) { $jobResult.exit_code } else { -1 })
        pid_file = $(if (Test-Path -LiteralPath $pidPath) { $pidPath } else { $null })
        worker_pid = $(if (Test-Path -LiteralPath $pidPath) { (Get-Content -LiteralPath $pidPath -Raw).Trim() } else { $null })
        result_path = $(if (Test-Path -LiteralPath $resultPath) { $resultPath } else { $null })
        result = $normalized
        launch_log = Join-Path $workersRoot ($entry.worker_id + '.launch.log')
        started_at = $entry.started_at
        finished_at = [datetime]::UtcNow.ToString('o')
    }
}

# Aggregate PID index for multi-worker watchdog.
$pidIndex = @()
foreach ($c in $completed) {
    if ($c.worker_pid) {
        $pidIndex += [pscustomobject]@{
            worker_id = $c.worker_id
            provider = $c.provider
            pid = [int]$c.worker_pid
            pid_file = $c.pid_file
        }
    }
}
Write-MmoJson -LiteralPath (Join-Path $RunDirectory 'WORKER_PIDS.json') -InputObject ([pscustomobject]@{
    workers = $pidIndex
    updated_at = [datetime]::UtcNow.ToString('o')
})

$summary = [pscustomobject]@{
    run_directory = $RunDirectory
    dry_run = [bool]$DryBuildOnly
    worker_count = $completed.Count
    workers = $completed
    finished_at = [datetime]::UtcNow.ToString('o')
}
Write-MmoJson -LiteralPath (Join-Path $RunDirectory 'concurrent-results.json') -InputObject $summary
Write-Output (ConvertTo-MmoJson -InputObject $summary)
return
