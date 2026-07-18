# Discover local grok executable, version, and models. Live discovery is authority.
# Authored 2026-07-18.
[CmdletBinding()]
param(
    [string]$RegistryPath = '',
    [string]$OutJson = '',
    [string]$Executable = '',
    [switch]$SkipInvoke,
    [switch]$RequireAvailable
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-GoCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )
    $stdout = Join-Path ([System.IO.Path]::GetTempPath()) ("go-disco-out-" + [guid]::NewGuid().ToString() + '.txt')
    $stderr = Join-Path ([System.IO.Path]::GetTempPath()) ("go-disco-err-" + [guid]::NewGuid().ToString() + '.txt')
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $outText = ''
        $errText = ''
        if (Test-Path -LiteralPath $stdout) { $outText = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderr) { $errText = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue }
        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            StdOut = $(if ($null -eq $outText) { '' } else { $outText })
            StdErr = $(if ($null -eq $errText) { '' } else { $errText })
        }
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Parse-GoModelLines {
    param([string]$Text)
    $models = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    foreach ($line in ($Text -split "(`r`n|`n|`r)")) {
        $t = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t -match '^(Available models|Default model|You are logged|Usage of|flags provided)') { continue }
        $t = $t -replace '^\*\s+', ''
        $t = $t -replace '\s+\(default\)\s*$', ''
        if ($t -match '^[A-Za-z0-9].{1,120}$') {
            if (-not $models.Contains($t)) { $models.Add($t) }
        }
    }
    return [string[]]$models.ToArray()
}

$registry = Get-GoRegistry -RegistryPath $RegistryPath
$cli = $registry.cli
$effortOrder = @($registry.reasoning_tier_policy.provider_effort_order_desc)
if ($effortOrder.Count -lt 1) { $effortOrder = @('high', 'medium', 'low') }

$results = [ordered]@{
    discovered_at = [datetime]::UtcNow.ToString('o')
    skill_root = Get-GoSkillRoot
    provider = 'grok'
    available = $false
    executable = $null
    version = $null
    models = @()
    eligible_models = @()
    forbidden_models = @()
    models_annotated = @()
    models_raw = ''
    reasoning_map = $null
    model_hints = $registry.model_hints
    error = $null
}

$exe = $Executable
if ([string]::IsNullOrWhiteSpace($exe)) {
    $exe = Resolve-GoExecutable -Names @($cli.cli_names) -CommonPaths @($cli.common_paths)
}

if ([string]::IsNullOrWhiteSpace($exe)) {
    $results.error = 'executable not found on PATH or common_paths'
    $results.searched_names = @($cli.cli_names)
    $results.searched_paths = @($cli.common_paths)
}
else {
    $results.available = $true
    $results.executable = $exe
    $results.reasoning_map = Get-GoAllowedReasoningLabels -OrderedDescending $effortOrder

    if (-not $SkipInvoke) {
        try {
            $verArgs = @($cli.version_command)
            $ver = Invoke-GoCapture -FilePath $exe -ArgumentList $verArgs
            $results.version = (($ver.StdOut + "`n" + $ver.StdErr).Trim() -split "(`r`n|`n)")[0]
        }
        catch {
            $results.error = "version probe failed: $($_.Exception.Message)"
        }

        try {
            $modelArgs = @($cli.discover_command)
            $mod = Invoke-GoCapture -FilePath $exe -ArgumentList $modelArgs
            $combined = ($mod.StdOut + "`n" + $mod.StdErr)
            $results.models_raw = $combined
            $parsed = @(Parse-GoModelLines -Text $combined)
            $split = Split-GoDiscoveredModels -Models $parsed
            $results.models = [string[]]$split.models
            $results.eligible_models = [string[]]$split.eligible_models
            $results.forbidden_models = [string[]]$split.forbidden_models
            $results.models_annotated = [object[]]$split.models_annotated
            if ($results.eligible_models.Count -lt 1 -and [string]::IsNullOrWhiteSpace($results.error)) {
                $results.error = 'no eligible models returned by grok models'
            }
        }
        catch {
            $msg = "models probe failed: $($_.Exception.Message)"
            if ([string]::IsNullOrWhiteSpace($results.error)) {
                $results.error = $msg
            }
            else {
                $results.error = $results.error + '; ' + $msg
            }
        }
    }
}

# Annotate optional composer availability without inventing it.
$composerHint = $null
if ($null -ne $registry.model_hints -and $null -ne $registry.model_hints.second_highest) {
    $composerHint = [string]$registry.model_hints.second_highest.model
}
$composerAvailable = $false
if (-not [string]::IsNullOrWhiteSpace($composerHint)) {
    foreach ($m in @($results.eligible_models)) {
        if ($m -eq $composerHint -or $m.ToLowerInvariant() -eq $composerHint.ToLowerInvariant()) {
            $composerAvailable = $true
            break
        }
    }
}
$results.composer_hint = $composerHint
$results.composer_available = $composerAvailable

$json = ConvertTo-GoJson -InputObject $results
if (-not [string]::IsNullOrWhiteSpace($OutJson)) {
    Write-GoUtf8Text -LiteralPath $OutJson -Text ($json + [Environment]::NewLine)
}
Write-Output $json

if ($RequireAvailable) {
    if (-not $results.available) {
        throw "Grok discovery failed: $($results.error)"
    }
    if (-not $SkipInvoke -and @($results.eligible_models).Count -lt 1) {
        throw "Grok discovery found no eligible models: $($results.error)"
    }
}
return
