# Grok-only fallback chain. Advances only on quota_exhausted / model_unavailable.
# Authored 2026-07-18.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,

    # Optional explicit route JSON array/path:
    # [{model, reasoning_tier, reasoning_effort?, executable?, cwd?, timeout_seconds?, optional?}, ...]
    [string]$RouteJson = '',

    [string]$DiscoveryJsonPath = '',
    [string]$RegistryPath = '',
    [string]$Prompt = '',
    [string]$PromptFile = '',
    [string]$Cwd = '',
    [string]$WorkerIdPrefix = 'fb',
    [int]$TimeoutSeconds = 3600,
    [string[]]$ExtraArgs = @(),
    [string]$ExtraArgsJson = '',
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

$registry = Get-GoRegistry -RegistryPath $RegistryPath

function Write-GoFallbackDiscoveryBlocked {
    param([string]$Detail)
    Write-GoStageArtifacts -RunDirectory $RunDirectory -Status ([ordered]@{
        run_id = Split-Path -Leaf $RunDirectory
        stage = 'fallback'
        state = 'blocked'
        summary = $Detail
        next_action = 'codex_review'
        updated_at = [datetime]::UtcNow.ToString('o')
    }) -StageReport "# Blocked`n`n$Detail`n"
    Write-GoSentinel -RunDirectory $RunDirectory -Kind 'BLOCKED' -Detail $Detail
    $summary = [pscustomobject]@{
        run_directory = $RunDirectory
        stopped_reason = 'discovery_unavailable'
        attempt_count = 0
        attempts = @()
        final = $null
        finished_at = [datetime]::UtcNow.ToString('o')
    }
    Write-GoJson -LiteralPath (Join-Path $RunDirectory 'fallback-summary.json') -InputObject $summary
    Write-Output (ConvertTo-GoJson -InputObject $summary)
    return
}

# Default route requires a valid discovery snapshot (safe structured default).
# Explicit -RouteJson still needs discovery so child Invoke-Grok keeps the same gate.
$discovery = $null
$eligible = @()
$discoveredExe = ''
$usingDefaultRoute = [string]::IsNullOrWhiteSpace($RouteJson)
if ([string]::IsNullOrWhiteSpace($DiscoveryJsonPath)) {
    $detail = 'Grok discovery unavailable or empty; refusing fallback chain. Provide -DiscoveryJsonPath from Discover-Grok.ps1 (structured default), or use the documented manual direct CLI path outside this runner.'
    Write-GoFallbackDiscoveryBlocked -Detail $detail
    return
}
if (-not (Test-Path -LiteralPath $DiscoveryJsonPath)) {
    throw "DiscoveryJsonPath not found: $DiscoveryJsonPath"
}
$discovery = Get-Content -LiteralPath $DiscoveryJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -ne $discovery.eligible_models) {
    $eligible = @($discovery.eligible_models)
}
elseif ($null -ne $discovery.providers -and $null -ne $discovery.providers.grok) {
    $eligible = @($discovery.providers.grok.eligible_models)
}
$eligible = @($eligible | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($discovery.executable) { $discoveredExe = [string]$discovery.executable }
elseif ($discovery.providers -and $discovery.providers.grok) {
    $discoveredExe = [string]$discovery.providers.grok.executable
}
$avail = $false
if ($null -ne $discovery.available) { $avail = [bool]$discovery.available }
elseif ($discovery.providers -and $discovery.providers.grok) { $avail = [bool]$discovery.providers.grok.available }
if (-not $avail -or $eligible.Count -lt 1) {
    $detail = 'Grok discovery unavailable or empty; refusing fallback chain.'
    Write-GoFallbackDiscoveryBlocked -Detail $detail
    return
}

function Build-GoDefaultRoute {
    param($Registry, [string[]]$EligibleModels)
    $hops = New-Object System.Collections.Generic.List[object]
    $chain = @($Registry.fallback_chain_default)
    if ($chain.Count -lt 1) {
        $chain = @(
            [pscustomobject]@{ model_hint = 'grok-4.5'; reasoning_tier = 'highest' },
            [pscustomobject]@{ model_hint = 'grok-composer-2.5-fast'; reasoning_tier = 'second_highest'; optional = $true }
        )
    }
    foreach ($item in $chain) {
        $hint = if ($item.model_hint) { [string]$item.model_hint } elseif ($item.model) { [string]$item.model } else { '' }
        $tier = if ($item.reasoning_tier) { [string]$item.reasoning_tier } else { 'highest' }
        $optional = $false
        if ($null -ne $item.optional) { $optional = [bool]$item.optional }
        try {
            $resolved = Resolve-GoModelFromDiscovery -ModelHint $hint -EligibleModels $EligibleModels -Optional:$optional
        }
        catch {
            if ($optional) { continue }
            throw
        }
        if ([string]::IsNullOrWhiteSpace($resolved)) { continue }
        $hops.Add([pscustomobject]@{
            model = $resolved
            reasoning_tier = $tier
            optional = $optional
        }) | Out-Null
    }
    if ($hops.Count -lt 1 -and $EligibleModels.Count -gt 0) {
        # At least use first eligible model at highest.
        $hops.Add([pscustomobject]@{
            model = [string]$EligibleModels[0]
            reasoning_tier = 'highest'
            optional = $false
        }) | Out-Null
    }
    # Explicit ToArray: @($List[object]) throws on Windows PowerShell 5.1.
    return [object[]]$hops.ToArray()
}

$hops = @()
if (-not $usingDefaultRoute) {
    $route = $null
    if (Test-Path -LiteralPath $RouteJson) {
        $route = Get-Content -LiteralPath $RouteJson -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else {
        $route = $RouteJson | ConvertFrom-Json
    }
    $hops = @($route)
}
else {
    $hops = @(Build-GoDefaultRoute -Registry $registry -EligibleModels $eligible)
}

if ($hops.Count -lt 1) {
    throw 'No Grok fallback hops available (discovery empty and no non-optional route).'
}

$invokeScript = Join-Path $PSScriptRoot 'Invoke-Grok.ps1'
$attempts = @()
$final = $null
$stoppedReason = 'route_exhausted'
$fallbacksPath = Join-Path $RunDirectory 'FALLBACKS.jsonl'

function Write-GoChainSentinel {
    param([string]$Kind, [string]$Detail)
    $statusState = $Kind.ToLowerInvariant()
    Write-GoStageArtifacts -RunDirectory $RunDirectory -Status ([ordered]@{
        run_id = Split-Path -Leaf $RunDirectory
        stage = 'fallback'
        state = $statusState
        summary = $Detail
        next_action = 'codex_review'
        updated_at = [datetime]::UtcNow.ToString('o')
    }) -StageReport "# Fallback stage`n`n$Detail`n"
    Write-GoSentinel -RunDirectory $RunDirectory -Kind $Kind -Detail $Detail
    return
}

for ($i = 0; $i -lt $hops.Count; $i++) {
    $hop = $hops[$i]
    $model = if ($hop.model) { [string]$hop.model } elseif ($hop.model_hint) { [string]$hop.model_hint } else { '' }
    $tier = if ($hop.reasoning_tier) { [string]$hop.reasoning_tier } else { 'highest' }
    $effort = if ($hop.reasoning_effort) { [string]$hop.reasoning_effort } else { '' }
    $exe = if ($hop.executable) { [string]$hop.executable } else { $discoveredExe }
    $cwd = if ($hop.cwd) { [string]$hop.cwd } elseif (-not [string]::IsNullOrWhiteSpace($Cwd)) { $Cwd } else { (Get-Location).Path }
    $timeout = if ($hop.timeout_seconds) { [int]$hop.timeout_seconds } else { $TimeoutSeconds }
    $workerId = '{0}{1}' -f $WorkerIdPrefix, ($i + 1)

    if ($tier -notin @('highest', 'second_highest')) {
        throw "Fallback hop requested forbidden reasoning_tier '$tier'."
    }
    Assert-GoInvocationPolicy -Model $model -ReasoningEffort $effort -ReasoningTier $tier -ExtraArgs $ExtraArgs

    $invokeArgs = @(
        '-NoProfile', '-NonInteractive', '-File', $invokeScript,
        '-RunDirectory', $RunDirectory,
        '-WorkerId', $workerId,
        '-Cwd', $cwd,
        '-ReasoningTier', $tier,
        '-TimeoutSeconds', "$timeout"
    )
    if (-not [string]::IsNullOrWhiteSpace($exe)) { $invokeArgs += @('-Executable', $exe) }
    if (-not [string]::IsNullOrWhiteSpace($model)) { $invokeArgs += @('-Model', $model) }
    if (-not [string]::IsNullOrWhiteSpace($effort)) { $invokeArgs += @('-ReasoningEffort', $effort) }
    # Structured child invoke always gates on discovery (safe default).
    $invokeArgs += @('-DiscoveryJsonPath', $DiscoveryJsonPath)
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

    $extraVals = @(@($ExtraArgs) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
    $childExtraPath = $null
    if ($extraVals.Count -gt 0) {
        $parts = @()
        foreach ($v in $extraVals) {
            $esc = $v.Replace('\', '\\').Replace('"', '\"')
            $parts += ('"' + $esc + '"')
        }
        $childExtraPath = Join-Path $RunDirectory ("extra-args-" + $workerId + ".json")
        Write-GoUtf8Text -LiteralPath $childExtraPath -Text (('[' + ($parts -join ',') + ']') + [Environment]::NewLine)
        $invokeArgs += @('-ExtraArgsJsonPath', $childExtraPath)
    }

    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & powershell.exe @invokeArgs 2>&1 | Out-String
        $invokeCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEa
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
        provider = 'grok'
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
    $nextModel = ''
    if (($i + 1) -lt $hops.Count) {
        $nextHop = $hops[$i + 1]
        $nextModel = if ($nextHop.model) { [string]$nextHop.model } elseif ($nextHop.model_hint) { [string]$nextHop.model_hint } else { '' }
    }

    $null = Add-GoFallbackRecord -RunDirectory $RunDirectory `
        -Reason $(if ($isSuccess) { 'success' } elseif ($fallbackEligible) { $classification } else { "stop:$classification" }) `
        -SourceModel $model `
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

    if (Test-GoFallbackEligibleClassification -Classification $classification) {
        if (($i + 1) -ge $hops.Count) {
            $stoppedReason = 'route_exhausted'
            Write-GoChainSentinel -Kind $ExhaustedSentinel -Detail "Grok fallback route exhausted after $classification on $model"
            break
        }
        continue
    }

    $stoppedReason = 'non_fallback_failure'
    Write-GoChainSentinel -Kind 'FAILED' -Detail "Non-fallback classification '$classification' on grok/$model; auto-fallback not allowed."
    break
}

if ($stoppedReason -eq 'route_exhausted' -and -not (Test-Path -LiteralPath (Join-Path $RunDirectory 'BLOCKED.flag')) -and -not (Test-Path -LiteralPath (Join-Path $RunDirectory 'FAILED.flag'))) {
    if ($null -eq $final -or [string]$final.classification -ne 'success') {
        Write-GoChainSentinel -Kind $ExhaustedSentinel -Detail 'Grok fallback route exhausted without success.'
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
Write-GoJson -LiteralPath (Join-Path $RunDirectory 'fallback-summary.json') -InputObject $summary
Write-Output (ConvertTo-GoJson -InputObject $summary)
return
