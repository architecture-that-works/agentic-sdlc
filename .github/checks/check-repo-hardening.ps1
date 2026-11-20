#Requires -Version 7.0
<#
.SYNOPSIS
    Assert four public-repo safeguards in the template source repo.

.DESCRIPTION
    Exits 0 silently when the .template/ marker directory is absent at the repository root
    (no-op in generated projects). When present, calls four GitHub REST endpoints via gh api
    and prints the owner remediation step for each failing assertion. Exits 1 if any assertion
    fails; exits 0 silently when all pass.

    Required environment: GH_TOKEN (classic PAT with repo scope).

.EXAMPLE
    pwsh .github/checks/check-repo-hardening.ps1
#>

$ErrorActionPreference = 'Stop'

# ── Resolve repo root ──────────────────────────────────────────────────────────

$repoRoot = git rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not in a git repository."
    exit 1
}
$repoRoot = $repoRoot.Trim()

# ── Template-source-repo gate ─────────────────────────────────────────────────
# Exit 0 silently in generated projects where .template/ is absent.

if (-not (Test-Path (Join-Path $repoRoot '.template'))) {
    exit 0
}

# ── Derive owner/repo ─────────────────────────────────────────────────────────

if ($env:GITHUB_REPOSITORY) {
    $nwo = $env:GITHUB_REPOSITORY
} else {
    $nwo = (gh repo view --json nameWithOwner -q .nameWithOwner).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to determine repository. Set GH_TOKEN and retry."
        exit 1
    }
}

$failures = @()

# ── Assertion 1: repo is public ───────────────────────────────────────────────

$repoInfo = gh api "/repos/$nwo" | ConvertFrom-Json
if ($repoInfo.private -eq $true) {
    $failures += "Step 1: Make the repository public (GitHub Settings → General → Danger Zone → Change visibility → Public)."
}

# ── Assertion 2: fork-PR approval policy is all_external_contributors ─────────

$forkPolicy = gh api "/repos/$nwo/actions/permissions/fork-pr-contributor-approval" | ConvertFrom-Json
if ($forkPolicy.approval_policy -ne 'all_external_contributors') {
    $failures += "Step 2: Set Actions → General → 'Approval for running fork pull request workflows' to 'Require approval for all external contributors'."
}

# ── Assertion 3: KANBAN_RUNNER_PROFILE is not self-hosted ────────────────────

$runnerVar = gh api "/repos/$nwo/actions/variables/KANBAN_RUNNER_PROFILE" | ConvertFrom-Json
if ($runnerVar.value -eq 'self-hosted') {
    $failures += "Step 3: Set KANBAN_RUNNER_PROFILE back to 'hosted': gh variable set KANBAN_RUNNER_PROFILE --body hosted"
}

# ── Assertion 4: no self-hosted runner registered ────────────────────────────

$runners = gh api "/repos/$nwo/actions/runners" | ConvertFrom-Json
if ($runners.total_count -ne 0) {
    $failures += "Step 3: Remove all self-hosted runners (GitHub Settings → Actions → Runners)."
}

# ── Result ────────────────────────────────────────────────────────────────────

if ($failures.Count -gt 0) {
    foreach ($msg in $failures) {
        Write-Host "check-repo-hardening: FAIL — $msg"
    }
    exit 1
}

Write-Host "check-repo-hardening: all public-repo safeguards verified — pass"
exit 0
