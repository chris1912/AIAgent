# Shared helpers for multi-model-orchestrator.
# Authored 2026-07-17.
$ErrorActionPreference = 'Stop'
$script:MmoUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-MmoUtf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [switch]$Append
    )
    if ($null -eq $Text) { $Text = '' }
    $dir = Split-Path -Parent -Path $LiteralPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ($Append) {
        [System.IO.File]::AppendAllText($LiteralPath, $Text, $script:MmoUtf8NoBom)
        return
    }
    [System.IO.File]::WriteAllText($LiteralPath, $Text, $script:MmoUtf8NoBom)
    return
}

function Expand-MmoEnvPath {
    param([Parameter(Mandatory = $true)][string]$PathTemplate)
    return [Environment]::ExpandEnvironmentVariables($PathTemplate)
}

function Get-MmoSkillRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-MmoRegistry {
    param([string]$RegistryPath = '')
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $RegistryPath = Join-Path (Get-MmoSkillRoot) 'config\model-registry.json'
    }
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        throw "Model registry not found: $RegistryPath"
    }
    return (Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function ConvertTo-MmoJson {
    param([Parameter(Mandatory = $true)]$InputObject, [int]$Depth = 12)
    return ($InputObject | ConvertTo-Json -Depth $Depth)
}

function Write-MmoJson {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$Depth = 12
    )
    Write-MmoUtf8Text -LiteralPath $LiteralPath -Text ((ConvertTo-MmoJson -InputObject $InputObject -Depth $Depth) + [Environment]::NewLine)
    return
}

function Resolve-MmoExecutable {
    <#
    Resolve a provider executable from PATH then common install locations.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [string[]]$CommonPaths = @()
    )
    foreach ($name in $Names) {
        $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Source) {
            return $cmd.Source
        }
    }
    foreach ($template in $CommonPaths) {
        $candidate = Expand-MmoEnvPath -PathTemplate $template
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-MmoAllowedReasoningLabels {
    <#
    From a descending-priority list of provider effort labels, keep only the top two non-forbidden.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$OrderedDescending,
        [string[]]$Forbidden = @('low', 'lowest', 'minimal')
    )
    $allowed = New-Object System.Collections.Generic.List[string]
    foreach ($label in $OrderedDescending) {
        $norm = $label.Trim().ToLowerInvariant()
        $isForbidden = $false
        foreach ($f in $Forbidden) {
            if ($norm -eq $f.ToLowerInvariant()) { $isForbidden = $true; break }
        }
        if ($isForbidden) { continue }
        if (-not $allowed.Contains($label)) { $allowed.Add($label) }
        if ($allowed.Count -ge 2) { break }
    }
    if ($allowed.Count -lt 1) {
        throw 'No allowed reasoning tiers remain after filtering low tiers.'
    }
    return [pscustomobject]@{
        highest = $allowed[0]
        second_highest = $(if ($allowed.Count -ge 2) { $allowed[1] } else { $allowed[0] })
        labels = @($allowed)
    }
}

function Resolve-MmoReasoningTier {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('highest', 'second_highest')][string]$Tier,
        [Parameter(Mandatory = $true)]$AllowedMap
    )
    if ($Tier -eq 'highest') { return [string]$AllowedMap.highest }
    return [string]$AllowedMap.second_highest
}

function Get-MmoForbiddenReasoningTokens {
    return @('low', 'lowest', 'minimal')
}

function Test-MmoForbiddenReasoningLabel {
    <#
    True when a provider effort/reasoning label is forbidden (case-insensitive).
    #>
    param([string]$Label)
    if ([string]::IsNullOrWhiteSpace($Label)) { return $false }
    $norm = $Label.Trim().ToLowerInvariant()
    foreach ($tok in (Get-MmoForbiddenReasoningTokens)) {
        if ($norm -eq $tok) { return $true }
    }
    return $false
}

function Test-MmoModelHasLowTier {
    <#
    True when a model display name embeds a low reasoning tier (case-insensitive).
    Thinking-class models are not treated as low merely for containing other words.
    #>
    param([string]$ModelName)
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    $n = $ModelName.ToLowerInvariant()
    # Explicit parenthetical or trailing tier markers: (low), [low], low)
    if ($n -match '\(\s*low\s*\)') { return $true }
    if ($n -match '\[\s*low\s*\]') { return $true }
    if ($n -match '(^|[\s_\-])low([\s_\-]|$)') {
        # Allow names that legitimately include "low" inside other tokens only if not a tier marker.
        # Ban when "low" appears as a standalone tier word.
        return $true
    }
    if ($n -match '(^|[\s_\-])lowest([\s_\-]|$)') { return $true }
    if ($n -match '(^|[\s_\-])minimal([\s_\-]|$)') { return $true }
    return $false
}

function Test-MmoModelEligible {
    param(
        [string]$ModelName,
        [string[]]$ForbiddenSubstrings = @(),
        [string[]]$ExcludeModels = @()
    )
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    foreach ($ex in $ExcludeModels) {
        if ($ModelName -eq $ex) { return $false }
    }
    foreach ($sub in $ForbiddenSubstrings) {
        if ([string]::IsNullOrWhiteSpace($sub)) { continue }
        if ($ModelName.IndexOf($sub, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
    }
    if (Test-MmoModelHasLowTier -ModelName $ModelName) { return $false }
    return $true
}

function Get-MmoEligibleModels {
    param(
        [string[]]$Models,
        [string[]]$ForbiddenSubstrings = @(),
        [string[]]$ExcludeModels = @()
    )
    $eligible = @()
    foreach ($m in @($Models)) {
        if (Test-MmoModelEligible -ModelName $m -ForbiddenSubstrings $ForbiddenSubstrings -ExcludeModels $ExcludeModels) {
            $eligible += $m
        }
    }
    return $eligible
}

function Assert-MmoInvocationPolicy {
    <#
    Enforce highest/second-highest-only reasoning at every invocation boundary.
    Rejects low efforts, low model names, and low values smuggled via ExtraArgs.
    #>
    param(
        [string]$Model = '',
        [string]$ReasoningEffort = '',
        [ValidateSet('highest', 'second_highest')][string]$ReasoningTier = 'highest',
        [string[]]$ExtraArgs = @(),
        [string[]]$BuiltArgs = @()
    )
    if ($ReasoningTier -notin @('highest', 'second_highest')) {
        throw "Invocation policy violation: ReasoningTier '$ReasoningTier' is not allowed."
    }
    if (Test-MmoForbiddenReasoningLabel -Label $ReasoningEffort) {
        throw "Invocation policy violation: ReasoningEffort '$ReasoningEffort' is forbidden (low tier)."
    }
    if (-not [string]::IsNullOrWhiteSpace($Model) -and (Test-MmoModelHasLowTier -ModelName $Model)) {
        throw "Invocation policy violation: model '$Model' embeds a forbidden low reasoning tier."
    }

    $allArgs = @()
    if ($null -ne $ExtraArgs) { $allArgs += @($ExtraArgs) }
    if ($null -ne $BuiltArgs) { $allArgs += @($BuiltArgs) }

    for ($i = 0; $i -lt $allArgs.Count; $i++) {
        $a = [string]$allArgs[$i]
        $al = $a.ToLowerInvariant()
        if ($al -in @('--reasoning-effort', '--effort', '-reasoning-effort', '-effort')) {
            if (($i + 1) -lt $allArgs.Count) {
                $val = [string]$allArgs[$i + 1]
                if (Test-MmoForbiddenReasoningLabel -Label $val) {
                    throw "Invocation policy violation: ExtraArgs/args set $a to forbidden value '$val'."
                }
            }
        }
        # Inline forms: --reasoning-effort=low or --effort=lowest
        if ($al -match '^(--reasoning-effort|--effort)=(.*)$') {
            $val = $Matches[2]
            if (Test-MmoForbiddenReasoningLabel -Label $val) {
                throw "Invocation policy violation: arg '$a' sets a forbidden low reasoning tier."
            }
        }
        if (Test-MmoForbiddenReasoningLabel -Label $a) {
            # Bare token "low" after an effort flag is already handled; bare "low" as any arg is also banned.
            $prev = if ($i -gt 0) { [string]$allArgs[$i - 1] } else { '' }
            $prevL = $prev.ToLowerInvariant()
            if ($prevL -in @('--reasoning-effort', '--effort', '-reasoning-effort', '-effort') -or $true) {
                # Always reject bare forbidden reasoning tokens in the arg list to prevent smuggling.
                if ($al -in (Get-MmoForbiddenReasoningTokens)) {
                    throw "Invocation policy violation: forbidden reasoning token '$a' present in args."
                }
            }
        }
    }
    return
}

function ConvertTo-MmoEscapedArgument {
    <#
    Escape one argument for ProcessStartInfo.Arguments under Windows (CommandLineToArgvW rules).
    PowerShell 5.1 / .NET Framework 4.x has no ProcessStartInfo.ArgumentList, so this is required.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument) { return '""' }
    # Quote empty values, whitespace/quotes, or trailing backslash (so close-quote doubling is applied).
    $needsQuotes = ($Argument.Length -eq 0) -or ($Argument -match '[\s"]') -or $Argument.EndsWith([string][char]92)
    if (-not $needsQuotes) { return $Argument }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([char]34)
    $backslashCount = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($ch -eq [char]34) {
            if ($backslashCount -gt 0) {
                [void]$sb.Append([string]::new([char]92, $backslashCount * 2))
                $backslashCount = 0
            }
            [void]$sb.Append([char]92)
            [void]$sb.Append([char]34)
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$sb.Append([string]::new([char]92, $backslashCount))
            $backslashCount = 0
        }
        [void]$sb.Append($ch)
    }
    if ($backslashCount -gt 0) {
        [void]$sb.Append([string]::new([char]92, $backslashCount * 2))
    }
    [void]$sb.Append([char]34)
    return $sb.ToString()
}

function Join-MmoProcessArguments {
    <#
    Join argv elements into a single ProcessStartInfo.Arguments string with Windows-safe escaping.
    #>
    param([AllowEmptyCollection()][string[]]$ArgumentList)
    if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgumentList) {
        $parts.Add((ConvertTo-MmoEscapedArgument -Argument ([string]$a))) | Out-Null
    }
    return ($parts -join ' ')
}

function Test-MmoProcessStartInfoArgumentListSupport {
    <#
    True when the runtime exposes usable ProcessStartInfo.ArgumentList (not available on PS 5.1/.NET 4).
    #>
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $prop = $psi.GetType().GetProperty('ArgumentList')
    if ($null -eq $prop) { return $false }
    try {
        $null = $psi.ArgumentList
        return $true
    }
    catch {
        return $false
    }
}

function Set-MmoProcessStartInfoArguments {
    <#
    Prefer ArgumentList when the runtime supports it; otherwise use Windows-safe Arguments escaping.
    Returns the mode used: 'ArgumentList' or 'Arguments'.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList
    )
    if (Test-MmoProcessStartInfoArgumentListSupport) {
        foreach ($a in @($ArgumentList)) {
            [void]$StartInfo.ArgumentList.Add([string]$a)
        }
        return 'ArgumentList'
    }
    $StartInfo.Arguments = Join-MmoProcessArguments -ArgumentList @($ArgumentList)
    return 'Arguments'
}

function Get-MmoDescendantProcessIds {
    <#
    Breadth-first child process IDs under RootId (excludes the root itself).
    #>
    param([Parameter(Mandatory = $true)][int]$RootId)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $queue = New-Object System.Collections.Queue
    $result = New-Object System.Collections.Generic.List[int]
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $parent = [int]$queue.Dequeue()
        foreach ($child in ($all | Where-Object { $_.ParentProcessId -eq $parent })) {
            $childId = [int]$child.ProcessId
            $result.Add($childId) | Out-Null
            $queue.Enqueue($childId)
        }
    }
    return @($result)
}

function Get-MmoTargetProcess {
    <#
    Return the process only when the live PID still matches the recorded start time (PID-reuse guard).
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [datetime]$ExpectedStartUtc = [datetime]::MinValue
    )
    $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    if ($ExpectedStartUtc -ne [datetime]::MinValue) {
        $actual = $process.StartTime.ToUniversalTime()
        # Allow tiny clock skew while still rejecting reused PIDs.
        $delta = [Math]::Abs(([single]($actual - $ExpectedStartUtc).TotalSeconds))
        if ($delta -gt [single]2.0) { return $null }
    }
    return $process
}

function Stop-MmoProcessTree {
    <#
    Force-stop a process tree. Guards against PID reuse with ExpectedStartUtc on the root.
    Children are terminated deepest-first; root last. Never kills an unrelated reused PID.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$RootId,
        [datetime]$ExpectedStartUtc = [datetime]::MinValue
    )
    if ($null -eq (Get-MmoTargetProcess -Id $RootId -ExpectedStartUtc $ExpectedStartUtc)) {
        return
    }
    $children = @(Get-MmoDescendantProcessIds -RootId $RootId)
    [array]::Reverse($children)
    foreach ($childId in $children) {
        Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne (Get-MmoTargetProcess -Id $RootId -ExpectedStartUtc $ExpectedStartUtc)) {
        Stop-Process -Id $RootId -Force -ErrorAction SilentlyContinue
    }
    return
}

function Add-MmoFallbackRecord {
    <#
    Append one durable fallback hop to FALLBACKS.jsonl under the run directory.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$SourceProvider = '',
        [string]$SourceModel = '',
        [string]$TargetProvider = '',
        [string]$TargetModel = '',
        [string]$ReasoningTier = '',
        [string]$Classification = '',
        [bool]$FallbackEligible = $false,
        [int]$ExitCode = 0,
        [string]$WorkerId = '',
        [hashtable]$Extra = $null
    )
    if (-not (Test-Path -LiteralPath $RunDirectory)) {
        New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    }
    $record = [ordered]@{
        timestamp = [datetime]::UtcNow.ToString('o')
        reason = $Reason
        source_provider = $SourceProvider
        source_model = $SourceModel
        target_provider = $TargetProvider
        target_model = $TargetModel
        reasoning_tier = $ReasoningTier
        classification = $Classification
        fallback_eligible = [bool]$FallbackEligible
        exit_code = [int]$ExitCode
        worker_id = $WorkerId
    }
    if ($null -ne $Extra) {
        foreach ($key in $Extra.Keys) {
            $record[$key] = $Extra[$key]
        }
    }
    # JSONL requires one compressed object per physical line.
    $line = (([pscustomobject]$record) | ConvertTo-Json -Depth 8 -Compress)
    $path = Join-Path $RunDirectory 'FALLBACKS.jsonl'
    Write-MmoUtf8Text -LiteralPath $path -Text ($line + [Environment]::NewLine) -Append
    return $path
}

function Test-MmoFallbackEligibleClassification {
    param([string]$Classification)
    if ([string]::IsNullOrWhiteSpace($Classification)) { return $false }
    $c = $Classification.Trim().ToLowerInvariant()
    return ($c -eq 'quota_exhausted' -or $c -eq 'model_unavailable')
}

function ConvertTo-MmoStringArray {
    <#
    PS 5.1-safe conversion from generic lists / enumerables to string[].
    Avoids `@($list)` on some generic collections that throw "Argument types do not match".
    #>
    param($InputObject)
    if ($null -eq $InputObject) { return [string[]]@() }
    if ($InputObject -is [string]) { return [string[]]@([string]$InputObject) }
    if ($InputObject -is [System.Collections.Generic.List[string]]) {
        return [string[]]$InputObject.ToArray()
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        $s = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($s)) { $out.Add($s) | Out-Null }
    }
    return [string[]]$out.ToArray()
}

function ConvertTo-MmoObjectArray {
    <#
    PS 5.1-safe conversion for List[object]/PSCustomObject collections.
    `@($list[object])` throws Argument types do not match on Windows PowerShell 5.1.
    #>
    param($InputObject)
    if ($null -eq $InputObject) { return [object[]]@() }
    if ($InputObject -is [System.Collections.ICollection] -and $InputObject.PSObject.Methods.Match('ToArray').Count -gt 0) {
        return [object[]]$InputObject.ToArray()
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($InputObject)) {
        $out.Add($item) | Out-Null
    }
    return [object[]]$out.ToArray()
}

function Split-MmoDiscoveredModels {
    <#
    Keep raw discovery transparent, but clearly separate eligible vs forbidden models.
    Direct consumers must not treat forbidden/low models as selectable.
    Return values are plain CLR arrays (not generic lists) for PS 5.1 safety.
    #>
    param(
        [string[]]$Models,
        [string[]]$ForbiddenSubstrings = @()
    )
    $rawList = New-Object System.Collections.Generic.List[string]
    foreach ($m in @($Models)) {
        if ([string]::IsNullOrWhiteSpace([string]$m)) { continue }
        $rawList.Add([string]$m) | Out-Null
    }
    $eligible = New-Object System.Collections.Generic.List[string]
    $forbidden = New-Object System.Collections.Generic.List[string]
    $annotated = New-Object System.Collections.Generic.List[object]
    foreach ($m in $rawList) {
        $isForbidden = -not (Test-MmoModelEligible -ModelName $m -ForbiddenSubstrings $ForbiddenSubstrings)
        if ($isForbidden) {
            $forbidden.Add($m) | Out-Null
        }
        else {
            $eligible.Add($m) | Out-Null
        }
        $annotated.Add([pscustomobject]@{
            name = $m
            eligible = (-not $isForbidden)
            forbidden = [bool]$isForbidden
            reason = $(if ($isForbidden) { 'low_tier_or_forbidden_substring' } else { 'eligible' })
        }) | Out-Null
    }
    # Explicit ToArray: `@($List[object])` throws on Windows PowerShell 5.1.
    return [pscustomobject]@{
        models = [string[]]$rawList.ToArray()
        eligible_models = [string[]]$eligible.ToArray()
        forbidden_models = [string[]]$forbidden.ToArray()
        models_annotated = [object[]]$annotated.ToArray()
    }
}

function Get-MmoTaskAttributeContract {
    <#
    Load the task-attribute contract from the registry (or built-in defaults).
    Canonical attributes: ui, web_frontend, image_generation.
    #>
    param($Registry = $null)
    $defaultAliases = [ordered]@{
        ui = @('ui', 'interface', 'ui_design', 'visual', 'visual_design')
        web_frontend = @('web_frontend', 'web-frontend', 'frontend', 'web')
        image_generation = @('image_generation', 'image-generation', 'image', 'images', 'img', 'img_gen')
    }
    $defaultVisual = @('ui', 'web_frontend', 'image_generation')
    $defaultPreferred = [pscustomobject]@{
        provider = 'agy'
        model_alias = 'gemini-3.5-flash-high'
        reasoning_tier = 'highest'
    }
    if ($null -eq $Registry -or $null -eq $Registry.task_attributes) {
        return [pscustomobject]@{
            canonical = @('ui', 'web_frontend', 'image_generation')
            aliases = $defaultAliases
            visual_group = $defaultVisual
            visual_preferred = $defaultPreferred
            notes = 'Built-in task-attribute defaults; registry.task_attributes overrides when present.'
        }
    }
    $ta = $Registry.task_attributes
    $canonical = @('ui', 'web_frontend', 'image_generation')
    if ($null -ne $ta.canonical) { $canonical = @($ta.canonical | ForEach-Object { [string]$_ }) }
    $aliases = $defaultAliases
    if ($null -ne $ta.aliases) {
        $aliases = [ordered]@{}
        foreach ($prop in $ta.aliases.PSObject.Properties) {
            $aliases[$prop.Name] = @($prop.Value | ForEach-Object { [string]$_ })
        }
    }
    $visualGroup = $defaultVisual
    if ($null -ne $ta.visual_group) { $visualGroup = @($ta.visual_group | ForEach-Object { [string]$_ }) }
    $visualPreferred = $defaultPreferred
    if ($null -ne $ta.visual_preferred) { $visualPreferred = $ta.visual_preferred }
    return [pscustomobject]@{
        canonical = $canonical
        aliases = $aliases
        visual_group = $visualGroup
        visual_preferred = $visualPreferred
        notes = $(if ($ta.notes) { [string]$ta.notes } else { '' })
    }
}

function Normalize-MmoTaskAttributes {
    <#
    Normalize caller task attributes to canonical ids. Unknown tokens are preserved
    for audit but do not change routing. Returns is_visual when any visual-group
    attribute is present.
    #>
    param(
        [string[]]$TaskAttributes = @(),
        $Registry = $null
    )
    $contract = Get-MmoTaskAttributeContract -Registry $Registry
    $raw = @(
        $TaskAttributes |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $canonicalList = New-Object System.Collections.Generic.List[string]
    $unknownList = New-Object System.Collections.Generic.List[string]
    $aliasMap = @{}
    foreach ($canon in @($contract.canonical)) {
        $keys = @($canon)
        if ($null -ne $contract.aliases -and $null -ne $contract.aliases.$canon) {
            $keys = @($contract.aliases.$canon)
        }
        foreach ($k in $keys) {
            $aliasMap[$k.Trim().ToLowerInvariant()] = $canon
        }
        # Always accept the canonical token itself.
        $aliasMap[$canon.Trim().ToLowerInvariant()] = $canon
    }
    foreach ($token in $raw) {
        $key = $token.Trim().ToLowerInvariant() -replace '\s+', '_'
        $key = $key -replace '-', '_'
        # Also try raw lower form for hyphen aliases already in map.
        $resolved = $null
        if ($aliasMap.ContainsKey($key)) {
            $resolved = $aliasMap[$key]
        }
        else {
            $keyHyphen = $token.Trim().ToLowerInvariant()
            if ($aliasMap.ContainsKey($keyHyphen)) {
                $resolved = $aliasMap[$keyHyphen]
            }
        }
        if ($null -ne $resolved) {
            if (-not $canonicalList.Contains($resolved)) {
                $canonicalList.Add($resolved) | Out-Null
            }
        }
        else {
            if (-not $unknownList.Contains($token)) {
                $unknownList.Add($token) | Out-Null
            }
        }
    }
    $canonicalArr = [string[]]$canonicalList.ToArray()
    $isVisual = $false
    foreach ($c in $canonicalArr) {
        foreach ($v in @($contract.visual_group)) {
            if ($c -eq $v) { $isVisual = $true; break }
        }
        if ($isVisual) { break }
    }
    return [pscustomobject]@{
        raw = [string[]]@($raw)
        canonical = $canonicalArr
        unknown = [string[]]$unknownList.ToArray()
        is_visual = [bool]$isVisual
        visual_group = @($contract.visual_group)
        visual_preferred = $contract.visual_preferred
    }
}

