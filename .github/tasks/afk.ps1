#Requires -Version 7.0
<#
.SYNOPSIS
    AFK runner — the one trigger. Dispatches afk.yml (stage=all) so the cloud
    refines every un-aligned issue and then processes everything that is ready,
    and returns immediately so the laptop can be closed.

.DESCRIPTION
    stage=all refines every open issue with no agent:* label that is not a
    human:decision, then — if anything carries agent:backlog — dispatches the
    implement drain: the oldest agent:backlog issue runs implement → review →
    ship, and the drain re-dispatches until the queue is empty (serialised by the
    implement-pipeline concurrency group). Issues that need a human end on
    human:decision questions, a human:approval hold, or agent:failed, each with
    a comment saying what is needed.

    This is the cloud counterpart to `task hitl` (HITL, local). It does NOT run
    anything in this terminal beyond the dispatch — close the laptop afterwards.

    Pre-flight:
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
Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" -Force
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
$backlog   = @($open | Where-Object { @($_.labels.name) -contains 'agent:backlog' })
$unaligned = @($open | Where-Object {
    $names = @($_.labels.name)
    -not ($names | Where-Object { $_ -like 'agent:*' }) -and ($names -notcontains 'human:decision')
})
if ($backlog.Count -eq 0 -and $unaligned.Count -eq 0) {
    Write-Log "Nothing to refine and nothing ready — no dispatch needed." -Color Yellow
    exit 0
}

Write-Host ""
Write-Host "  $KanbanRepo — $($unaligned.Count) to refine, $($backlog.Count) ready to implement" -ForegroundColor Cyan
Write-Host "  $('─' * 60)" -ForegroundColor DarkGray
foreach ($i in $unaligned) { Write-Host ("  refine  #{0,-4} {1}" -f $i.number, $i.title) -ForegroundColor White }
foreach ($i in $backlog)   { Write-Host ("  ready   #{0,-4} {1}" -f $i.number, $i.title) -ForegroundColor White }
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

# ── Dispatch: refine everything, then drain ──────────────────────────────────
gh workflow run afk.yml --repo $KanbanRepo `
    --field stage=all --field issue_number=0
if ($LASTEXITCODE -ne 0) { throw "Failed to dispatch afk.yml" }

Write-Log "  🚀 Dispatched — refine, then an oldest-first drain of everything that is ready." -Color Green
Write-Log "  Watch: https://github.com/$KanbanRepo/actions/workflows/afk.yml" -Color Cyan
Write-Host ""
Write-Log "  You can walk away. What needs you: label:human:decision, label:human:approval, label:agent:failed." -Color DarkGray
