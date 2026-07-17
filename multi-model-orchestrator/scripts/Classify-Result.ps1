# Classify provider output into success / quota / auth / network / permission / task / unknown.
# Authored 2026-07-17; hardened 2026-07-17 for context-aware matching (no bare 401/timeout false positives).
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

function Test-MmoRegexAny {
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

function Get-MmoErrorEvidenceSlices {
    <#
    Prefer stderr and error-framed lines over the full successful report body.
    Benign narrative mentions of 401/timeout/dns/authentication/unauthenticated are not evidence.
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
        # Explicit provider/CLI error framing only. Narrative audit text must not become evidence.
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

function Get-MmoClassification {
    <#
    Context-aware classification. Prefer stderr/exit code/error-framed phrases over bare substrings.
    Quota/model-unavailable remain fallback-eligible. Benign report text mentioning 401/auth/timeout/dns
    with exit code 0 must not become provider failures.
    #>
    param(
        [string]$Text,
        [string]$Stderr = '',
        [int]$Code
    )

    $t = if ($null -eq $Text) { '' } else { $Text }
    $err = if ($null -eq $Stderr) { '' } else { $Stderr }
    $combined = ($t + "`n" + $err).Trim()
    $evidenceSlices = @(Get-MmoErrorEvidenceSlices -Combined $combined -Stderr $err)
    $evidence = if ($evidenceSlices.Count -gt 0) { ($evidenceSlices -join "`n") } else { '' }

    # Strong provider-style phrases safe to match in evidence (and in full text when exit != 0).
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
    # Auth: multi-word / provider phrases; never bare "authentication" or bare 401/403 alone.
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

    # Primary search space: error evidence when present; else full text only if exit != 0.
    $searchPrimary = $evidence
    if ([string]::IsNullOrWhiteSpace($searchPrimary) -and $Code -ne 0) {
        $searchPrimary = $combined
    }

    # Fallback-eligible classes may also be detected from full combined text when non-zero exit,
    # or from evidence slices even on exit 0 (provider sometimes exits 0 with quota message).
    $quotaHay = if (-not [string]::IsNullOrWhiteSpace($evidence)) { $evidence } else { if ($Code -ne 0) { $combined } else { $evidence } }
    if (Test-MmoRegexAny -Hay $quotaHay -Patterns $quotaPatterns) {
        return [pscustomobject]@{
            classification = 'quota_exhausted'
            fallback_eligible = $true
            reason = 'Matched quota/rate-limit/credit pattern in error context'
        }
    }
    $modelHay = $quotaHay
    if (Test-MmoRegexAny -Hay $modelHay -Patterns $modelUnavailablePatterns) {
        return [pscustomobject]@{
            classification = 'model_unavailable'
            fallback_eligible = $true
            reason = 'Matched model unavailable pattern in error context'
        }
    }

    # Non-fallback failures: require error context when exit code is 0.
    if ($Code -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($evidence)) {
            if (Test-MmoRegexAny -Hay $evidence -Patterns $authPatterns) {
                return [pscustomobject]@{
                    classification = 'auth_failure'
                    fallback_eligible = $false
                    reason = 'Matched authentication/authorization pattern in error context'
                }
            }
            if (Test-MmoRegexAny -Hay $evidence -Patterns $networkPatterns) {
                return [pscustomobject]@{
                    classification = 'network_failure'
                    fallback_eligible = $false
                    reason = 'Matched network/timeout pattern in error context'
                }
            }
            if (Test-MmoRegexAny -Hay $evidence -Patterns $permissionPatterns) {
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

    # Non-zero exit: still prefer evidence, then full text, with bounded/strong patterns only.
    $failHay = if (-not [string]::IsNullOrWhiteSpace($searchPrimary)) { $searchPrimary } else { $combined }
    if (Test-MmoRegexAny -Hay $failHay -Patterns $authPatterns) {
        return [pscustomobject]@{
            classification = 'auth_failure'
            fallback_eligible = $false
            reason = 'Matched authentication/authorization pattern'
        }
    }
    if (Test-MmoRegexAny -Hay $failHay -Patterns $networkPatterns) {
        return [pscustomobject]@{
            classification = 'network_failure'
            fallback_eligible = $false
            reason = 'Matched network/timeout pattern'
        }
    }
    if (Test-MmoRegexAny -Hay $failHay -Patterns $permissionPatterns) {
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

$cls = Get-MmoClassification -Text $text -Stderr $stderrCombined -Code $ExitCode
$result = [ordered]@{
    exit_code = $ExitCode
    classification = $cls.classification
    fallback_eligible = [bool]$cls.fallback_eligible
    reason = $cls.reason
    classified_at = [datetime]::UtcNow.ToString('o')
}

$json = ConvertTo-MmoJson -InputObject $result
if (-not [string]::IsNullOrWhiteSpace($OutJson)) {
    Write-MmoUtf8Text -LiteralPath $OutJson -Text ($json + [Environment]::NewLine)
}
Write-Output $json
return
