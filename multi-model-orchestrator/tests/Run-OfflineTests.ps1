# Deterministic offline tests for multi-model-orchestrator.
# Authored 2026-07-17; expanded for revision-1 corrections.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$scripts = Join-Path $skillRoot 'scripts'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$pass = 0
$fail = 0
$results = New-Object System.Collections.Generic.List[object]

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:pass++
        $results.Add([pscustomobject]@{ name = $Name; ok = $true; detail = $Detail }) | Out-Null
        Write-Host "PASS  $Name"
        return
    }
    $script:fail++
    $results.Add([pscustomobject]@{ name = $Name; ok = $false; detail = $Detail }) | Out-Null
    Write-Host "FAIL  $Name :: $Detail"
    return
}

function Invoke-JsonScript {
    param([string]$File, [string[]]$ArgumentList, [switch]$AllowFailure)
    # Child stderr must not terminate the parent when ErrorActionPreference=Stop.
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & powershell.exe -NoProfile -NonInteractive -File $File @ArgumentList 2>&1
        $code = $LASTEXITCODE
        $raw = ($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine
    }
    finally {
        $ErrorActionPreference = $prevEa
    }
    if (-not $AllowFailure -and $code -ne 0) {
        throw "Script failed ($code): $File`n$raw"
    }
    $trim = if ($null -eq $raw) { '' } else { $raw.Trim() }
    $idx = $trim.IndexOf('{')
    $obj = $null
    if ($idx -ge 0) {
        $jsonText = $trim.Substring($idx)
        $last = $jsonText.LastIndexOf('}')
        if ($last -ge 0) { $jsonText = $jsonText.Substring(0, $last + 1) }
        try { $obj = $jsonText | ConvertFrom-Json } catch { $obj = $null }
    }
    return [pscustomobject]@{ ExitCode = $code; Raw = $raw; Object = $obj }
}

function Invoke-ExpectFail {
    param([string]$File, [string[]]$ArgumentList, [string]$Name, [string]$MustMatch = '')
    $r = Invoke-JsonScript -File $File -ArgumentList $ArgumentList -AllowFailure
    $ok = ($r.ExitCode -ne 0)
    if ($ok -and -not [string]::IsNullOrWhiteSpace($MustMatch)) {
        $ok = ($r.Raw -match $MustMatch)
    }
    Assert-True -Condition $ok -Name $Name -Detail ("exit=$($r.ExitCode) raw=" + $r.Raw.Trim().Substring(0, [Math]::Min(240, $r.Raw.Trim().Length)))
    return $r
}

. (Join-Path $scripts 'Common.ps1')

# --- Classify-Result ---
$clsScript = Join-Path $scripts 'Classify-Result.ps1'

$c1 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '0', '-RawText', 'all good')).Object
Assert-True -Condition ($c1.classification -eq 'success' -and $c1.fallback_eligible -eq $false) -Name 'classify-success'

$c2 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '2', '-RawText', 'insufficient_quota: rate limit exceeded')).Object
Assert-True -Condition ($c2.classification -eq 'quota_exhausted' -and $c2.fallback_eligible -eq $true) -Name 'classify-quota-fallback-eligible'

$c3 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '4', '-RawText', 'model not found: xyz')).Object
Assert-True -Condition ($c3.classification -eq 'model_unavailable' -and $c3.fallback_eligible -eq $true) -Name 'classify-model-unavailable'

$c4 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '3', '-RawText', 'unauthorized: not logged in')).Object
Assert-True -Condition ($c4.classification -eq 'auth_failure' -and $c4.fallback_eligible -eq $false) -Name 'classify-auth-no-fallback'

$c5 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '1', '-RawText', 'assertion mismatch in tests')).Object
Assert-True -Condition ($c5.classification -eq 'task_failure' -and $c5.fallback_eligible -eq $false) -Name 'classify-task-failure-no-fallback'

# Negative: successful audit/code text must not become auth/network failures.
$benignPath = Join-Path ([System.IO.Path]::GetTempPath()) ('mmo-benign-' + [guid]::NewGuid().ToString() + '.txt')
@(
    '# Multi-Model Orchestrator Audit',
    'Handlers return 401 for unauthenticated callers and 403 forbidden for ACL misses.',
    'Document authentication flows and timeout/dns health checks without failing.',
    'The endpoint remains healthy; timeout values and dns resolvers were verified.'
) -join [Environment]::NewLine | Set-Content -LiteralPath $benignPath -Encoding UTF8
$cNeg1 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '0', '-RawLogPath', $benignPath)).Object
Remove-Item -LiteralPath $benignPath -Force -ErrorAction SilentlyContinue
Assert-True -Condition ($cNeg1.classification -eq 'success') -Name 'classify-benign-401-auth-timeout-dns-success' -Detail $cNeg1.classification

$claudePath = Join-Path ([System.IO.Path]::GetTempPath()) ('mmo-claude-audit-' + [guid]::NewGuid().ToString() + '.txt')
@(
    '### F1. Argument-quoting injection',
    'A carefully crafted prompt could inject flags. Fix quoting.',
    '### Auth notes',
    'HTTP handlers document 401 and 403 forbidden responses for authentication tests.',
    'DNS and timeout probes in the health suite passed.'
) -join [Environment]::NewLine | Set-Content -LiteralPath $claudePath -Encoding UTF8
$cNeg2 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '0', '-RawLogPath', $claudePath)).Object
Remove-Item -LiteralPath $claudePath -Force -ErrorAction SilentlyContinue
Assert-True -Condition ($cNeg2.classification -eq 'success') -Name 'classify-claude-audit-regression-success' -Detail $cNeg2.reason

$cPosNet = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '1', '-RawText', 'Error: timeout waiting for response')).Object
Assert-True -Condition ($cPosNet.classification -eq 'network_failure') -Name 'classify-real-timeout-waiting-network'

$cPosAuth = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '3', '-RawText', 'Error: authentication required')).Object
Assert-True -Condition ($cPosAuth.classification -eq 'auth_failure' -and $cPosAuth.fallback_eligible -eq $false) -Name 'classify-auth-required-no-fallback'

# --- Argument escaping (CommandLineToArgvW round-trip) ---
$nativeArgv = @'
using System;
using System.Runtime.InteropServices;
public static class MmoNativeArgv {
  [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);
  [DllImport("kernel32.dll")]
  static extern IntPtr LocalFree(IntPtr hMem);
  public static string[] Split(string commandLine) {
    int argc;
    IntPtr argv = CommandLineToArgvW(commandLine, out argc);
    if (argv == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    try {
      string[] args = new string[argc];
      for (int i = 0; i < argc; i++) {
        IntPtr p = Marshal.ReadIntPtr(argv, i * IntPtr.Size);
        args[i] = Marshal.PtrToStringUni(p);
      }
      return args;
    } finally { LocalFree(argv); }
  }
}
'@
try { [void][MmoNativeArgv] } catch { Add-Type -TypeDefinition $nativeArgv -ErrorAction Stop }

function Test-MmoArgvRoundTrip {
    param([string[]]$ArgsIn, [string]$Name)
    $joined = Join-MmoProcessArguments -ArgumentList $ArgsIn
    $parsed = [MmoNativeArgv]::Split('exe ' + $joined)
    $got = @($parsed | Select-Object -Skip 1)
    $ok = ($got.Count -eq $ArgsIn.Count)
    if ($ok) {
        for ($i = 0; $i -lt $ArgsIn.Count; $i++) {
            if ($got[$i] -cne $ArgsIn[$i]) { $ok = $false; break }
        }
    }
    Assert-True -Condition $ok -Name $Name -Detail ("in=" + ($ArgsIn -join ' | ') + " got=" + ($got -join ' | '))
    return $ok
}

Test-MmoArgvRoundTrip -ArgsIn @('--single', 'hello world') -Name 'escape-spaces-one-prompt-arg'
Test-MmoArgvRoundTrip -ArgsIn @('--single', 'say "quoted" text') -Name 'escape-embedded-quotes'
Test-MmoArgvRoundTrip -ArgsIn @('--single', 'path\ends\with\') -Name 'escape-trailing-backslashes'
Test-MmoArgvRoundTrip -ArgsIn @('--single', 'mix \" quote\path\') -Name 'escape-quote-and-backslash-mix'
Test-MmoArgvRoundTrip -ArgsIn @('--single', 'value with $() and `backticks` and %PATH%') -Name 'escape-dollar-backtick-percent'
Test-MmoArgvRoundTrip -ArgsIn @('--model', 'Claude Opus 4.6 (Thinking)', '--print', 'a b', 'x') -Name 'escape-multi-arg-exact-order'
Assert-True -Condition (-not (Test-MmoProcessStartInfoArgumentListSupport)) -Name 'runtime-uses-arguments-fallback-on-ps51' -Detail 'expected false on Windows PowerShell 5.1'

# Benign successful audit/report text must not become auth/network failure (Claude audit regression).
$auditTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mmo-audit-' + [guid]::NewGuid().ToString() + '.txt')
@(
    '# Claude Opus Audit',
    'Findings mention HTTP handlers returning 401 and 403 forbidden during review of authentication middleware.',
    'The healthy DNS resolver and timeout checks passed. Classification of authentication terminology in docs is intentional.',
    'Verdict: successful read-only audit with no provider failure.'
) -join [Environment]::NewLine | Set-Content -LiteralPath $auditTmp -Encoding UTF8
$cAudit = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '0', '-RawLogPath', $auditTmp)).Object
Remove-Item -LiteralPath $auditTmp -Force -ErrorAction SilentlyContinue
Assert-True -Condition ($cAudit.classification -eq 'success') -Name 'classify-benign-audit-not-auth' -Detail $cAudit.classification

$cDns = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '0', '-RawText', 'documented dns timeout behavior for clients')).Object
Assert-True -Condition ($cDns.classification -eq 'success') -Name 'classify-benign-dns-timeout-success'

$cNet = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '1', '-RawText', 'error: network error: connection refused')).Object
Assert-True -Condition ($cNet.classification -eq 'network_failure' -and $cNet.fallback_eligible -eq $false) -Name 'classify-network-positive'

$cAuthStderr = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '3', '-StderrText', 'error: authentication required')).Object
Assert-True -Condition ($cAuthStderr.classification -eq 'auth_failure') -Name 'classify-auth-from-stderr'

# --- Reasoning helpers + escaping ---
$map = Get-MmoAllowedReasoningLabels -OrderedDescending @('high', 'medium', 'low')
Assert-True -Condition ($map.highest -eq 'high' -and $map.second_highest -eq 'medium' -and $map.labels.Count -eq 2) -Name 'reasoning-only-top-two'

$escSpace = ConvertTo-MmoEscapedArgument -Argument 'hello world'
$escQuote = ConvertTo-MmoEscapedArgument -Argument 'say "hi"'
$escTrail = ConvertTo-MmoEscapedArgument -Argument 'C:\path\'
$escEmpty = ConvertTo-MmoEscapedArgument -Argument ''
Assert-True -Condition ($escSpace -eq '"hello world"') -Name 'escape-spaces'
Assert-True -Condition ($escQuote -eq '"say \"hi\""') -Name 'escape-embedded-quotes'
# Trailing backslash before closing quote must be doubled under CommandLineToArgvW rules.
Assert-True -Condition ($escTrail -eq '"C:\path\\"') -Name 'escape-trailing-backslash' -Detail $escTrail
Assert-True -Condition ($escEmpty -eq '""') -Name 'escape-empty'
$joinedArgs = Join-MmoProcessArguments -ArgumentList @('--single', 'a b', 'x"y', 'end\')
Assert-True -Condition ($joinedArgs -match '--single' -and $joinedArgs -match '"a b"') -Name 'join-process-arguments'

$map2 = Get-MmoAllowedReasoningLabels -OrderedDescending @('High', 'Medium', 'Low')
$simpleEffort = Resolve-MmoReasoningTier -Tier 'second_highest' -AllowedMap $map2
$diffEffort = Resolve-MmoReasoningTier -Tier 'highest' -AllowedMap $map2
Assert-True -Condition ($simpleEffort -eq 'Medium' -and $diffEffort -eq 'High') -Name 'reasoning-task-class-mapping'

# Case-insensitive low model rejection
Assert-True -Condition (Test-MmoModelHasLowTier -ModelName 'Gemini 3.5 Flash (low)') -Name 'low-model-detect-lowercase-paren'
Assert-True -Condition (Test-MmoModelHasLowTier -ModelName 'Gemini 3.5 Flash (LOW)') -Name 'low-model-detect-uppercase-paren'
Assert-True -Condition (Test-MmoModelHasLowTier -ModelName 'model_low_tier') -Name 'low-model-detect-token'
Assert-True -Condition (-not (Test-MmoModelHasLowTier -ModelName 'Claude Opus 4.6 (Thinking)')) -Name 'low-model-allow-thinking'
Assert-True -Condition (-not (Test-MmoModelEligible -ModelName 'Gemini 3.1 Pro (Low)')) -Name 'eligible-rejects-low'
Assert-True -Condition (Test-MmoModelEligible -ModelName 'Gemini 3.1 Pro (High)') -Name 'eligible-allows-high'
Assert-True -Condition (Test-MmoForbiddenReasoningLabel -Label 'LOW') -Name 'forbidden-effort-LOW'
Assert-True -Condition (Test-MmoForbiddenReasoningLabel -Label 'minimal') -Name 'forbidden-effort-minimal'
Assert-True -Condition (-not (Test-MmoForbiddenReasoningLabel -Label 'high')) -Name 'allow-effort-high'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mmo-tests-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $fakeGrok = Join-Path $fixtures 'fake-grok.ps1'
    $fakeAgy = Join-Path $fixtures 'fake-agy.ps1'
    $discovery = [ordered]@{
        discovered_at = [datetime]::UtcNow.ToString('o')
        providers = [ordered]@{
            grok = [ordered]@{
                available = $true
                executable = "powershell.exe -NoProfile -File `"$fakeGrok`""
                models = @('grok-4.5')
                reasoning_map = [ordered]@{ highest = 'high'; second_highest = 'medium'; labels = @('high', 'medium') }
            }
            agy = [ordered]@{
                available = $true
                executable = "powershell.exe -NoProfile -File `"$fakeAgy`""
                models = @(
                    'Gemini 3.5 Flash (Medium)',
                    'Gemini 3.5 Flash (High)',
                    'Gemini 3.5 Flash (Low)',
                    'Gemini 3.5 Flash (low)',
                    'Gemini 3.1 Pro (Low)',
                    'Gemini 3.1 Pro (HIGH)',
                    'Gemini 3.1 Pro (High)',
                    'Claude Sonnet 4.6 (Thinking)',
                    'Claude Opus 4.6 (Thinking)'
                )
                reasoning_map = [ordered]@{ highest = 'High'; second_highest = 'Medium'; labels = @('High', 'Medium') }
            }
        }
    }
    $discoPath = Join-Path $tmp 'discovery.json'
    Write-MmoJson -LiteralPath $discoPath -InputObject $discovery

    $selScript = Join-Path $scripts 'Select-Model.ps1'
    $hard = (Invoke-JsonScript -File $selScript -ArgumentList @('-Profile', 'difficult_architecture', '-DiscoveryJsonPath', $discoPath)).Object
    Assert-True -Condition (
        $hard.selected.provider -eq 'agy' -and
        $hard.selected.model -like '*Claude Opus*' -and
        $hard.selected.reasoning_tier -eq 'highest'
    ) -Name 'select-difficult-prefers-claude-opus' -Detail ($hard.selected | ConvertTo-Json -Compress)

    $hardFallback = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'difficult_architecture',
        '-DiscoveryJsonPath', $discoPath,
        '-ExcludeModels', 'Claude Opus 4.6 (Thinking)'
    )).Object
    Assert-True -Condition (
        $hardFallback.selected.provider -eq 'agy' -and
        $hardFallback.selected.model -like '*Claude Sonnet*'
    ) -Name 'select-difficult-fallback-sonnet' -Detail ($hardFallback.selected | ConvertTo-Json -Compress)

    $hardFallback2 = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'difficult_security',
        '-DiscoveryJsonPath', $discoPath,
        '-ExcludeModels', 'Claude Opus 4.6 (Thinking),Claude Sonnet 4.6 (Thinking)'
    )).Object
    Assert-True -Condition (
        $hardFallback2.selected.model -like '*Gemini 3.1 Pro (High)*' -or
        $hardFallback2.selected.model -like '*Gemini 3.1 Pro (HIGH)*'
    ) -Name 'select-difficult-fallback-gemini-pro-high' -Detail ($hardFallback2.selected | ConvertTo-Json -Compress)

    # Eligible list must exclude all low variants (any case)
    $agyEligible = @($hard.eligible_by_provider.agy.eligible_models)
    $hasLowEligible = $false
    foreach ($m in $agyEligible) {
        if (Test-MmoModelHasLowTier -ModelName $m) { $hasLowEligible = $true }
    }
    Assert-True -Condition (-not $hasLowEligible -and $agyEligible.Count -ge 3) -Name 'select-eligible-list-excludes-low' -Detail (($agyEligible -join '; '))

    $ord = (Invoke-JsonScript -File $selScript -ArgumentList @('-Profile', 'ordinary_implementation', '-DiscoveryJsonPath', $discoPath)).Object
    Assert-True -Condition (
        $ord.selected.provider -eq 'grok' -and
        $ord.selected.model -eq 'grok-4.5' -and
        $ord.selected.reasoning_tier -eq 'highest'
    ) -Name 'select-ordinary-grok-highest'

    $simple = (Invoke-JsonScript -File $selScript -ArgumentList @('-Profile', 'simple_mechanical', '-DiscoveryJsonPath', $discoPath)).Object
    Assert-True -Condition (
        $simple.selected.provider -eq 'grok' -and
        $simple.selected.reasoning_tier -eq 'second_highest' -and
        $simple.selected.reasoning_effort -eq 'medium'
    ) -Name 'select-simple-second-highest'

    $flashDiscovery = [ordered]@{
        providers = [ordered]@{
            grok = [ordered]@{ available = $false; executable = $null; models = @() }
            agy = [ordered]@{
                available = $true
                executable = "powershell.exe -NoProfile -File `"$fakeAgy`""
                models = @('Gemini 3.5 Flash (Medium)', 'Gemini 3.5 Flash (High)', 'Gemini 3.5 Flash (Low)', 'Gemini 3.5 Flash (low)')
                reasoning_map = [ordered]@{ highest = 'High'; second_highest = 'Medium'; labels = @('High', 'Medium') }
            }
        }
    }
    $flashPath = Join-Path $tmp 'discovery-flash.json'
    Write-MmoJson -LiteralPath $flashPath -InputObject $flashDiscovery
    $ordFlash = (Invoke-JsonScript -File $selScript -ArgumentList @('-Profile', 'ordinary_implementation', '-DiscoveryJsonPath', $flashPath)).Object
    Assert-True -Condition (
        $ordFlash.selected.model -eq 'Gemini 3.5 Flash (High)' -and
        $ordFlash.selected.model -notmatch '(?i)low'
    ) -Name 'select-never-low-flash' -Detail ($ordFlash.selected | ConvertTo-Json -Compress)

    # --- Task attribute normalization + visual preference ---
    $normUi = Normalize-MmoTaskAttributes -TaskAttributes @('UI', 'frontend', 'image', 'ui_design', 'not_a_real_attr')
    Assert-True -Condition (
        @($normUi.canonical) -contains 'ui' -and
        @($normUi.canonical) -contains 'web_frontend' -and
        @($normUi.canonical) -contains 'image_generation' -and
        @($normUi.unknown) -contains 'not_a_real_attr' -and
        $normUi.is_visual -eq $true
    ) -Name 'attr-normalize-ui-web-image-aliases' -Detail (($normUi | ConvertTo-Json -Compress))

    $normWeb = Normalize-MmoTaskAttributes -TaskAttributes @('web', 'visual')
    Assert-True -Condition (
        @($normWeb.canonical) -contains 'web_frontend' -and
        @($normWeb.canonical) -contains 'ui' -and
        $normWeb.is_visual -eq $true
    ) -Name 'attr-normalize-web-visual' -Detail (($normWeb.canonical) -join ',')

    $uiSel = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $discoPath,
        '-TaskAttributes', 'ui'
    )).Object
    Assert-True -Condition (
        $uiSel.selected.provider -eq 'agy' -and
        $uiSel.selected.model -eq 'Gemini 3.5 Flash (High)' -and
        $uiSel.visual_preference_applied -eq $true -and
        @($uiSel.task_attributes.canonical) -contains 'ui' -and
        $uiSel.selected.reasoning_tier -eq 'highest'
    ) -Name 'select-ui-prefers-agy-gemini-flash-high' -Detail ($uiSel.selected | ConvertTo-Json -Compress)

    $webSel = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $discoPath,
        '-TaskAttributes', 'web_frontend'
    )).Object
    Assert-True -Condition (
        $webSel.selected.model -eq 'Gemini 3.5 Flash (High)' -and
        $webSel.visual_preference_applied -eq $true
    ) -Name 'select-web-frontend-prefers-flash-high' -Detail ($webSel.selected.model)

    $imgSel = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $discoPath,
        '-TaskAttributes', 'image_generation'
    )).Object
    Assert-True -Condition (
        $imgSel.selected.model -eq 'Gemini 3.5 Flash (High)' -and
        $imgSel.visual_preference_applied -eq $true
    ) -Name 'select-image-generation-prefers-flash-high' -Detail ($imgSel.selected.model)

    $flashExcluded = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $discoPath,
        '-TaskAttributes', 'ui',
        '-ExcludeModels', 'Gemini 3.5 Flash (High)'
    )).Object
    Assert-True -Condition (
        $flashExcluded.selected.provider -eq 'grok' -and
        $flashExcluded.selected.model -eq 'grok-4.5' -and
        $flashExcluded.visual_preference_applied -eq $true -and
        (@($flashExcluded.route_notes) -join ' ') -match 'visual_preferred_absent_or_excluded'
    ) -Name 'select-ui-flash-excluded-falls-to-ordinary' -Detail ($flashExcluded.selected | ConvertTo-Json -Compress)

    $agyDownDisco = [ordered]@{
        providers = [ordered]@{
            grok = [ordered]@{
                available = $true
                executable = "powershell.exe -NoProfile -File `"$fakeGrok`""
                models = @('grok-4.5')
                reasoning_map = [ordered]@{ highest = 'high'; second_highest = 'medium'; labels = @('high', 'medium') }
            }
            agy = [ordered]@{
                available = $false
                executable = $null
                models = @()
            }
        }
    }
    $agyDownPath = Join-Path $tmp 'discovery-agy-down.json'
    Write-MmoJson -LiteralPath $agyDownPath -InputObject $agyDownDisco
    $uiAgyDown = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $agyDownPath,
        '-TaskAttributes', 'ui'
    )).Object
    Assert-True -Condition (
        $uiAgyDown.selected.provider -eq 'grok' -and
        $uiAgyDown.selected.model -eq 'grok-4.5'
    ) -Name 'select-ui-agy-unavailable-falls-to-grok' -Detail ($uiAgyDown.selected | ConvertTo-Json -Compress)

    $unknownOnly = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $discoPath,
        '-TaskAttributes', 'totally_unknown_attr'
    )).Object
    Assert-True -Condition (
        $unknownOnly.selected.provider -eq 'grok' -and
        $unknownOnly.visual_preference_applied -eq $false -and
        @($unknownOnly.task_attributes.unknown) -contains 'totally_unknown_attr' -and
        @($unknownOnly.task_attributes.canonical).Count -eq 0
    ) -Name 'select-unknown-attributes-do-not-reroute' -Detail (($unknownOnly.task_attributes | ConvertTo-Json -Compress))

    $diffWithUi = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'difficult_architecture',
        '-DiscoveryJsonPath', $discoPath,
        '-TaskAttributes', 'ui'
    )).Object
    Assert-True -Condition (
        $diffWithUi.selected.model -like '*Claude Opus*' -and
        $diffWithUi.visual_preference_applied -eq $false -and
        $diffWithUi.visual_preference_skipped_reason -eq 'difficult_task_quality_not_downgraded'
    ) -Name 'select-difficult-ui-does-not-downgrade-to-flash' -Detail ($diffWithUi.selected | ConvertTo-Json -Compress)

    $simpleBackup = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'simple_mechanical',
        '-DiscoveryJsonPath', $flashPath
    )).Object
    Assert-True -Condition (
        $simpleBackup.selected.provider -eq 'agy' -and
        $simpleBackup.selected.model -eq 'Gemini 3.5 Flash (High)' -and
        $simpleBackup.selected.model -notmatch '(?i)\(low\)' -and
        $simpleBackup.selected.model -notmatch '(?i)\(medium\)'
    ) -Name 'select-simple-backup-gemini-flash-high' -Detail ($simpleBackup.selected | ConvertTo-Json -Compress)

    $simplePrimary = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'simple_mechanical',
        '-DiscoveryJsonPath', $discoPath
    )).Object
    Assert-True -Condition (
        $simplePrimary.selected.provider -eq 'grok' -and
        $simplePrimary.selected.reasoning_tier -eq 'second_highest' -and
        $simplePrimary.selected.reasoning_effort -eq 'medium'
    ) -Name 'select-simple-primary-still-second-highest'

    $overrideSel = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $discoPath,
        '-TaskAttributes', 'ui',
        '-OverrideProvider', 'grok',
        '-OverrideModel', 'grok-4.5',
        '-OverrideReasoningTier', 'highest'
    )).Object
    Assert-True -Condition (
        $overrideSel.selected.provider -eq 'grok' -and
        $overrideSel.selected.model -eq 'grok-4.5' -and
        $overrideSel.override_applied -eq $true -and
        (@($overrideSel.route_notes) -join ' ') -match 'explicit_override'
    ) -Name 'select-explicit-safe-override-authoritative' -Detail ($overrideSel.selected | ConvertTo-Json -Compress)

    Invoke-ExpectFail -File $selScript -ArgumentList @(
        '-Profile', 'ordinary_implementation',
        '-DiscoveryJsonPath', $discoPath,
        '-OverrideProvider', 'agy',
        '-OverrideModel', 'Gemini 3.5 Flash (Low)'
    ) -Name 'select-reject-low-override-model' -MustMatch 'low|forbidden|policy'

    # Difficult chain reaches Grok highest after Claude + Gemini Pro High exclusions
    $diffToGrok = (Invoke-JsonScript -File $selScript -ArgumentList @(
        '-Profile', 'difficult_architecture',
        '-DiscoveryJsonPath', $discoPath,
        '-ExcludeModels', 'Claude Opus 4.6 (Thinking),Claude Sonnet 4.6 (Thinking),Gemini 3.1 Pro (High),Gemini 3.1 Pro (HIGH)'
    )).Object
    Assert-True -Condition (
        $diffToGrok.selected.provider -eq 'grok' -and
        $diffToGrok.selected.model -eq 'grok-4.5' -and
        $diffToGrok.selected.reasoning_tier -eq 'highest' -and
        $diffToGrok.selected.reasoning_effort -eq 'high'
    ) -Name 'select-difficult-claude-unavailable-to-grok-highest' -Detail ($diffToGrok.selected | ConvertTo-Json -Compress)

    # --- Allocate-Worktree no-git fallback ---
    $allocScript = Join-Path $scripts 'Allocate-Worktree.ps1'
    $nonGit = Join-Path $tmp 'nongit-repo'
    New-Item -ItemType Directory -Path $nonGit -Force | Out-Null
    $runDir = Join-Path $tmp 'run'
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $alloc = (Invoke-JsonScript -File $allocScript -ArgumentList @(
        '-RepoRoot', $nonGit,
        '-WorkerId', 'w-parallel-1',
        '-RunDirectory', $runDir
    )).Object
    Assert-True -Condition (
        $alloc.mode -eq 'no_git_fallback' -and
        $alloc.writable -eq $false
    ) -Name 'worktree-no-git-fallback'

    $allocRo = (Invoke-JsonScript -File $allocScript -ArgumentList @(
        '-RepoRoot', $nonGit,
        '-WorkerId', 'w-parallel-2',
        '-RunDirectory', $runDir,
        '-ForceReadOnlyFallback'
    )).Object
    Assert-True -Condition ($allocRo.mode -eq 'no_git_fallback') -Name 'worktree-force-readonly-fallback'

    # --- Invoke-Provider dry builds ---
    $invokeScript = Join-Path $scripts 'Invoke-Provider.ps1'
    $workerRun = Join-Path $tmp 'invoke-run'
    New-Item -ItemType Directory -Path $workerRun -Force | Out-Null
    $dry = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Provider', 'grok',
        '-Executable', 'powershell.exe',
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'hello offline',
        '-Cwd', $tmp,
        '-RunDirectory', $workerRun,
        '-WorkerId', 'dry1',
        '-DryBuildOnly'
    )).Object
    Assert-True -Condition (
        $dry.dry_run -eq $true -and
        (Test-Path -LiteralPath (Join-Path $workerRun 'workers\dry1\request.json'))
    ) -Name 'invoke-dry-build-writes-request'

    $req = Get-Content -LiteralPath (Join-Path $workerRun 'workers\dry1\request.json') -Raw | ConvertFrom-Json
    Assert-True -Condition (
        $req.provider -eq 'grok' -and
        $req.reasoning_tier -eq 'highest' -and
        $req.args -contains '--reasoning-effort' -and
        $req.args -contains 'high' -and
        $req.args -contains '--always-approve' -and
        $req.always_approve -eq $true
    ) -Name 'invoke-dry-grok-always-approve-and-highest' -Detail (($req.args) -join ' ')

    $dryAgy = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Provider', 'agy',
        '-Executable', 'powershell.exe',
        '-Model', 'Gemini 3.5 Flash (High)',
        '-ReasoningTier', 'highest',
        '-Prompt', 'hello agy',
        '-Cwd', $tmp,
        '-RunDirectory', $workerRun,
        '-WorkerId', 'dry-agy',
        '-DryBuildOnly'
    )).Object
    Assert-True -Condition (
        $dryAgy.dry_run -eq $true -and
        $dryAgy.args -contains '--print' -and
        $dryAgy.args -contains 'Gemini 3.5 Flash (High)' -and
        $dryAgy.reasoning_tier -eq 'highest'
    ) -Name 'invoke-dry-agy-args' -Detail (($dryAgy.args) -join ' ')

    # Invocation boundary: reject low effort / low model / smuggled ExtraArgs
    Invoke-ExpectFail -File $invokeScript -ArgumentList @(
        '-Provider', 'grok', '-Executable', 'powershell.exe',
        '-Model', 'grok-4.5', '-ReasoningTier', 'highest',
        '-ReasoningEffort', 'low',
        '-Prompt', 'x', '-Cwd', $tmp, '-RunDirectory', $workerRun, '-WorkerId', 'bad-effort', '-DryBuildOnly'
    ) -Name 'invoke-reject-reasoning-effort-low' -MustMatch 'forbidden|policy|low'

    Invoke-ExpectFail -File $invokeScript -ArgumentList @(
        '-Provider', 'grok', '-Executable', 'powershell.exe',
        '-Model', 'grok-4.5', '-ReasoningTier', 'highest',
        '-ReasoningEffort', 'LOWEST',
        '-Prompt', 'x', '-Cwd', $tmp, '-RunDirectory', $workerRun, '-WorkerId', 'bad-effort2', '-DryBuildOnly'
    ) -Name 'invoke-reject-reasoning-effort-LOWEST' -MustMatch 'forbidden|policy|low'

    Invoke-ExpectFail -File $invokeScript -ArgumentList @(
        '-Provider', 'agy', '-Executable', 'powershell.exe',
        '-Model', 'Gemini 3.5 Flash (low)', '-ReasoningTier', 'highest',
        '-Prompt', 'x', '-Cwd', $tmp, '-RunDirectory', $workerRun, '-WorkerId', 'bad-model', '-DryBuildOnly'
    ) -Name 'invoke-reject-model-low-case' -MustMatch 'forbidden|policy|low'

    # ExtraArgs smuggling is enforced by Assert-MmoInvocationPolicy (used at invoke boundary).
    $extraRejected = $false
    try {
        Assert-MmoInvocationPolicy -Model 'grok-4.5' -ReasoningEffort 'high' -ReasoningTier 'highest' -ExtraArgs @('--reasoning-effort', 'minimal')
    }
    catch {
        $extraRejected = ($_.Exception.Message -match 'forbidden|policy|minimal|low')
    }
    Assert-True -Condition $extraRejected -Name 'invoke-reject-extraargs-minimal'

    $inlineRejected = $false
    try {
        Assert-MmoInvocationPolicy -Model 'grok-4.5' -ReasoningEffort 'high' -ReasoningTier 'highest' -BuiltArgs @('--effort=low')
    }
    catch {
        $inlineRejected = ($_.Exception.Message -match 'forbidden|policy|low')
    }
    Assert-True -Condition $inlineRejected -Name 'invoke-reject-inline-effort-equals-low'

    # Fake executable wrappers
    $cmdGrok = Join-Path $tmp 'fake-grok.cmd'
    @"
@echo off
powershell.exe -NoProfile -NonInteractive -File "$fakeGrok" %*
"@ | Set-Content -LiteralPath $cmdGrok -Encoding ASCII
    $cmdAgy = Join-Path $tmp 'fake-agy.cmd'
    @"
@echo off
powershell.exe -NoProfile -NonInteractive -File "$fakeAgy" %*
"@ | Set-Content -LiteralPath $cmdAgy -Encoding ASCII

    $execRun = Join-Path $tmp 'exec-run'
    New-Item -ItemType Directory -Path $execRun -Force | Out-Null
    $env:MMO_FAKE_GROK_MODE = ''
    $ok = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Provider', 'grok',
        '-Executable', $cmdGrok,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'second_highest',
        '-Prompt', 'offline success',
        '-Cwd', $tmp,
        '-RunDirectory', $execRun,
        '-WorkerId', 'ok1',
        '-TimeoutSeconds', '30'
    )).Object
    Assert-True -Condition ($ok.classification -eq 'success' -and $ok.exit_code -eq 0) -Name 'invoke-fake-grok-success' -Detail ($ok.classification)

    $quotaRun = Join-Path $tmp 'quota-run'
    New-Item -ItemType Directory -Path $quotaRun -Force | Out-Null
    $env:MMO_FAKE_GROK_MODE = 'quota'
    $quota = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Provider', 'grok',
        '-Executable', $cmdGrok,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'offline quota',
        '-Cwd', $tmp,
        '-RunDirectory', $quotaRun,
        '-WorkerId', 'q1',
        '-TimeoutSeconds', '30'
    )).Object
    $env:MMO_FAKE_GROK_MODE = ''
    Assert-True -Condition (
        $quota.classification -eq 'quota_exhausted' -and
        $quota.fallback_eligible -eq $true
    ) -Name 'invoke-fake-grok-quota' -Detail ($quota | ConvertTo-Json -Compress)

    # --- Concurrent two-provider: success + quota, isolated cwds, overlap ---
    $concRun = Join-Path $tmp 'concurrent-run'
    New-Item -ItemType Directory -Path $concRun -Force | Out-Null
    $cwdGrok = Join-Path $tmp 'cwd-grok'
    $cwdAgy = Join-Path $tmp 'cwd-agy'
    New-Item -ItemType Directory -Path $cwdGrok, $cwdAgy -Force | Out-Null

    $workersSpec = @(
        [pscustomobject]@{
            worker_id = 'w-grok'
            provider = 'grok'
            executable = $cmdGrok
            model = 'grok-4.5'
            reasoning_tier = 'highest'
            prompt = 'concurrent success worker'
            cwd = $cwdGrok
            timeout_seconds = 60
            env = [pscustomobject]@{ MMO_FAKE_SLEEP_MS = '500'; MMO_FAKE_GROK_MODE = '' }
        },
        [pscustomobject]@{
            worker_id = 'w-agy'
            provider = 'agy'
            executable = $cmdAgy
            model = 'Claude Opus 4.6 (Thinking)'
            reasoning_tier = 'highest'
            prompt = 'concurrent quota worker'
            cwd = $cwdAgy
            timeout_seconds = 60
            env = [pscustomobject]@{ MMO_FAKE_SLEEP_MS = '500'; MMO_FAKE_AGY_MODE = 'quota' }
        }
    )
    $specPath = Join-Path $concRun 'workers-spec.json'
    Write-MmoJson -LiteralPath $specPath -InputObject $workersSpec

    $concScript = Join-Path $scripts 'Start-ConcurrentWorkers.ps1'
    $t0 = [datetime]::UtcNow
    $conc = (Invoke-JsonScript -File $concScript -ArgumentList @(
        '-RunDirectory', $concRun,
        '-WorkersJson', $specPath
    )).Object
    $t1 = [datetime]::UtcNow
    $elapsedSec = ($t1 - $t0).TotalSeconds

    $wGrok = $conc.workers | Where-Object { $_.worker_id -eq 'w-grok' } | Select-Object -First 1
    $wAgy = $conc.workers | Where-Object { $_.worker_id -eq 'w-agy' } | Select-Object -First 1
    Assert-True -Condition ($null -ne $wGrok -and $null -ne $wAgy) -Name 'concurrent-both-workers-present'

    Assert-True -Condition (
        $wGrok.result.classification -eq 'success' -and
        $wGrok.result.exit_code -eq 0
    ) -Name 'concurrent-grok-success-recorded' -Detail ($wGrok.result | ConvertTo-Json -Compress)

    Assert-True -Condition (
        $wAgy.result.classification -eq 'quota_exhausted' -and
        $wAgy.result.fallback_eligible -eq $true
    ) -Name 'concurrent-agy-quota-fallback-eligible' -Detail ($wAgy.result | ConvertTo-Json -Compress)

    # Overlap evidence: wall clock with two 500ms sleeps should be << 1.0s sequential sum if concurrent.
    # Allow generous bound for job overhead but require < 4s total and both started.
    Assert-True -Condition ($elapsedSec -lt 8.0 -and $conc.worker_count -eq 2) -Name 'concurrent-wallclock-overlap-bound' -Detail "elapsedSec=$elapsedSec"

    $pidIndexPath = Join-Path $concRun 'WORKER_PIDS.json'
    Assert-True -Condition (Test-Path -LiteralPath $pidIndexPath) -Name 'concurrent-worker-pids-index'
    $pidIndex = Get-Content -LiteralPath $pidIndexPath -Raw | ConvertFrom-Json
    Assert-True -Condition (@($pidIndex.workers).Count -eq 2) -Name 'concurrent-two-pids-recorded' -Detail (($pidIndex.workers | ConvertTo-Json -Compress))

    # Distinct cwds persisted in plan
    $plan = Get-Content -LiteralPath (Join-Path $concRun 'concurrent-plan.json') -Raw | ConvertFrom-Json
    $planCwds = @($plan.workers | ForEach-Object { $_.cwd }) | Select-Object -Unique
    Assert-True -Condition ($planCwds.Count -eq 2) -Name 'concurrent-isolated-cwds' -Detail (($planCwds -join ' | '))

    # Shared-cwd rejection
    $badSpec = @(
        [pscustomobject]@{ worker_id = 'a'; provider = 'grok'; executable = $cmdGrok; model = 'grok-4.5'; reasoning_tier = 'highest'; prompt = 'x'; cwd = $cwdGrok },
        [pscustomobject]@{ worker_id = 'b'; provider = 'agy'; executable = $cmdAgy; model = 'Claude Opus 4.6 (Thinking)'; reasoning_tier = 'highest'; prompt = 'y'; cwd = $cwdGrok }
    )
    $badSpecPath = Join-Path $tmp 'bad-shared-cwd.json'
    Write-MmoJson -LiteralPath $badSpecPath -InputObject $badSpec
    Invoke-ExpectFail -File $concScript -ArgumentList @(
        '-RunDirectory', (Join-Path $tmp 'bad-conc'),
        '-WorkersJson', $badSpecPath
    ) -Name 'concurrent-reject-shared-cwd' -MustMatch 'share|Overlap|cwd'

    # Dry concurrent plan still builds always-approve for grok
    $dryConcRun = Join-Path $tmp 'dry-conc'
    New-Item -ItemType Directory -Path $dryConcRun -Force | Out-Null
    $dryConc = (Invoke-JsonScript -File $concScript -ArgumentList @(
        '-RunDirectory', $dryConcRun,
        '-WorkersJson', $specPath,
        '-DryBuildOnly'
    )).Object
    $dryGrokReq = Get-Content -LiteralPath (Join-Path $dryConcRun 'workers\w-grok\request.json') -Raw | ConvertFrom-Json
    Assert-True -Condition (
        $dryGrokReq.args -contains '--always-approve' -and
        $dryGrokReq.reasoning_tier -eq 'highest'
    ) -Name 'concurrent-dry-grok-always-approve' -Detail (($dryGrokReq.args) -join ' ')

    # Concurrent Grok no_always_approve opt-out
    $optOutSpec = @(
        [pscustomobject]@{
            worker_id = 'w-opt'
            provider = 'grok'
            executable = $cmdGrok
            model = 'grok-4.5'
            reasoning_tier = 'highest'
            prompt = 'opt out approve'
            cwd = $cwdGrok
            no_always_approve = $true
        }
    )
    $optOutPath = Join-Path $tmp 'opt-out-spec.json'
    Write-MmoJson -LiteralPath $optOutPath -InputObject $optOutSpec
    $optOutRun = Join-Path $tmp 'opt-out-run'
    New-Item -ItemType Directory -Path $optOutRun -Force | Out-Null
    $null = Invoke-JsonScript -File $concScript -ArgumentList @(
        '-RunDirectory', $optOutRun,
        '-WorkersJson', $optOutPath,
        '-DryBuildOnly'
    )
    $optReq = Get-Content -LiteralPath (Join-Path $optOutRun 'workers\w-opt\request.json') -Raw | ConvertFrom-Json
    $optPlan = Get-Content -LiteralPath (Join-Path $optOutRun 'concurrent-plan.json') -Raw | ConvertFrom-Json
    Assert-True -Condition (
        $optReq.always_approve -eq $false -and
        -not ($optReq.args -contains '--always-approve') -and
        $optPlan.workers[0].no_always_approve -eq $true -and
        ($optPlan.workers[0].args -contains '-NoAlwaysApprove')
    ) -Name 'concurrent-grok-no-always-approve-opt-out' -Detail (($optReq.args) -join ' ')

    # --- New-RunDirectory ---
    $newRunScript = Join-Path $scripts 'New-RunDirectory.ps1'
    $projRoot = Join-Path $tmp 'proj-root'
    New-Item -ItemType Directory -Path $projRoot -Force | Out-Null
    $newRun = (Invoke-JsonScript -File $newRunScript -ArgumentList @(
        '-ProjectRoot', $projRoot,
        '-Slug', 'Offline Hardening',
        '-Strategy', 'single',
        '-Stage', 'implement'
    )).Object
    Assert-True -Condition (
        $newRun.run_id -match 'offline-hardening' -and
        (Test-Path -LiteralPath (Join-Path $newRun.run_directory 'STATUS.json')) -and
        (Test-Path -LiteralPath (Join-Path $newRun.run_directory 'BRIEF.md')) -and
        (Test-Path -LiteralPath (Join-Path $newRun.run_directory 'workers'))
    ) -Name 'new-run-directory-skeleton' -Detail $newRun.run_directory

    # --- ArgumentList / argv integrity via ProcessStartInfo helper ---
    $argvPath = Join-Path $tmp 'argv-record.json'
    $env:MMO_FAKE_ARGV_PATH = $argvPath
    $advPrompt = 'spaces and "quotes" and path\trail\ and $(no-sub) and `backticks` and %PATH% text'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.WorkingDirectory = $tmp
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $directArgs = @(
        '-NoProfile', '-NonInteractive', '-File', $fakeGrok,
        '--cwd', $tmp,
        '--model', 'grok-4.5',
        '--reasoning-effort', 'high',
        '--always-approve',
        '--single', $advPrompt
    )
    $mode = Set-MmoProcessStartInfoArguments -StartInfo $psi -ArgumentList $directArgs
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $null = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    $p.WaitForExit(15000) | Out-Null
    $p.Dispose()
    $argvRec = $null
    if (Test-Path -LiteralPath $argvPath) {
        $argvRec = Get-Content -LiteralPath $argvPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $env:MMO_FAKE_ARGV_PATH = $null
    $argvList = @()
    if ($argvRec) { $argvList = @($argvRec.argv) }
    $singleIdx = [array]::IndexOf($argvList, '--single')
    $promptArg = if ($singleIdx -ge 0 -and $singleIdx -lt ($argvList.Count - 1)) { [string]$argvList[$singleIdx + 1] } else { '' }
    Assert-True -Condition (
        $null -ne $argvRec -and
        $argvList -contains '--always-approve' -and
        $argvList -contains '--reasoning-effort' -and
        $promptArg -eq $advPrompt -and
        -not ($argvList -contains '-NoAlwaysApprove')
    ) -Name 'argv-escaping-preserves-single-prompt' -Detail ("mode=$mode promptArg=$promptArg")

    # --- Timeout process-tree cleanup ---
    $hangRun = Join-Path $tmp 'hang-run'
    New-Item -ItemType Directory -Path $hangRun -Force | Out-Null
    $childPidPath = Join-Path $tmp 'hang-child.pid'
    $env:MMO_FAKE_GROK_MODE = 'hang_with_child'
    $env:MMO_FAKE_CHILD_PID_PATH = $childPidPath
    $hang = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Provider', 'grok',
        '-Executable', $cmdGrok,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'hang please',
        '-Cwd', $tmp,
        '-RunDirectory', $hangRun,
        '-WorkerId', 'hang1',
        '-TimeoutSeconds', '2'
    ) -AllowFailure).Object
    $env:MMO_FAKE_GROK_MODE = ''
    $env:MMO_FAKE_CHILD_PID_PATH = $null
    Start-Sleep -Milliseconds 500
    $childAlive = $false
    $childId = 0
    if (Test-Path -LiteralPath $childPidPath) {
        $childId = [int]((Get-Content -LiteralPath $childPidPath -Raw).Trim())
        $childAlive = $null -ne (Get-Process -Id $childId -ErrorAction SilentlyContinue)
        if ($childAlive) {
            Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
        }
    }
    Assert-True -Condition (
        $hang.timed_out -eq $true -and
        $hang.classification -eq 'timeout' -and
        -not $childAlive
    ) -Name 'timeout-kills-descendant-tree' -Detail ("childId=$childId childAlive=$childAlive cls=$($hang.classification)")

    # --- Fallback chain: multi-hop success, exhausted, non-fallback stop ---
    $fbScript = Join-Path $scripts 'Invoke-FallbackChain.ps1'
    Assert-True -Condition (Test-Path -LiteralPath $fbScript) -Name 'script-invoke-fallback-chain-exists'

    $fbSuccessRun = Join-Path $tmp 'fb-success'
    New-Item -ItemType Directory -Path $fbSuccessRun -Force | Out-Null
    $routeSuccess = @(
        [pscustomobject]@{
            provider = 'agy'; executable = $cmdAgy; model = 'Claude Opus 4.6 (Thinking)'
            reasoning_tier = 'highest'; cwd = $cwdAgy
            env = [pscustomobject]@{ MMO_FAKE_AGY_MODE = 'quota' }
        },
        [pscustomobject]@{
            provider = 'agy'; executable = $cmdAgy; model = 'Claude Sonnet 4.6 (Thinking)'
            reasoning_tier = 'highest'; cwd = $cwdAgy
            env = [pscustomobject]@{ MMO_FAKE_AGY_MODE = 'model_unavailable' }
        },
        [pscustomobject]@{
            provider = 'grok'; executable = $cmdGrok; model = 'grok-4.5'
            reasoning_tier = 'highest'; cwd = $cwdGrok
            env = [pscustomobject]@{ MMO_FAKE_GROK_MODE = '' }
        }
    )
    $routeSuccessPath = Join-Path $tmp 'route-success.json'
    Write-MmoJson -LiteralPath $routeSuccessPath -InputObject $routeSuccess
    $fbOk = (Invoke-JsonScript -File $fbScript -ArgumentList @(
        '-RunDirectory', $fbSuccessRun,
        '-RouteJson', $routeSuccessPath,
        '-Prompt', 'fallback multi hop',
        '-TimeoutSeconds', '30'
    )).Object
    $fbLines = @()
    if (Test-Path -LiteralPath (Join-Path $fbSuccessRun 'FALLBACKS.jsonl')) {
        $fbLines = @(Get-Content -LiteralPath (Join-Path $fbSuccessRun 'FALLBACKS.jsonl') -Encoding UTF8)
    }
    Assert-True -Condition (
        $fbOk.stopped_reason -eq 'success' -and
        $fbOk.final.classification -eq 'success' -and
        $fbOk.attempts.Count -eq 3 -and
        $fbLines.Count -ge 3
    ) -Name 'fallback-multi-hop-success' -Detail ("attempts=$($fbOk.attempts.Count) lines=$($fbLines.Count)")

    $fbExhaustRun = Join-Path $tmp 'fb-exhaust'
    New-Item -ItemType Directory -Path $fbExhaustRun -Force | Out-Null
    $routeExhaust = @(
        [pscustomobject]@{
            provider = 'agy'; executable = $cmdAgy; model = 'Claude Opus 4.6 (Thinking)'
            reasoning_tier = 'highest'; cwd = $cwdAgy
            env = [pscustomobject]@{ MMO_FAKE_AGY_MODE = 'quota' }
        },
        [pscustomobject]@{
            provider = 'agy'; executable = $cmdAgy; model = 'Claude Sonnet 4.6 (Thinking)'
            reasoning_tier = 'highest'; cwd = $cwdAgy
            env = [pscustomobject]@{ MMO_FAKE_AGY_MODE = 'quota' }
        }
    )
    $routeExhaustPath = Join-Path $tmp 'route-exhaust.json'
    Write-MmoJson -LiteralPath $routeExhaustPath -InputObject $routeExhaust
    $fbEx = (Invoke-JsonScript -File $fbScript -ArgumentList @(
        '-RunDirectory', $fbExhaustRun,
        '-RouteJson', $routeExhaustPath,
        '-Prompt', 'fallback exhaust',
        '-TimeoutSeconds', '30'
    )).Object
    Assert-True -Condition (
        $fbEx.stopped_reason -eq 'route_exhausted' -and
        (Test-Path -LiteralPath (Join-Path $fbExhaustRun 'BLOCKED.flag')) -and
        (Test-Path -LiteralPath (Join-Path $fbExhaustRun 'FALLBACKS.jsonl'))
    ) -Name 'fallback-route-exhausted-blocked' -Detail $fbEx.stopped_reason

    $fbAuthRun = Join-Path $tmp 'fb-auth'
    New-Item -ItemType Directory -Path $fbAuthRun -Force | Out-Null
    $routeAuth = @(
        [pscustomobject]@{
            provider = 'agy'; executable = $cmdAgy; model = 'Claude Opus 4.6 (Thinking)'
            reasoning_tier = 'highest'; cwd = $cwdAgy
            env = [pscustomobject]@{ MMO_FAKE_AGY_MODE = 'auth' }
        },
        [pscustomobject]@{
            provider = 'grok'; executable = $cmdGrok; model = 'grok-4.5'
            reasoning_tier = 'highest'; cwd = $cwdGrok
        }
    )
    $routeAuthPath = Join-Path $tmp 'route-auth.json'
    Write-MmoJson -LiteralPath $routeAuthPath -InputObject $routeAuth
    $fbAuth = (Invoke-JsonScript -File $fbScript -ArgumentList @(
        '-RunDirectory', $fbAuthRun,
        '-RouteJson', $routeAuthPath,
        '-Prompt', 'fallback auth stop',
        '-TimeoutSeconds', '30'
    )).Object
    Assert-True -Condition (
        $fbAuth.stopped_reason -eq 'non_fallback_failure' -and
        $fbAuth.attempts.Count -eq 1 -and
        $fbAuth.final.classification -eq 'auth_failure' -and
        (Test-Path -LiteralPath (Join-Path $fbAuthRun 'FAILED.flag'))
    ) -Name 'fallback-auth-does-not-advance' -Detail ("count=$($fbAuth.attempts.Count) cls=$($fbAuth.final.classification)")

    # Fallback rejects low tier hop
    $routeLow = @(
        [pscustomobject]@{
            provider = 'grok'; executable = $cmdGrok; model = 'grok-4.5'
            reasoning_tier = 'highest'; reasoning_effort = 'low'; cwd = $cwdGrok
        }
    )
    $routeLowPath = Join-Path $tmp 'route-low.json'
    Write-MmoJson -LiteralPath $routeLowPath -InputObject $routeLow
    Invoke-ExpectFail -File $fbScript -ArgumentList @(
        '-RunDirectory', (Join-Path $tmp 'fb-low'),
        '-RouteJson', $routeLowPath,
        '-Prompt', 'no low',
        '-DryBuildOnly'
    ) -Name 'fallback-rejects-low-effort' -MustMatch 'forbidden|policy|low'

    # ExtraArgs must be forwarded one argv element each into the provider process.
    $extraArgvPath = Join-Path $tmp 'fb-extra-argv.json'
    $extraRun = Join-Path $tmp 'fb-extra'
    New-Item -ItemType Directory -Path $extraRun -Force | Out-Null
    $routeExtra = @(
        [pscustomobject]@{
            provider = 'grok'; executable = $cmdGrok; model = 'grok-4.5'
            reasoning_tier = 'highest'; cwd = $cwdGrok
            env = [pscustomobject]@{ MMO_FAKE_GROK_MODE = ''; MMO_FAKE_ARGV_PATH = $extraArgvPath }
        }
    )
    $routeExtraPath = Join-Path $tmp 'route-extra.json'
    Write-MmoJson -LiteralPath $routeExtraPath -InputObject $routeExtra
    # Multi ExtraArgs via JSON file (PS 5.1 -File cannot safely repeat -ExtraArgs or preserve JSON quotes).
    $extraArgsFile = Join-Path $extraRun 'caller-extra-args.json'
    Write-MmoUtf8Text -LiteralPath $extraArgsFile -Text '["--mmo-trace-tag","revision-extra-1"]'
    $fbExtra = (Invoke-JsonScript -File $fbScript -ArgumentList @(
        '-RunDirectory', $extraRun,
        '-RouteJson', $routeExtraPath,
        '-Prompt', 'extra args hop',
        '-TimeoutSeconds', '30',
        '-ExtraArgsJsonPath', $extraArgsFile
    )).Object
    $extraArgv = $null
    if (Test-Path -LiteralPath $extraArgvPath) {
        $extraArgv = Get-Content -LiteralPath $extraArgvPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $extraList = @()
    if ($extraArgv) {
        if ($extraArgv.argv) { $extraList = @($extraArgv.argv) }
        elseif ($extraArgv.args) { $extraList = @($extraArgv.args) }
    }
    $tagIdx = [array]::IndexOf($extraList, '--mmo-trace-tag')
    $valIdx = [array]::IndexOf($extraList, 'revision-extra-1')
    Assert-True -Condition (
        $fbExtra.stopped_reason -eq 'success' -and
        $tagIdx -ge 0 -and
        $valIdx -ge 0 -and
        $tagIdx -ne $valIdx -and
        (Test-Path -LiteralPath (Join-Path $extraRun 'fallback-summary.json'))
    ) -Name 'fallback-extraargs-forwarded-one-each' -Detail (("argv=" + ($extraList -join ' | ')))

    # Profile-driven Invoke-WithFallback: quota on first preferred model, advance, durable hops.
    $withFbScript = Join-Path $scripts 'Invoke-WithFallback.ps1'
    Assert-True -Condition (Test-Path -LiteralPath $withFbScript) -Name 'script-invoke-with-fallback-exists'
    $withDisco = [ordered]@{
        discovered_at = [datetime]::UtcNow.ToString('o')
        providers = [ordered]@{
            grok = [ordered]@{
                available = $true
                executable = $cmdGrok
                models = @('grok-4.5')
                reasoning_map = [ordered]@{ highest = 'high'; second_highest = 'medium'; labels = @('high', 'medium') }
            }
            agy = [ordered]@{
                available = $true
                executable = $cmdAgy
                models = @(
                    'Claude Opus 4.6 (Thinking)',
                    'Claude Sonnet 4.6 (Thinking)',
                    'Gemini 3.1 Pro (High)',
                    'Gemini 3.5 Flash (High)'
                )
                reasoning_map = [ordered]@{ highest = 'High'; second_highest = 'Medium'; labels = @('High', 'Medium') }
            }
        }
    }
    $withDiscoPath = Join-Path $tmp 'with-fb-discovery.json'
    Write-MmoJson -LiteralPath $withDiscoPath -InputObject $withDisco
    $withRun = Join-Path $tmp 'with-fb-success'
    New-Item -ItemType Directory -Path $withRun -Force | Out-Null
    $env:MMO_FAKE_AGY_MODE = ''
    $env:MMO_FAKE_AGY_QUOTA_MODELS = 'Opus'
    $env:MMO_FAKE_GROK_MODE = ''
    $withFb = (Invoke-JsonScript -File $withFbScript -ArgumentList @(
        '-RunDirectory', $withRun,
        '-RoutingProfile', 'difficult_architecture',
        '-DiscoveryJsonPath', $withDiscoPath,
        '-Prompt', 'profile driven fallback',
        '-Cwd', $tmp,
        '-TimeoutSeconds', '30',
        '-WorkerIdPrefix', 'wf'
    )).Object
    $env:MMO_FAKE_AGY_QUOTA_MODELS = $null
    $withLines = @()
    if (Test-Path -LiteralPath (Join-Path $withRun 'FALLBACKS.jsonl')) {
        $withLines = @(Get-Content -LiteralPath (Join-Path $withRun 'FALLBACKS.jsonl') -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $with0 = if ($withLines.Count -ge 1) { $withLines[0] | ConvertFrom-Json } else { $null }
    $withLast = if ($withLines.Count -ge 1) { $withLines[$withLines.Count - 1] | ConvertFrom-Json } else { $null }
    Assert-True -Condition (
        $null -ne $withFb.final -and
        $withFb.final.classification -eq 'success' -and
        $withFb.hop_count -ge 2 -and
        $withLines.Count -ge 2 -and
        $null -ne $with0 -and
        $with0.classification -eq 'quota_exhausted' -and
        $with0.source_model -like '*Opus*' -and
        $with0.target_model -like '*Sonnet*' -and
        $null -ne $withLast -and
        $withLast.classification -eq 'success' -and
        (Test-Path -LiteralPath (Join-Path $withRun 'fallback-summary.json'))
    ) -Name 'with-fallback-profile-quota-to-next-durable' -Detail ("hops=$($withFb.hop_count) lines=$($withLines.Count)")

    # Difficult: Claude quota + Sonnet unavailable + Pro High quota → Grok highest (no credits).
    $withGrokRun = Join-Path $tmp 'with-fb-to-grok'
    New-Item -ItemType Directory -Path $withGrokRun -Force | Out-Null
    $env:MMO_FAKE_AGY_MODE = ''
    $env:MMO_FAKE_AGY_QUOTA_MODELS = 'Opus;Gemini 3.1 Pro'
    $env:MMO_FAKE_AGY_UNAVAILABLE_MODELS = 'Sonnet'
    $env:MMO_FAKE_GROK_MODE = ''
    $withToGrok = (Invoke-JsonScript -File $withFbScript -ArgumentList @(
        '-RunDirectory', $withGrokRun,
        '-RoutingProfile', 'difficult_architecture',
        '-DiscoveryJsonPath', $withDiscoPath,
        '-Prompt', 'difficult fallback to grok highest',
        '-Cwd', $tmp,
        '-TimeoutSeconds', '30',
        '-WorkerIdPrefix', 'wg'
    )).Object
    $env:MMO_FAKE_AGY_QUOTA_MODELS = $null
    $env:MMO_FAKE_AGY_UNAVAILABLE_MODELS = $null
    $withGrokFinal = $withToGrok.final
    $withGrokHops = @($withToGrok.hops)
    $lastHop = if ($withGrokHops.Count -ge 1) { $withGrokHops[$withGrokHops.Count - 1] } else { $null }
    Assert-True -Condition (
        $null -ne $withGrokFinal -and
        $withGrokFinal.classification -eq 'success' -and
        $withGrokHops.Count -ge 4 -and
        $null -ne $lastHop -and
        $lastHop.provider -eq 'grok' -and
        $lastHop.model -eq 'grok-4.5' -and
        $lastHop.reasoning_tier -eq 'highest' -and
        (Test-Path -LiteralPath (Join-Path $withGrokRun 'FALLBACKS.jsonl'))
    ) -Name 'with-fallback-difficult-claude-to-grok-highest' -Detail ("hops=$($withGrokHops.Count) last=$($lastHop | ConvertTo-Json -Compress)")

    # Auth terminal hop must still be recorded in FALLBACKS.jsonl for WithFallback.
    $withAuthRun = Join-Path $tmp 'with-fb-auth'
    New-Item -ItemType Directory -Path $withAuthRun -Force | Out-Null
    $env:MMO_FAKE_AGY_MODE = 'auth'
    $withAuth = (Invoke-JsonScript -File $withFbScript -ArgumentList @(
        '-RunDirectory', $withAuthRun,
        '-RoutingProfile', 'difficult_architecture',
        '-DiscoveryJsonPath', $withDiscoPath,
        '-Prompt', 'profile auth stop',
        '-Cwd', $tmp,
        '-TimeoutSeconds', '30',
        '-WorkerIdPrefix', 'wa'
    )).Object
    $env:MMO_FAKE_AGY_MODE = ''
    $withAuthLines = @()
    if (Test-Path -LiteralPath (Join-Path $withAuthRun 'FALLBACKS.jsonl')) {
        $withAuthLines = @(Get-Content -LiteralPath (Join-Path $withAuthRun 'FALLBACKS.jsonl') -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $withAuth0 = if ($withAuthLines.Count -ge 1) { $withAuthLines[0] | ConvertFrom-Json } else { $null }
    Assert-True -Condition (
        $withAuth.non_fallback_stop -eq $true -and
        $withAuth.hop_count -eq 1 -and
        $withAuthLines.Count -eq 1 -and
        $null -ne $withAuth0 -and
        $withAuth0.classification -eq 'auth_failure' -and
        $withAuth0.fallback_eligible -eq $false -and
        (Test-Path -LiteralPath (Join-Path $withAuthRun 'FAILED.flag'))
    ) -Name 'with-fallback-auth-records-terminal-hop' -Detail ("lines=$($withAuthLines.Count)")

    # Canonical aggregate name is fallback-summary.json (not fallback-results.json).
    Assert-True -Condition (
        (Test-Path -LiteralPath (Join-Path $fbSuccessRun 'fallback-summary.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $fbSuccessRun 'fallback-results.json'))
    ) -Name 'fallback-summary-artifact-name'

    # --- Discovery eligible/forbidden partition (offline unit of Split via helper path) ---
    $discoScript = Join-Path $scripts 'Discover-Providers.ps1'
    $discoText = Get-Content -LiteralPath $discoScript -Raw
    $commonText = Get-Content -LiteralPath (Join-Path $scripts 'Common.ps1') -Raw
    Assert-True -Condition (
        $commonText -match 'function Split-MmoDiscoveredModels' -and
        $discoText -match 'Split-MmoDiscoveredModels' -and
        $discoText -match 'eligible_models' -and
        $discoText -match 'forbidden_models'
    ) -Name 'discover-exposes-eligible-forbidden'

    # PS 5.1 regression: List[object] + @() threw "Argument types do not match" on real model lines.
    $observedGrokModels = @('grok-4.5')
    $observedAgyModels = @(
        'Gemini 3.5 Flash (Medium)',
        'Gemini 3.5 Flash (High)',
        'Gemini 3.5 Flash (Low)',
        'Gemini 3.1 Pro (Low)',
        'Gemini 3.1 Pro (High)',
        'Claude Sonnet 4.6 (Thinking)',
        'Claude Opus 4.6 (Thinking)',
        'GPT-OSS 120B (Medium)'
    )
    $splitGrok = $null
    $splitAgy = $null
    $splitOk = $true
    $splitDetail = ''
    try {
        $splitGrok = Split-MmoDiscoveredModels -Models $observedGrokModels -ForbiddenSubstrings @()
        $splitAgy = Split-MmoDiscoveredModels -Models $observedAgyModels -ForbiddenSubstrings @('(Low)', '(low)', ' Low')
    }
    catch {
        $splitOk = $false
        $splitDetail = $_.Exception.Message
    }
    Assert-True -Condition (
        $splitOk -and
        $null -ne $splitGrok -and
        @($splitGrok.models).Count -eq 1 -and
        @($splitGrok.eligible_models).Count -eq 1 -and
        @($splitGrok.forbidden_models).Count -eq 0 -and
        $null -ne $splitAgy -and
        @($splitAgy.models).Count -eq 8 -and
        @($splitAgy.forbidden_models) -contains 'Gemini 3.5 Flash (Low)' -and
        @($splitAgy.forbidden_models) -contains 'Gemini 3.1 Pro (Low)' -and
        @($splitAgy.eligible_models) -contains 'Claude Opus 4.6 (Thinking)' -and
        @($splitAgy.eligible_models) -notcontains 'Gemini 3.5 Flash (Low)' -and
        @($splitAgy.models_annotated).Count -eq 8
    ) -Name 'split-discovered-models-ps51-observed-lines' -Detail $splitDetail

    # --- Watchdog: CPU-only must not count as activity ---
    $watchScript = Join-Path $scripts 'Watch-Run.ps1'
    $watchText = Get-Content -LiteralPath $watchScript -Raw
    Assert-True -Condition (
        $watchText -match 'artifact progress' -and
        $watchText -match 'CPU-only' -and
        $watchText -notmatch '\$cpuTotal -gt \$lastCpuTotal'
    ) -Name 'watch-cpu-only-does-not-refresh-activity'

    # Registry strategies
    $reg = Get-MmoRegistry
    $strategyNames = @('single', 'parallel', 'debate', 'dual-implementation', 'pipeline')
    $allPresent = $true
    foreach ($s in $strategyNames) {
        if ($null -eq $reg.strategies.$s) { $allPresent = $false }
    }
    Assert-True -Condition $allPresent -Name 'registry-has-all-strategies'

    $skillMd = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
    $lineCount = (Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md')).Count
    Assert-True -Condition ($lineCount -lt 150 -and $skillMd -match 'multi-model-orchestrator') -Name 'skill-md-under-150-lines' -Detail "lines=$lineCount"
    Assert-True -Condition ($skillMd -match 'Start-ConcurrentWorkers' -and $skillMd -match 'AggregateWorkers') -Name 'skill-md-documents-concurrent-and-aggregate'
    Assert-True -Condition ($skillMd -match 'Invoke-FallbackChain' -or $skillMd -match 'FALLBACKS') -Name 'skill-md-documents-fallback'

    $grokSkill = Join-Path (Split-Path $skillRoot -Parent) 'grok-orchestrator\SKILL.md'
    $grokRoot = Split-Path $grokSkill -Parent
    Assert-True -Condition (Test-Path -LiteralPath $grokSkill) -Name 'grok-orchestrator-still-present'
    # Do not require a fixed file count (install layouts differ); ensure this skill did not write into it.
    $mmoMarkerInGrok = Test-Path -LiteralPath (Join-Path $grokRoot 'Invoke-FallbackChain.ps1')
    Assert-True -Condition (-not $mmoMarkerInGrok) -Name 'grok-orchestrator-not-modified-by-mmo' -Detail $grokRoot

    Assert-True -Condition (
        (Test-Path -LiteralPath $watchScript) -and
        $watchText -match 'AggregateWorkers' -and
        $watchText -match 'WORKER_PIDS'
    ) -Name 'watch-supports-aggregate-workers'

    Assert-True -Condition (Test-Path -LiteralPath $concScript) -Name 'script-start-concurrent-workers-exists'
}
finally {
    $env:MMO_FAKE_GROK_MODE = $null
    $env:MMO_FAKE_AGY_MODE = $null
    $env:MMO_FAKE_SLEEP_MS = $null
    $env:MMO_FAKE_ARGV_PATH = $null
    $env:MMO_FAKE_CHILD_PID_PATH = $null
    $env:MMO_FAKE_AGY_QUOTA_MODELS = $null
    $env:MMO_FAKE_AGY_UNAVAILABLE_MODELS = $null
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $pass  Failed: $fail"
$summaryPath = Join-Path $PSScriptRoot 'last-offline-results.json'
$summary = [pscustomobject]@{
    passed = $pass
    failed = $fail
    results = @($results.ToArray())
    finished_at = [datetime]::UtcNow.ToString('o')
}
($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

if ($fail -gt 0) { exit 1 }
exit 0
