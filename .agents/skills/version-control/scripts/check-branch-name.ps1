#Requires -Version 7.0
<#
.SYNOPSIS
    Validates the current branch name and last commit subject against project conventions.

.DESCRIPTION
    Checks two things:
    1. The current branch name matches: ^(feature|fix|docs|refactor)/\d+-[a-z0-9-]{1,40}$
    2. The last commit subject matches:  ^(feat|fix|refactor|test|docs|chore)(\(.+\))?: .+$

    Exits 0 if both pass. Exits 1 with an actionable message (showing the failing string,
    the expected pattern, and a corrective example) if either fails.

    Idempotent: re-running on an already-correct branch always exits 0 without changing
    any repository state.

.EXAMPLE
    # Run from the project root
    pwsh .agents/skills/version-control/scripts/check-branch-name.ps1

.EXAMPLE
    # Run from any directory (pass the repo root)
    pwsh /path/to/.agents/skills/version-control/scripts/check-branch-name.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ── Verify git is available ───────────────────────────────────────────────────

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git is not installed or not on PATH."
    exit 1
}

# ── Patterns ─────────────────────────────────────────────────────────────────

$branchPattern = '^(feature|fix|docs|refactor)/\d+-[a-z0-9-]{1,40}$'
$commitPattern = '^(feat|fix|refactor|test|docs|chore)(\(.+\))?: .+'

# ── Read current state ────────────────────────────────────────────────────────

$branch = git rev-parse --abbrev-ref HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not determine current branch. Are you inside a git repository?"
    exit 1
}

$lastCommitSubject = git log -1 --format='%s' 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not read last commit subject. Does the repository have any commits?"
    exit 1
}

# ── Validate branch name ─────────────────────────────────────────────────────

$branchOk = $branch -match $branchPattern

if (-not $branchOk) {
    Write-Host ""
    Write-Host "FAIL: Branch name does not match the required pattern." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Current branch : $branch"
    Write-Host "  Required pattern: $branchPattern"
    Write-Host ""
    Write-Host "  Valid examples:"
    Write-Host "    feature/42-user-auth-endpoint"
    Write-Host "    fix/17-order-rounding"
    Write-Host "    docs/16-sdlc-prd"
    Write-Host "    refactor/55-extract-config-loader"
    Write-Host ""
    Write-Host "  To fix: git checkout -b feature/<issue-number>-<2-4-word-slug>"
    Write-Host ""
    exit 1
}

Write-Host "OK: Branch name matches convention: $branch" -ForegroundColor Green

# ── Validate last commit subject ─────────────────────────────────────────────

$commitOk = $lastCommitSubject -match $commitPattern

if (-not $commitOk) {
    Write-Host ""
    Write-Host "FAIL: Last commit subject does not match the conventional-commit format." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Last commit subject : $lastCommitSubject"
    Write-Host "  Required pattern    : $commitPattern"
    Write-Host ""
    Write-Host "  Valid examples:"
    Write-Host "    feat(orders): add tax calculation to order total"
    Write-Host "    fix(auth): handle missing LOG_LEVEL env var"
    Write-Host "    refactor(config): extract settings loader to utility"
    Write-Host "    test(orders): add parametrized tax-rate cases"
    Write-Host "    docs(adr): document worktree isolation decision"
    Write-Host "    chore(deps): bump pydantic-settings to 2.4.0"
    Write-Host ""
    Write-Host "  To fix: git commit --amend -m '<type>(<scope>): <short description>'"
    Write-Host "          Types: feat, fix, refactor, test, docs, chore"
    Write-Host ""
    exit 1
}

Write-Host "OK: Last commit subject matches convention: $lastCommitSubject" -ForegroundColor Green

Write-Host ""
Write-Host "All checks passed." -ForegroundColor Green
exit 0
