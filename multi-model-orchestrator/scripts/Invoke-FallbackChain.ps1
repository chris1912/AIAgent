# Bounded preferred-route fallback runner with durable FALLBACKS.jsonl audit trail.
# Advances only on quota_exhausted / model_unavailable. Never invents credentials or paid credits.
# Authored 2026-07-17 hardening.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,

    # JSON array (or path to JSON) of route hops:
    # [{provider, executable, model, reasoning_tier, reasoning_effort?, cwd?, env?, timeout_seconds?, no_always_approve?}, ...]
    [Parameter(Mandatory = $true)]
    [string]$RouteJson,

    [string]$Prompt = '',
    [string]$PromptFile = '',
    [string]$WorkerIdPrefix = 'fb',
    [int]$TimeoutSeconds = 3600,
    [string[]]$ExtraArgs = @(),
    # JSON array string for multi ExtraArgs under PS 5.1 -File (cannot repeat -ExtraArgs).
    [string]$ExtraArgsJson = '',
    # Preferred multi-value path: UTF-8 JSON string array file (avoids -File quoting loss).
    [string]$ExtraArgsJsonPath = '',
    [ValidateSet('BLOCKED', 'FAILED')]
    [string]$ExhaustedSentinel = 'BLOCKED',
    [switch]$DryBuildOnly
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not [string]::IsNullOrWhiteSpace($ExtraArgsJsonPath)) {
    if (-not (Test-Path -LiteralPath $ExtraArgsJsonPath)) {
        throw "ExtraArgsJsonPath not found: $ExtraArgsJsonPath"
    }
    try {
        $parsedPath = Get-Content -LiteralPath $ExtraArgsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $ExtraArgs = @(@($ExtraArgs) + @($parsedPath) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
    catch {
        throw "Invalid ExtraArgsJsonPath content: $($_.Exception.Message)"
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExtraArgsJson)) {
    try {
        $parsed = $ExtraArgsJson | ConvertFrom-Json
        $ExtraArgs = @(@($ExtraArgs) + @($parsed) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
    catch {
        throw "Invalid -ExtraArgsJson: $($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($Prompt) -and [string]::IsNullOrWhiteSpace($PromptFile)) {
    throw 'Either -Prompt or -PromptFile is required.'
}
if (-not (Test-Path -LiteralPath $RunDirectory)) {
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
}
$RunDirectory = (Resolve-Path -LiteralPath $RunDirectory).Path

$route = $null
if (Test-Path -LiteralPath $RouteJson) {
    $route = Get-Content -LiteralPath $RouteJson -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    $route = $RouteJson | ConvertFrom-Json
}
$hops = @($route)
if ($hops.Count -lt 1) {
    throw 'RouteJson must contain at least one hop.'
}

$invokeScript = Join-Path $PSScriptRoot 'Invoke-Provider.ps1'
$attempts = @()
$final = $null
$stoppedReason = 'route_exhausted'
$fallbacksPath = Join-Path $RunDirectory 'FALLBACKS.jsonl'

function Write-MmoChainSentinel {
    param([string]$Kind, [string]$Detail)
    $flagName = if ($Kind -eq 'BLOCKED') { 'BLOCKED.flag' } else { 'FAILED.flag' }
    Write-MmoUtf8Text -LiteralPath (Join-Path $RunDirectory $flagName) -Text ("$Detail`n")
    Write-MmoJson -LiteralPath (Join-Path $RunDirectory 'STATUS.json') -InputObject ([ordered]@{
        run_id = Split-Path -Leaf $RunDirectory
        stage = 'fallback'
        state = $Kind.ToLowerInvariant()
        summary = $Detail
        next_action = 'codex_review'
        updated_at = [datetime]::UtcNow.ToString('o')
    })
    return
}

for ($i = 0; $i -lt $hops.Count; $i++) {
    $hop = $hops[$i]
    $provider = [string]$hop.provider
    $model = if ($hop.model) { [string]$hop.model } else { '' }
    $tier = if ($hop.reasoning_tier) { [string]$hop.reasoning_tier } else { 'highest' }
    $effort = if ($hop.reasoning_effort) { [string]$hop.reasoning_effort } else { '' }
    $exe = if ($hop.executable) { [string]$hop.executable } else { '' }
    $cwd = if ($hop.cwd) { [string]$hop.cwd } else { (Get-Location).Path }
    $timeout = if ($hop.timeout_seconds) { [int]$hop.timeout_seconds } else { $TimeoutSeconds }
    $workerId = '{0}{1}' -f $WorkerIdPrefix, ($i + 1)

    if ($tier -notin @('highest', 'second_highest')) {
        throw "Fallback hop requested forbidden reasoning_tier '$tier'."
    }
    Assert-MmoInvocationPolicy -Model $model -ReasoningEffort $effort -ReasoningTier $tier -ExtraArgs $ExtraArgs

    $invokeArgs = @(
        '-NoProfile', '-NonInteractive', '-File', $invokeScript,
        '-Provider', $provider,
        '-RunDirectory', $RunDirectory,
        '-WorkerId', $workerId,
        '-Cwd', $cwd,
        '-ReasoningTier', $tier,
        '-TimeoutSeconds', "$timeout"
    )
    if (-not [string]::IsNullOrWhiteSpace($exe)) { $invokeArgs += @('-Executable', $exe) }
    if (-not [string]::IsNullOrWhiteSpace($model)) { $invokeArgs += @('-Model', $model) }
    if (-not [string]::IsNullOrWhiteSpace($effort)) { $invokeArgs += @('-ReasoningEffort', $effort) }
    if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
        $invokeArgs += @('-PromptFile', $PromptFile)
    }
    else {
        $invokeArgs += @('-Prompt', $Prompt)
    }
    $noAlways = $false
    if ($null -ne $hop.no_always_approve) {
        $noAlways = [System.Convert]::ToBoolean($hop.no_always_approve)
    }
    if ($noAlways) { $invokeArgs += '-NoAlwaysApprove' }
    if ($DryBuildOnly) { $invokeArgs += '-DryBuildOnly' }
    # Forward ExtraArgs via a JSON file so each value remains one provider argv under PS 5.1 -File.
    $extraVals = @(@($ExtraArgs) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
    $childExtraPath = $null
    if ($extraVals.Count -gt 0) {
        $parts = @()
        foreach ($v in $extraVals) {
            $esc = $v.Replace('\', '\\').Replace('"', '\"')
            $parts += ('"' + $esc + '"')
        }
        $childExtraPath = Join-Path $RunDirectory ("extra-args-" + $workerId + ".json")
        Write-MmoUtf8Text -LiteralPath $childExtraPath -Text (('[' + ($parts -join ',') + ']') + [Environment]::NewLine)
        $invokeArgs += @('-ExtraArgsJsonPath', $childExtraPath)
    }

    # Optional per-hop env (isolated to this process tree via Start-Process env is not used;
    # set in current process then restore).
    $savedEnv = @{}
    if ($null -ne $hop.env) {
        $hop.env.PSObject.Properties | ForEach-Object {
            $name = [string]$_.Name
            $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            Set-Item -Path ("Env:" + $name) -Value ([string]$_.Value)
        }
    }

    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & powershell.exe @invokeArgs 2>&1 | Out-String
        $invokeCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEa
        foreach ($name in $savedEnv.Keys) {
            $prior = $savedEnv[$name]
            if ($null -eq $prior) {
                Remove-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -Path ("Env:" + $name) -Value $prior
            }
        }
    }

    $resultPath = Join-Path $RunDirectory (Join-Path 'workers' (Join-Path $workerId 'result.json'))
    $resultObj = $null
    if (Test-Path -LiteralPath $resultPath) {
        $resultObj = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $classification = if ($resultObj) { [string]$resultObj.classification } else { 'task_failure' }
    $fallbackEligible = if ($resultObj) { [bool]$resultObj.fallback_eligible } else { $false }
    $exitCode = if ($resultObj) { [int]$resultObj.exit_code } else { [int]$invokeCode }
    $resolvedEffort = if ($resultObj -and $resultObj.reasoning_effort) { [string]$resultObj.reasoning_effort } else { $effort }
    $resolvedTier = if ($resultObj -and $resultObj.reasoning_tier) { [string]$resultObj.reasoning_tier } else { $tier }

    $attempt = [pscustomobject]@{
        index = $i
        worker_id = $workerId
        provider = $provider
        model = $model
        reasoning_tier = $resolvedTier
        reasoning_effort = $resolvedEffort
        classification = $classification
        fallback_eligible = $fallbackEligible
        exit_code = $exitCode
        result_path = $resultPath
    }
    $attempts += $attempt
    $final = $resultObj

    $isSuccess = ($classification -eq 'success') -or ($DryBuildOnly -and $resultObj -and $resultObj.dry_run -eq $true)
    $nextProvider = ''
    $nextModel = ''
    if (($i + 1) -lt $hops.Count) {
        $nextProvider = [string]$hops[$i + 1].provider
        $nextModel = [string]$hops[$i + 1].model
    }

    # Always record the hop outcome; advancement only when fallback-eligible.
    $null = Add-MmoFallbackRecord -RunDirectory $RunDirectory `
        -Reason $(if ($isSuccess) { 'success' } elseif ($fallbackEligible) { $classification } else { "stop:$classification" }) `
        -SourceProvider $provider `
        -SourceModel $model `
        -TargetProvider $(if ($isSuccess) { '' } elseif ($fallbackEligible) { $nextProvider } else { '' }) `
        -TargetModel $(if ($isSuccess) { '' } elseif ($fallbackEligible) { $nextModel } else { '' }) `
        -ReasoningTier $resolvedTier `
        -Classification $classification `
        -FallbackEligible $fallbackEligible `
        -ExitCode $exitCode `
        -WorkerId $workerId `
        -Extra @{
            attempt_index = $i
            reasoning_effort = $resolvedEffort
            advanced = [bool]((-not $isSuccess) -and $fallbackEligible -and (($i + 1) -lt $hops.Count))
        }

    if ($isSuccess) {
        $stoppedReason = 'success'
        break
    }

    if (Test-MmoFallbackEligibleClassification -Classification $classification) {
        if (($i + 1) -ge $hops.Count) {
            $stoppedReason = 'route_exhausted'
            Write-MmoChainSentinel -Kind $ExhaustedSentinel -Detail "Fallback route exhausted after $classification on $provider/$model"
            break
        }
        # Continue to next hop.
        continue
    }

    $stoppedReason = 'non_fallback_failure'
    Write-MmoChainSentinel -Kind 'FAILED' -Detail "Non-fallback classification '$classification' on $provider/$model; auto-fallback not allowed."
    break
}

if ($stoppedReason -eq 'route_exhausted' -and -not (Test-Path -LiteralPath (Join-Path $RunDirectory 'BLOCKED.flag')) -and -not (Test-Path -LiteralPath (Join-Path $RunDirectory 'FAILED.flag'))) {
    if ($null -eq $final -or [string]$final.classification -ne 'success') {
        Write-MmoChainSentinel -Kind $ExhaustedSentinel -Detail 'Fallback route exhausted without success.'
    }
}

$summary = [pscustomobject]@{
    run_directory = $RunDirectory
    stopped_reason = $stoppedReason
    attempt_count = $attempts.Count
    attempts = $attempts
    final = $final
    fallbacks_path = $(if (Test-Path -LiteralPath $fallbacksPath) { $fallbacksPath } else { $null })
    finished_at = [datetime]::UtcNow.ToString('o')
}
Write-MmoJson -LiteralPath (Join-Path $RunDirectory 'fallback-summary.json') -InputObject $summary
Write-Output (ConvertTo-MmoJson -InputObject $summary)
return
