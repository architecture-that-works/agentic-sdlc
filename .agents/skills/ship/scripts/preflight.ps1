#Requires -Version 7.0
<#
.SYNOPSIS
    Idempotent pre-merge preflight for the `ship` skill.

.DESCRIPTION
    Verifies all [BLOCK] conditions in ship/SKILL.md before attempting a merge. Checks:
      1. PR is in OPEN state
      2. PR body contains 'Closes #N'
      3. Module Map check passes (via check-module-map.ps1 if present)
      4. No credential or secret files in the PR diff
      5. No unpinned dependencies introduced in pyproject.toml

    Idempotent: does not mutate project state. Safe to run multiple times.
    Exits 0 only when ALL [BLOCK] conditions pass.

.PARAMETER PR
    GitHub PR number to validate. Required.

.EXAMPLE
    pwsh .agents/skills/ship/scripts/preflight.ps1 -PR 42
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$PR
)

$ErrorActionPreference = 'Stop'
$failed = $false

# ── 1. PR must be OPEN ────────────────────────────────────────────────────────

$prData = gh pr view $PR --json state,body 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "[BLOCK] PR #$PR not found or gh CLI error: $prData"
    exit 1
}

$pr = $prData | ConvertFrom-Json

if ($pr.state -ne 'OPEN') {
    Write-Warning "[BLOCK] PR #$PR is not open (state: $($pr.state)). Only merge open PRs."
    $failed = $true
} else {
    Write-Host "[OK] PR #$PR is OPEN."
}

# ── 2. Auto-close validation ──────────────────────────────────────────────────

if ($pr.body -imatch 'closes\s+#\d+') {
    Write-Host "[OK] PR body contains 'Closes #N'."
} else {
    Write-Warning "[BLOCK] PR #$PR body does not contain 'Closes #N'. Add it before merging."
    $failed = $true
}

# ── 3. Module Map check ───────────────────────────────────────────────────────

$moduleMapScript = '.github/scripts/ci/check-module-map.ps1'
if (Test-Path $moduleMapScript) {
    Write-Host "Running Module Map check..."
    & pwsh $moduleMapScript
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[BLOCK] Module Map check failed. Add missing rows to CONTEXT.md."
        $failed = $true
    } else {
        Write-Host "[OK] Module Map check passed."
    }
} else {
    Write-Host "[SKIP] $moduleMapScript not found — skipping Module Map check."
}

# ── 4. Sandboxing: no credential files ────────────────────────────────────────

$diffNames = git diff "main...HEAD" --name-only 2>&1
$credFiles = $diffNames | Where-Object {
    $_ -match '\.(env|key|pem|p12|pfx|crt|cer)$' -or
    $_ -imatch '(secret|credential|password|token|api.key)'
}

if ($credFiles) {
    Write-Warning "[BLOCK] Credential or secret files detected in PR diff:"
    $credFiles | ForEach-Object { Write-Warning "  $_" }
    $failed = $true
} else {
    Write-Host "[OK] No credential or secret files in PR diff."
}

# ── 5. Supply chain: pinned dependencies ─────────────────────────────────────

$depDiff = git diff "main...HEAD" -- pyproject.toml 2>&1
# Lines starting with '+' (additions) that look like package entries without '=='
$unpinned = $depDiff | Where-Object {
    $_ -match '^\+\s+"[a-zA-Z]' -and $_ -notmatch '=='
}

if ($unpinned) {
    Write-Warning "[BLOCK] Unpinned dependencies found in pyproject.toml diff:"
    $unpinned | ForEach-Object { Write-Warning "  $_" }
    Write-Warning "Pin each package to a specific version (e.g. requests==2.32.3)."
    $failed = $true
} else {
    Write-Host "[OK] No unpinned dependencies detected."
}

# ── Result ────────────────────────────────────────────────────────────────────

if ($failed) {
    Write-Error "`n[FAIL] Preflight checks failed for PR #$PR. Resolve all [BLOCK] items before merging."
    exit 1
}

Write-Host "`n[PASS] All preflight checks passed for PR #$PR."
Write-Host "Safe to run: gh pr merge $PR --squash --delete-branch"
exit 0
