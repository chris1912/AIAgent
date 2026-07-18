# Deterministic offline tests for grok-orchestrator.
# Authored 2026-07-18.
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
    $snippet = ''
    if ($r.Raw) {
        $t = $r.Raw.Trim()
        $snippet = $t.Substring(0, [Math]::Min(240, $t.Length))
    }
    Assert-True -Condition $ok -Name $Name -Detail ("exit=$($r.ExitCode) raw=$snippet")
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

$benignPath = Join-Path ([System.IO.Path]::GetTempPath()) ('go-benign-' + [guid]::NewGuid().ToString() + '.txt')
@(
    '# Grok Orchestrator Audit',
    'Handlers return 401 for unauthenticated callers and 403 forbidden for ACL misses.',
    'Document authentication flows and timeout/dns health checks without failing.',
    'The endpoint remains healthy; timeout values and dns resolvers were verified.'
) -join [Environment]::NewLine | Set-Content -LiteralPath $benignPath -Encoding UTF8
$cNeg1 = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '0', '-RawLogPath', $benignPath)).Object
Remove-Item -LiteralPath $benignPath -Force -ErrorAction SilentlyContinue
Assert-True -Condition ($cNeg1.classification -eq 'success') -Name 'classify-benign-401-auth-timeout-dns-success' -Detail $cNeg1.classification

$cPosNet = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '1', '-RawText', 'Error: timeout waiting for response')).Object
Assert-True -Condition ($cPosNet.classification -eq 'network_failure' -and $cPosNet.fallback_eligible -eq $false) -Name 'classify-real-timeout-waiting-network'

$cPosAuth = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '3', '-RawText', 'Error: authentication required')).Object
Assert-True -Condition ($cPosAuth.classification -eq 'auth_failure' -and $cPosAuth.fallback_eligible -eq $false) -Name 'classify-auth-required-no-fallback'

$cPerm = (Invoke-JsonScript -File $clsScript -ArgumentList @('-ExitCode', '1', '-StderrText', 'error: permission denied writing file')).Object
Assert-True -Condition ($cPerm.classification -eq 'permission_failure' -and $cPerm.fallback_eligible -eq $false) -Name 'classify-permission-no-fallback'

# Exit 0 + optional MCP WARN "Auth required" (observed Grok/Tavily shape) must stay success.
$esc = [char]27
$mcpWarnShape = @(
    ("{0}[2m2026-07-17T17:53:28.336244Z{0}[0m {0}[33m WARN{0}[0m OAuth discovery timed out {0}[3mserver{0}[0m{0}[2m={0}[0mtavily" -f $esc),
    ("{0}[2m2026-07-17T17:53:28.347138Z{0}[0m {0}[33m WARN{0}[0m Failed to spawn MCP server: MCP server 'tavily': Auth required (non-interactive session; authenticate in TUI or set Authorization header)" -f $esc),
    ("{0}[2m2026-07-17T17:53:28.347303Z{0}[0m {0}[33m WARN{0}[0m MCP server spawn failed, removing from initializing set {0}[3mserver{0}[0m{0}[2m={0}[0m`"tavily`"" -f $esc)
) -join [Environment]::NewLine
$cMcpWarn = (Invoke-JsonScript -File $clsScript -ArgumentList @(
    '-ExitCode', '0',
    '-RawText', 'Task completed; discovery gate fixed; offline suite passed.',
    '-StderrText', $mcpWarnShape
)).Object
Assert-True -Condition ($cMcpWarn.classification -eq 'success' -and $cMcpWarn.fallback_eligible -eq $false) `
    -Name 'classify-exit0-mcp-warn-auth-required-success' -Detail $cMcpWarn.classification

# Non-zero explicit auth still fails even if WARN noise is present.
$cAuthNz = (Invoke-JsonScript -File $clsScript -ArgumentList @(
    '-ExitCode', '3',
    '-RawText', 'provider rejected credentials',
    '-StderrText', ("WARN MCP server 'tavily': Auth required`nError: authentication required")
)).Object
Assert-True -Condition ($cAuthNz.classification -eq 'auth_failure' -and $cAuthNz.fallback_eligible -eq $false) `
    -Name 'classify-nonzero-auth-despite-warn-noise' -Detail $cAuthNz.classification

# --- Argument escaping (CommandLineToArgvW round-trip) ---
$nativeArgv = @'
using System;
using System.Runtime.InteropServices;
public static class GoNativeArgv {
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
try { [void][GoNativeArgv] } catch { Add-Type -TypeDefinition $nativeArgv -ErrorAction Stop }

function Test-GoArgvRoundTrip {
    param([string[]]$ArgsIn, [string]$Name)
    $joined = Join-GoProcessArguments -ArgumentList $ArgsIn
    $parsed = [GoNativeArgv]::Split('exe ' + $joined)
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

Test-GoArgvRoundTrip -ArgsIn @('--single', 'hello world') -Name 'escape-spaces-one-prompt-arg'
Test-GoArgvRoundTrip -ArgsIn @('--single', 'say "quoted" text') -Name 'escape-embedded-quotes'
Test-GoArgvRoundTrip -ArgsIn @('--single', 'path\ends\with\') -Name 'escape-trailing-backslashes'
Test-GoArgvRoundTrip -ArgsIn @('--single', 'mix \" quote\path\') -Name 'escape-quote-and-backslash-mix'
Test-GoArgvRoundTrip -ArgsIn @('--single', 'value with $() and `backticks` and %PATH%') -Name 'escape-dollar-backtick-percent'
Test-GoArgvRoundTrip -ArgsIn @('--model', 'grok-4.5', '--single', 'a b', 'x') -Name 'escape-multi-arg-exact-order'
# Model-name injection: metacharacters must remain a single argv element after escaping.
Test-GoArgvRoundTrip -ArgsIn @('--model', 'evil; rm -rf /', '--single', 'ok') -Name 'escape-model-injection-metacharacters'
Test-GoArgvRoundTrip -ArgsIn @('--model', 'name with spaces & | >', '--prompt-file', 'C:\path with space\brief.md') -Name 'escape-model-and-path-spaces'

# --- Reasoning helpers ---
$map = Get-GoAllowedReasoningLabels -OrderedDescending @('high', 'medium', 'low')
Assert-True -Condition ($map.highest -eq 'high' -and $map.second_highest -eq 'medium' -and $map.labels.Count -eq 2) -Name 'reasoning-only-top-two'

Assert-True -Condition (Test-GoForbiddenReasoningLabel -Label 'LOW') -Name 'forbidden-effort-LOW'
Assert-True -Condition (Test-GoForbiddenReasoningLabel -Label 'minimal') -Name 'forbidden-effort-minimal'
Assert-True -Condition (Test-GoForbiddenReasoningLabel -Label 'lowest') -Name 'forbidden-effort-lowest'
Assert-True -Condition (-not (Test-GoForbiddenReasoningLabel -Label 'high')) -Name 'allow-effort-high'
Assert-True -Condition (Test-GoModelHasLowTier -ModelName 'grok-low') -Name 'low-model-detect-token'
Assert-True -Condition (-not (Test-GoModelHasLowTier -ModelName 'grok-4.5')) -Name 'low-model-allow-grok45'

$policyOk = $true
try {
    Assert-GoInvocationPolicy -Model 'grok-4.5' -ReasoningEffort 'high' -ReasoningTier 'highest' -ExtraArgs @()
}
catch { $policyOk = $false }
Assert-True -Condition $policyOk -Name 'policy-allows-highest-high'

$policyLow = $false
try {
    Assert-GoInvocationPolicy -Model 'grok-4.5' -ReasoningEffort 'low' -ReasoningTier 'highest' -ExtraArgs @()
}
catch { $policyLow = $true }
Assert-True -Condition $policyLow -Name 'policy-rejects-effort-low'

$policySmuggle = $false
try {
    Assert-GoInvocationPolicy -Model 'grok-4.5' -ReasoningEffort 'high' -ReasoningTier 'highest' -ExtraArgs @('--reasoning-effort', 'minimal')
}
catch { $policySmuggle = $true }
Assert-True -Condition $policySmuggle -Name 'policy-rejects-extraargs-minimal'

$policyBare = $false
try {
    Assert-GoInvocationPolicy -Model 'grok-4.5' -ReasoningEffort 'high' -ReasoningTier 'highest' -ExtraArgs @('lowest')
}
catch { $policyBare = $true }
Assert-True -Condition $policyBare -Name 'policy-rejects-bare-lowest-token'

# --- Invoke boundary: low rejection before provider contact ---
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('go-tests-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $fakeGrok = Join-Path $fixtures 'fake-grok.ps1'
    $invokeScript = Join-Path $scripts 'Invoke-Grok.ps1'
    $discoverScript = Join-Path $scripts 'Discover-Grok.ps1'
    $fallbackScript = Join-Path $scripts 'Invoke-GrokFallback.ps1'
    $watchScript = Join-Path $scripts 'watch_grok_run.ps1'
    $fakeExe = "powershell.exe -NoProfile -File `"$fakeGrok`""

    # Discovery via fake executable
    $discoOut = Join-Path $tmp 'discovery.json'
    $env:GO_FAKE_INCLUDE_COMPOSER = '0'
    $d1 = Invoke-JsonScript -File $discoverScript -ArgumentList @(
        '-Executable', 'powershell.exe',
        '-OutJson', $discoOut
    ) -AllowFailure
    # Discover-Grok expects real executable that accepts models/version; invoke via powershell -File needs special handling.
    # Use direct Start-Process style: pass fake as executable through a wrapper batch isn't needed —
    # call Discover with SkipInvoke and inject models, plus a real capture via fake for version/models.
    # Re-run discovery by setting executable to powershell and using a small wrapper isn't available.
    # Instead write discovery manually for most tests, and test Discover-Grok parse path with a child powershell file as exe via -Executable powershell and we need args models - Discover uses models as only args.
    # Fix: use powershell.exe as FilePath won't work for "models" alone. Use SkipInvoke + synthetic, and a dedicated discovery parse test.

    # Direct discovery test: run fake-grok models via capture pattern using Discover with a .ps1 executable
    # Invoke-Grok supports .ps1 executable; Discover uses Start-Process -FilePath $exe -ArgumentList models
    # So for .ps1 we need to pass executable as powershell.exe... Discover doesn't wrap .ps1.
    # Work around: create a cmd wrapper.
    $wrapper = Join-Path $tmp 'fake-grok.cmd'
    @"
@echo off
powershell.exe -NoProfile -NonInteractive -File "$fakeGrok" %*
"@ | Set-Content -LiteralPath $wrapper -Encoding ASCII

    $dReal = Invoke-JsonScript -File $discoverScript -ArgumentList @(
        '-Executable', $wrapper,
        '-OutJson', $discoOut
    )
    Assert-True -Condition (
        $dReal.Object.available -eq $true -and
        @($dReal.Object.eligible_models) -contains 'grok-4.5' -and
        $dReal.Object.reasoning_map.highest -eq 'high' -and
        $dReal.Object.reasoning_map.second_highest -eq 'medium'
    ) -Name 'discover-fake-lists-grok45' -Detail ($dReal.Object | ConvertTo-Json -Compress -Depth 6)

    Assert-True -Condition ($dReal.Object.composer_available -eq $false) -Name 'discover-composer-absent-not-invented'

    $env:GO_FAKE_INCLUDE_COMPOSER = '1'
    $discoOut2 = Join-Path $tmp 'discovery-composer.json'
    $dComp = Invoke-JsonScript -File $discoverScript -ArgumentList @(
        '-Executable', $wrapper,
        '-OutJson', $discoOut2
    )
    Assert-True -Condition ($dComp.Object.composer_available -eq $true) -Name 'discover-composer-when-listed'
    $env:GO_FAKE_INCLUDE_COMPOSER = '0'

    # Low-tier rejection at invoke boundary (DryBuild and real)
    $runLow = Join-Path $tmp 'run-low'
    New-Item -ItemType Directory -Path $runLow -Force | Out-Null
    $rLow = Invoke-ExpectFail -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningEffort', 'low',
        '-ReasoningTier', 'highest',
        '-Prompt', 'x',
        '-RunDirectory', $runLow,
        '-DiscoveryJsonPath', $discoOut,
        '-DryBuildOnly'
    ) -Name 'invoke-rejects-reasoning-effort-low' -MustMatch 'forbidden|policy|low'

    $runMin = Join-Path $tmp 'run-minimal'
    New-Item -ItemType Directory -Path $runMin -Force | Out-Null
    $extraMinPath = Join-Path $runMin 'extra-minimal.json'
    Write-GoUtf8Text -LiteralPath $extraMinPath -Text ('["--reasoning-effort","minimal"]' + [Environment]::NewLine)
    Invoke-ExpectFail -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'x',
        '-RunDirectory', $runMin,
        '-DiscoveryJsonPath', $discoOut,
        '-ExtraArgsJsonPath', $extraMinPath,
        '-DryBuildOnly'
    ) -Name 'invoke-rejects-extraargs-minimal' -MustMatch 'forbidden|policy|minimal'

    # Dry build maps tiers and sets always-approve
    $runDry = Join-Path $tmp 'run-dry'
    New-Item -ItemType Directory -Path $runDry -Force | Out-Null
    $dry = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'hello world',
        '-RunDirectory', $runDry,
        '-WorkerId', 'dry1',
        '-DiscoveryJsonPath', $discoOut,
        '-DryBuildOnly'
    )).Object
    Assert-True -Condition (
        $dry.dry_run -eq $true -and
        $dry.reasoning_effort -eq 'high' -and
        $dry.always_approve -eq $true -and
        ($dry.args -contains '--always-approve') -and
        ($dry.args -contains 'high')
    ) -Name 'invoke-dry-maps-highest-to-high' -Detail ($dry | ConvertTo-Json -Compress)

    $runDry2 = Join-Path $tmp 'run-dry2'
    New-Item -ItemType Directory -Path $runDry2 -Force | Out-Null
    $dry2 = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'second_highest',
        '-Prompt', 'hello',
        '-RunDirectory', $runDry2,
        '-WorkerId', 'dry2',
        '-DiscoveryJsonPath', $discoOut,
        '-DryBuildOnly'
    )).Object
    Assert-True -Condition ($dry2.reasoning_effort -eq 'medium') -Name 'invoke-dry-maps-second-highest-to-medium'

    # Successful fake invoke with prompt-file
    $runOk = Join-Path $tmp 'run-ok'
    New-Item -ItemType Directory -Path $runOk -Force | Out-Null
    $promptFile = Join-Path $runOk 'prompt.md'
    Set-Content -LiteralPath $promptFile -Value 'do a tiny offline task' -Encoding UTF8
    $argvCap = Join-Path $tmp 'argv-ok.json'
    $env:GO_FAKE_ARGV_PATH = $argvCap
    $okRes = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-PromptFile', $promptFile,
        '-RunDirectory', $runOk,
        '-WorkerId', 'w1',
        '-TimeoutSeconds', '30',
        '-Cwd', $skillRoot,
        '-DiscoveryJsonPath', $discoOut
    )).Object
    Remove-Item Env:GO_FAKE_ARGV_PATH -ErrorAction SilentlyContinue
    Assert-True -Condition (
        $okRes.classification -eq 'success' -and
        $okRes.exit_code -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $runOk 'workers\w1\stdout.log')) -and
        (Test-Path -LiteralPath (Join-Path $runOk 'workers\w1\result.json')) -and
        (Test-Path -LiteralPath (Join-Path $runOk 'workers\w1\request.json'))
    ) -Name 'invoke-success-writes-artifacts' -Detail ($okRes.classification)

    if (Test-Path -LiteralPath $argvCap) {
        $captured = Get-Content -LiteralPath $argvCap -Raw -Encoding UTF8 | ConvertFrom-Json
        $argvList = @($captured.argv)
        $modelIdx = [array]::IndexOf($argvList, '--model')
        $modelVal = if ($modelIdx -ge 0 -and ($modelIdx + 1) -lt $argvList.Count) { $argvList[$modelIdx + 1] } else { '' }
        Assert-True -Condition ($modelVal -eq 'grok-4.5') -Name 'invoke-argv-model-single-token' -Detail ($argvList -join ' | ')
        Assert-True -Condition ($argvList -contains '--prompt-file') -Name 'invoke-uses-prompt-file'
        Assert-True -Condition ($argvList -contains '--always-approve') -Name 'invoke-default-always-approve'
    }
    else {
        Assert-True -Condition $false -Name 'invoke-argv-model-single-token' -Detail 'argv capture missing'
        Assert-True -Condition $false -Name 'invoke-uses-prompt-file' -Detail 'argv capture missing'
        Assert-True -Condition $false -Name 'invoke-default-always-approve' -Detail 'argv capture missing'
    }

    # Default structured path refuses missing discovery (no -DiscoveryJsonPath)
    $runMissingDisco = Join-Path $tmp 'run-missing-disco'
    New-Item -ItemType Directory -Path $runMissingDisco -Force | Out-Null
    Invoke-ExpectFail -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'x',
        '-RunDirectory', $runMissingDisco,
        '-DryBuildOnly'
    ) -Name 'invoke-missing-discovery-refuses' -MustMatch 'DiscoveryJsonPath|discovery snapshot|Discover-Grok'

    # Unavailable/empty discovery blocks before provider contact
    $badDisco = Join-Path $tmp 'discovery-bad.json'
    Write-GoJson -LiteralPath $badDisco -InputObject ([ordered]@{
        available = $false
        eligible_models = @()
        error = 'executable not found'
    })
    $runBlock = Join-Path $tmp 'run-block-disco'
    New-Item -ItemType Directory -Path $runBlock -Force | Out-Null
    Invoke-ExpectFail -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'x',
        '-RunDirectory', $runBlock,
        '-DiscoveryJsonPath', $badDisco,
        '-DryBuildOnly'
    ) -Name 'invoke-require-discovery-blocks' -MustMatch 'unavailable|eligible|Discovery'

    # Omitted -Model resolves from valid discovery eligible list (registry highest hint / first eligible)
    $runOmitModel = Join-Path $tmp 'run-omit-model'
    New-Item -ItemType Directory -Path $runOmitModel -Force | Out-Null
    $omitDisco = Join-Path $runOmitModel 'discovery.json'
    Write-GoJson -LiteralPath $omitDisco -InputObject ([ordered]@{
        available = $true
        executable = $wrapper
        eligible_models = @('grok-4.5')
        models = @('grok-4.5')
        reasoning_map = [ordered]@{ highest = 'high'; second_highest = 'medium'; labels = @('high', 'medium') }
    })
    $omitRes = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-ReasoningTier', 'highest',
        '-Prompt', 'resolve model from discovery',
        '-RunDirectory', $runOmitModel,
        '-WorkerId', 'omit1',
        '-DiscoveryJsonPath', $omitDisco,
        '-DryBuildOnly'
    )).Object
    Assert-True -Condition (
        $omitRes.dry_run -eq $true -and
        $omitRes.model -eq 'grok-4.5' -and
        ($omitRes.args -contains 'grok-4.5') -and
        ($omitRes.args -contains '--model')
    ) -Name 'invoke-omitted-model-from-discovery' -Detail ($omitRes | ConvertTo-Json -Compress)

    # Timeout kills process tree including child
    $runHang = Join-Path $tmp 'run-hang'
    New-Item -ItemType Directory -Path $runHang -Force | Out-Null
    $childPidPath = Join-Path $runHang 'child.pid'
    $env:GO_FAKE_GROK_MODE = 'hang_with_child'
    $env:GO_FAKE_CHILD_PID_PATH = $childPidPath
    $hangRes = (Invoke-JsonScript -File $invokeScript -ArgumentList @(
        '-Executable', $wrapper,
        '-Model', 'grok-4.5',
        '-ReasoningTier', 'highest',
        '-Prompt', 'hang',
        '-RunDirectory', $runHang,
        '-WorkerId', 'hang1',
        '-TimeoutSeconds', '3',
        '-Cwd', $skillRoot,
        '-DiscoveryJsonPath', $discoOut
    ) -AllowFailure).Object
    Remove-Item Env:GO_FAKE_GROK_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:GO_FAKE_CHILD_PID_PATH -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $childAlive = $false
    if (Test-Path -LiteralPath $childPidPath) {
        $childId = [int](Get-Content -LiteralPath $childPidPath -Raw).Trim()
        $childAlive = $null -ne (Get-Process -Id $childId -ErrorAction SilentlyContinue)
    }
    $rootPidPath = Join-Path $runHang 'workers\hang1\WORKER_PID.txt'
    $rootAlive = $false
    if (Test-Path -LiteralPath $rootPidPath) {
        $rootId = [int](Get-Content -LiteralPath $rootPidPath -Raw).Trim()
        $rootAlive = $null -ne (Get-Process -Id $rootId -ErrorAction SilentlyContinue)
    }
    Assert-True -Condition (
        $hangRes.classification -eq 'timeout' -and
        $hangRes.timed_out -eq $true -and
        $hangRes.fallback_eligible -eq $false -and
        -not $childAlive -and
        -not $rootAlive
    ) -Name 'timeout-kills-process-tree' -Detail ("childAlive=$childAlive rootAlive=$rootAlive class=$($hangRes.classification)")

    # Fallback: quota advances to next hop when chain has two hops
    $runFb = Join-Path $tmp 'run-fb-quota'
    New-Item -ItemType Directory -Path $runFb -Force | Out-Null
    $routePath = Join-Path $runFb 'route.json'
    # Two hops same fake; first always quota via mode, second needs success — use quota_once
    $env:GO_FAKE_GROK_MODE = 'quota_once'
    $marker = Join-Path $runFb 'quota-once.marker'
    $env:GO_FAKE_QUOTA_ONCE_MARKER = $marker
    Write-GoJson -LiteralPath $routePath -InputObject @(
        [pscustomobject]@{ model = 'grok-4.5'; reasoning_tier = 'highest'; executable = $wrapper },
        [pscustomobject]@{ model = 'grok-4.5'; reasoning_tier = 'second_highest'; executable = $wrapper }
    )
    $fb = (Invoke-JsonScript -File $fallbackScript -ArgumentList @(
        '-RunDirectory', $runFb,
        '-RouteJson', $routePath,
        '-DiscoveryJsonPath', $discoOut,
        '-Prompt', 'fallback test',
        '-TimeoutSeconds', '30'
    )).Object
    Remove-Item Env:GO_FAKE_GROK_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:GO_FAKE_QUOTA_ONCE_MARKER -ErrorAction SilentlyContinue
    Assert-True -Condition (
        $fb.stopped_reason -eq 'success' -and
        $fb.attempt_count -ge 2 -and
        (Test-Path -LiteralPath (Join-Path $runFb 'FALLBACKS.jsonl'))
    ) -Name 'fallback-quota-advances' -Detail ($fb | ConvertTo-Json -Compress -Depth 6)

    $fbLines = Get-Content -LiteralPath (Join-Path $runFb 'FALLBACKS.jsonl') -Encoding UTF8
    Assert-True -Condition ($fbLines.Count -ge 2) -Name 'fallback-jsonl-records-hops' -Detail ("lines=$($fbLines.Count)")

    # Auth failure does NOT auto-advance
    $runAuth = Join-Path $tmp 'run-fb-auth'
    New-Item -ItemType Directory -Path $runAuth -Force | Out-Null
    $routeAuth = Join-Path $runAuth 'route.json'
    Write-GoJson -LiteralPath $routeAuth -InputObject @(
        [pscustomobject]@{ model = 'grok-4.5'; reasoning_tier = 'highest'; executable = $wrapper },
        [pscustomobject]@{ model = 'grok-4.5'; reasoning_tier = 'second_highest'; executable = $wrapper }
    )
    $env:GO_FAKE_GROK_MODE = 'auth'
    $fbAuth = (Invoke-JsonScript -File $fallbackScript -ArgumentList @(
        '-RunDirectory', $runAuth,
        '-RouteJson', $routeAuth,
        '-DiscoveryJsonPath', $discoOut,
        '-Prompt', 'auth fail',
        '-TimeoutSeconds', '30'
    )).Object
    Remove-Item Env:GO_FAKE_GROK_MODE -ErrorAction SilentlyContinue
    Assert-True -Condition (
        $fbAuth.stopped_reason -eq 'non_fallback_failure' -and
        $fbAuth.attempt_count -eq 1 -and
        (Test-Path -LiteralPath (Join-Path $runAuth 'FAILED.flag'))
    ) -Name 'fallback-auth-stops-no-advance' -Detail ($fbAuth.stopped_reason)

    # Task failure does not advance
    $runTask = Join-Path $tmp 'run-fb-task'
    New-Item -ItemType Directory -Path $runTask -Force | Out-Null
    $routeTask = Join-Path $runTask 'route.json'
    Write-GoJson -LiteralPath $routeTask -InputObject @(
        [pscustomobject]@{ model = 'grok-4.5'; reasoning_tier = 'highest'; executable = $wrapper },
        [pscustomobject]@{ model = 'grok-4.5'; reasoning_tier = 'second_highest'; executable = $wrapper }
    )
    $env:GO_FAKE_GROK_MODE = 'task_fail'
    $fbTask = (Invoke-JsonScript -File $fallbackScript -ArgumentList @(
        '-RunDirectory', $runTask,
        '-RouteJson', $routeTask,
        '-DiscoveryJsonPath', $discoOut,
        '-Prompt', 'task fail',
        '-TimeoutSeconds', '30'
    )).Object
    Remove-Item Env:GO_FAKE_GROK_MODE -ErrorAction SilentlyContinue
    Assert-True -Condition (
        $fbTask.stopped_reason -eq 'non_fallback_failure' -and
        $fbTask.attempt_count -eq 1
    ) -Name 'fallback-task-failure-stops' -Detail ($fbTask.stopped_reason)

    # Discovery failure on fallback with empty discovery -> BLOCKED, zero workers
    $runNoDisco = Join-Path $tmp 'run-no-disco'
    New-Item -ItemType Directory -Path $runNoDisco -Force | Out-Null
    $emptyDisco = Join-Path $runNoDisco 'discovery.json'
    Write-GoJson -LiteralPath $emptyDisco -InputObject ([ordered]@{
        available = $false
        eligible_models = @()
        error = 'executable not found'
    })
    $fbEmpty = (Invoke-JsonScript -File $fallbackScript -ArgumentList @(
        '-RunDirectory', $runNoDisco,
        '-DiscoveryJsonPath', $emptyDisco,
        '-Prompt', 'should block',
        '-TimeoutSeconds', '10'
    )).Object
    $workerDirs = @(Get-ChildItem -LiteralPath (Join-Path $runNoDisco 'workers') -Directory -ErrorAction SilentlyContinue)
    Assert-True -Condition (
        $fbEmpty.stopped_reason -eq 'discovery_unavailable' -and
        (Test-Path -LiteralPath (Join-Path $runNoDisco 'BLOCKED.flag')) -and
        $workerDirs.Count -eq 0
    ) -Name 'fallback-discovery-failure-blocks' -Detail ($fbEmpty.stopped_reason)

    # Default-route fallback refuses missing discovery path (no -DiscoveryJsonPath)
    $runFbMissingDisco = Join-Path $tmp 'run-fb-missing-disco'
    New-Item -ItemType Directory -Path $runFbMissingDisco -Force | Out-Null
    $fbMissing = (Invoke-JsonScript -File $fallbackScript -ArgumentList @(
        '-RunDirectory', $runFbMissingDisco,
        '-Prompt', 'should block missing discovery',
        '-TimeoutSeconds', '10',
        '-DryBuildOnly'
    )).Object
    $fbMissingWorkers = @(Get-ChildItem -LiteralPath (Join-Path $runFbMissingDisco 'workers') -Directory -ErrorAction SilentlyContinue)
    Assert-True -Condition (
        $fbMissing.stopped_reason -eq 'discovery_unavailable' -and
        (Test-Path -LiteralPath (Join-Path $runFbMissingDisco 'BLOCKED.flag')) -and
        $fbMissingWorkers.Count -eq 0
    ) -Name 'fallback-missing-discovery-refuses' -Detail ($fbMissing.stopped_reason)

    # Optional composer not invented when absent from discovery
    $runNoComp = Join-Path $tmp 'run-no-composer'
    New-Item -ItemType Directory -Path $runNoComp -Force | Out-Null
    $discoOnly45 = Join-Path $runNoComp 'discovery.json'
    Write-GoJson -LiteralPath $discoOnly45 -InputObject ([ordered]@{
        available = $true
        executable = $wrapper
        eligible_models = @('grok-4.5')
        models = @('grok-4.5')
        reasoning_map = [ordered]@{ highest = 'high'; second_highest = 'medium'; labels = @('high', 'medium') }
    })
    $fbNoComp = (Invoke-JsonScript -File $fallbackScript -ArgumentList @(
        '-RunDirectory', $runNoComp,
        '-DiscoveryJsonPath', $discoOnly45,
        '-Prompt', 'default chain',
        '-TimeoutSeconds', '30',
        '-DryBuildOnly'
    )).Object
    Assert-True -Condition (
        $fbNoComp.attempt_count -eq 1 -and
        $fbNoComp.attempts[0].model -eq 'grok-4.5'
    ) -Name 'fallback-default-skips-missing-composer' -Detail ($fbNoComp | ConvertTo-Json -Compress -Depth 6)

    # Sentinel ordering: Write-GoSentinel requires STATUS first
    $runSent = Join-Path $tmp 'run-sentinel'
    New-Item -ItemType Directory -Path $runSent -Force | Out-Null
    $sentFail = $false
    try {
        Write-GoSentinel -RunDirectory $runSent -Kind 'READY_FOR_REVIEW' -Detail 'too early'
    }
    catch { $sentFail = $true }
    Assert-True -Condition ($sentFail -and -not (Test-Path -LiteralPath (Join-Path $runSent 'READY_FOR_REVIEW.flag'))) -Name 'sentinel-requires-status-first'

    Write-GoStageArtifacts -RunDirectory $runSent -Status ([ordered]@{
        run_id = 'run-sentinel'
        stage = 'test'
        state = 'ready_for_review'
        summary = 'ok'
        updated_at = [datetime]::UtcNow.ToString('o')
    }) -StageReport "# Stage`n`nok`n"
    $flagPath = Write-GoSentinel -RunDirectory $runSent -Kind 'READY_FOR_REVIEW' -Detail 'after reports'
    Assert-True -Condition (
        (Test-Path -LiteralPath $flagPath) -and
        (Test-Path -LiteralPath (Join-Path $runSent 'STATUS.json')) -and
        (Test-Path -LiteralPath (Join-Path $runSent 'STAGE_REPORT.md'))
    ) -Name 'sentinel-after-status-and-report'

    $dupFail = $false
    try {
        Write-GoSentinel -RunDirectory $runSent -Kind 'DONE' -Detail 'dup'
    }
    catch { $dupFail = $true }
    Assert-True -Condition ($dupFail -and -not (Test-Path -LiteralPath (Join-Path $runSent 'DONE.flag'))) -Name 'sentinel-exactly-one'

    # Watchdog: DONE.flag terminates with done
    $runWatch = Join-Path $tmp 'run-watch'
    New-Item -ItemType Directory -Path $runWatch -Force | Out-Null
    $sleeper = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60'
    ) -PassThru -WindowStyle Hidden
    try {
        Write-GoUtf8Text -LiteralPath (Join-Path $runWatch 'GROK_PID.txt') -Text ([string]$sleeper.Id)
        $watchJob = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $watchScript,
            '-RunDirectory', $runWatch,
            '-PollSeconds', '5',
            '-StallMinutes', '30',
            '-HardTimeoutMinutes', '30'
        ) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runWatch 'watch-out.txt') -RedirectStandardError (Join-Path $runWatch 'watch-err.txt')
        Start-Sleep -Milliseconds 800
        Write-GoUtf8Text -LiteralPath (Join-Path $runWatch 'DONE.flag') -Text "done`n"
        $null = $watchJob.WaitForExit(20000)
        try { $watchJob.Refresh() } catch { }
        $watchCode = $watchJob.ExitCode
        $wdStatus = $null
        if (Test-Path -LiteralPath (Join-Path $runWatch 'WATCHDOG_STATUS.json')) {
            $wdStatus = Get-Content -LiteralPath (Join-Path $runWatch 'WATCHDOG_STATUS.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        # Start-Process ExitCode can be null even after clean exit; durable status is the contract.
        $doneOk = ($wdStatus -and $wdStatus.state -eq 'done' -and $watchJob.HasExited -and ($null -eq $watchCode -or $watchCode -eq 0))
        Assert-True -Condition $doneOk -Name 'watchdog-done-flag' -Detail ("code=$watchCode state=$($wdStatus.state) hasExited=$($watchJob.HasExited)")
    }
    finally {
        if (-not $sleeper.HasExited) { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue }
        if ($watchJob -and -not $watchJob.HasExited) { Stop-Process -Id $watchJob.Id -Force -ErrorAction SilentlyContinue }
    }

    # Watchdog stall on no artifact progress (short windows)
    $runStall = Join-Path $tmp 'run-stall'
    New-Item -ItemType Directory -Path $runStall -Force | Out-Null
    $sleeper2 = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120'
    ) -PassThru -WindowStyle Hidden
    try {
        Write-GoUtf8Text -LiteralPath (Join-Path $runStall 'GROK_PID.txt') -Text ([string]$sleeper2.Id)
        # Seed one artifact so snapshot stabilizes; then no further progress.
        Write-GoUtf8Text -LiteralPath (Join-Path $runStall 'seed.txt') -Text "seed`n"
        $watchStall = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $watchScript,
            '-RunDirectory', $runStall,
            '-PollSeconds', '5',
            '-StallMinutes', '1',
            '-HardTimeoutMinutes', '10'
        ) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runStall 'watch-out.txt') -RedirectStandardError (Join-Path $runStall 'watch-err.txt')
        $null = $watchStall.WaitForExit(90000)
        try { $watchStall.Refresh() } catch { }
        $stallCode = $watchStall.ExitCode
        $stallStatus = $null
        if (Test-Path -LiteralPath (Join-Path $runStall 'WATCHDOG_STATUS.json')) {
            $stallStatus = Get-Content -LiteralPath (Join-Path $runStall 'WATCHDOG_STATUS.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        $stallOk = ($stallStatus -and $stallStatus.state -eq 'stalled' -and $watchStall.HasExited -and ($null -eq $stallCode -or $stallCode -eq 4))
        Assert-True -Condition $stallOk -Name 'watchdog-artifact-stall' -Detail ("code=$stallCode state=$($stallStatus.state) detail=$($stallStatus.detail)")
    }
    finally {
        if (-not $sleeper2.HasExited) { Stop-Process -Id $sleeper2.Id -Force -ErrorAction SilentlyContinue }
        if ($watchStall -and -not $watchStall.HasExited) { Stop-Process -Id $watchStall.Id -Force -ErrorAction SilentlyContinue }
    }

    # PowerShell 5.1 parser check on all scripts
    $scriptFiles = @(Get-ChildItem -LiteralPath $scripts -Filter '*.ps1' -File)
    $scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $skillRoot 'tests') -Filter '*.ps1' -File -Recurse)
    $parseFail = @()
    foreach ($sf in $scriptFiles) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($sf.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $parseFail += ($sf.Name + ': ' + $errors[0].Message)
        }
    }
    Assert-True -Condition ($parseFail.Count -eq 0) -Name 'powershell-51-parser-all-scripts' -Detail (($parseFail -join '; '))

    # Docs mention natural language handoff and scripts without MMO imports
    $skillMd = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw -Encoding UTF8
    Assert-True -Condition ($skillMd -match 'Discover-Grok' -and $skillMd -match 'Invoke-Grok') -Name 'skill-md-references-scripts'
    Assert-True -Condition ($skillMd -notmatch 'multi-model-orchestrator\\scripts') -Name 'skill-md-no-mmo-script-import'
    Assert-True -Condition ($skillMd -match 'Natural language' -or $skillMd -match 'natural-language' -or $skillMd -match 'Natural Language') -Name 'skill-md-keeps-nl-handoff'

    $noMmoImport = $true
    foreach ($sf in $scriptFiles) {
        if ($sf.Name -eq 'Run-OfflineTests.ps1') { continue }
        $content = Get-Content -LiteralPath $sf.FullName -Raw -Encoding UTF8
        # Fail only on real path/import usage, not prose mentions of the other skill's name.
        if ($content -match '(?i)(Join-Path|\\\\|\.codex\\skills\\)[^\r\n]*multi-model-orchestrator\\(scripts|config)') {
            $noMmoImport = $false
        }
        if ($content -match '(?i)\. +.*multi-model-orchestrator') {
            $noMmoImport = $false
        }
    }
    Assert-True -Condition $noMmoImport -Name 'scripts-no-mmo-path-import'
}
finally {
    Remove-Item Env:GO_FAKE_GROK_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:GO_FAKE_ARGV_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:GO_FAKE_CHILD_PID_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:GO_FAKE_INCLUDE_COMPOSER -ErrorAction SilentlyContinue
    Remove-Item Env:GO_FAKE_QUOTA_ONCE_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:GO_FAKE_MODELS -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$summary = [pscustomobject]@{
    passed = $pass
    failed = $fail
    total = ($pass + $fail)
    results = $results
    finished_at = [datetime]::UtcNow.ToString('o')
}
$outPath = Join-Path $PSScriptRoot 'last-offline-results.json'
Write-GoJson -LiteralPath $outPath -InputObject $summary
Write-Host ""
Write-Host "Offline tests: $pass passed, $fail failed, $($pass + $fail) total"
if ($fail -gt 0) { exit 1 }
exit 0
