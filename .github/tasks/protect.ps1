#Requires -Version 7.0
<#
.SYNOPSIS
    Apply branch-protection rules to the main branch.

.DESCRIPTION
    Configures branch protection on 'main' with:
      - Required status checks: lint, typecheck, test, audit, secret-scan, module-map-check
      - Require branches to be up-to-date before merging (strict)
      - Require a pull request before merging (no approval count required)
      - github-actions app bypass for direct push (orchestrator CONTEXT.md update)
      - Enforce all rules for admins too (no admin bypass)

    Run via:  task protect
    Requires: GH_TOKEN with 'repo' scope (repository admin access)
    Verify:   gh api repos/{owner}/{repo}/branches/main/protection

.NOTES
    The github-actions bypass allows the orchestrator's post-merge CONTEXT.md
    direct push (afk.yml) to succeed despite the PR requirement.
    If the bypass API call is rejected (e.g. plan limitation), branch protection
    is still applied and the CONTEXT.md push fails gracefully (non-blocking).

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
$RequiredChecks = @("lint", "typecheck", "test", "audit", "secret-scan", "module-map-check")

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
        require_code_owner_reviews      = $false
        require_last_push_approval      = $false
        bypass_pull_request_allowances  = [ordered]@{
            users = @()
            teams = @()
            apps  = @("github-actions")
        }
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

$Bypass = $Protection.required_pull_request_reviews.bypass_pull_request_allowances.apps
if ($Bypass -and ($Bypass | Where-Object { $_.slug -eq 'github-actions' -or $_ -eq 'github-actions' })) {
    Write-Host "  ✅ github-actions bypass configured (CONTEXT.md direct push allowed)." -ForegroundColor Green
} else {
    Write-Host "  ℹ️  github-actions bypass not present — CONTEXT.md direct push may be rejected (non-blocking)." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "✅ Done. Verify anytime with:" -ForegroundColor Green
Write-Host "   gh api repos/$Repo/branches/$Branch/protection" -ForegroundColor DarkGray
Write-Host ""
