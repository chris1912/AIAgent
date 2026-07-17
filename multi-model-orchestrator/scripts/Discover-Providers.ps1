# Discover local grok/agy executables, versions, and models.
# Authored 2026-07-17.
[CmdletBinding()]
param(
    [string]$RegistryPath = '',
    [string]$OutJson = '',
    [string[]]$Providers = @('grok', 'agy'),
    [switch]$SkipInvoke
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-MmoCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )
    $stdout = Join-Path ([System.IO.Path]::GetTempPath()) ("mmo-disco-out-" + [guid]::NewGuid().ToString() + '.txt')
    $stderr = Join-Path ([System.IO.Path]::GetTempPath()) ("mmo-disco-err-" + [guid]::NewGuid().ToString() + '.txt')
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

function Parse-MmoModelLines {
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
    return @($models)
}

# Split-MmoDiscoveredModels lives in Common.ps1 (PS 5.1-safe ToArray returns).

$registry = Get-MmoRegistry -RegistryPath $RegistryPath
$results = [ordered]@{
    discovered_at = [datetime]::UtcNow.ToString('o')
    skill_root = Get-MmoSkillRoot
    providers = [ordered]@{}
}

foreach ($name in $Providers) {
    $prov = $registry.providers.$name
    if ($null -eq $prov) {
        $results.providers[$name] = [ordered]@{ available = $false; error = "unknown provider key: $name" }
        continue
    }
    $exe = Resolve-MmoExecutable -Names @($prov.cli_names) -CommonPaths @($prov.common_paths)
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $results.providers[$name] = [ordered]@{
            available = $false
            error = 'executable not found on PATH or common_paths'
            searched_names = @($prov.cli_names)
            searched_paths = @($prov.common_paths)
        }
        continue
    }

    $forbiddenSubs = @()
    if ($null -ne $prov.forbidden_model_substrings) {
        $forbiddenSubs = @($prov.forbidden_model_substrings)
    }

    $entry = [ordered]@{
        available = $true
        executable = $exe
        version = $null
        models = @()
        eligible_models = @()
        forbidden_models = @()
        models_annotated = @()
        models_raw = ''
        reasoning_map = $null
        forbidden_model_substrings = $forbiddenSubs
        error = $null
    }

    if (-not $SkipInvoke) {
        try {
            $verArgs = @($prov.version_command)
            $ver = Invoke-MmoCapture -FilePath $exe -ArgumentList $verArgs
            $entry.version = (($ver.StdOut + "`n" + $ver.StdErr).Trim() -split "(`r`n|`n)")[0]
        }
        catch {
            $entry.error = "version probe failed: $($_.Exception.Message)"
        }

        try {
            $modelArgs = @($prov.discover_command)
            $mod = Invoke-MmoCapture -FilePath $exe -ArgumentList $modelArgs
            $combined = ($mod.StdOut + "`n" + $mod.StdErr)
            $entry.models_raw = $combined
            $parsed = @(Parse-MmoModelLines -Text $combined)
            $split = Split-MmoDiscoveredModels -Models $parsed -ForbiddenSubstrings $forbiddenSubs
            # Assign plain arrays only (no @() re-wrap of generic lists).
            $entry.models = [string[]]$split.models
            $entry.eligible_models = [string[]]$split.eligible_models
            $entry.forbidden_models = [string[]]$split.forbidden_models
            $entry.models_annotated = [object[]]$split.models_annotated
        }
        catch {
            $entry.error = "models probe failed: $($_.Exception.Message)"
        }
    }

    if ($name -eq 'grok') {
        $order = @($prov.reasoning_effort_order_desc)
        $entry.reasoning_map = Get-MmoAllowedReasoningLabels -OrderedDescending $order
    }
    elseif ($name -eq 'agy') {
        # Prefer High > Medium for flash; Thinking models map to highest only.
        $entry.reasoning_map = Get-MmoAllowedReasoningLabels -OrderedDescending @('High', 'Medium', 'Low')
    }

    $results.providers[$name] = $entry
}

$json = ConvertTo-MmoJson -InputObject $results
if (-not [string]::IsNullOrWhiteSpace($OutJson)) {
    Write-MmoUtf8Text -LiteralPath $OutJson -Text ($json + [Environment]::NewLine)
}
Write-Output $json
return
