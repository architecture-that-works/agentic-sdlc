#Requires -Version 7.0
<#
    Orchestrator — the pipeline module (ADR-013, ADR-015).

    Import-Module exposes the functions declared in Orchestrator.psd1; the private
    $Kanban* variables and module-internal functions stay in module scope, so the
    dot-source scope leak that once ran the pipeline against issue #0 is impossible
    by construction. The runnables in ../tasks/ and afk.yml import it and call
    Get-OrchestratorContext and Invoke-Orchestration.

    Load order (dependencies first):

        lib/Config     settings, run context (Get-OrchestratorContext), the
                       $PipelineStates label table, model selection
        lib/Util       logging, runtime, lock, ISSUES.md reader, engine ping, usage limit
        lib/GitHub     labels, lanes, comments, board, issue-body carrier sections
        lib/Reconcile  re-entry (Restart-Issue) and the hourly warden over stuck states
        engines/       Claude and Gemini adapters (streaming, commit messages)
        lib/Grill      refine's self-grill subagent (Invoke-Grill)
        stages/        Refine, Architect, Plan, Implement, Review, Ship
        this file      Invoke-Orchestration, the conductor
#>

$ErrorActionPreference = 'Stop'

# lib — settings, run context, logging, GitHub/board access
. "$PSScriptRoot\lib\Config.ps1"
. "$PSScriptRoot\lib\Util.ps1"
. "$PSScriptRoot\lib\GitHub.ps1"

# engines — LLM provider adapters, selected by KANBAN_ENGINE
. "$PSScriptRoot\engines\Claude.ps1"
. "$PSScriptRoot\engines\Gemini.ps1"

. "$PSScriptRoot\lib\Reconcile.ps1"
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
#   -From refine     refine -> architect -> plan. Grants agent:backlog when nothing
#                    waits on the owner (the label then starts implement in afk.yml);
#                    otherwise asks in the issue and labels it human:decision
#   -From implement  implement -> review -> ship
#
# A failure is retried up to MaxRetries attempts per round, each recorded in the
# issue's Attempts section; only an exhausted round lands the issue on agent:failed.
#
# There is no Export-ModuleMember call: the public surface is declared in
# Orchestrator.psd1 FunctionsToExport, which is data rather than logic and lets
# PowerShell resolve commands without loading the module (ADR-015).

function Invoke-Orchestration {
    param([int]$IssueNumber, [ValidateSet('refine','implement','comment')] [string]$From = 'implement', [int]$MaxRetries = -1, [switch]$Force)

    $ctx = Get-OrchestratorContext               # run context: repo, default branch, retries
    if ($MaxRetries -lt 0) { $MaxRetries = $ctx.MaxRetries }

    # Fail-fast engine validation. A spent usage allowance pauses the issue instead of
    # failing it; the hourly resume job picks it up again.
    try {
        Assert-EngineReady
    } catch {
        if ("$($_.Exception.Message)" -like 'USAGE-LIMIT|*') {
            $until = ([datetime](("$($_.Exception.Message)" -split '\|', 2)[1])).ToUniversalTime()
            Suspend-ForUsageLimit -IssueNumber $IssueNumber -Stage $From -Until $until
            return $false
        }
        throw
    }

    # Prevent two concurrent instances from processing the same issue.
    if (-not (Acquire-OrchestratorLock -IssueNumber $IssueNumber)) {
        Write-Log "  ⏳ Issue #$IssueNumber is locked by another process — skipping." -Color Yellow
        return
    }

    $stashed = $false
    $currentStage = $From

    try {
        $meta = gh issue view $IssueNumber --repo $ctx.Repo --json title,labels,state | ConvertFrom-Json

        # ── comment router — central dispatch for every owner comment ─────────
        # Reads the live pipeline label and routes via OnComment in $PipelineStates.
        # Runs before refine/implement so the comment job in afk.yml has one entry point.
        if ($From -eq 'comment') {
            $liveLabels   = @(Get-IssueLabel -IssueNumber $IssueNumber)
            $currentLabel = @($liveLabels | Where-Object { $PipelineStates.Contains($_) }) | Select-Object -First 1
            $onComment    = if ($currentLabel -and $PipelineStates.ContainsKey($currentLabel)) {
                $PipelineStates[$currentLabel].OnComment
            } else {
                'refine'
            }
            Write-Log "  Comment router: label='$currentLabel' → OnComment='$onComment'" -Color DarkGray

            switch ($onComment) {
                'refine' {
                    $From = 'refine'
                    # fall through to the refine block below
                }
                'retry' {
                    $stage = Restart-Issue -IssueNumber $IssueNumber -Reason 'owner comment'
                    if (-not $stage) {
                        Add-Comment -Number $IssueNumber -Body "🤖⚠️ Could not restart issue #$IssueNumber — see the warning above."
                    }
                    return $stage
                }
                'revise' {
                    $branch = Get-BranchName -Number $IssueNumber -Title $meta.title
                    $prList = gh pr list --head $branch --repo $ctx.Repo --json number --limit 1 2>$null | ConvertFrom-Json
                    if ($null -eq $prList -or $prList.Count -eq 0) {
                        Add-Comment -Number $IssueNumber -Body "· no open PR found for this issue — comment noted, but no revision started"
                        return $false
                    }
                    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:implementing'
                    $From = 'implement'
                    # fall through to the implement block below
                }
                'ack' {
                    Add-Comment -Number $IssueNumber -Body "· comment noted"
                    return $true
                }
                default {
                    Write-Log "  Comment on #$IssueNumber in state '$currentLabel' — skipped (OnComment='')." -Color DarkGray
                    return $true
                }
            }
        }

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
            if (@($labels | Where-Object { $_ -in @('agent:implementing', 'agent:reviewing', 'agent:shipped') }).Count -gt 0) {
                Write-Log "  Issue #$IssueNumber is already past refine — skipping alignment." -Color DarkGray
                return $false
            }

            # A planned issue on human:approval is a PR held for the owner's merge: it
            # carries no agent:* label (#225), and a comment on it must not re-plan it.
            # An owner's human:approval on a new, unplanned issue is a hold request and
            # is refined as usual (Set-AgentState keeps the request in the carrier).
            if ($labels -contains 'human:approval') {
                $held = Get-IssueState -IssueNumber $IssueNumber
                if ($held -and $held.readiness.planned.done) {
                    Write-Log "  Issue #$IssueNumber is held for the owner's merge — skipping alignment." -Color DarkGray
                    return $false
                }
            }

            $null = Add-IssueToBoard -IssueNumber $IssueNumber

            # The owner's reply first. An issue that is refined and waiting on decisions
            # only needs its new comments judged against the open questions; with no new
            # owner comment there is nothing to do, and no model is called.
            $state   = Get-IssueState -IssueNumber $IssueNumber
            $waiting = $state -and $state.readiness.refined.done -and
                       @($state.open_questions | Where-Object { $_ }).Count -gt 0
            if ($waiting) {
                $check = Invoke-AnswerCheck -IssueNumber $IssueNumber
                if ($check.Error) {
                    $until = Test-EngineUsageLimit
                    if ($until) { Suspend-ForUsageLimit -IssueNumber $IssueNumber -Stage 'refine' -Until $until; return $false }
                    Add-Comment -Number $IssueNumber -Body "🤖⚠️ Could not check your reply — comment again to retry.`n``````text`n$($check.Error)`n``````"
                    return $false
                }
                if (-not $check.Evaluated) {
                    Write-Log "⏸ Issue #$IssueNumber waits on $($check.Open) decision(s); no new reply from the owner." -Color Yellow
                    return $false
                }
                if ($check.Open -gt 0) {
                    Request-Decisions -IssueNumber $IssueNumber -Answered $check.Answered
                    return $false
                }
                # Every question answered: fall through, so architect and plan re-run with
                # the decisions (refine itself short-circuits — the Agent Brief exists).
            }

            # Refine failures (model or tool errors) get the same attempt budget as
            # implementation, recorded in the issue the same way.
            $attempt = if ($state -and $state.PSObject.Properties['attempt_count']) { [int]$state.attempt_count } else { 0 }
            while ($true) {
                try {
                    $currentStage = 'refine'
                    Invoke-Refine    -Number      $IssueNumber
                    $currentStage = 'architect'
                    Invoke-Architect -IssueNumber $IssueNumber
                    $currentStage = 'plan'
                    Invoke-Plan      -Number      $IssueNumber
                    break
                } catch {
                    $reason = $_.Exception.Message
                    $until  = Test-EngineUsageLimit
                    if ($until) { Suspend-ForUsageLimit -IssueNumber $IssueNumber -Stage 'refine' -Until $until; return $false }
                    $attempt++
                    Add-FailedAttempt -IssueNumber $IssueNumber -Stage $currentStage -Reason $reason -Attempt $attempt -Max $MaxRetries
                    if ($attempt -ge $MaxRetries) {
                        Set-AgentFailedState -IssueNumber $IssueNumber -FailedAt $currentStage -Reason $reason
                        Add-Comment -Number $IssueNumber -Body "🤖❌ Refine failed after $attempt attempts at $currentStage — needs you. Every attempt is listed in the issue's **Attempts** section; comment on this issue to retry.`n``````text`n$reason`n``````"
                        Write-Log "❌ Alignment error for issue #$IssueNumber : $reason" -Color Red
                        return $false
                    }
                    Write-Log "  🔁 Refine attempt $attempt/$MaxRetries failed at $currentStage — retrying." -Color Yellow
                }
            }
            Reset-AttemptCount -IssueNumber $IssueNumber

            $state = Get-IssueState -IssueNumber $IssueNumber
            if (Test-Readiness -State $state) {
                Set-DecisionSection -IssueNumber $IssueNumber -State $state
                Set-AgentState -IssueNumber $IssueNumber -Label 'agent:backlog'   # replaces human:decision
                Add-Comment -Number $IssueNumber -Body "🤖✅ Ready — refined, architected and planned, with nothing waiting on you. Implementation starts automatically (agent:backlog)."
                Write-Log "✅ Issue #$IssueNumber aligned — agent:backlog granted." -Color Green
                return $true
            }

            Request-Decisions -IssueNumber $IssueNumber
            Write-Log "⏸ Issue #$IssueNumber NOT aligned — waiting on the owner's decision(s)." -Color Yellow
            return $false
        }

        Write-Log "━━━ Orchestrator (Implement): issue #$IssueNumber — $($meta.title)" -Color Cyan

        # ── backlog → implementing ────────────────────────────────────────────
        Set-AgentState -IssueNumber $IssueNumber -Label 'agent:implementing'
        $commitBefore = git rev-parse HEAD 2>$null

        $stashOut = git stash 2>&1
        $stashed  = $stashOut -notmatch 'No local changes'

        # One budget of $MaxRetries attempts per round covers every failure after
        # agent:backlog — an implement error, failing tests, a review rejection, red CI
        # on the PR, a rebase conflict. A failed attempt is recorded in the issue
        # (Add-FailedAttempt) and the next one re-implements on top of the existing
        # branch with that history in its prompt. The count lives in the issue, so a
        # lost runner resumes the round rather than restarting it.
        $state    = Get-IssueState -IssueNumber $IssueNumber
        $attempt  = if ($state -and $state.PSObject.Properties['attempt_count']) { [int]$state.attempt_count } else { 0 }
        $retrying = $attempt -gt 0 -or @($state.attempts | Where-Object { $_ }).Count -gt 0

        while ($true) {
            $currentStage = 'implement'
            try {
                $implementResult = Invoke-Implement -IssueNumber $IssueNumber -Force:($Force -or $retrying)

                if ($null -eq $implementResult) {
                    # No code changes: either a question-answer (revision path with
                    # approval_required) or a tracker issue whose work already landed.
                    $state = Get-IssueState -IssueNumber $IssueNumber
                    if ($state -and $state.PSObject.Properties['approval_required'] -and $state.approval_required) {
                        # Owner asked a question — the agent answered it without new commits.
                        # Post the answer (last 🤖 signal comment) and return to human:approval.
                        $latestSignal = gh issue view $IssueNumber --repo $ctx.Repo --json comments `
                            --jq '[.comments[] | select(.body | startswith("🤖"))] | last | .body' 2>&1 | Out-String
                        $answerBody = if ($LASTEXITCODE -eq 0 -and $latestSignal.Trim() -and $latestSignal.Trim() -ne 'null') {
                            $latestSignal.Trim()
                        } else {
                            '(The agent analysed the request but produced no code changes.)'
                        }
                        Add-Comment -Number $IssueNumber -Body "🤖 Question answered — no code changes needed.`n`n$answerBody"
                        Set-AgentState -IssueNumber $IssueNumber -Label 'human:approval'
                        Write-Log "⏸ Issue #$IssueNumber — no commits; answered question and returned to human:approval." -Color Yellow
                        Reset-AttemptCount -IssueNumber $IssueNumber
                        return $false
                    }
                    # Normal tracker-issue case: branch already up-to-date, ship immediately.
                    Reset-AttemptCount -IssueNumber $IssueNumber
                    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:shipped'
                    gh issue close $IssueNumber --repo $ctx.Repo --reason completed 2>&1 | Out-Null
                    Write-Log "🎉 Issue #$IssueNumber complete — already implemented; closed without PR." -Color Green
                    return
                }

                $branch = Get-BranchName -Number $IssueNumber -Title $meta.title
                $prList = gh pr list --head $branch --json number --limit 1 | ConvertFrom-Json
                if ($prList.Count -eq 0) { throw "No PR found for branch $branch after implement stage." }
                $prNum = $prList[0].number

                $currentStage = 'review'
                if (-not (Invoke-Review -IssueNumber $IssueNumber -PRNumber $prNum)) {
                    throw 'Review rejected the implementation — the latest 🤖❌ Review Rejected comment lists what to fix.'
                }

                $currentStage = 'ship'
                $merged = Invoke-Ship -IssueNumber $IssueNumber -PRNumber $prNum
                Reset-AttemptCount -IssueNumber $IssueNumber

                # Invoke-Ship returns $false when it holds the issue at human:approval
                # rather than merging — report that honestly.
                if ($false -eq $merged) {
                    Write-Log "⏸ Issue #$IssueNumber implemented and held at review — merge PR #$prNum to complete." -Color Yellow
                } else {
                    Write-Log "🎉 Issue #$IssueNumber complete." -Color Green
                }
                return
            } catch {
                $reason = $_.Exception.Message
                # A spent usage allowance is not the agent's failure: pause, count nothing.
                $until = Test-EngineUsageLimit
                if ($until) { Suspend-ForUsageLimit -IssueNumber $IssueNumber -Stage 'implement' -Until $until; return }
                $attempt++
                Add-FailedAttempt -IssueNumber $IssueNumber -Stage $currentStage -Reason $reason -Attempt $attempt -Max $MaxRetries
                if ($attempt -ge $MaxRetries) {
                    Set-AgentFailedState -IssueNumber $IssueNumber -FailedAt $currentStage -Reason $reason
                    $errBlock = Format-ErrorBlock -Raw $reason
                    Add-Comment -Number $IssueNumber -Body ("🤖❌ Failed after $attempt attempts — needs you`n`n" +
                        "The last attempt failed at **$currentStage**:`n`n$errBlock`n`n" +
                        "Every attempt is listed in the issue's **Attempts** section. Fix it hands-on, or explain what " +
                        "should change, then comment on this issue (for example ""retry"", or your guidance) — that " +
                        "starts a new round of $MaxRetries attempts with your comment in the agent's instructions.")
                    Write-Log "⛔ Issue #$IssueNumber failed after $attempt attempts at $currentStage." -Color Red
                    return
                }
                $first = ("$reason" -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 1)
                Add-Comment -Number $IssueNumber -Body "🤖🔁 Attempt $attempt/$MaxRetries failed at **$currentStage** — $first`n`nRetrying: the next attempt re-implements with this failure in context."
                Write-Log "  🔁 Attempt $attempt/$MaxRetries failed at $currentStage — retrying." -Color Yellow
                $retrying = $true
                Set-AgentState -IssueNumber $IssueNumber -Label 'agent:implementing'
            }
        }

    } catch {
        # ── any error → failed ────────────────────────────────────────────────
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
