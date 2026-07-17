# Select provider/model/reasoning tier from registry + discovery + routing profile.
# Authored 2026-07-17; revised for case-insensitive low-model rejection + eligible lists.
# Extended 2026-07-17: explicit task attributes, visual preference, safe overrides.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'difficult_architecture', 'difficult_security', 'difficult_migration', 'difficult_debug',
        'ordinary_implementation', 'simple_mechanical'
    )]
    [Alias('Profile')]
    [string]$RoutingProfile,

    [string]$DiscoveryJsonPath = '',
    [string]$RegistryPath = '',
    [string]$OutJson = '',
    [string[]]$ExcludeModels = @(),
    # Explicit task attributes (ui, web_frontend, image_generation + aliases). Comma-joined OK under -File.
    [string[]]$TaskAttributes = @(),
    # Safe explicit override: when policy-eligible, tried before profile/attribute defaults.
    [string]$OverrideProvider = '',
    [string]$OverrideModel = '',
    [string]$OverrideModelAlias = '',
    [ValidateSet('', 'highest', 'second_highest')]
    [string]$OverrideReasoningTier = ''
)

. (Join-Path $PSScriptRoot 'Common.ps1')

# Allow -ExcludeModels A,B or repeated values when invoked via powershell -File.
$ExcludeModels = @(
    $ExcludeModels |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$TaskAttributes = @(
    $TaskAttributes |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

function Resolve-MmoAlias {
    param(
        $ProviderConfig,
        [string]$Alias,
        [string[]]$EligibleModels
    )
    if ([string]::IsNullOrWhiteSpace($Alias)) { return $null }
    $aliases = $ProviderConfig.model_aliases
    $candidates = @()
    if ($null -ne $aliases -and $null -ne $aliases.$Alias) {
        $candidates = @($aliases.$Alias)
    }
    else {
        $candidates = @($Alias)
    }
    foreach ($cand in $candidates) {
        foreach ($m in $EligibleModels) {
            if ($m -eq $cand -or $m -like "*$cand*") {
                if (Test-MmoModelEligible -ModelName $m) { return $m }
            }
        }
    }
    # Fallback candidate only if it itself is not a low tier.
    $fallback = [string]$candidates[0]
    if (Test-MmoModelEligible -ModelName $fallback) { return $fallback }
    return $null
}

function Test-MmoPrefEntryMatch {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ([string]$Left.provider -ne [string]$Right.provider) { return $false }
    $la = if ($Left.model_alias) { [string]$Left.model_alias } else { '' }
    $ra = if ($Right.model_alias) { [string]$Right.model_alias } else { '' }
    $lh = if ($Left.model_hint) { [string]$Left.model_hint } else { '' }
    $rh = if ($Right.model_hint) { [string]$Right.model_hint } else { '' }
    if ($la -and $ra -and $la -eq $ra) { return $true }
    if ($lh -and $rh -and $lh -eq $rh) { return $true }
    if ($la -and $rh -and $la -eq $rh) { return $true }
    if ($lh -and $ra -and $lh -eq $ra) { return $true }
    return $false
}

$registry = Get-MmoRegistry -RegistryPath $RegistryPath
$profileObj = $registry.routing_profiles.$RoutingProfile
if ($null -eq $profileObj) { throw "Unknown routing profile: $RoutingProfile" }

$discovery = $null
if (-not [string]::IsNullOrWhiteSpace($DiscoveryJsonPath) -and (Test-Path -LiteralPath $DiscoveryJsonPath)) {
    $discovery = Get-Content -LiteralPath $DiscoveryJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

$attrNorm = Normalize-MmoTaskAttributes -TaskAttributes $TaskAttributes -Registry $registry
$taskClass = [string]$profileObj.task_class
$tierKey = [string]$registry.reasoning_tier_policy.task_defaults.$taskClass
if ([string]::IsNullOrWhiteSpace($tierKey)) { $tierKey = 'highest' }
if ($tierKey -notin @('highest', 'second_highest')) {
    throw "Invalid reasoning tier policy value: $tierKey"
}

# Build preferred chain: optional safe override, visual preference (non-difficult), then profile.
$preferredList = New-Object System.Collections.Generic.List[object]
$visualPreferenceApplied = $false
$visualPreferenceSkippedReason = ''
$overrideApplied = $false

if (-not [string]::IsNullOrWhiteSpace($OverrideProvider)) {
    if ([string]::IsNullOrWhiteSpace($OverrideModel) -and [string]::IsNullOrWhiteSpace($OverrideModelAlias)) {
        throw 'OverrideProvider requires OverrideModel or OverrideModelAlias.'
    }
    $ov = [pscustomobject]@{
        provider = $OverrideProvider.Trim()
        model_hint = $(if (-not [string]::IsNullOrWhiteSpace($OverrideModel)) { $OverrideModel.Trim() } else { $null })
        model_alias = $(if (-not [string]::IsNullOrWhiteSpace($OverrideModelAlias)) { $OverrideModelAlias.Trim() } else { $null })
        reasoning_tier = $(if (-not [string]::IsNullOrWhiteSpace($OverrideReasoningTier)) { $OverrideReasoningTier } else { $null })
        is_override = $true
    }
    # Reject low-tier override labels up front (policy gate).
    if ($ov.model_hint -and (Test-MmoModelHasLowTier -ModelName ([string]$ov.model_hint))) {
        throw "OverrideModel '$($ov.model_hint)' embeds a forbidden low reasoning tier."
    }
    if ($ov.reasoning_tier -and $ov.reasoning_tier -notin @('highest', 'second_highest')) {
        throw "OverrideReasoningTier '$($ov.reasoning_tier)' is not allowed."
    }
    $preferredList.Add($ov) | Out-Null
    $overrideApplied = $true
}

if ($attrNorm.is_visual) {
    if ($taskClass -eq 'difficult') {
        $visualPreferenceSkippedReason = 'difficult_task_quality_not_downgraded'
    }
    else {
        $vp = $attrNorm.visual_preferred
        if ($null -ne $vp) {
            $visualEntry = [pscustomobject]@{
                provider = [string]$vp.provider
                model_alias = $(if ($vp.model_alias) { [string]$vp.model_alias } else { $null })
                model_hint = $(if ($vp.model_hint) { [string]$vp.model_hint } else { $null })
                reasoning_tier = $(if ($vp.reasoning_tier) { [string]$vp.reasoning_tier } else { 'highest' })
                is_visual_preference = $true
            }
            $preferredList.Add($visualEntry) | Out-Null
            $visualPreferenceApplied = $true
        }
    }
}

foreach ($pref in @($profileObj.preferred)) {
    $dup = $false
    $existingArr = ConvertTo-MmoObjectArray -InputObject $preferredList
    foreach ($existing in $existingArr) {
        if (Test-MmoPrefEntryMatch -Left $existing -Right $pref) { $dup = $true; break }
    }
    if (-not $dup) {
        $preferredList.Add($pref) | Out-Null
    }
}

$selection = $null
$attempts = @()
$eligibleByProvider = @{}
$routeNotes = @()

$preferredArr = ConvertTo-MmoObjectArray -InputObject $preferredList
foreach ($pref in $preferredArr) {
    $providerName = [string]$pref.provider
    $provCfg = $registry.providers.$providerName
    $rawModels = @()
    $exe = $null
    $reasoningMap = $null
    $providerKnownUnavailable = $false
    if ($null -ne $discovery -and $null -ne $discovery.providers.$providerName) {
        $d = $discovery.providers.$providerName
        if ($d.available -eq $true) {
            $exe = [string]$d.executable
            $rawModels = @($d.models)
            if ($null -ne $d.reasoning_map) { $reasoningMap = $d.reasoning_map }
        }
        else {
            $providerKnownUnavailable = $true
        }
    }
    if ($null -eq $reasoningMap) {
        if ($providerName -eq 'grok') {
            $reasoningMap = Get-MmoAllowedReasoningLabels -OrderedDescending @($provCfg.reasoning_effort_order_desc)
        }
        else {
            $reasoningMap = Get-MmoAllowedReasoningLabels -OrderedDescending @('High', 'Medium', 'Low')
        }
    }
    if (-not $providerKnownUnavailable -and [string]::IsNullOrWhiteSpace($exe) -and $null -ne $provCfg) {
        $exe = Resolve-MmoExecutable -Names @($provCfg.cli_names) -CommonPaths @($provCfg.common_paths)
    }

    $forbidden = @()
    if ($null -ne $provCfg -and $null -ne $provCfg.forbidden_model_substrings) {
        $forbidden = @($provCfg.forbidden_model_substrings)
    }

    $eligibleModels = Get-MmoEligibleModels -Models $rawModels -ForbiddenSubstrings $forbidden -ExcludeModels $ExcludeModels
    $eligibleByProvider[$providerName] = [pscustomobject]@{
        raw_models = $rawModels
        eligible_models = $eligibleModels
    }

    $model = $null
    if ($pref.model_alias) {
        $model = Resolve-MmoAlias -ProviderConfig $provCfg -Alias ([string]$pref.model_alias) -EligibleModels $eligibleModels
    }
    elseif ($pref.model_hint) {
        $hint = [string]$pref.model_hint
        $model = $eligibleModels | Where-Object { $_ -eq $hint -or $_ -like "*$hint*" } | Select-Object -First 1
        if (-not $model) {
            # Only accept undiscovered hint if it is not a low-tier label.
            if (Test-MmoModelEligible -ModelName $hint -ForbiddenSubstrings $forbidden -ExcludeModels $ExcludeModels) {
                $model = $hint
            }
        }
    }

    $prefTier = $tierKey
    if ($pref.reasoning_tier) { $prefTier = [string]$pref.reasoning_tier }
    if ($prefTier -notin @('highest', 'second_highest')) {
        throw "Preferred entry requested forbidden tier: $prefTier"
    }

    $effort = Resolve-MmoReasoningTier -Tier $prefTier -AllowedMap $reasoningMap
    if (Test-MmoForbiddenReasoningLabel -Label $effort) {
        throw "Resolved reasoning effort '$effort' is forbidden."
    }

    $allowed = $false
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        $allowed = Test-MmoModelEligible -ModelName $model -ForbiddenSubstrings $forbidden -ExcludeModels $ExcludeModels
    }

    $isVisualPref = $false
    if ($pref.PSObject.Properties.Name -contains 'is_visual_preference' -and $pref.is_visual_preference) {
        $isVisualPref = $true
    }
    $isOverride = $false
    if ($pref.PSObject.Properties.Name -contains 'is_override' -and $pref.is_override) {
        $isOverride = $true
    }

    $attempt = [pscustomobject]@{
        provider = $providerName
        model = $model
        reasoning_tier = $prefTier
        reasoning_effort = $effort
        executable = $exe
        allowed = $allowed
        available = (-not [string]::IsNullOrWhiteSpace($exe))
        eligible_models = $eligibleModels
        is_visual_preference = $isVisualPref
        is_override = $isOverride
    }
    $attempts += $attempt

    if ($allowed -and -not [string]::IsNullOrWhiteSpace($exe) -and -not [string]::IsNullOrWhiteSpace($model)) {
        $selection = $attempt
        if ($isVisualPref) {
            $routeNotes += 'selected_via_visual_task_attribute'
        }
        if ($isOverride) {
            $routeNotes += 'selected_via_explicit_override'
        }
        break
    }
    else {
        if ($isVisualPref) {
            $routeNotes += 'visual_preferred_absent_or_excluded_continue_profile'
        }
        if ($isOverride) {
            $routeNotes += 'override_absent_or_ineligible_continue_profile'
        }
    }
}

if ($null -eq $selection) {
    throw "No selectable model for profile '$RoutingProfile' after exclusions and low-tier filtering."
}

$result = [pscustomobject]@{
    profile = $RoutingProfile
    task_class = $taskClass
    task_attributes = [pscustomobject]@{
        raw = $attrNorm.raw
        canonical = $attrNorm.canonical
        unknown = $attrNorm.unknown
        is_visual = $attrNorm.is_visual
    }
    visual_preference_applied = [bool]$visualPreferenceApplied
    visual_preference_skipped_reason = $visualPreferenceSkippedReason
    override_applied = [bool]$overrideApplied
    route_notes = @($routeNotes)
    selected = $selection
    attempts = $attempts
    eligible_by_provider = $eligibleByProvider
    selected_at = [datetime]::UtcNow.ToString('o')
}

$json = ConvertTo-MmoJson -InputObject $result
if (-not [string]::IsNullOrWhiteSpace($OutJson)) {
    Write-MmoUtf8Text -LiteralPath $OutJson -Text ($json + [Environment]::NewLine)
}
Write-Output $json
return
