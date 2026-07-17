# Profile-driven sequential fallback: Select-Model preferred chain, then invoke hops.
# Behaviorally aligned with Invoke-FallbackChain: record every hop in FALLBACKS.jsonl
# (success, quota/model-unavailable advance, and terminal auth/network/task failure).
# Auto-advances only on quota_exhausted / model_unavailable. Never invents credentials or paid credits.
# Authored 2026-07-17 hardening; revision: full hop audit + ExtraArgs already forwarded.
# Extended 2026-07-17: task attributes passed through Select-Model and hop audit records.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'difficult_architecture', 'difficult_security', 'difficult_migration', 'difficult_debug',
        'ordinary_implementation', 'simple_mechanical'
    )]
    [string]$RoutingProfile,

    [string]$DiscoveryJsonPath = '',
    [string]$RegistryPath = '',
    [string]$Prompt = '',
    [string]$PromptFile = '',
    [string]$Cwd = '',
    [string]$WorkerIdPrefix = 'fb',
    [int]$TimeoutSeconds = 3600,
    [string[]]$ExtraArgs = @(),
    # JSON array string for multi ExtraArgs under PS 5.1 -File (cannot repeat -ExtraArgs).
    [string]$ExtraArgsJson = '',
    # Preferred multi-value path: UTF-8 JSON string array file (avoids -File quoting loss).
    [string]$ExtraArgsJsonPath = '',
    # Explicit task attributes forwarded to Select-Model (comma-joined OK under -File).
    [string[]]$TaskAttributes = @(),
    [string]$OverrideProvider = '',
    [string]$OverrideModel = '',
    [string]$OverrideModelAlias = '',
    [ValidateSet('', 'highest', 'second_highest')]
    [string]$OverrideReasoningTier = '',
    [switch]$NoAlwaysApprove,
    [switch]$DryBuildOnly,
    [ValidateSet('BLOCKED', 'FAILED')]
    [string]$ExhaustedSentinel = 'BLOCKED'
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
if ([string]::IsNullOrWhiteSpace($Cwd)) {
    $Cwd = (Get-Location).Path
}
$Cwd = (Resolve-Path -LiteralPath $Cwd).Path

$TaskAttributes = @(
    $TaskAttributes |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$selectScript = Join-Path $PSScriptRoot 'Select-Model.ps1'
$invokeScript = Join-Path $PSScriptRoot 'Invoke-Provider.ps1'
$lastSelection = $null

function Invoke-MmoSelectJson {
    param([string[]]$ExcludeModels)
    $args = @(
        '-NoProfile', '-NonInteractive', '-File', $selectScript,
        '-RoutingProfile', $RoutingProfile
    )
    if (-not [string]::IsNullOrWhiteSpace($DiscoveryJsonPath)) {
        $args += @('-DiscoveryJsonPath', $DiscoveryJsonPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($RegistryPath)) {
        $args += @('-RegistryPath', $RegistryPath)
    }
    if ($null -ne $ExcludeModels -and $ExcludeModels.Count -gt 0) {
        $args += @('-ExcludeModels', ($ExcludeModels -join ','))
    }
    if ($null -ne $TaskAttributes -and $TaskAttributes.Count -gt 0) {
        $args += @('-TaskAttributes', ($TaskAttributes -join ','))
    }
    if (-not [string]::IsNullOrWhiteSpace($OverrideProvider)) {
        $args += @('-OverrideProvider', $OverrideProvider)
    }
    if (-not [string]::IsNullOrWhiteSpace($OverrideModel)) {
        $args += @('-OverrideModel', $OverrideModel)
    }
    if (-not [string]::IsNullOrWhiteSpace($OverrideModelAlias)) {
        $args += @('-OverrideModelAlias', $OverrideModelAlias)
    }
    if (-not [string]::IsNullOrWhiteSpace($OverrideReasoningTier)) {
        $args += @('-OverrideReasoningTier', $OverrideReasoningTier)
    }
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & powershell.exe @args 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEa
    }
    if ($code -ne 0) {
        return [pscustomobject]@{ ok = $false; exit_code = $code; raw = $raw; object = $null }
    }
    $trim = $raw.Trim()
    $idx = $trim.IndexOf('{')
    if ($idx -lt 0) {
        return [pscustomobject]@{ ok = $false; exit_code = $code; raw = $raw; object = $null }
    }
    $jsonText = $trim.Substring($idx)
    $last = $jsonText.LastIndexOf('}')
    if ($last -ge 0) { $jsonText = $jsonText.Substring(0, $last + 1) }
    try {
        $obj = $jsonText | ConvertFrom-Json
        return [pscustomobject]@{ ok = $true; exit_code = 0; raw = $raw; object = $obj }
    }
    catch {
        return [pscustomobject]@{ ok = $false; exit_code = $code; raw = $raw; object = $null }
    }
}

function Write-MmoTerminalSentinel {
    param([string]$Kind, [string]$Detail)
    $flagName = switch ($Kind) {
        'BLOCKED' { 'BLOCKED.flag' }
        'FAILED' { 'FAILED.flag' }
        default { 'FAILED.flag' }
    }
    $flagPath = Join-Path $RunDirectory $flagName
    Write-MmoUtf8Text -LiteralPath $flagPath -Text ("$Detail`n")
    $statusPath = Join-Path $RunDirectory 'STATUS.json'
    $status = [ordered]@{
        run_id = Split-Path -Leaf $RunDirectory
        stage = 'fallback'
        state = $Kind.ToLowerInvariant()
        summary = $Detail
        next_action = 'codex_review'
        updated_at = [datetime]::UtcNow.ToString('o')
    }
    Write-MmoJson -LiteralPath $statusPath -InputObject $status
    return $flagPath
}

$exclude = New-Object System.Collections.Generic.List[string]
$hops = @()
$attemptIndex = 0
$finalResult = $null
$chainExhausted = $false
$nonFallbackStop = $false
$sourceProvider = ''
$sourceModel = ''
$maxHops = 8

while ($attemptIndex -lt $maxHops) {
    $attemptIndex++
    $sel = Invoke-MmoSelectJson -ExcludeModels @($exclude)
    if (-not $sel.ok -or $null -eq $sel.object -or $null -eq $sel.object.selected) {
        $chainExhausted = $true
        $detail = "Fallback chain exhausted or no selectable model for profile '$RoutingProfile'."
        if ($attemptIndex -eq 1) {
            $null = Write-MmoTerminalSentinel -Kind 'FAILED' -Detail $detail
            $nonFallbackStop = $true
        }
        else {
            $null = Write-MmoTerminalSentinel -Kind $ExhaustedSentinel -Detail $detail
        }
        break
    }

    $lastSelection = $sel.object
    $selected = $sel.object.selected
    $provider = [string]$selected.provider
    $model = [string]$selected.model
    $tier = [string]$selected.reasoning_tier
    $effort = [string]$selected.reasoning_effort
    $exe = [string]$selected.executable

    Assert-MmoInvocationPolicy -Model $model -ReasoningEffort $effort -ReasoningTier $tier -ExtraArgs $ExtraArgs

    $workerId = '{0}{1}' -f $WorkerIdPrefix, $attemptIndex
    $selectionArtifact = Join-Path $RunDirectory ("selection-" + $workerId + ".json")
    Write-MmoJson -LiteralPath $selectionArtifact -InputObject $sel.object

    $invokeArgs = @(
        '-NoProfile', '-NonInteractive', '-File', $invokeScript,
        '-Provider', $provider,
        '-RunDirectory', $RunDirectory,
        '-WorkerId', $workerId,
        '-Cwd', $Cwd,
        '-ReasoningTier', $tier,
        '-TimeoutSeconds', "$TimeoutSeconds"
    )
    if (-not [string]::IsNullOrWhiteSpace($exe)) {
        # Discovery may store a display-only pseudo executable; only pass real paths.
        if (Test-Path -LiteralPath $exe) {
            $invokeArgs += @('-Executable', $exe)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($model)) { $invokeArgs += @('-Model', $model) }
    if (-not [string]::IsNullOrWhiteSpace($effort)) { $invokeArgs += @('-ReasoningEffort', $effort) }
    if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
        $invokeArgs += @('-PromptFile', $PromptFile)
    }
    else {
        $invokeArgs += @('-Prompt', $Prompt)
    }
    if ($NoAlwaysApprove) { $invokeArgs += '-NoAlwaysApprove' }
    if ($DryBuildOnly) { $invokeArgs += '-DryBuildOnly' }
    # Forward ExtraArgs via a JSON file so each value remains one provider argv under PS 5.1 -File.
    $extraVals = @(@($ExtraArgs) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
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

    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOut = & powershell.exe @invokeArgs 2>&1 | Out-String
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

    $taskAttrsCanonical = @()
    $taskAttrsRaw = @()
    $taskAttrsUnknown = @()
    $visualPrefApplied = $false
    if ($null -ne $sel.object.task_attributes) {
        if ($null -ne $sel.object.task_attributes.canonical) {
            $taskAttrsCanonical = @($sel.object.task_attributes.canonical | ForEach-Object { [string]$_ })
        }
        if ($null -ne $sel.object.task_attributes.raw) {
            $taskAttrsRaw = @($sel.object.task_attributes.raw | ForEach-Object { [string]$_ })
        }
        if ($null -ne $sel.object.task_attributes.unknown) {
            $taskAttrsUnknown = @($sel.object.task_attributes.unknown | ForEach-Object { [string]$_ })
        }
    }
    if ($null -ne $sel.object.visual_preference_applied) {
        $visualPrefApplied = [bool]$sel.object.visual_preference_applied
    }

    $hop = [pscustomobject]@{
        attempt = $attemptIndex
        worker_id = $workerId
        provider = $provider
        model = $model
        reasoning_tier = $tier
        reasoning_effort = $resolvedEffort
        classification = $classification
        fallback_eligible = $fallbackEligible
        exit_code = $exitCode
        result_path = $resultPath
        selection_path = $selectionArtifact
        task_attributes = $taskAttrsCanonical
    }
    $hops += $hop
    $finalResult = $resultObj

    $isSuccess = ($classification -eq 'success') -or ($DryBuildOnly -and $resultObj -and $resultObj.dry_run -eq $true)
    $nextExclude = @($exclude) + @($model)
    $probe = $null
    $targetProvider = ''
    $targetModel = ''
    if ((-not $isSuccess) -and (Test-MmoFallbackEligibleClassification -Classification $classification)) {
        $probe = Invoke-MmoSelectJson -ExcludeModels $nextExclude
        if ($probe.ok -and $null -ne $probe.object -and $null -ne $probe.object.selected) {
            $targetProvider = [string]$probe.object.selected.provider
            $targetModel = [string]$probe.object.selected.model
        }
    }

    # Always record the hop (success, fallback advance, and terminal non-fallback failure).
    $null = Add-MmoFallbackRecord -RunDirectory $RunDirectory `
        -Reason $(if ($isSuccess) { 'success' } elseif ($fallbackEligible) { $classification } else { "stop:$classification" }) `
        -SourceProvider $provider `
        -SourceModel $model `
        -TargetProvider $(if ($isSuccess) { '' } elseif ($fallbackEligible) { $targetProvider } else { '' }) `
        -TargetModel $(if ($isSuccess) { '' } elseif ($fallbackEligible) { $targetModel } else { '' }) `
        -ReasoningTier $tier `
        -Classification $classification `
        -FallbackEligible $fallbackEligible `
        -ExitCode $exitCode `
        -WorkerId $workerId `
        -Extra @{
            routing_profile = $RoutingProfile
            attempt = $attemptIndex
            reasoning_effort = $resolvedEffort
            advanced = [bool]((-not $isSuccess) -and $fallbackEligible -and (-not [string]::IsNullOrWhiteSpace($targetModel)))
            task_attributes = $taskAttrsCanonical
            task_attributes_raw = $taskAttrsRaw
            task_attributes_unknown = $taskAttrsUnknown
            visual_preference_applied = $visualPrefApplied
            selection_path = $selectionArtifact
        }

    if ($isSuccess) {
        break
    }

    if (Test-MmoFallbackEligibleClassification -Classification $classification) {
        if ($null -eq $probe -or -not $probe.ok -or $null -eq $probe.object -or $null -eq $probe.object.selected) {
            $chainExhausted = $true
            $null = Write-MmoTerminalSentinel -Kind $ExhaustedSentinel -Detail "Fallback chain exhausted after $classification on $provider/$model"
            break
        }

        $exclude.Add($model) | Out-Null
        $sourceProvider = $provider
        $sourceModel = $model
        continue
    }

    # Non-fallback failure: stop without advancing.
    $nonFallbackStop = $true
    $null = Write-MmoTerminalSentinel -Kind 'FAILED' -Detail "Non-fallback classification '$classification' on $provider/$model; auto-fallback not allowed."
    break
}

if ($attemptIndex -ge $maxHops -and -not $nonFallbackStop -and $null -ne $finalResult -and [string]$finalResult.classification -ne 'success') {
    $chainExhausted = $true
    $null = Write-MmoTerminalSentinel -Kind $ExhaustedSentinel -Detail "Fallback hop cap ($maxHops) reached."
}

$summaryAttrs = $null
if ($null -ne $lastSelection -and $null -ne $lastSelection.task_attributes) {
    $summaryAttrs = $lastSelection.task_attributes
}
elseif ($TaskAttributes.Count -gt 0) {
    $summaryAttrs = (Normalize-MmoTaskAttributes -TaskAttributes $TaskAttributes)
}

$summary = [pscustomobject]@{
    run_directory = $RunDirectory
    routing_profile = $RoutingProfile
    task_attributes = $summaryAttrs
    hop_count = $hops.Count
    hops = $hops
    final = $finalResult
    chain_exhausted = [bool]$chainExhausted
    non_fallback_stop = [bool]$nonFallbackStop
    fallbacks_path = $(if (Test-Path -LiteralPath (Join-Path $RunDirectory 'FALLBACKS.jsonl')) { Join-Path $RunDirectory 'FALLBACKS.jsonl' } else { $null })
    finished_at = [datetime]::UtcNow.ToString('o')
}
Write-MmoJson -LiteralPath (Join-Path $RunDirectory 'fallback-summary.json') -InputObject $summary
Write-Output (ConvertTo-MmoJson -InputObject $summary)
return
