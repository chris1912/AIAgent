# Create a dated multi-model run directory with skeleton artifacts.
# Authored 2026-07-17.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$Slug,
    [string]$Strategy = 'single',
    [string]$Stage = 'stage-1',
    [string]$OutJson = ''
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$day = Get-Date -Format 'yyyy-MM-dd'
$safeSlug = ($Slug -replace '[^A-Za-z0-9._-]', '-').ToLowerInvariant()
$runId = "$day-$safeSlug"
$runDir = Join-Path $root (Join-Path '.codex\mmo-runs' $runId)
New-Item -ItemType Directory -Path (Join-Path $runDir 'workers') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runDir 'worktrees') -Force | Out-Null

$briefPath = Join-Path $runDir 'BRIEF.md'
if (-not (Test-Path -LiteralPath $briefPath)) {
    Write-MmoUtf8Text -LiteralPath $briefPath -Text @"
# BRIEF

- run_id: $runId
- strategy: $Strategy
- stage: $Stage
- created: $([datetime]::UtcNow.ToString('o'))

## Objective

TODO

## Constraints

TODO

## Acceptance

TODO
"@
}

$logPath = Join-Path $runDir 'EXECUTION_LOG.md'
if (-not (Test-Path -LiteralPath $logPath)) {
    Write-MmoUtf8Text -LiteralPath $logPath -Text "# EXECUTION LOG`n`n"
}

$status = [ordered]@{
    run_id = $runId
    stage = $Stage
    state = 'queued'
    strategy = $Strategy
    session_id = $null
    providers = @()
    models = @()
    reasoning_tiers = @()
    summary = 'run directory created'
    next_action = 'write_brief_and_discover'
    updated_at = [datetime]::UtcNow.ToString('o')
}
Write-MmoJson -LiteralPath (Join-Path $runDir 'STATUS.json') -InputObject $status

$result = [ordered]@{
    run_id = $runId
    run_directory = $runDir
    status = $status
}
$json = ConvertTo-MmoJson -InputObject $result
if (-not [string]::IsNullOrWhiteSpace($OutJson)) {
    Write-MmoUtf8Text -LiteralPath $OutJson -Text ($json + [Environment]::NewLine)
}
Write-Output $json
return
