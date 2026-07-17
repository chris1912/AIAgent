# Invoke grok or agy for one bounded worker stage and normalize the result envelope.
# Authored 2026-07-17; revised for invocation-boundary policy + headless Grok defaults.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('grok', 'agy')]
    [string]$Provider,

    [string]$Executable = '',
    [string]$Model = '',
    [ValidateSet('highest', 'second_highest')]
    [string]$ReasoningTier = 'highest',
    [string]$ReasoningEffort = '',
    [string]$Prompt = '',
    [string]$PromptFile = '',
    [string]$Cwd = '',
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,
    [string]$WorkerId = 'w1',
    [int]$TimeoutSeconds = 3600,
    [string[]]$ExtraArgs = @(),
    # JSON array of extra argv strings for -File callers that cannot repeat -ExtraArgs (PS 5.1).
    [string]$ExtraArgsJson = '',
    # Preferred multi-value path: UTF-8 file containing a JSON string array (avoids -File quoting loss).
    [string]$ExtraArgsJsonPath = '',
    # Headless Grok requires non-interactive permission approval in this environment.
    # Default ON for grok; pass -NoAlwaysApprove only when intentionally interactive.
    [switch]$NoAlwaysApprove,
    [switch]$DryBuildOnly
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Merge-MmoExtraArgs {
    param([string[]]$Base, [string[]]$More)
    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Base)) {
        if (-not [string]::IsNullOrEmpty([string]$e)) { $merged.Add([string]$e) | Out-Null }
    }
    foreach ($e in @($More)) {
        if (-not [string]::IsNullOrEmpty([string]$e)) { $merged.Add([string]$e) | Out-Null }
    }
    return @($merged)
}

# Merge ExtraArgsJson / ExtraArgsJsonPath into ExtraArgs (each value remains one provider argv).
if (-not [string]::IsNullOrWhiteSpace($ExtraArgsJsonPath)) {
    if (-not (Test-Path -LiteralPath $ExtraArgsJsonPath)) {
        throw "ExtraArgsJsonPath not found: $ExtraArgsJsonPath"
    }
    try {
        $parsedPath = Get-Content -LiteralPath $ExtraArgsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ExtraArgs = Merge-MmoExtraArgs -Base $ExtraArgs -More @($parsedPath)
    }
    catch {
        throw "Invalid ExtraArgsJsonPath content (expected JSON string array): $($_.Exception.Message)"
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExtraArgsJson)) {
    try {
        $parsedExtra = $ExtraArgsJson | ConvertFrom-Json
        $ExtraArgs = Merge-MmoExtraArgs -Base $ExtraArgs -More @($parsedExtra)
    }
    catch {
        throw "Invalid -ExtraArgsJson (expected JSON string array): $($_.Exception.Message)"
    }
}

function Invoke-MmoClassifyLocal {
    param([string]$Text, [string]$Stderr = '', [int]$Code)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mmo-cls-" + [guid]::NewGuid().ToString() + '.json')
    $raw = $null
    $errPath = $null
    try {
        $scriptPath = Join-Path $PSScriptRoot 'Classify-Result.ps1'
        $psArgs = @('-NoProfile', '-NonInteractive', '-File', $scriptPath, '-ExitCode', "$Code", '-OutJson', $tmp)
        if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
            $errPath = Join-Path ([System.IO.Path]::GetTempPath()) ("mmo-err-" + [guid]::NewGuid().ToString() + '.txt')
            Write-MmoUtf8Text -LiteralPath $errPath -Text $Stderr
            $psArgs += @('-StderrPath', $errPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($Text)) {
            $raw = Join-Path ([System.IO.Path]::GetTempPath()) ("mmo-raw-" + [guid]::NewGuid().ToString() + '.txt')
            Write-MmoUtf8Text -LiteralPath $raw -Text $Text
            $psArgs += @('-RawLogPath', $raw)
        }
        & powershell.exe @psArgs | Out-Null
        return (Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    finally {
        if ($raw) { Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue }
        if ($errPath) { Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

if ([string]::IsNullOrWhiteSpace($Prompt) -and [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Either -Prompt or -PromptFile is required.'
}
if (-not [string]::IsNullOrWhiteSpace($PromptFile) -and -not (Test-Path -LiteralPath $PromptFile)) {
    throw "Prompt file not found: $PromptFile"
}

# Early policy gate: reject low effort / low model before any provider contact.
Assert-MmoInvocationPolicy -Model $Model -ReasoningEffort $ReasoningEffort -ReasoningTier $ReasoningTier -ExtraArgs $ExtraArgs

$registry = Get-MmoRegistry
$provCfg = $registry.providers.$Provider
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Resolve-MmoExecutable -Names @($provCfg.cli_names) -CommonPaths @($provCfg.common_paths)
}
if ([string]::IsNullOrWhiteSpace($Executable)) {
    throw "Executable for provider '$Provider' not found."
}

if ([string]::IsNullOrWhiteSpace($Cwd)) {
    $Cwd = (Get-Location).Path
}
$Cwd = (Resolve-Path -LiteralPath $Cwd).Path
if (-not (Test-Path -LiteralPath $RunDirectory)) {
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
}
$RunDirectory = (Resolve-Path -LiteralPath $RunDirectory).Path
$workerDir = Join-Path $RunDirectory (Join-Path 'workers' $WorkerId)
New-Item -ItemType Directory -Path $workerDir -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($ReasoningEffort)) {
    if ($Provider -eq 'grok') {
        $map = Get-MmoAllowedReasoningLabels -OrderedDescending @($provCfg.reasoning_effort_order_desc)
        $ReasoningEffort = Resolve-MmoReasoningTier -Tier $ReasoningTier -AllowedMap $map
    }
    else {
        $map = Get-MmoAllowedReasoningLabels -OrderedDescending @('High', 'Medium', 'Low')
        $ReasoningEffort = Resolve-MmoReasoningTier -Tier $ReasoningTier -AllowedMap $map
    }
}

# Resolved effort must also pass the policy (covers mapping mistakes).
Assert-MmoInvocationPolicy -Model $Model -ReasoningEffort $ReasoningEffort -ReasoningTier $ReasoningTier -ExtraArgs $ExtraArgs

$promptText = $Prompt
if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    $promptText = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
}

$argList = New-Object System.Collections.Generic.List[string]
$alwaysApproveApplied = $false
if ($Provider -eq 'grok') {
    $argList.Add('--cwd') | Out-Null
    $argList.Add($Cwd) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $argList.Add('--model') | Out-Null
        $argList.Add($Model) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
        $argList.Add('--reasoning-effort') | Out-Null
        $argList.Add($ReasoningEffort) | Out-Null
    }
    # Controlled default for non-interactive headless runs on this host.
    if (-not $NoAlwaysApprove) {
        $argList.Add('--always-approve') | Out-Null
        $alwaysApproveApplied = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
        $argList.Add('--prompt-file') | Out-Null
        $argList.Add((Resolve-Path -LiteralPath $PromptFile).Path) | Out-Null
    }
    else {
        $argList.Add('--single') | Out-Null
        $argList.Add($promptText) | Out-Null
    }
}
else {
    # agy: process WorkingDirectory is the isolation boundary; --add-dir is supplementary only.
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $argList.Add('--model') | Out-Null
        $argList.Add($Model) | Out-Null
    }
    $argList.Add('--add-dir') | Out-Null
    $argList.Add($Cwd) | Out-Null
    $argList.Add('--print') | Out-Null
    $argList.Add($promptText) | Out-Null
}
foreach ($a in $ExtraArgs) { $argList.Add($a) | Out-Null }

# Final boundary check over the fully built arg list (catches ExtraArgs smuggling).
Assert-MmoInvocationPolicy -Model $Model -ReasoningEffort $ReasoningEffort -ReasoningTier $ReasoningTier -ExtraArgs @() -BuiltArgs @($argList)

$request = [pscustomobject]@{
    provider = $Provider
    executable = $Executable
    model = $Model
    reasoning_tier = $ReasoningTier
    reasoning_effort = $ReasoningEffort
    always_approve = $alwaysApproveApplied
    no_always_approve = [bool]$NoAlwaysApprove
    cwd = $Cwd
    worker_id = $WorkerId
    args = @($argList)
    timeout_seconds = $TimeoutSeconds
    created_at = [datetime]::UtcNow.ToString('o')
}
Write-MmoJson -LiteralPath (Join-Path $workerDir 'request.json') -InputObject $request

if ($DryBuildOnly) {
    $dry = [pscustomobject]@{
        provider = $Provider
        worker_id = $WorkerId
        dry_run = $true
        always_approve = $alwaysApproveApplied
        no_always_approve = [bool]$NoAlwaysApprove
        reasoning_tier = $ReasoningTier
        reasoning_effort = $ReasoningEffort
        model = $Model
        request_path = (Join-Path $workerDir 'request.json')
        args = @($argList)
        command = (@($Executable) + @($argList)) -join ' '
    }
    Write-MmoJson -LiteralPath (Join-Path $workerDir 'result.json') -InputObject $dry
    Write-Output (ConvertTo-MmoJson -InputObject $dry)
    return
}

$stdoutPath = Join-Path $workerDir 'stdout.log'
$stderrPath = Join-Path $workerDir 'stderr.log'
$pidPath = Join-Path $workerDir 'WORKER_PID.txt'
$started = [datetime]::UtcNow

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Executable
$psi.WorkingDirectory = $Cwd
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
# PS 5.1 lacks ArgumentList; use verified Windows escaping (or ArgumentList when available).
$argMode = Set-MmoProcessStartInfoArguments -StartInfo $psi -ArgumentList @($argList)
$request | Add-Member -NotePropertyName argument_mode -NotePropertyValue $argMode -Force
Write-MmoJson -LiteralPath (Join-Path $workerDir 'request.json') -InputObject $request

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()
$rootStartUtc = $proc.StartTime.ToUniversalTime()
Write-MmoUtf8Text -LiteralPath $pidPath -Text ([string]$proc.Id)
# Always record root aliases for primary worker; multi-worker uses per-worker PID files.
if ($WorkerId -eq 'w1') {
    Write-MmoUtf8Text -LiteralPath (Join-Path $RunDirectory 'WORKER_PID.txt') -Text ([string]$proc.Id)
}
if ($Provider -eq 'grok') {
    Write-MmoUtf8Text -LiteralPath (Join-Path $RunDirectory 'GROK_PID.txt') -Text ([string]$proc.Id)
    Write-MmoUtf8Text -LiteralPath (Join-Path $workerDir 'GROK_PID.txt') -Text ([string]$proc.Id)
}
if ($Provider -eq 'agy') {
    Write-MmoUtf8Text -LiteralPath (Join-Path $RunDirectory 'AGY_PID.txt') -Text ([string]$proc.Id)
    Write-MmoUtf8Text -LiteralPath (Join-Path $workerDir 'AGY_PID.txt') -Text ([string]$proc.Id)
}

$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$timeoutMs = [Math]::Max(1000, $TimeoutSeconds * 1000)
$exited = $proc.WaitForExit($timeoutMs)
if (-not $exited) {
    # Kill the whole tree; PID-reuse guarded by recorded root start time.
    Stop-MmoProcessTree -RootId $proc.Id -ExpectedStartUtc $rootStartUtc
    try { $proc.WaitForExit(5000) } catch { }
    $exitCode = 124
    $timedOut = $true
}
else {
    $exitCode = [int]$proc.ExitCode
    $timedOut = $false
}

$outText = ''
$errText = ''
try { $outText = $stdoutTask.Result } catch { $outText = '' }
try { $errText = $stderrTask.Result } catch { $errText = '' }
Write-MmoUtf8Text -LiteralPath $stdoutPath -Text $(if ($null -eq $outText) { '' } else { $outText })
Write-MmoUtf8Text -LiteralPath $stderrPath -Text $(if ($null -eq $errText) { '' } else { $errText })
$proc.Dispose()

$ended = [datetime]::UtcNow
$combined = (($outText + "`n" + $errText).Trim())

if ($timedOut) {
    $classification = [pscustomobject]@{
        classification = 'timeout'
        fallback_eligible = $false
        reason = "Hard timeout after $TimeoutSeconds seconds"
        exit_code = $exitCode
    }
}
else {
    $classification = Invoke-MmoClassifyLocal -Text $outText -Stderr $errText -Code $exitCode
}

$summaryText = $combined
if ($null -ne $combined -and $combined.Length -gt 500) {
    $summaryText = $combined.Substring(0, 500) + '...'
}
$exitCodeInt = [int]$exitCode
$result = [pscustomobject]@{
    provider = $Provider
    worker_id = $WorkerId
    session_id = $null
    model = $Model
    reasoning_tier = $ReasoningTier
    reasoning_effort = $ReasoningEffort
    always_approve = $alwaysApproveApplied
    exit_code = $exitCodeInt
    classification = [string]$classification.classification
    fallback_eligible = [bool]$classification.fallback_eligible
    classification_reason = [string]$classification.reason
    raw_stdout_path = $stdoutPath
    raw_stderr_path = $stderrPath
    changed_paths = @()
    summary = $summaryText
    error_message = $(if ($exitCodeInt -ne 0) { [string]$classification.reason } else { $null })
    started_at = $started.ToString('o')
    ended_at = $ended.ToString('o')
    timed_out = [bool]$timedOut
}

Write-MmoJson -LiteralPath (Join-Path $workerDir 'result.json') -InputObject $result
Write-Output (ConvertTo-MmoJson -InputObject $result)
return
