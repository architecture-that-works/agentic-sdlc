#Requires -Version 7.0
<#
.SYNOPSIS
    AFK runner — dispatch the GHA orchestrator to process EVERY open
    agent:backlog issue in the cloud, then return immediately so the laptop
    can be closed.

.DESCRIPTION
    Dispatches orchestrator.yml (stage=implement, issue_number=0). The workflow
    resolves the oldest agent:backlog issue, runs the full pipeline, and its
    drain step re-dispatches while any agent:backlog issues remain — so a single
    invocation drains the whole queue, one issue at a time (serialised by the
    implement-pipeline concurrency group).

    This is the cloud counterpart to `task hitl` (HITL, local). It does NOT run
    anything in this terminal beyond the dispatch — close the laptop afterwards.

    Pre-flight:
      - Exits cleanly if there are zero open agent:backlog issues.
      - Warns (and confirms, unless -Force) if KANBAN_RUNNER_PROFILE=self-hosted,
        since then a self-hosted runner must be online for the queue to drain.
      - Prints the queue and the Actions URL to watch.

.PARAMETER Force
    Skip the self-hosted confirmation prompt (for non-interactive use).

.EXAMPLE
    task afk             # dispatch the cloud drain, then walk away
    task afk -- -Force   # same, no prompt even on a self-hosted profile
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\orchestrator\Orchestrator.psd1" -Force
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

# ── Pre-flight: is there anything to drain? ──────────────────────────────────
# Capture gh's exit code: a failed read (rate limit, auth, bad repo) must throw,
# never be mistaken for an empty queue and reported as "nothing to drain".
$raw = gh issue list --repo $KanbanRepo `
    --label 'agent:backlog' --state open `
    --json number,title --jq 'sort_by(.number)' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read the agent:backlog queue (gh exited $LASTEXITCODE):`n$raw"
}
$backlog = $raw | ConvertFrom-Json
$count = @($backlog).Count
if ($count -eq 0) {
    Write-Log "No open agent:backlog issues — nothing to drain." -Color Yellow
    exit 0
}

Write-Host ""
Write-Host "  agent:backlog queue — $KanbanRepo  ($count issue$(if ($count -ne 1) { 's' }))" -ForegroundColor Cyan
Write-Host "  $('─' * 60)" -ForegroundColor DarkGray
foreach ($i in $backlog) {
    Write-Host ("  #{0,-4} {1}" -f $i.number, $i.title) -ForegroundColor White
}
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

# ── Dispatch the cloud drain ─────────────────────────────────────────────────
gh workflow run afk.yml --repo $KanbanRepo `
    --field stage=implement --field issue_number=0
if ($LASTEXITCODE -ne 0) { throw "Failed to dispatch afk.yml" }

Write-Log "  🚀 Dispatched — oldest-first drain of $count issue$(if ($count -ne 1) { 's' }) started." -Color Green
Write-Log "  Watch: https://github.com/$KanbanRepo/actions/workflows/afk.yml" -Color Cyan
Write-Host ""
Write-Log "  The drain step re-dispatches until the queue is empty. You can walk away." -Color DarkGray
