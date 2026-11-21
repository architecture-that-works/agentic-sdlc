#Requires -Version 7.0
<#
.SYNOPSIS
    Apply branch-protection rules to the main branch.

.DESCRIPTION
    Configures branch protection on 'main' with:
      - Required status checks: lint, typecheck, test, audit, secret-scan, checks, eval
        (eval is skipped — reported as success — on PRs that touch no model-facing path)
      - Require branches to be up-to-date before merging (strict)
      - Require a pull request before merging (no approval count required), with no
        bypass allowances for any user, team or app — every change, the orchestrator's
        included, reaches the default branch through a pull request
      - Enforce all rules for admins too (no admin bypass)

    Branch protection is a one-time setting. The owner runs this once from a terminal
    with their own `gh` login, which needs repository admin rights. No workflow applies
    it, and no admin-capable token is stored as an Actions secret for it (SECURITY.md:
    GH_TOKEN never carries admin:* scope).

    Run via:  task protect
    Verify:   gh api repos/{owner}/{repo}/branches/main/protection

.EXAMPLE
    task protect
#>

$ErrorActionPreference = 'Stop'

# ── Resolve repo ───────────────────────────────────────────────────────────────

$Repo = gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>&1 | Out-String
$Repo = $Repo.Trim()
if ($LASTEXITCODE -ne 0 -or -not $Repo) {
    Write-Error "Could not determine repo name. Ensure 'gh auth login' has been run."
    exit 1
}

$Branch         = "main"
# Job names in checks.yml. Every .github/checks/check-*.ps1 runs inside the `checks`
# job; no check has a job of its own, so requiring one would block every merge.
$RequiredChecks = @("lint", "typecheck", "test", "audit", "secret-scan", "checks", "eval")

Write-Host ""
Write-Host "🔒 Applying branch protection to '$Branch' in '$Repo'..." -ForegroundColor Cyan
Write-Host "   Required checks: $($RequiredChecks -join ', ')" -ForegroundColor DarkGray

# ── Build protection body ──────────────────────────────────────────────────────

$BodyObject = [ordered]@{
    required_status_checks           = [ordered]@{
        strict   = $true
        contexts = $RequiredChecks
    }
    enforce_admins                   = $true
    required_pull_request_reviews    = [ordered]@{
        required_approving_review_count = 0
        dismiss_stale_reviews           = $false
        # false: agent PRs are opened under the owner's PAT; GitHub prevents an author from approving
        # their own PR, so requiring code-owner review would block every merge. Enforcement is
        # delegated to the human:approval label (GovernancePaths in lib/Config.ps1) instead.
        require_code_owner_reviews      = $false
        require_last_push_approval      = $false
    }
    restrictions                     = $null
    allow_force_pushes               = $false
    allow_deletions                  = $false
    required_linear_history          = $false
    required_conversation_resolution = $false
}

$BodyJson = $BodyObject | ConvertTo-Json -Depth 10

# ── Apply via GitHub API ────────────────────────────────────────────────────────

$Result = $BodyJson | gh api --method PUT "repos/$Repo/branches/$Branch/protection" --input - 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to apply branch protection:`n$Result"
    exit 1
}

Write-Host "  ✅ Branch protection applied." -ForegroundColor Green

# ── Verify ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "🔍 Verifying branch protection..." -ForegroundColor Cyan

$VerifyJson = gh api "repos/$Repo/branches/$Branch/protection" 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ⚠️  Could not verify: $($VerifyJson.Trim())" -ForegroundColor Yellow
    exit 0
}

$Protection = $VerifyJson | ConvertFrom-Json
$Contexts   = @($Protection.required_status_checks.contexts)
$Missing    = $RequiredChecks | Where-Object { $_ -notin $Contexts }

if ($Missing.Count -gt 0) {
    Write-Host "  ⚠️  Missing required checks: $($Missing -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "  ✅ All $($RequiredChecks.Count) required status checks configured." -ForegroundColor Green
}

if ($Protection.required_status_checks.strict) {
    Write-Host "  ✅ Strict mode (up-to-date requirement) enabled." -ForegroundColor Green
} else {
    Write-Host "  ⚠️  Strict mode not enabled — branches may not be required to be up to date." -ForegroundColor Yellow
}

if ($Protection.required_pull_request_reviews) {
    Write-Host "  ✅ Pull request requirement configured." -ForegroundColor Green
} else {
    Write-Host "  ⚠️  Pull request requirement not configured." -ForegroundColor Yellow
}

if ($Protection.enforce_admins.enabled) {
    Write-Host "  ✅ Admin bypass disabled (enforce_admins: true)." -ForegroundColor Green
} else {
    Write-Host "  ⚠️  Admin bypass not disabled — enforce_admins may be false." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ Done. Verify anytime with:" -ForegroundColor Green
Write-Host "   gh api repos/$Repo/branches/$Branch/protection" -ForegroundColor DarkGray
Write-Host ""
