# Allocate an isolated Git worktree for a concurrent writer, or report no-git fallback.
# Authored 2026-07-17.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$WorkerId,
    [string]$RunDirectory = '',
    [string]$BranchName = '',
    [string]$BaseRef = 'HEAD',
    [switch]$ForceReadOnlyFallback,
    [string]$OutJson = ''
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Test-MmoGitRepo {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Push-Location -LiteralPath $Path
    try {
        git rev-parse --is-inside-work-tree 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
    finally {
        Pop-Location
    }
}

$resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$safeWorker = ($WorkerId -replace '[^A-Za-z0-9._-]', '_')
if ([string]::IsNullOrWhiteSpace($BranchName)) {
    $BranchName = "mmo/$safeWorker-" + (Get-Date -Format 'yyyyMMddHHmmss')
}

$result = [ordered]@{
    worker_id = $WorkerId
    repo_root = $resolvedRoot
    mode = $null
    worktree_path = $null
    branch = $null
    base_ref = $BaseRef
    writable = $false
    message = $null
    allocated_at = [datetime]::UtcNow.ToString('o')
}

if ($ForceReadOnlyFallback -or -not (Test-MmoGitRepo -Path $resolvedRoot)) {
    $result.mode = 'no_git_fallback'
    $result.worktree_path = $resolvedRoot
    $result.writable = $false
    $result.message = 'Git worktree unavailable; parallelize read-only analysis and serialize writes.'
}
else {
    $wtParent = if (-not [string]::IsNullOrWhiteSpace($RunDirectory)) {
        Join-Path $RunDirectory 'worktrees'
    }
    else {
        Join-Path $resolvedRoot '.codex\mmo-worktrees'
    }
    if (-not (Test-Path -LiteralPath $wtParent)) {
        New-Item -ItemType Directory -Path $wtParent -Force | Out-Null
    }
    $wtPath = Join-Path $wtParent $safeWorker
    if (Test-Path -LiteralPath $wtPath) {
        throw "Worktree path already exists: $wtPath"
    }

    Push-Location -LiteralPath $resolvedRoot
    try {
        git worktree add -b $BranchName $wtPath $BaseRef
        if ($LASTEXITCODE -ne 0) {
            throw "git worktree add failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $result.mode = 'git_worktree'
    $result.worktree_path = (Resolve-Path -LiteralPath $wtPath).Path
    $result.branch = $BranchName
    $result.writable = $true
    $result.message = 'Allocated isolated worktree for concurrent writer.'
}

if (-not [string]::IsNullOrWhiteSpace($RunDirectory)) {
    $metaDir = Join-Path $RunDirectory 'worktrees'
    if (-not (Test-Path -LiteralPath $metaDir)) {
        New-Item -ItemType Directory -Path $metaDir -Force | Out-Null
    }
    $metaPath = Join-Path $metaDir ($safeWorker + '.json')
    Write-MmoJson -LiteralPath $metaPath -InputObject $result
    if ([string]::IsNullOrWhiteSpace($OutJson)) { $OutJson = $metaPath }
}

$json = ConvertTo-MmoJson -InputObject $result
if (-not [string]::IsNullOrWhiteSpace($OutJson) -and (Join-Path $RunDirectory 'worktrees') -ne (Split-Path -Parent $OutJson)) {
    Write-MmoUtf8Text -LiteralPath $OutJson -Text ($json + [Environment]::NewLine)
}
Write-Output $json
return
