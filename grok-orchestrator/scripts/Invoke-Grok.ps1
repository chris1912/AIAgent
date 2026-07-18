# Invoke Grok for one bounded worker stage: safe argv, policy gate, timeout tree kill, result envelope.
# Authored 2026-07-18.
[CmdletBinding()]
param(
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
    [string]$ExtraArgsJson = '',
    [string]$ExtraArgsJsonPath = '',
    [string]$DiscoveryJsonPath = '',
    [string]$RegistryPath = '',
    # Kept for backward-compatible call sites; structured invoke always enforces discovery.
    [switch]$RequireDiscovery,
    [switch]$NoAlwaysApprove,
    [switch]$DryBuildOnly
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Merge-GoExtraArgs {
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

if (-not [string]::IsNullOrWhiteSpace($ExtraArgsJsonPath)) {
    if (-not (Test-Path -LiteralPath $ExtraArgsJsonPath)) {
        throw "ExtraArgsJsonPath not found: $ExtraArgsJsonPath"
    }
    try {
        $parsedPath = Get-Content -LiteralPath $ExtraArgsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ExtraArgs = Merge-GoExtraArgs -Base $ExtraArgs -More @($parsedPath)
    }
    catch {
        throw "Invalid ExtraArgsJsonPath content (expected JSON string array): $($_.Exception.Message)"
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExtraArgsJson)) {
    try {
        $parsedExtra = $ExtraArgsJson | ConvertFrom-Json
        $ExtraArgs = Merge-GoExtraArgs -Base $ExtraArgs -More @($parsedExtra)
    }
    catch {
        throw "Invalid -ExtraArgsJson (expected JSON string array): $($_.Exception.Message)"
    }
}

function Invoke-GoClassifyLocal {
    param([string]$Text, [string]$Stderr = '', [int]$Code)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("go-cls-" + [guid]::NewGuid().ToString() + '.json')
    $raw = $null
    $errPath = $null
    try {
        $scriptPath = Join-Path $PSScriptRoot 'Classify-Result.ps1'
        $psArgs = @('-NoProfile', '-NonInteractive', '-File', $scriptPath, '-ExitCode', "$Code", '-OutJson', $tmp)
        if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
            $errPath = Join-Path ([System.IO.Path]::GetTempPath()) ("go-err-" + [guid]::NewGuid().ToString() + '.txt')
            Write-GoUtf8Text -LiteralPath $errPath -Text $Stderr
            $psArgs += @('-StderrPath', $errPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($Text)) {
            $raw = Join-Path ([System.IO.Path]::GetTempPath()) ("go-raw-" + [guid]::NewGuid().ToString() + '.txt')
            Write-GoUtf8Text -LiteralPath $raw -Text $Text
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

# Early policy gate on effort/ExtraArgs before provider contact (model may still be empty).
Assert-GoInvocationPolicy -Model $Model -ReasoningEffort $ReasoningEffort -ReasoningTier $ReasoningTier -ExtraArgs $ExtraArgs

$registry = Get-GoRegistry -RegistryPath $RegistryPath
$cli = $registry.cli

# Discovery is the safe default for structured Invoke-Grok: refuse before provider contact when
# discovery is absent, unavailable, or has no eligible models. Manual direct CLI handoff
# (documented in SKILL.md) is the compatibility path outside this runner contract.
# -RequireDiscovery is accepted for call-site compatibility and is always effectively on.
$discovery = $null
$elig = @()
if ([string]::IsNullOrWhiteSpace($DiscoveryJsonPath)) {
    throw 'Structured Invoke-Grok requires -DiscoveryJsonPath with a valid discovery snapshot (available=true and at least one eligible model). Run Discover-Grok.ps1 first, or use the documented manual direct CLI path for ad-hoc calls.'
}
if (-not (Test-Path -LiteralPath $DiscoveryJsonPath)) {
    throw "DiscoveryJsonPath not found: $DiscoveryJsonPath"
}
$discovery = Get-Content -LiteralPath $DiscoveryJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$avail = $false
if ($null -ne $discovery.available) { $avail = [bool]$discovery.available }
elseif ($null -ne $discovery.providers -and $null -ne $discovery.providers.grok) {
    $avail = [bool]$discovery.providers.grok.available
}
if (-not $avail) {
    throw 'Discovery reports Grok unavailable; refusing invocation.'
}
if ($null -ne $discovery.eligible_models) { $elig = @($discovery.eligible_models) }
elseif ($null -ne $discovery.providers -and $null -ne $discovery.providers.grok -and $null -ne $discovery.providers.grok.eligible_models) {
    $elig = @($discovery.providers.grok.eligible_models)
}
$elig = @($elig | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($elig.Count -lt 1) {
    throw 'Discovery has no eligible Grok models; refusing invocation.'
}

if ([string]::IsNullOrWhiteSpace($Model)) {
    $defaultHint = ''
    if ($null -ne $registry.model_hints -and $null -ne $registry.model_hints.highest -and $registry.model_hints.highest.model) {
        $defaultHint = [string]$registry.model_hints.highest.model
    }
    if (-not [string]::IsNullOrWhiteSpace($defaultHint)) {
        $resolvedDefault = Resolve-GoModelFromDiscovery -ModelHint $defaultHint -EligibleModels $elig -Optional
        if (-not [string]::IsNullOrWhiteSpace([string]$resolvedDefault)) {
            $Model = [string]$resolvedDefault
        }
    }
    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = [string]$elig[0]
    }
}
else {
    $Model = [string](Resolve-GoModelFromDiscovery -ModelHint $Model -EligibleModels $elig -Optional:([bool]$false))
}

if ([string]::IsNullOrWhiteSpace($Executable)) {
    if ($null -ne $discovery) {
        if ($discovery.executable) { $Executable = [string]$discovery.executable }
        elseif ($discovery.providers -and $discovery.providers.grok -and $discovery.providers.grok.executable) {
            $Executable = [string]$discovery.providers.grok.executable
        }
    }
}
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Resolve-GoExecutable -Names @($cli.cli_names) -CommonPaths @($cli.common_paths)
}
if ([string]::IsNullOrWhiteSpace($Executable)) {
    throw "Grok executable not found."
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
    $order = @($registry.reasoning_tier_policy.provider_effort_order_desc)
    if ($order.Count -lt 1) { $order = @('high', 'medium', 'low') }
    $map = Get-GoAllowedReasoningLabels -OrderedDescending $order
    $ReasoningEffort = Resolve-GoReasoningTier -Tier $ReasoningTier -AllowedMap $map
}

Assert-GoInvocationPolicy -Model $Model -ReasoningEffort $ReasoningEffort -ReasoningTier $ReasoningTier -ExtraArgs $ExtraArgs

$promptText = $Prompt
if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    $promptText = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
}

$argList = New-Object System.Collections.Generic.List[string]
$alwaysApproveApplied = $false
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
foreach ($a in $ExtraArgs) { $argList.Add($a) | Out-Null }

Assert-GoInvocationPolicy -Model $Model -ReasoningEffort $ReasoningEffort -ReasoningTier $ReasoningTier -ExtraArgs @() -BuiltArgs @($argList)

$request = [pscustomobject]@{
    provider = 'grok'
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
Write-GoJson -LiteralPath (Join-Path $workerDir 'request.json') -InputObject $request

if ($DryBuildOnly) {
    $dry = [pscustomobject]@{
        provider = 'grok'
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
    Write-GoJson -LiteralPath (Join-Path $workerDir 'result.json') -InputObject $dry
    Write-Output (ConvertTo-GoJson -InputObject $dry)
    return
}

# Support "powershell.exe -NoProfile -File path\to\fake.ps1" style fake executables for offline tests.
$exePath = $Executable
$prefixArgs = @()
if ($Executable -match '(?i)powershell(\.exe)?\s+-NoProfile\s+-File\s+"?([^"]+\.ps1)"?') {
    $exePath = 'powershell.exe'
    $fakeScript = $Matches[2]
    $prefixArgs = @('-NoProfile', '-NonInteractive', '-File', $fakeScript)
}
elseif ($Executable.ToLowerInvariant().EndsWith('.ps1')) {
    $exePath = 'powershell.exe'
    $prefixArgs = @('-NoProfile', '-NonInteractive', '-File', $Executable)
}

$fullArgs = @($prefixArgs) + @($argList)

$stdoutPath = Join-Path $workerDir 'stdout.log'
$stderrPath = Join-Path $workerDir 'stderr.log'
$pidPath = Join-Path $workerDir 'WORKER_PID.txt'
$started = [datetime]::UtcNow

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exePath
$psi.WorkingDirectory = $Cwd
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$argMode = Set-GoProcessStartInfoArguments -StartInfo $psi -ArgumentList @($fullArgs)
$request | Add-Member -NotePropertyName argument_mode -NotePropertyValue $argMode -Force
$request | Add-Member -NotePropertyName resolved_executable -NotePropertyValue $exePath -Force
Write-GoJson -LiteralPath (Join-Path $workerDir 'request.json') -InputObject $request

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()
$rootStartUtc = $proc.StartTime.ToUniversalTime()
Write-GoUtf8Text -LiteralPath $pidPath -Text ([string]$proc.Id)
if ($WorkerId -eq 'w1') {
    Write-GoUtf8Text -LiteralPath (Join-Path $RunDirectory 'WORKER_PID.txt') -Text ([string]$proc.Id)
}
Write-GoUtf8Text -LiteralPath (Join-Path $RunDirectory 'GROK_PID.txt') -Text ([string]$proc.Id)
Write-GoUtf8Text -LiteralPath (Join-Path $workerDir 'GROK_PID.txt') -Text ([string]$proc.Id)

$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$timeoutMs = [Math]::Max(1000, $TimeoutSeconds * 1000)
$exited = $proc.WaitForExit($timeoutMs)
if (-not $exited) {
    Stop-GoProcessTree -RootId $proc.Id -ExpectedStartUtc $rootStartUtc
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
Write-GoUtf8Text -LiteralPath $stdoutPath -Text $(if ($null -eq $outText) { '' } else { $outText })
Write-GoUtf8Text -LiteralPath $stderrPath -Text $(if ($null -eq $errText) { '' } else { $errText })
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
    $classification = Invoke-GoClassifyLocal -Text $outText -Stderr $errText -Code $exitCode
}

$summaryText = $combined
if ($null -ne $combined -and $combined.Length -gt 500) {
    $summaryText = $combined.Substring(0, 500) + '...'
}
$exitCodeInt = [int]$exitCode
$result = [pscustomobject]@{
    provider = 'grok'
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

Write-GoJson -LiteralPath (Join-Path $workerDir 'result.json') -InputObject $result
Write-Output (ConvertTo-GoJson -InputObject $result)
return
