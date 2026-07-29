#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-review state verification for the `review` skill.

.DESCRIPTION
    Verifies that the environment is in a clean, reviewable state before starting a
    code review. Checks:
      1. Working tree is clean (no uncommitted changes on the review branch)
      2. Test suite passes on the current branch
      3. The PR exists and is in OPEN state

    Idempotent: read-only — does not mutate project state. Safe to run multiple times.
    Run before invoking the Senior Architect review step in the `review` skill.

.PARAMETER PR
    GitHub PR number to validate. Required.

.EXAMPLE
    pwsh .agents/skills/review/scripts/pre-review.ps1 -PR 42
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$PR
)

$ErrorActionPreference = 'Stop'
$failed = $false

# ── 1. Working tree must be clean ─────────────────────────────────────────────

$dirty = git status --porcelain 2>&1
if ($dirty) {
    Write-Warning "[BLOCK] Working tree has uncommitted changes. Stash or commit before reviewing."
    $dirty | ForEach-Object { Write-Warning "  $_" }
    $failed = $true
} else {
    Write-Host "[OK] Working tree is clean."
}

# ── 2. Test suite must pass ───────────────────────────────────────────────────

Write-Host "Running test suite (this may take a moment)..."
$testOutput = uv run pytest -x --no-cov -q 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "[BLOCK] Test suite has failures on this branch. Fix tests before reviewing."
    $testOutput | Select-Object -Last 20 | ForEach-Object { Write-Warning "  $_" }
    $failed = $true
} else {
    Write-Host "[OK] Test suite passes."
}

# ── 3. PR must exist and be OPEN ──────────────────────────────────────────────

$prState = gh pr view $PR --json state --jq '.state' 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "[BLOCK] PR #$PR not found or gh CLI error: $prState"
    $failed = $true
} elseif ($prState -ne 'OPEN') {
    Write-Warning "[BLOCK] PR #$PR is not open (state: $prState). Review only open PRs."
    $failed = $true
} else {
    Write-Host "[OK] PR #$PR is OPEN."
}

# ── Result ────────────────────────────────────────────────────────────────────

if ($failed) {
    Write-Error "`n[FAIL] Pre-review checks failed. Resolve the issues above before starting the review."
    exit 1
}

Write-Host "`n[PASS] All pre-review checks passed. Ready to review PR #$PR."
exit 0
