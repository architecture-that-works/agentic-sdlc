#Requires -Version 7.0
<#
    Kanban — the AFK orchestrator library (ADR-013).

    Import-Module Orchestrator exposes the orchestration functions; the module's private
    $Kanban* variables and any internal param() defaults stay in module scope and
    never reach the caller, so the dot-source scope leak that once ran the pipeline
    against issue #0 is impossible by construction.

    The thin trigger scripts in ../tasks/ (run/start/runner/retry) import this
    module and call its functions — chiefly Get-OrchestratorContext and
    Invoke-Orchestration.

    Load order (dependencies first):

        Config        settings, run context (Get-OrchestratorContext), model selection
        Util          logging, runtime, lock, review counter, ISSUES.md reader
        GitHub        labels, lanes, comments, board, branches, issue-body state
        ../Claude     generic Claude helpers (Invoke-ClaudeStreaming, commit msg)
        _grill        refine self-grill subagent (Invoke-Grill)
        Refine        Backlog gate — Invoke-Refine + Invoke-Plan + Invoke-Alignment
        Architecture  Backlog gate, Architect step — blast radius
        Plan          Backlog gate, Plan decomposition — Lean PRD + child issues
        Implement     Implementing lane — develop → PR
        Review        Review lane — self-review loop
        Merge         Merged lane — squash-merge → CONTEXT.md
        Orchestrator  conducts the agent:* state machine across the lanes
#>

$ErrorActionPreference = 'Stop'

# lib — settings, run context, logging, GitHub/board access
. "$PSScriptRoot\lib\Config.ps1"
. "$PSScriptRoot\lib\Util.ps1"
. "$PSScriptRoot\lib\GitHub.ps1"

# engines — LLM provider adapters, selected by KANBAN_ENGINE
. "$PSScriptRoot\engines\Claude.ps1"
. "$PSScriptRoot\engines\Gemini.ps1"

. "$PSScriptRoot\lib\Grill.ps1"

# stages — one file per stage, in pipeline order
. "$PSScriptRoot\stages\Refine.ps1"
. "$PSScriptRoot\stages\Architect.ps1"
. "$PSScriptRoot\stages\Plan.ps1"
. "$PSScriptRoot\stages\Implement.ps1"
. "$PSScriptRoot\stages\Review.ps1"
. "$PSScriptRoot\stages\Ship.ps1"


# -- The conductor ------------------------------------------------------------
# Sequences the six stages for one issue and owns every lane transition. This is
# the only component that decides what runs next (ADR-015).
#
#   -From refine     refine -> architect -> plan, stopping at agent:backlog
#                    ("ready" is not "go" -- ADR-014)
#   -From implement  implement -> review -> ship
#
# Any error, or exhausted review retries, lands the issue on agent:failed.
#
# There is no Export-ModuleMember call: the public surface is declared in
# Orchestrator.psd1 FunctionsToExport, which is data rather than logic and lets
# PowerShell resolve commands without loading the module (ADR-015).

function Invoke-Orchestration {
    param([int]$IssueNumber, [ValidateSet('refine','implement')] [string]$From = 'implement', [int]$MaxRetries = -1, [switch]$Force)

    $ctx = Get-OrchestratorContext               # run context: repo, default branch, retries
    if ($MaxRetries -lt 0) { $MaxRetries = $ctx.MaxRetries }

    # Fail-fast engine validation
    Assert-EngineReady

    # Prevent two concurrent instances from processing the same issue.
    if (-not (Acquire-OrchestratorLock -IssueNumber $IssueNumber)) {
        Write-Log "  ⏳ Issue #$IssueNumber is locked by another process — skipping." -Color Yellow
        return
    }

    $stashed = $false
    $currentStage = $From

    try {
        $meta = gh issue view $IssueNumber --repo $ctx.Repo --json title,labels,state | ConvertFrom-Json

        if ($From -eq 'refine') {
            Write-Log "━━━ Orchestrator (Refine): issue #$IssueNumber — $($meta.title)" -Color Cyan
            $labels = @($meta.labels.name)
            if ($meta.state -ne 'OPEN') {
                Write-Log "  Issue #$IssueNumber is $($meta.state) — skipping alignment." -Color DarkGray
                return $false
            }
            if ($labels -contains 'agent:backlog') {
                Write-Log "  Issue #$IssueNumber already agent:backlog — alignment already granted." -Color DarkGray
                return $true
            }
            if ($labels -contains 'human:decision') {
                Write-Log "  Issue #$IssueNumber is a human decision — skipping alignment." -Color DarkGray
                return $false
            }

            try {
                $currentStage = 'refine'
                Invoke-Refine    -Number      $IssueNumber
                $currentStage = 'architect'
                Invoke-Architect -IssueNumber $IssueNumber
                $currentStage = 'plan'
                Invoke-Plan      -Number      $IssueNumber
            } catch {
                Set-AgentFailedState -IssueNumber $IssueNumber -FailedAt $currentStage -Reason $_.Exception.Message
                Add-Comment -Number $IssueNumber -Body "🤖❌ Alignment Failed`n``````text`n`$_`n``````"
                Write-Log "❌ Alignment error for issue #$IssueNumber : `$_" -Color Red
                return $false
            }

            $state = Get-IssueState -IssueNumber $IssueNumber
            if (Test-Readiness -State $state) {
                Set-AgentState -IssueNumber $IssueNumber -Label 'agent:backlog'
                Add-Comment -Number $IssueNumber -Body "🤖✅ Aligned — refined, architected, planned, zero open questions. Queued in Backlog (agent:backlog); run ``task runner`` or ``task start`` to process."
                Write-Log "✅ Issue #$IssueNumber aligned — agent:backlog granted." -Color Green
                return $true
            }

            $open = if ($state -and $state.open_questions) { @($state.open_questions).Count } else { 0 }
            Add-Comment -Number $IssueNumber -Body "🤖⏸ Alignment incomplete — $open open question(s) need a human decision before this issue can enter the backlog. Resolve the linked human:decision issue(s), record the answer in ``decided_questions[]``, then re-run ``task align ISSUE=$IssueNumber``."
            Write-Log "⏸ Issue #$IssueNumber NOT aligned — readiness gate unmet (open questions=$open). agent:backlog withheld." -Color Yellow
            return $false
        }

        Write-Log "━━━ Orchestrator (Implement): issue #$IssueNumber — $($meta.title)" -Color Cyan

        # ── backlog → implementing ────────────────────────────────────────────
        Set-AgentState -IssueNumber $IssueNumber -Label 'agent:implementing'

        $stashOut = git stash 2>&1
        $stashed  = $stashOut -notmatch 'No local changes'

        $currentStage = 'implement'
        $implementResult = Invoke-Implement -IssueNumber $IssueNumber -Force:$Force

        if ($null -eq $implementResult) {
            # Implement signalled "already satisfied" — branch has no commits ahead of
            # the default branch (typical for tracker/coordinator issues whose work
            # was delivered by previously-merged child PRs). Mark merged, close,
            # skip the review/merge stages.
            Clear-IssueReviewCount -IssueNumber $IssueNumber
            Set-AgentState -IssueNumber $IssueNumber -Label 'agent:shipped'
            gh issue close $IssueNumber --repo $ctx.Repo --reason completed 2>&1 | Out-Null
            Write-Log "🎉 Issue #$IssueNumber complete — already implemented; closed without PR." -Color Green
            return
        }

        $branch = Get-BranchName -Number $IssueNumber -Title $meta.title
        $prList = gh pr list --head $branch --json number --limit 1 | ConvertFrom-Json
        if ($prList.Count -eq 0) { throw "No PR found for branch $branch after implement stage." }
        $prNum = $prList[0].number

        # ── implementing → review loop (up to MaxRetries) ─────────────────────
        # Read the CUMULATIVE review count — persists across stall recovery and GHA reruns.
        $cyclesDone = Get-IssueReviewCount -IssueNumber $IssueNumber
        $approved   = $false

        while ($cyclesDone -lt $MaxRetries) {
            Write-Log "  Review cycle $($cyclesDone + 1) / $MaxRetries" -Color DarkGray
            $currentStage = 'review'
            $approved = Invoke-Review -IssueNumber $IssueNumber -PRNumber $prNum
            $cyclesDone++
            Set-IssueReviewCount -IssueNumber $IssueNumber -Count $cyclesDone

            if ($approved) { break }

            if ($cyclesDone -lt $MaxRetries) {
                Write-Log "  Review rejected — re-running implement (cycle $($cyclesDone + 1)/$MaxRetries)..." -Color Yellow
                Invoke-Implement -IssueNumber $IssueNumber -Force | Out-Null
            }
        }

        # ── exhausted retries → failed ────────────────────────────────────────
        if (-not $approved) {
            Clear-IssueReviewCount -IssueNumber $IssueNumber
            Set-AgentFailedState -IssueNumber $IssueNumber -FailedAt $currentStage -Reason "Max retries reached ($cyclesDone/$MaxRetries review cycles)"
            Add-Comment -Number $IssueNumber -Body "🤖❌ Orchestrator Error`n`nMax retries reached ($cyclesDone/$MaxRetries review cycles). Manual intervention required."
            Write-Log "⛔ Gave up after $cyclesDone cycles for issue #$IssueNumber." -Color Red
            return
        }

        # ── review → merged ───────────────────────────────────────────────────
        Clear-IssueReviewCount -IssueNumber $IssueNumber
        $currentStage = 'ship'
        $merged = Invoke-Ship -IssueNumber $IssueNumber -PRNumber $prNum -Approved

        # Invoke-Ship returns $false when it holds a human:approval issue at agent:reviewing rather
        # than merging. Report that honestly — claiming "complete" for work still
        # awaiting a human merge is the same class of false signal as a drain run
        # exiting 0 while the issue it processed ended agent:failed.
        if ($false -eq $merged) {
            Write-Log "⏸ Issue #$IssueNumber implemented and held at review — merge PR #$prNum to complete." -Color Yellow
        } else {
            Write-Log "🎉 Issue #$IssueNumber complete." -Color Green
        }

    } catch {
        # ── any error → failed ────────────────────────────────────────────────
        Clear-IssueReviewCount -IssueNumber $IssueNumber
        Set-AgentFailedState -IssueNumber $IssueNumber -FailedAt $currentStage -Reason $_.Exception.Message
        $errBlock = Format-ErrorBlock -Raw "$_"
        Add-Comment -Number $IssueNumber -Body "🤖❌ Orchestrator Error`n`n$errBlock"
        Write-Log "❌ Orchestrator error for issue #$IssueNumber : $_" -Color Red
    } finally {
        Release-OrchestratorLock
        if ($stashed) { git stash pop 2>&1 | Out-Null }

        # Always return to a clean, origin-synced default branch so the next issue starts fresh.
        $default = $ctx.DefaultBranch
        $curr    = git rev-parse --abbrev-ref HEAD 2>$null

        if ($curr -and $curr -ne $default) {
            $dirty = git status --porcelain 2>$null
            if ($dirty) {
                git stash push --include-untracked --quiet `
                    -m "auto: pre-branch-switch from issue #$IssueNumber orchestrator" 2>$null
            }
            Write-Log "  ↩ Returning to $default (feature branch '$curr' preserved for human review)." -Color DarkGray
            git checkout --quiet $default 2>$null
        }
        git fetch --quiet origin $default 2>$null
        git reset --hard --quiet "origin/$default" 2>$null
    }
}
