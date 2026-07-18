# Shared helpers for grok-orchestrator (Grok-only).
# Authored 2026-07-18.
$ErrorActionPreference = 'Stop'
$script:GoUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-GoUtf8Text {
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
        [System.IO.File]::AppendAllText($LiteralPath, $Text, $script:GoUtf8NoBom)
        return
    }
    [System.IO.File]::WriteAllText($LiteralPath, $Text, $script:GoUtf8NoBom)
    return
}

function Expand-GoEnvPath {
    param([Parameter(Mandatory = $true)][string]$PathTemplate)
    return [Environment]::ExpandEnvironmentVariables($PathTemplate)
}

function Get-GoSkillRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-GoRegistry {
    param([string]$RegistryPath = '')
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $RegistryPath = Join-Path (Get-GoSkillRoot) 'config\grok-models.json'
    }
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        throw "Grok model registry not found: $RegistryPath"
    }
    return (Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function ConvertTo-GoJson {
    param([Parameter(Mandatory = $true)]$InputObject, [int]$Depth = 12)
    return ($InputObject | ConvertTo-Json -Depth $Depth)
}

function Write-GoJson {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$InputObject,
        [int]$Depth = 12
    )
    Write-GoUtf8Text -LiteralPath $LiteralPath -Text ((ConvertTo-GoJson -InputObject $InputObject -Depth $Depth) + [Environment]::NewLine)
    return
}

function Resolve-GoExecutable {
    <#
    Resolve the grok executable from PATH then common install locations.
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
        $candidate = Expand-GoEnvPath -PathTemplate $template
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-GoAllowedReasoningLabels {
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

function Resolve-GoReasoningTier {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('highest', 'second_highest')][string]$Tier,
        [Parameter(Mandatory = $true)]$AllowedMap
    )
    if ($Tier -eq 'highest') { return [string]$AllowedMap.highest }
    return [string]$AllowedMap.second_highest
}

function Get-GoForbiddenReasoningTokens {
    return @('low', 'lowest', 'minimal')
}

function Test-GoForbiddenReasoningLabel {
    <#
    True when a provider effort/reasoning label is forbidden (case-insensitive).
    #>
    param([string]$Label)
    if ([string]::IsNullOrWhiteSpace($Label)) { return $false }
    $norm = $Label.Trim().ToLowerInvariant()
    foreach ($tok in (Get-GoForbiddenReasoningTokens)) {
        if ($norm -eq $tok) { return $true }
    }
    return $false
}

function Test-GoModelHasLowTier {
    <#
    True when a model display name embeds a low reasoning tier (case-insensitive).
    #>
    param([string]$ModelName)
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    $n = $ModelName.ToLowerInvariant()
    if ($n -match '\(\s*low\s*\)') { return $true }
    if ($n -match '\[\s*low\s*\]') { return $true }
    if ($n -match '(^|[\s_\-])low([\s_\-]|$)') { return $true }
    if ($n -match '(^|[\s_\-])lowest([\s_\-]|$)') { return $true }
    if ($n -match '(^|[\s_\-])minimal([\s_\-]|$)') { return $true }
    return $false
}

function Test-GoModelEligible {
    param(
        [string]$ModelName,
        [string[]]$ExcludeModels = @()
    )
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    foreach ($ex in $ExcludeModels) {
        if ($ModelName -eq $ex) { return $false }
    }
    if (Test-GoModelHasLowTier -ModelName $ModelName) { return $false }
    return $true
}

function Split-GoDiscoveredModels {
    <#
    Separate raw discovered models into eligible vs forbidden (low-tier) lists.
    Returns plain CLR arrays for PS 5.1 safety.
    #>
    param([string[]]$Models)
    $rawList = New-Object System.Collections.Generic.List[string]
    foreach ($m in @($Models)) {
        if ([string]::IsNullOrWhiteSpace([string]$m)) { continue }
        $rawList.Add([string]$m) | Out-Null
    }
    $eligible = New-Object System.Collections.Generic.List[string]
    $forbidden = New-Object System.Collections.Generic.List[string]
    $annotated = New-Object System.Collections.Generic.List[object]
    foreach ($m in $rawList) {
        $isForbidden = -not (Test-GoModelEligible -ModelName $m)
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
            reason = $(if ($isForbidden) { 'low_tier_or_forbidden' } else { 'eligible' })
        }) | Out-Null
    }
    return [pscustomobject]@{
        models = [string[]]$rawList.ToArray()
        eligible_models = [string[]]$eligible.ToArray()
        forbidden_models = [string[]]$forbidden.ToArray()
        models_annotated = [object[]]$annotated.ToArray()
    }
}

function Assert-GoInvocationPolicy {
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
    if (Test-GoForbiddenReasoningLabel -Label $ReasoningEffort) {
        throw "Invocation policy violation: ReasoningEffort '$ReasoningEffort' is forbidden (low tier)."
    }
    if (-not [string]::IsNullOrWhiteSpace($Model) -and (Test-GoModelHasLowTier -ModelName $Model)) {
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
                if (Test-GoForbiddenReasoningLabel -Label $val) {
                    throw "Invocation policy violation: ExtraArgs/args set $a to forbidden value '$val'."
                }
            }
        }
        if ($al -match '^(--reasoning-effort|--effort)=(.*)$') {
            $val = $Matches[2]
            if (Test-GoForbiddenReasoningLabel -Label $val) {
                throw "Invocation policy violation: arg '$a' sets a forbidden low reasoning tier."
            }
        }
        if (Test-GoForbiddenReasoningLabel -Label $a) {
            if ($al -in (Get-GoForbiddenReasoningTokens)) {
                throw "Invocation policy violation: forbidden reasoning token '$a' present in args."
            }
        }
    }
    return
}

function ConvertTo-GoEscapedArgument {
    <#
    Escape one argument for ProcessStartInfo.Arguments under Windows (CommandLineToArgvW rules).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument) { return '""' }
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

function Join-GoProcessArguments {
    <#
    Join argv elements into a single ProcessStartInfo.Arguments string with Windows-safe escaping.
    #>
    param([AllowEmptyCollection()][string[]]$ArgumentList)
    if ($null -eq $ArgumentList -or $ArgumentList.Count -eq 0) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgumentList) {
        $parts.Add((ConvertTo-GoEscapedArgument -Argument ([string]$a))) | Out-Null
    }
    return ($parts -join ' ')
}

function Test-GoProcessStartInfoArgumentListSupport {
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

function Set-GoProcessStartInfoArguments {
    <#
    Prefer ArgumentList when the runtime supports it; otherwise use Windows-safe Arguments escaping.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList
    )
    if (Test-GoProcessStartInfoArgumentListSupport) {
        foreach ($a in @($ArgumentList)) {
            [void]$StartInfo.ArgumentList.Add([string]$a)
        }
        return 'ArgumentList'
    }
    $StartInfo.Arguments = Join-GoProcessArguments -ArgumentList @($ArgumentList)
    return 'Arguments'
}

function Get-GoDescendantProcessIds {
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
    return [int[]]$result.ToArray()
}

function Get-GoTargetProcess {
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
        $delta = [Math]::Abs(([single]($actual - $ExpectedStartUtc).TotalSeconds))
        if ($delta -gt [single]2.0) { return $null }
    }
    return $process
}

function Stop-GoProcessTree {
    <#
    Force-stop a process tree. Guards against PID reuse with ExpectedStartUtc on the root.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$RootId,
        [datetime]$ExpectedStartUtc = [datetime]::MinValue
    )
    if ($null -eq (Get-GoTargetProcess -Id $RootId -ExpectedStartUtc $ExpectedStartUtc)) {
        return
    }
    $children = @(Get-GoDescendantProcessIds -RootId $RootId)
    [array]::Reverse($children)
    foreach ($childId in $children) {
        Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne (Get-GoTargetProcess -Id $RootId -ExpectedStartUtc $ExpectedStartUtc)) {
        Stop-Process -Id $RootId -Force -ErrorAction SilentlyContinue
    }
    return
}

function Add-GoFallbackRecord {
    <#
    Append one durable fallback hop to FALLBACKS.jsonl under the run directory.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$SourceModel = '',
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
        provider = 'grok'
        source_model = $SourceModel
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
    $line = (([pscustomobject]$record) | ConvertTo-Json -Depth 8 -Compress)
    $path = Join-Path $RunDirectory 'FALLBACKS.jsonl'
    Write-GoUtf8Text -LiteralPath $path -Text ($line + [Environment]::NewLine) -Append
    return $path
}

function Test-GoFallbackEligibleClassification {
    param([string]$Classification)
    if ([string]::IsNullOrWhiteSpace($Classification)) { return $false }
    $c = $Classification.Trim().ToLowerInvariant()
    return ($c -eq 'quota_exhausted' -or $c -eq 'model_unavailable')
}

function Write-GoStageArtifacts {
    <#
    Write STATUS.json and optional STAGE_REPORT.md before any sentinel flag.
    Callers must invoke this before Write-GoSentinel.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Status,
        [string]$StageReport = '',
        [string]$StageReportPath = ''
    )
    if (-not (Test-Path -LiteralPath $RunDirectory)) {
        New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($StageReportPath)) {
        $StageReportPath = Join-Path $RunDirectory 'STAGE_REPORT.md'
    }
    if (-not [string]::IsNullOrWhiteSpace($StageReport)) {
        Write-GoUtf8Text -LiteralPath $StageReportPath -Text $StageReport
    }
    $statusPath = Join-Path $RunDirectory 'STATUS.json'
    Write-GoJson -LiteralPath $statusPath -InputObject $Status
    return [pscustomobject]@{
        status_path = $statusPath
        stage_report_path = $StageReportPath
    }
}

function Write-GoSentinel {
    <#
    Create exactly one terminal sentinel after reports are durable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('READY_FOR_REVIEW', 'DONE', 'BLOCKED', 'FAILED')][string]$Kind,
        [string]$Detail = ''
    )
    $flags = @('READY_FOR_REVIEW.flag', 'DONE.flag', 'BLOCKED.flag', 'FAILED.flag')
    foreach ($f in $flags) {
        $p = Join-Path $RunDirectory $f
        if (Test-Path -LiteralPath $p) {
            throw "Sentinel already present: $p (refusing to create $Kind.flag)"
        }
    }
    $statusPath = Join-Path $RunDirectory 'STATUS.json'
    if (-not (Test-Path -LiteralPath $statusPath)) {
        throw "STATUS.json missing; write stage artifacts before sentinel $Kind.flag"
    }
    $flagPath = Join-Path $RunDirectory ($Kind + '.flag')
    $text = if ([string]::IsNullOrWhiteSpace($Detail)) { $Kind } else { $Detail }
    Write-GoUtf8Text -LiteralPath $flagPath -Text ($text + [Environment]::NewLine)
    return $flagPath
}

function Resolve-GoModelFromDiscovery {
    <#
    Resolve a model hint against live discovery eligible models. Optional hints may return null.
    #>
    param(
        [string]$ModelHint,
        [string[]]$EligibleModels,
        [switch]$Optional
    )
    if ([string]::IsNullOrWhiteSpace($ModelHint)) {
        if ($Optional) { return $null }
        throw 'Model hint is empty.'
    }
    if (Test-GoModelHasLowTier -ModelName $ModelHint) {
        throw "Model hint '$ModelHint' embeds a forbidden low tier."
    }
    $eligible = @($EligibleModels)
    if ($eligible.Count -eq 0) {
        if ($Optional) { return $null }
        throw "No eligible models in discovery for hint '$ModelHint'."
    }
    foreach ($m in $eligible) {
        if ($m -eq $ModelHint) { return $m }
    }
    $hintLower = $ModelHint.ToLowerInvariant()
    foreach ($m in $eligible) {
        if ($m.ToLowerInvariant() -eq $hintLower) { return $m }
    }
    foreach ($m in $eligible) {
        if ($m.ToLowerInvariant().Contains($hintLower) -or $hintLower.Contains($m.ToLowerInvariant())) {
            return $m
        }
    }
    if ($Optional) { return $null }
    throw "Model hint '$ModelHint' not found in discovery eligible models: $($eligible -join ', ')"
}
