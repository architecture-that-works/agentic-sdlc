#Requires -Version 7.0
<#
.SYNOPSIS
    Apply branch-protection rules to the main branch, set the repository's merge settings,
    and switch on secret scanning and push protection.

.DESCRIPTION
    Configures branch protection on 'main' with:
      - Required status checks: lint, typecheck, test, audit, checks, eval
        (eval is skipped — reported as success — on PRs that touch no model-facing path)
      - A branch need not be up to date before merging (strict off), so a pull request held
        for the owner stays mergeable after another one merges. GitHub still blocks a merge
        with a conflict or with a failed or missing required check, and checks.yml runs on
        every push to the default branch, so two changes that only fail together show up on
        the first merge
      - Require a pull request before merging (no approval count required), with no
        bypass allowances for any user, team or app — every change, the orchestrator's
        included, reaches the default branch through a pull request
      - Enforce all rules for admins too (no admin bypass)

    It then sets the merge settings, in a call of its own, so a merge by hand lands like the
    orchestrator's: squash merging only (no merge commits, no rebase merging), the pull
    request's title as the squash commit's title with the commits' messages as its body,
    merged branches deleted, and the "Update branch" button always offered.

    Last it switches on secret scanning and push protection, so GitHub refuses any push that holds a secret.
    A private repository gets them only if its owner buys GitHub Secret Protection; the branch rules
    and the merge settings, which come first, apply regardless.

    These are one-time settings. The owner runs this once from a terminal
    with their own `gh` login, which needs repository admin rights. No workflow applies
    them, and no admin-capable token is stored as an Actions secret for it (SECURITY.md:
    GH_TOKEN never carries admin:* scope).

    Run via:  pwsh -NoProfile -File .github/tasks/protect.ps1
    Verify:   gh api repos/{owner}/{repo}/branches/main/protection
              gh api repos/{owner}/{repo} --jq .security_and_analysis
              gh api repos/{owner}/{repo}   (merge settings: allow_squash_merge, …)

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/protect.ps1
#>

$ErrorActionPreference = 'Stop'

# ── Resolve repo ───────────────────────────────────────────────────────────────

$RepoJson = gh repo view --json nameWithOwner,visibility 2>&1 | Out-String
$RepoInfo = $null
if ($LASTEXITCODE -eq 0) {
    try { $RepoInfo = $RepoJson | ConvertFrom-Json } catch { $RepoInfo = $null }
}
$Repo = if ($RepoInfo) { "$($RepoInfo.nameWithOwner)".Trim() } else { '' }
if (-not $Repo) {
    Write-Error "Could not determine repo name. Ensure 'gh auth login' has been run."
    exit 1
}
# Only a public repository has secret scanning at no cost; private and internal ones need
# GitHub Secret Protection, so a refusal there is reported rather than treated as an error.
$IsPublic = "$($RepoInfo.visibility)" -eq 'PUBLIC'

$Branch         = "main"
# Job names in checks.yml. Every .github/checks/check-*.ps1 runs inside the `checks`
# job; no check has a job of its own, so requiring one would block every merge.
$RequiredChecks = @("lint", "typecheck", "test", "audit", "checks", "eval")

Write-Host ""
Write-Host "🔒 Applying branch protection to '$Branch' in '$Repo'..." -ForegroundColor Cyan
Write-Host "   Required checks: $($RequiredChecks -join ', ')" -ForegroundColor DarkGray

# ── Build protection body ──────────────────────────────────────────────────────

$BodyObject = [ordered]@{
    required_status_checks           = [ordered]@{
        strict   = $false
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

# ── Merge settings ─────────────────────────────────────────────────────────────
# A call of its own, after the branch rules and before secret scanning: a refusal of
# secret scanning then leaves these applied. They depend on no plan, so a failure is an error.

Write-Host ""
Write-Host "🔒 Setting merge settings in '$Repo'..." -ForegroundColor Cyan

$MergeSettings = [ordered]@{
    allow_squash_merge          = $true
    allow_merge_commit          = $false
    allow_rebase_merge          = $false
    squash_merge_commit_title   = 'PR_TITLE'
    squash_merge_commit_message = 'COMMIT_MESSAGES'
    delete_branch_on_merge      = $true
    allow_update_branch         = $true
}

$MergeResult = $MergeSettings | ConvertTo-Json | gh api --method PATCH "repos/$Repo" --input - 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to apply merge settings:`n$MergeResult"
    exit 1
}

Write-Host "  ✅ Merge settings applied." -ForegroundColor Green

# ── Secret scanning and push protection ────────────────────────────────────────
# Applied after the branch rules, so even a refused run leaves main protected.

Write-Host ""
Write-Host "🔒 Switching on secret scanning and push protection in '$Repo'..." -ForegroundColor Cyan

$SecurityJson = [ordered]@{
    security_and_analysis = [ordered]@{
        secret_scanning                 = [ordered]@{ status = 'enabled' }
        secret_scanning_push_protection = [ordered]@{ status = 'enabled' }
    }
} | ConvertTo-Json -Depth 5

$SecurityResult = $SecurityJson | gh api --method PATCH "repos/$Repo" --input - 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    if ($IsPublic) {
        Write-Error "Failed to switch on secret scanning and push protection:`n$SecurityResult"
        exit 1
    }
    Write-Host "  ⚠️  This repository has no secret scanning: GitHub Secret Protection provides it for a private repository." -ForegroundColor Yellow
} else {
    Write-Host "  ✅ Secret scanning and push protection switched on." -ForegroundColor Green
}

# ── Verify ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "🔍 Verifying branch protection and secret scanning..." -ForegroundColor Cyan

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
    Write-Host "  ⚠️  Branches are still required to be up to date before merging (strict on) — re-run protect to turn it off." -ForegroundColor Yellow
} else {
    Write-Host "  ✅ Up-to-date requirement off (branches need not be up to date before merging)." -ForegroundColor Green
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

$RepoSettingsJson = gh api "repos/$Repo" 2>&1 | Out-String
$Security = $null
$RepoSettings = $null
if ($LASTEXITCODE -eq 0) {
    try {
        $RepoSettings = $RepoSettingsJson | ConvertFrom-Json
        $Security = $RepoSettings.security_and_analysis
    } catch { $Security = $null; $RepoSettings = $null }
}
foreach ($Key in $MergeSettings.Keys) {
    $Want = $MergeSettings[$Key]
    $Got  = if ($RepoSettings) { $RepoSettings.$Key } else { $null }
    $Text  = { param($V) if ($V -is [bool]) { "$V".ToLowerInvariant() } else { "$V" } }
    $Shown = if ($null -ne $Got) { & $Text $Got } else { 'unknown' }
    if ($null -ne $Got -and $Got -eq $Want) {
        Write-Host "  ✅ Merge setting ${Key}: $Shown." -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Merge setting ${Key}: $Shown (wanted $(& $Text $Want))." -ForegroundColor Yellow
    }
}
foreach ($Feature in @(
        @{ Key = 'secret_scanning'; Name = 'Secret scanning' },
        @{ Key = 'secret_scanning_push_protection'; Name = 'Push protection' }
    )) {
    $Status = if ($Security) { "$($Security.($Feature.Key).status)" } else { '' }
    if ($Status -eq 'enabled') {
        Write-Host "  ✅ $($Feature.Name) enabled ($($Feature.Key): enabled)." -ForegroundColor Green
    } else {
        $Shown = if ($Status) { $Status } else { 'unknown' }
        Write-Host "  ⚠️  $($Feature.Name) not enabled ($($Feature.Key): $Shown)." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "✅ Done. Verify anytime with:" -ForegroundColor Green
Write-Host "   gh api repos/$Repo/branches/$Branch/protection" -ForegroundColor DarkGray
Write-Host ""
