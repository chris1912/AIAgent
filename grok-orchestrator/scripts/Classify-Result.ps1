# Classify Grok provider output into success / quota / auth / network / permission / task / unknown.
# Context-aware: benign report text mentioning 401/auth/timeout must not become failures.
# Authored 2026-07-18.
[CmdletBinding()]
param(
    [string]$RawLogPath = '',
    [string]$RawText = '',
    [int]$ExitCode = 0,
    [string]$StderrText = '',
    [string]$StderrPath = '',
    [string]$OutJson = ''
)

. (Join-Path $PSScriptRoot 'Common.ps1')

function Test-GoRegexAny {
    param(
        [string]$Hay,
        [string[]]$Patterns
    )
    if ([string]::IsNullOrEmpty($Hay)) { return $false }
    foreach ($p in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ([regex]::IsMatch($Hay, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            return $true
        }
    }
    return $false
}

function Remove-GoLogWarningLines {
    <#
    Drop non-fatal tracing WARN lines (optional MCP/OAuth noise) while keeping ERROR/error frames.
    ANSI CSI sequences are stripped only for severity detection.
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "(`r`n|`n|`r)")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $plain = [regex]::Replace($line, '\x1b\[[0-9;]*m', '')
        if ($plain -match '(?i)(?:^|\s)WARN\b') {
            continue
        }
        $kept.Add($line) | Out-Null
    }
    if ($kept.Count -eq 0) { return '' }
    return ($kept -join "`n")
}

function Get-GoErrorEvidenceSlices {
    <#
    Prefer stderr and error-framed lines over the full successful report body.
    #>
    param(
        [string]$Combined,
        [string]$Stderr
    )
    $slices = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
        $slices.Add($Stderr) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($Combined)) {
        return @($slices)
    }
    foreach ($line in ($Combined -split "(`r`n|`n|`r)")) {
        $t = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t -match '(?i)^(error|err|exception|fatal)\b') {
            $slices.Add($t) | Out-Null
            continue
        }
        if ($t -match '(?i)\b(error|exception|fatal)\s*:') {
            $slices.Add($t) | Out-Null
            continue
        }
    }
    return @($slices)
}

function Get-GoClassification {
    param(
        [string]$Text,
        [string]$Stderr = '',
        [int]$Code
    )

    $t = if ($null -eq $Text) { '' } else { $Text }
    $err = if ($null -eq $Stderr) { '' } else { $Stderr }
    # Exit 0: ignore non-fatal WARN stderr (e.g. optional MCP "Auth required") so success is preserved.
    # Non-zero exits keep full stderr so explicit provider failures still classify.
    $errEvidence = if ($Code -eq 0) { Remove-GoLogWarningLines -Text $err } else { $err }
    $combined = ($t + "`n" + $err).Trim()
    $combinedForEvidence = ($t + "`n" + $errEvidence).Trim()
    $evidenceSlices = @(Get-GoErrorEvidenceSlices -Combined $combinedForEvidence -Stderr $errEvidence)
    $evidence = if ($evidenceSlices.Count -gt 0) { ($evidenceSlices -join "`n") } else { '' }

    $quotaPatterns = @(
        '(?i)\binsufficient[_\s-]?quota\b',
        '(?i)\bquota(?:\s+exhausted|\s+exceeded|\s+limit)?\b',
        '(?i)\brate[_\s-]?limit(?:ed|s)?\b',
        '(?i)\bresource exhausted\b',
        '(?i)\btoo many requests\b',
        '(?i)\btokens? exceeded\b',
        '(?i)\busage limit\b',
        '(?i)\bbilling hard limit\b',
        '(?i)\bcredit(?:s)?\s+(?:exhausted|exceeded|limit)\b'
    )
    $modelUnavailablePatterns = @(
        '(?i)\bmodel not found\b',
        '(?i)\bmodel[_\s-]?unavailable\b',
        '(?i)\bunknown model\b',
        '(?i)\bunsupported model\b',
        '(?i)\binvalid model\b',
        '(?i)\bmodel\b.+\bdoes not exist\b',
        '(?i)\bnot available\b.+\bmodel\b',
        '(?i)\bmodel\b.+\bnot available\b'
    )
    $authPatterns = @(
        '(?i)\bunauthorized\b',
        '(?i)\bunauthenticated\b',
        '(?i)\bnot logged in\b',
        '(?i)\blogin required\b',
        '(?i)\binvalid api key\b',
        '(?i)\binvalid token\b',
        '(?i)\bauthentication(?:\s+required|\s+failed|\s+error|\s+failure)\b',
        '(?i)\bauth(?:entication)?\s*(?:error|failed|failure|required)\b',
        '(?i)\b403\s+forbidden\b',
        '(?i)\bhttp(?:\s+status)?\s*[:\s]+401\b',
        '(?i)\bstatus(?:\s+code)?\s*[:\s]+401\b',
        '(?i)\berror[^.\n]{0,40}\b401\b',
        '(?i)\b401\b[^.\n]{0,40}\b(unauthorized|unauthenticated|auth)\b'
    )
    $networkPatterns = @(
        '(?i)\bnetwork error\b',
        '(?i)\bconnection refused\b',
        '(?i)\bconnection reset\b',
        '(?i)\btimed?\s*out\b',
        '(?i)\btimeout waiting\b',
        '(?i)\brequest timed?\s*out\b',
        '(?i)\bcould not resolve\b',
        '(?i)\bdns\s+(?:error|failure|lookup failed|resolution failed)\b',
        '(?i)\btemporary failure\b',
        '(?i)\btls handshake\b'
    )
    $permissionPatterns = @(
        '(?i)\bpermission denied\b',
        '(?i)\baccess is denied\b',
        '(?i)\baccess denied\b',
        '(?i)\beacces\b',
        '(?i)\boperation not permitted\b',
        '(?i)\breadonly file system\b'
    )

    $searchPrimary = $evidence
    if ([string]::IsNullOrWhiteSpace($searchPrimary) -and $Code -ne 0) {
        $searchPrimary = $combined
    }

    $quotaHay = if (-not [string]::IsNullOrWhiteSpace($evidence)) { $evidence } else { if ($Code -ne 0) { $combined } else { $evidence } }
    if (Test-GoRegexAny -Hay $quotaHay -Patterns $quotaPatterns) {
        return [pscustomobject]@{
            classification = 'quota_exhausted'
            fallback_eligible = $true
            reason = 'Matched quota/rate-limit/credit pattern in error context'
        }
    }
    if (Test-GoRegexAny -Hay $quotaHay -Patterns $modelUnavailablePatterns) {
        return [pscustomobject]@{
            classification = 'model_unavailable'
            fallback_eligible = $true
            reason = 'Matched model unavailable pattern in error context'
        }
    }

    if ($Code -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($evidence)) {
            if (Test-GoRegexAny -Hay $evidence -Patterns $authPatterns) {
                return [pscustomobject]@{
                    classification = 'auth_failure'
                    fallback_eligible = $false
                    reason = 'Matched authentication/authorization pattern in error context'
                }
            }
            if (Test-GoRegexAny -Hay $evidence -Patterns $networkPatterns) {
                return [pscustomobject]@{
                    classification = 'network_failure'
                    fallback_eligible = $false
                    reason = 'Matched network/timeout pattern in error context'
                }
            }
            if (Test-GoRegexAny -Hay $evidence -Patterns $permissionPatterns) {
                return [pscustomobject]@{
                    classification = 'permission_failure'
                    fallback_eligible = $false
                    reason = 'Matched permission pattern in error context'
                }
            }
        }
        return [pscustomobject]@{
            classification = 'success'
            fallback_eligible = $false
            reason = 'Exit code 0 without error-context failure signatures'
        }
    }

    $failHay = if (-not [string]::IsNullOrWhiteSpace($searchPrimary)) { $searchPrimary } else { $combined }
    if (Test-GoRegexAny -Hay $failHay -Patterns $authPatterns) {
        return [pscustomobject]@{
            classification = 'auth_failure'
            fallback_eligible = $false
            reason = 'Matched authentication/authorization pattern'
        }
    }
    if (Test-GoRegexAny -Hay $failHay -Patterns $networkPatterns) {
        return [pscustomobject]@{
            classification = 'network_failure'
            fallback_eligible = $false
            reason = 'Matched network/timeout pattern'
        }
    }
    if (Test-GoRegexAny -Hay $failHay -Patterns $permissionPatterns) {
        return [pscustomobject]@{
            classification = 'permission_failure'
            fallback_eligible = $false
            reason = 'Matched permission pattern'
        }
    }

    return [pscustomobject]@{
        classification = 'task_failure'
        fallback_eligible = $false
        reason = "Non-zero exit code $Code without fallback-eligible signatures"
    }
}

$text = $RawText
if (-not [string]::IsNullOrWhiteSpace($RawLogPath)) {
    if (-not (Test-Path -LiteralPath $RawLogPath)) {
        throw "Raw log not found: $RawLogPath"
    }
    $fileText = Get-Content -LiteralPath $RawLogPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = $fileText
    }
    else {
        $text = $text + "`n" + $fileText
    }
}

$stderrCombined = $StderrText
if (-not [string]::IsNullOrWhiteSpace($StderrPath)) {
    if (Test-Path -LiteralPath $StderrPath) {
        $stderrFile = Get-Content -LiteralPath $StderrPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($stderrFile)) {
            if ([string]::IsNullOrWhiteSpace($stderrCombined)) {
                $stderrCombined = $stderrFile
            }
            else {
                $stderrCombined = $stderrCombined + "`n" + $stderrFile
            }
        }
    }
}

$cls = Get-GoClassification -Text $text -Stderr $stderrCombined -Code $ExitCode
$result = [ordered]@{
    exit_code = $ExitCode
    classification = $cls.classification
    fallback_eligible = [bool]$cls.fallback_eligible
    reason = $cls.reason
    classified_at = [datetime]::UtcNow.ToString('o')
}

$json = ConvertTo-GoJson -InputObject $result
if (-not [string]::IsNullOrWhiteSpace($OutJson)) {
    Write-GoUtf8Text -LiteralPath $OutJson -Text ($json + [Environment]::NewLine)
}
Write-Output $json
return
