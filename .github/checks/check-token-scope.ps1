#Requires -Version 7.0
<#
.SYNOPSIS
    Guards the pipeline's tokens: no secret sits in the workflow-level env of afk.yml, and no
    installer step runs after a checkout that stored credentials in the same job.

.DESCRIPTION
    Two checks:
    1. The top-level env: block of afk.yml must not contain GH_TOKEN or
       CLAUDE_CODE_OAUTH_TOKEN.
    2. For each job in afk.yml, every step whose run block contains 'uv' or
       'npm install' must appear before every actions/checkout step that does
       NOT include 'persist-credentials: false' (a credentialed checkout).

    Exits 0 when both checks pass; exits 1 with a descriptive message on failure.
#>

$ErrorActionPreference = 'Stop'

# Resolve relative to repo root regardless of CWD
$repo = git rev-parse --show-toplevel 2>$null
if (-not $repo) { $repo = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent }
$workflowPath = Join-Path $repo '.github' 'workflows' 'afk.yml'

if (-not (Test-Path $workflowPath)) {
    Write-Error "afk.yml not found at $workflowPath — restore .github/workflows/afk.yml."
    exit 1
}

$lines = Get-Content $workflowPath

# ── Check 1: no secret in the workflow-level env block ───────────────────────
# The workflow-level env block starts at a line that is exactly "env:" (no indent)
# and ends at the first line that starts a top-level key (also no indent, e.g. "jobs:").
$secretNames = @('GH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')
$inTopEnv = $false
$failures = [System.Collections.Generic.List[string]]::new()

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^env:\s*$') { $inTopEnv = $true; continue }
    if ($inTopEnv) {
        # A non-indented line ends the block
        if ($line -match '^[a-zA-Z]') { $inTopEnv = $false; continue }
        foreach ($secret in $secretNames) {
            if ($line -match "^\s+${secret}\s*:") {
                $failures.Add("workflow-level env contains '$secret' at line $($i + 1) — move it to the env of the step that uses it")
            }
        }
    }
}

# ── Check 2: no installer step after a credentialed checkout in the same job ─
# Parse jobs as ordered lists of steps, then verify relative ordering.
#
# A "credentialed checkout" is an actions/checkout step block that does NOT
# contain the text "persist-credentials: false" within its own step block.
# An "installer step" is any step whose run: block contains "uv" or "npm install".
#
# We parse by scanning for job and step boundaries in the YAML text.

# Split into job sections (lines between job-name: and the next sibling or EOF).
$jobPattern   = [regex]'^  (?!#)([a-zA-Z][a-zA-Z0-9_-]*):\s*$'
$jobBoundaries = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($jobPattern.IsMatch($lines[$i])) {
        $jobBoundaries += [pscustomobject]@{ Name = $jobPattern.Match($lines[$i]).Groups[1].Value; Start = $i }
    }
}

for ($j = 0; $j -lt $jobBoundaries.Count; $j++) {
    $jobName  = $jobBoundaries[$j].Name
    $jobStart = $jobBoundaries[$j].Start
    $jobEnd   = if ($j + 1 -lt $jobBoundaries.Count) { $jobBoundaries[$j + 1].Start - 1 } else { $lines.Count - 1 }
    $jobLines = $lines[$jobStart..$jobEnd]

    # Find step boundaries within the job (lines that match "      - " with 6 spaces).
    $stepPattern = [regex]'^      - '
    $stepStarts  = @()
    for ($k = 0; $k -lt $jobLines.Count; $k++) {
        if ($stepPattern.IsMatch($jobLines[$k])) { $stepStarts += $k }
    }

    $credentialedCheckoutIndices = [System.Collections.Generic.List[int]]::new()
    $installerIndices            = [System.Collections.Generic.List[int]]::new()

    for ($s = 0; $s -lt $stepStarts.Count; $s++) {
        $stepStart = $stepStarts[$s]
        $stepEndEx = if ($s + 1 -lt $stepStarts.Count) { $stepStarts[$s + 1] } else { $jobLines.Count }
        $stepBlock = $jobLines[$stepStart..($stepEndEx - 1)] -join "`n"

        $isCheckout       = $stepBlock -match 'actions/checkout'
        $hasNoCreds       = $stepBlock -match 'persist-credentials:\s*false'
        $isInstaller      = $stepBlock -match '\buv\b' -or $stepBlock -match 'npm install'

        if ($isCheckout -and -not $hasNoCreds) { $credentialedCheckoutIndices.Add($s) }
        if ($isInstaller) {
            $installerIndices.Add($s)
            # Check 2b: no known secret in an installer step's env block.
            foreach ($secret in @('GH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')) {
                if ($stepBlock -match "\b${secret}\s*:") {
                    $failures.Add(
                        "job '$jobName': installer step (index $s) has secret '$secret' in its env — remove it; an installer needs no secret"
                    )
                }
            }
        }
    }

    foreach ($instIdx in $installerIndices) {
        foreach ($coIdx in $credentialedCheckoutIndices) {
            if ($instIdx -gt $coIdx) {
                $failures.Add(
                    "job '$jobName': installer step (index $instIdx) appears after credentialed checkout (index $coIdx) — move the installer before the checkout, or set 'persist-credentials: false' on the checkout"
                )
            }
        }
    }
}

if ($failures.Count -gt 0) {
    foreach ($msg in $failures) { Write-Host "FAIL: $msg" }
    exit 1
}

Write-Host 'check-token-scope: all assertions passed.'
exit 0
