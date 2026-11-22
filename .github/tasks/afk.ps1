#Requires -Version 7.0
<#
.SYNOPSIS
    AFK backfill — dispatch afk.yml (stage=refine, issue 0) so the cloud refines
    every open issue with no agent:* label, then return so the laptop can be closed.

.DESCRIPTION
    Normally nothing needs triggering: afk.yml refines an issue when it is opened
    or when the owner comments, and the agent:backlog label that refine grants
    starts implement → review → ship on its own. This command covers issues that
    predate that, or that were never refined. Issues that need a human end on
    human:decision (answer in a comment), a human:approval hold (merge the PR) or
    agent:failed (comment to retry), each with a comment saying what is needed.

    Pre-flight:
      - Warns (and confirms, unless -Force) if KANBAN_RUNNER_PROFILE=self-hosted,
        since then a self-hosted runner must be online for the queue to drain.
      - Prints what will be refined and the Actions URL to watch.

.PARAMETER Force
    Skip the self-hosted confirmation prompt (for non-interactive use).

.PARAMETER Root
    The repository root whose .env is read. Default: the repository this script is in.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/afk.ps1             # dispatch the cloud backfill refine, then walk away
    pwsh -NoProfile -File .github/tasks/afk.ps1 -Force   # same, no prompt even on a self-hosted profile
#>
param([switch]$Force, [string]$Root = '')

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Settings.ps1"
Import-Settings -Root $Root
if (-not (Get-Module Orchestrator)) { Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" }
$KanbanRepo = (Get-OrchestratorContext).Repo

# ── Pre-flight: GraphQL budget ───────────────────────────────────────────────
# Reading the backlog (gh issue list) AND the whole cloud pipeline drive the
# GraphQL API, which throttles separately from REST (5000 pts/hr each).
# `rate_limit` is a free endpoint, so check it first and fail with a precise
# reset time rather than a raw gh error if the budget is gone.
$gql = gh api rate_limit --jq '.resources.graphql | "\(.remaining) \(.reset)"' 2>$null
if ($gql -match '^(\d+)\s+(\d+)$') {
    $gqlRemaining = [int]$Matches[1]
    $gqlReset     = [DateTimeOffset]::FromUnixTimeSeconds([int]$Matches[2]).ToLocalTime().ToString('HH:mm')
    if ($gqlRemaining -eq 0) {
        throw "GraphQL rate limit exhausted (resets ~$gqlReset). Reading the backlog and the cloud pipeline both need GraphQL — retry after reset."
    }
    if ($gqlRemaining -lt 500) {
        Write-Log "  ⚠️ GraphQL budget low ($gqlRemaining left, resets ~$gqlReset). The cloud pipeline may stall on board updates until then." -Color Yellow
    }
}

# ── Pre-flight: what will be processed? ──────────────────────────────────────
# Capture gh's exit code: a failed read (rate limit, auth, bad repo) must throw,
# never be mistaken for an empty queue and reported as "nothing to do".
$raw = gh issue list --repo $KanbanRepo --state open `
    --json number,title,labels --limit 200 --jq 'sort_by(.number)' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read open issues (gh exited $LASTEXITCODE):`n$raw"
}
$open      = @($raw | ConvertFrom-Json)
$unaligned = @($open | Where-Object { -not (@($_.labels.name) | Where-Object { $_ -like 'agent:*' }) })
if ($unaligned.Count -eq 0) {
    Write-Log "Every open issue is already refined or in progress — no dispatch needed." -Color Yellow
    exit 0
}

Write-Host ""
Write-Host "  $KanbanRepo — $($unaligned.Count) issue(s) to refine" -ForegroundColor Cyan
Write-Host "  $('─' * 60)" -ForegroundColor DarkGray
foreach ($i in $unaligned) { Write-Host ("  #{0,-4} {1}" -f $i.number, $i.title) -ForegroundColor White }
Write-Host ""

# ── Where will it run? ───────────────────────────────────────────────────────
# `gh api` is more portable than `gh variable get` across gh versions.
# ($profile is a PowerShell automatic variable — use a distinct name.)
$runnerProfile = gh api "repos/$KanbanRepo/actions/variables/KANBAN_RUNNER_PROFILE" `
    --jq '.value' 2>$null
if ($runnerProfile -eq 'self-hosted') {
    Write-Log "  ⚠️ KANBAN_RUNNER_PROFILE=self-hosted — the queue runs on a self-hosted runner." -Color Yellow
    Write-Log "     Ensure that runner is registered and online, or switch to hosted:" -Color Yellow
    Write-Log "     gh variable set KANBAN_RUNNER_PROFILE --body 'hosted'" -Color Yellow
    if (-not $Force) {
        if ((Read-Host "  Dispatch to the self-hosted runner anyway? (y/N)") -notmatch '^(y|yes)$') {
            Write-Log "Aborted." -Color DarkGray
            exit 0
        }
    }
} else {
    Write-Log "  Runner: hosted (ubuntu-latest) — laptop can be closed after dispatch." -Color Green
}

# ── Dispatch the backfill refine ─────────────────────────────────────────────
gh workflow run afk.yml --repo $KanbanRepo `
    --field stage=refine --field issue_number=0
if ($LASTEXITCODE -ne 0) { throw "Failed to dispatch afk.yml" }

Write-Log "  🚀 Dispatched — each issue that comes out ready starts implementing on its own." -Color Green
Write-Log "  Watch: https://github.com/$KanbanRepo/actions/workflows/afk.yml" -Color Cyan
Write-Host ""
Write-Log "  You can walk away. What needs you: label:human:decision, label:human:approval, label:agent:failed." -Color DarkGray
