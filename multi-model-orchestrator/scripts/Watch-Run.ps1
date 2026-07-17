# Watch one multi-model run. Supports single-PID and aggregate multi-worker modes.
# Authored 2026-07-17; revised for multi-worker monitoring.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,

    [int]$TargetProcessId = 0,

    # When set, monitor every workers/*/WORKER_PID.txt (and WORKER_PIDS.json) instead of only w1.
    [switch]$AggregateWorkers,

    [string]$WorkerId = '',

    [ValidateRange(5, 300)]
    [int]$PollSeconds = 15,

    [ValidateRange(1, 1440)]
    [int]$StallMinutes = 10,

    [ValidateRange(1, 10080)]
    [int]$HardTimeoutMinutes = 60,

    [switch]$TerminateOnTimeout
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Common.ps1')

function Write-Utf8Text {
    param([string]$LiteralPath, [string]$Text, [switch]$Append)
    if ($Append) {
        [System.IO.File]::AppendAllText($LiteralPath, $Text, $Utf8NoBom)
        return
    }
    [System.IO.File]::WriteAllText($LiteralPath, $Text, $Utf8NoBom)
    return
}

function Get-RunSnapshot {
    param([string]$LiteralPath)
    $ignored = @('WATCHDOG_STATUS.json', 'WATCHDOG_EVENTS.jsonl')
    $files = @(Get-ChildItem -LiteralPath $LiteralPath -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $ignored -notcontains $_.Name })
    [long]$bytes = 0
    [datetime]$latest = [datetime]::MinValue
    foreach ($file in $files) {
        $bytes += $file.Length
        if ($file.LastWriteTimeUtc -gt $latest) { $latest = $file.LastWriteTimeUtc }
    }
    return [pscustomobject]@{ Bytes = $bytes; LatestUtc = $latest }
}

function Get-TargetProcess {
    param([int]$Id, [datetime]$ExpectedStartUtc)
    return (Get-MmoTargetProcess -Id $Id -ExpectedStartUtc $ExpectedStartUtc)
}

function Get-DescendantProcessIds {
    param([int]$RootId)
    return @(Get-MmoDescendantProcessIds -RootId $RootId)
}

function Stop-TargetProcessTree {
    param([int]$RootId, [datetime]$ExpectedStartUtc)
    Stop-MmoProcessTree -RootId $RootId -ExpectedStartUtc $ExpectedStartUtc
    return
}

function Get-WorkerTargets {
    param([string]$RunDir, [string]$OnlyWorkerId, [switch]$Aggregate, [int]$SinglePid)
    $targets = @()

    if ($SinglePid -gt 0 -and -not $Aggregate -and [string]::IsNullOrWhiteSpace($OnlyWorkerId)) {
        $proc = Get-Process -Id $SinglePid -ErrorAction SilentlyContinue
        $start = if ($proc) { $proc.StartTime.ToUniversalTime() } else { [datetime]::MinValue }
        $targets += [pscustomobject]@{
            worker_id = 'root'
            process_id = $SinglePid
            expected_start_utc = $start
            pid_file = $null
            result_file = $null
        }
        return $targets
    }

    if (-not [string]::IsNullOrWhiteSpace($OnlyWorkerId)) {
        $pidFile = Join-Path $RunDir (Join-Path 'workers' (Join-Path $OnlyWorkerId 'WORKER_PID.txt'))
        if (-not (Test-Path -LiteralPath $pidFile)) { throw "Missing PID file for worker $OnlyWorkerId : $pidFile" }
        $pid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
        $start = if ($proc) { $proc.StartTime.ToUniversalTime() } else { [datetime]::MinValue }
        $targets += [pscustomobject]@{
            worker_id = $OnlyWorkerId
            process_id = $pid
            expected_start_utc = $start
            pid_file = $pidFile
            result_file = Join-Path $RunDir (Join-Path 'workers' (Join-Path $OnlyWorkerId 'result.json'))
        }
        return $targets
    }

    if ($Aggregate) {
        $indexPath = Join-Path $RunDir 'WORKER_PIDS.json'
        if (Test-Path -LiteralPath $indexPath) {
            $idx = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($w in @($idx.workers)) {
                $pidFile = [string]$w.pid_file
                $pid = [int]$w.pid
                $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
                $start = if ($proc) { $proc.StartTime.ToUniversalTime() } else { [datetime]::MinValue }
                $targets += [pscustomobject]@{
                    worker_id = [string]$w.worker_id
                    process_id = $pid
                    expected_start_utc = $start
                    pid_file = $pidFile
                    result_file = Join-Path $RunDir (Join-Path 'workers' (Join-Path ([string]$w.worker_id) 'result.json'))
                }
            }
        }
        $workerDirs = @(Get-ChildItem -LiteralPath (Join-Path $RunDir 'workers') -Directory -ErrorAction SilentlyContinue)
        foreach ($dir in $workerDirs) {
            $pidFile = Join-Path $dir.FullName 'WORKER_PID.txt'
            if (-not (Test-Path -LiteralPath $pidFile)) { continue }
            $wid = $dir.Name
            if ($targets | Where-Object { $_.worker_id -eq $wid }) { continue }
            $pid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            $start = if ($proc) { $proc.StartTime.ToUniversalTime() } else { [datetime]::MinValue }
            $targets += [pscustomobject]@{
                worker_id = $wid
                process_id = $pid
                expected_start_utc = $start
                pid_file = $pidFile
                result_file = Join-Path $dir.FullName 'result.json'
            }
        }
        if ($targets.Count -eq 0) {
            throw "Aggregate mode found no worker PID files under $RunDir\workers"
        }
        return $targets
    }

    # Default single-root fallback
    $pidCandidates = @(
        (Join-Path $RunDir 'WORKER_PID.txt'),
        (Join-Path $RunDir 'GROK_PID.txt'),
        (Join-Path $RunDir 'AGY_PID.txt')
    )
    $pidPath = $pidCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $pidPath) { throw "Missing worker PID file in $RunDir" }
    $pid = [int](Get-Content -LiteralPath $pidPath -Raw).Trim()
    $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
    if ($null -eq $proc) { throw "Process $pid from $pidPath is not running" }
    $targets += [pscustomobject]@{
        worker_id = 'root'
        process_id = $pid
        expected_start_utc = $proc.StartTime.ToUniversalTime()
        pid_file = $pidPath
        result_file = $null
    }
    return $targets
}

function Write-WatchdogState {
    param([string]$State, [string]$Detail, $Workers = @(), [switch]$Emit)
    $data = [ordered]@{
        run_directory = $ResolvedRunDirectory
        mode = $WatchMode
        process_id = $PrimaryProcessId
        workers = @($Workers)
        state = $State
        detail = $Detail
        updated_at = [datetime]::UtcNow.ToString('o')
    }
    $json = $data | ConvertTo-Json -Depth 8 -Compress
    Write-Utf8Text -LiteralPath $StatusPath -Text $json
    if ($Emit) {
        Write-Utf8Text -LiteralPath $EventsPath -Text ($json + [Environment]::NewLine) -Append
        Write-Output $json
    }
    return
}

$ResolvedRunDirectory = (Resolve-Path -LiteralPath $RunDirectory).Path
$StatusPath = Join-Path -Path $ResolvedRunDirectory -ChildPath 'WATCHDOG_STATUS.json'
$EventsPath = Join-Path -Path $ResolvedRunDirectory -ChildPath 'WATCHDOG_EVENTS.jsonl'

$WatchMode = 'single'
if ($AggregateWorkers) { $WatchMode = 'aggregate' }
elseif (-not [string]::IsNullOrWhiteSpace($WorkerId)) { $WatchMode = "worker:$WorkerId" }

$targets = @(Get-WorkerTargets -RunDir $ResolvedRunDirectory -OnlyWorkerId $WorkerId -Aggregate:$AggregateWorkers -SinglePid $TargetProcessId)
$PrimaryProcessId = $targets[0].process_id

$startedUtc = [datetime]::UtcNow
$lastActivityUtc = $startedUtc
$lastRun = Get-RunSnapshot -LiteralPath $ResolvedRunDirectory

$workerStates = @()
foreach ($t in $targets) {
    $workerStates += [pscustomobject]@{
        worker_id = $t.worker_id
        process_id = $t.process_id
        state = 'running'
    }
}
Write-WatchdogState -State 'running' -Detail 'watchdog attached' -Workers $workerStates -Emit

while ($true) {
    foreach ($terminal in @(
        @{ File = 'DONE.flag'; State = 'done'; Code = 0 },
        @{ File = 'READY_FOR_REVIEW.flag'; State = 'ready_for_review'; Code = 0 },
        @{ File = 'BLOCKED.flag'; State = 'blocked'; Code = 2 },
        @{ File = 'FAILED.flag'; State = 'failed'; Code = 1 }
    )) {
        if (Test-Path -LiteralPath (Join-Path $ResolvedRunDirectory $terminal.File)) {
            Write-WatchdogState -State $terminal.State -Detail $terminal.File -Workers $workerStates -Emit
            exit $terminal.Code
        }
    }

    $anyAlive = $false
    $allTerminalResults = $true
    $workerStates = @()
    foreach ($t in $targets) {
        $proc = Get-TargetProcess -Id $t.process_id -ExpectedStartUtc $t.expected_start_utc
        $wState = 'running'
        if ($null -ne $proc) {
            $anyAlive = $true
            $wState = 'running'
            $allTerminalResults = $false
        }
        else {
            if ($t.result_file -and (Test-Path -LiteralPath $t.result_file)) {
                $wState = 'completed'
            }
            else {
                $wState = 'exited_unreported'
                $allTerminalResults = $false
            }
        }
        $workerStates += [pscustomobject]@{
            worker_id = $t.worker_id
            process_id = $t.process_id
            state = $wState
        }
    }

    if ($WatchMode -eq 'aggregate') {
        if (-not $anyAlive) {
            $hasUnreported = @($workerStates | Where-Object { $_.state -eq 'exited_unreported' }).Count -gt 0
            if ($hasUnreported) {
                Write-WatchdogState -State 'failed_unreported' -Detail 'one or more workers exited without result.json' -Workers $workerStates -Emit
                exit 3
            }
            Write-WatchdogState -State 'workers_complete' -Detail 'all workers exited with results' -Workers $workerStates -Emit
            exit 0
        }
    }
    else {
        if (-not $anyAlive) {
            Write-WatchdogState -State 'failed_unreported' -Detail 'process exited without sentinel' -Workers $workerStates -Emit
            exit 3
        }
    }

    # Activity requires meaningful run-artifact progress only. CPU-only spin must not suppress stalls.
    $run = Get-RunSnapshot -LiteralPath $ResolvedRunDirectory
    if ($run.Bytes -ne $lastRun.Bytes -or $run.LatestUtc -ne $lastRun.LatestUtc) {
        $lastActivityUtc = [datetime]::UtcNow
        $lastRun = $run
        Write-WatchdogState -State 'running' -Detail 'artifact progress observed' -Workers $workerStates
    }

    [single]$elapsed = [single](([datetime]::UtcNow - $startedUtc).TotalMinutes)
    [single]$inactive = [single](([datetime]::UtcNow - $lastActivityUtc).TotalMinutes)
    if ($elapsed -ge [single]$HardTimeoutMinutes) {
        if ($TerminateOnTimeout) {
            foreach ($t in $targets) {
                Stop-TargetProcessTree -RootId $t.process_id -ExpectedStartUtc $t.expected_start_utc
            }
        }
        Write-WatchdogState -State 'timeout' -Detail "hard timeout after $HardTimeoutMinutes minutes" -Workers $workerStates -Emit
        exit 5
    }
    if ($inactive -ge [single]$StallMinutes) {
        Write-WatchdogState -State 'stalled' -Detail "no artifact progress for $StallMinutes minutes" -Workers $workerStates -Emit
        exit 4
    }

    Start-Sleep -Seconds $PollSeconds
}
