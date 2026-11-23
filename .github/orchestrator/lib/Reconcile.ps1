#Requires -Version 7.0
<#
    Reconcile.ps1 — recovery of the pipeline's own stuck states (#278).

    Every other recovery path in the orchestrator runs inside the conductor's
    try/catch: a failed stage is retried, a spent usage allowance pauses the issue,
    a rejected review re-implements. A killed process runs no catch. A lost runner,
    a cancelled job, an Actions timeout, or a drain step whose `gh workflow run`
    re-dispatch failed all leave an issue holding a label that claims work nobody
    is doing — and until this file, nothing noticed. Recovery was a human running
    `retry.ps1` after spotting it.

    What counts as stuck is read from $PipelineStates (lib/Config.ps1), not decided
    here: a label whose Holder is 'agent' means the pipeline owes progress, so an
    issue sitting on one with nothing happening is stale. A label held by a human
    — human:decision, human:approval, agent:failed — is never touched, however long
    it waits. That is the whole point of those states.

    Liveness is judged from the issue, not from the Actions API. A live run posts
    `·` progress comments as it works (branch checked out, exploring, writing,
    running tests), and each one moves the issue's updated_at. An agent-held label
    with no activity for StuckAfterMinutes therefore means no runner is on it. This
    needs no run-to-issue mapping — the Actions API has none that is reliable — and
    costs one REST call for the whole repository.

    Re-entry is bounded. Each reconciliation of an issue increments a counter in
    the carrier, reset whenever the issue reaches a different state. Past
    MaxReconcile the warden stops re-dispatching and hands the issue to the owner
    on agent:failed with the history named, so a permanently broken issue cannot be
    re-queued every hour forever.

    Loaded after lib/GitHub.ps1 — it needs the carrier, labels, comments and
    Resume-PausedIssues.
#>

# ── Re-entry ──────────────────────────────────────────────────────────────────

# The one implementation of "start this issue again from where it got to".
# `retry.ps1` calls it, the owner's comment on an agent:failed issue reaches it
# through retry.ps1, and the warden calls it for a state that stalled.
#
# Readiness decides the entry point, not failed_at. A runner killed mid-stage
# never records failed_at, and the old rule ("failed_at is refine/architect/plan →
# refine, else → agent:backlog") then sent an unrefined issue to agent:backlog,
# where the readiness gate in Set-AgentState silently refuses it — leaving the
# issue exactly as stuck as before, with a comment claiming it had been retried.
#
# Returns the stage it re-entered — 'refine' or 'implement' — or '' when it could
# not dispatch, so the caller can report that honestly rather than assume success.
function Restart-Issue {
    param([Parameter(Mandatory)][int]$IssueNumber, [string]$Reason = '')

    $state = Get-IssueState -IssueNumber $IssueNumber
    $why   = if ($Reason) { " ($Reason)" } else { '' }

    # A new round of attempts. The attempt history in the carrier is kept — the
    # next implement prompt reads it, so the retry knows what already failed.
    Reset-AttemptCount -IssueNumber $IssueNumber

    if (Test-Readiness -State $state) {
        # Already at agent:backlog: setting it again changes nothing and so starts
        # nothing — dispatch its implement run, as the warden does.
        if (@(Get-IssueLabel -IssueNumber $IssueNumber) -contains 'agent:backlog') {
            return Start-ImplementRun -IssueNumber $IssueNumber -Reason $Reason
        }
        # Refined, architected and planned: agent:backlog is accepted, and its label
        # event starts implement → review → ship again on top of whatever the
        # feature branch already holds.
        Set-AgentState -IssueNumber $IssueNumber -Label 'agent:backlog'
        Add-Comment -Number $IssueNumber -Body "· restarting from implement$why"
        return 'implement'
    }

    # Not ready: refine → architect → plan has to run before agent:backlog can be
    # granted. Clear any stale pipeline label first — a refine run starts only from
    # the labels StartsRun allows (Test-RunMayStart), and from none.
    foreach ($stale in @(Get-IssueLabel -IssueNumber $IssueNumber |
                         Where-Object { $PipelineStates.Contains($_) })) {
        Set-IssueLabel -Number $IssueNumber -Remove $stale
    }
    $out = gh workflow run afk.yml --repo $KanbanRepo `
        --field stage=refine --field issue_number=$IssueNumber 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not dispatch refine for #${IssueNumber}: $($out.Trim())" -Color Yellow
        return ''
    }
    Add-Comment -Number $IssueNumber -Body "· restarting refine$why"
    return 'refine'
}

# A refine run that finds agent:failed (StartsRun 'restart') re-enters the issue
# through Restart-Issue instead of refining it in place — once. The re-entry is
# recorded in the carrier as a transition marked 'refine from agent:failed', with the
# failed run's error notes beside it, so the new refine reads them in the issue body,
# and as a signal comment. An issue that fails again after one such re-entry is not
# restarted: it goes to human:decision with the notes, and the owner decides.
# Returns the stage Restart-Issue re-entered, or '' when it did not restart.
$KanbanFailedReEntry = 'refine from agent:failed'

function Restart-FailedIssue {
    param([Parameter(Mandatory)][int]$IssueNumber)

    $state = Get-IssueState -IssueNumber $IssueNumber
    $notes = @()
    if ($state -and $state.PSObject.Properties['failed_at'] -and $state.failed_at) { $notes += "Failed at: $($state.failed_at)" }
    if ($state -and $state.PSObject.Properties['failed_reason'] -and $state.failed_reason) { $notes += "Reason: $($state.failed_reason)" }
    foreach ($c in @(Get-SignalComments -IssueNumber $IssueNumber -Prefix '🤖❌' | Select-Object -Last 3)) {
        $notes += $(if ($c.Length -gt 1500) { $c.Substring(0, 1497) + '...' } else { $c })
    }
    $notesText  = if ($notes.Count -gt 0) { $notes -join "`n---`n" } else { '(no error notes recorded)' }
    $notesBlock = "``````text`n$notesText`n``````"

    $earlier = @($state.transitions | Where-Object { $_ -and $_.PSObject.Properties['reason'] -and $_.reason -eq $KanbanFailedReEntry })
    if ($earlier.Count -gt 0) {
        Set-AgentState -IssueNumber $IssueNumber -Label 'human:decision'
        Add-Comment -Number $IssueNumber -Body ("🤖⏸ Needs your decision — this issue failed again after refine was already triggered from agent:failed, so it is not restarted.`n`n" +
            "Error notes:`n`n$notesBlock`n`nComment on this issue with what should change; your comment starts refine again.")
        Write-Log "⏸ Issue #$IssueNumber failed again after a re-entry from agent:failed — waiting on the owner." -Color Yellow
        return ''
    }

    if ($state) {
        # Lanes as the carrier names them: agent:failed rests in the Backlog lane.
        $entry = [pscustomobject]@{
            from      = 'backlog'
            to        = 'backlog'
            reason    = $KanbanFailedReEntry
            notes     = $notesText
            runtime   = Get-RuntimeName
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        $state | Add-Member -NotePropertyName transitions -NotePropertyValue @(@($state.transitions | Where-Object { $_ }) + $entry) -Force
        Set-PlanningState -IssueNumber $IssueNumber -State $state
    }
    Add-Comment -Number $IssueNumber -Body ("🤖🔁 Refine triggered from agent:failed — the issue is re-entered once, with the error notes of the failed run (kept in its carrier for the new refine). " +
        "If it fails again, it waits for your decision instead.`n`n$notesBlock")
    return Restart-Issue -IssueNumber $IssueNumber -Reason $KanbanFailedReEntry
}

# agent:backlog is already the go signal — the label is right and nothing is wrong
# with the issue; the implement job simply never ran, or its re-dispatch from the
# drain step failed. Dispatch it rather than re-setting a label the issue already
# carries, which would produce no `labeled` event and so start nothing.
function Start-ImplementRun {
    param([Parameter(Mandatory)][int]$IssueNumber, [string]$Reason = '')

    $out = gh workflow run afk.yml --repo $KanbanRepo `
        --field stage=implement --field issue_number=$IssueNumber 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not dispatch implement for #${IssueNumber}: $($out.Trim())" -Color Yellow
        return ''
    }
    $why = if ($Reason) { " ($Reason)" } else { '' }
    Add-Comment -Number $IssueNumber -Body "· re-dispatching implement$why"
    return 'implement'
}

# ── Liveness ──────────────────────────────────────────────────────────────────

# Is any AFK run live right now? One global question, and it is enough.
#
# The implement job is a single serial concurrency group (implement-pipeline), so
# at most one issue in the whole repository can be mid-implement or mid-review at
# a time. That makes "is anything running" equivalent to "might this in-flight
# state have a runner on it", with no per-issue correlation — which the Actions
# API cannot give: a run exposes no issue number, so correlating would mean
# reading every run's logs (#278, refine's question 2).
#
# The grace period alone would be probabilistic: a run can be genuinely alive yet
# silent between progress comments, and re-entering it would queue a second
# pipeline behind live work. This check makes the in-flight states safe outright.
#
# Self is excluded — the reconciliation pass is itself an afk.yml run and would
# otherwise always see the pipeline as busy. A failed check reads as busy: never
# re-enter work that might be live.
function Test-PipelineBusy {
    $self = if ($env:GITHUB_RUN_ID) { [long]$env:GITHUB_RUN_ID } else { 0 }
    $raw  = gh api "repos/$KanbanRepo/actions/workflows/afk.yml/runs?per_page=50" `
        --jq "[.workflow_runs[] | select((.status == `"in_progress`" or .status == `"queued`") and .id != $self)] | length" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not check for live AFK runs — assuming the pipeline is busy." -Color Yellow
        return $true
    }
    $count = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$count)) {
        Write-Log "  ⚠️ Unexpected run count '$($raw.Trim())' — assuming the pipeline is busy." -Color Yellow
        return $true
    }
    return $count -gt 0
}

# ── Survey ────────────────────────────────────────────────────────────────────

# Every open issue with the warden's verdict for each. One REST call for the whole
# repository: `gh issue list` goes through GraphQL and the orchestrator is
# GraphQL-bound (ADR-012). The REST /issues collection includes pull requests, so
# anything carrying .pull_request is dropped.
#
# Verdicts:
#   held    a human owes the next move — never touched, however long it waits
#   done    terminal (agent:shipped) — nothing is owed
#   paused  the usage-limit path owns it; Resume-PausedIssues decides when it is due
#   fresh   agent-held, but touched inside the grace period — assume a live runner
#   stuck   agent-held and silent past the grace period — no runner is on it
function Get-StuckIssue {
    param([datetime]$Now = (Get-Date).ToUniversalTime())
    $StuckAfterMinutes = $OrchestratorConfig.StuckAfterMinutes

    $raw = gh api "repos/$KanbanRepo/issues?state=open&per_page=100" `
        --jq '.[] | select(.pull_request == null) | {n: .number, u: .updated_at, l: [.labels[].name]} | @json' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Could not list open issues: $($raw.Trim())" }

    $rows = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($line in @($raw -split '\r?\n' | Where-Object { $_.Trim().StartsWith('{') })) {
        $issue  = $line | ConvertFrom-Json
        # An issue carries exactly one pipeline label (ADR-015); take the first in
        # $PipelineStates order so a transient double-label is still decided, never skipped.
        $label  = @(@($issue.l) | Where-Object { $PipelineStates.Contains($_) })[0]
        $idle   = [int]($Now - ([datetime]$issue.u).ToUniversalTime()).TotalMinutes

        # No pipeline label means refine has not claimed the issue yet. That is the
        # agent's move — a new issue is refined on its `opened` event — so a silent
        # unlabelled issue is a refine job that died before it could label anything.
        $holder   = if ($label) { $PipelineStates[$label].Holder   } else { 'agent'   }
        $recovery = if ($label) { $PipelineStates[$label].Recovery } else { 'restart' }

        $verdict = if     ($holder -eq 'human')       { 'held'   }
                   elseif ($holder -eq 'none')        { 'done'   }
                   elseif ($recovery -eq 'resume')    { 'paused' }
                   elseif ($idle -lt $StuckAfterMinutes) { 'fresh' }
                   else                               { 'stuck'  }

        $rows.Add([pscustomobject]@{
            Number      = [int]$issue.n
            Label       = if ($label) { $label } else { '(none)' }
            Holder      = $holder
            Recovery    = $recovery
            IdleMinutes = $idle
            Verdict     = $verdict
        })
    }
    return $rows.ToArray()
}

# ── The hourly pass ───────────────────────────────────────────────────────────

# How many times this issue has been reconciled at its current state. The count
# lives in the carrier beside the attempt history, and resets whenever the issue
# reaches a different state — progress, however small, earns a fresh budget.
function Get-ReconcileCount {
    param([pscustomobject]$State, [string]$Label)
    if (-not $State) { return 0 }
    $at = if ($State.PSObject.Properties['reconciled_from']) { "$($State.reconciled_from)" } else { '' }
    if ($at -ne $Label) { return 0 }
    if ($State.PSObject.Properties['reconcile_count']) { return [int]$State.reconcile_count }
    return 0
}

function Set-ReconcileCount {
    param([int]$IssueNumber, [pscustomobject]$State, [string]$Label, [int]$Count)
    if (-not $State) { return }
    $State | Add-Member -NotePropertyName reconcile_count -NotePropertyValue $Count -Force
    $State | Add-Member -NotePropertyName reconciled_from -NotePropertyValue $Label -Force
    $State | Add-Member -NotePropertyName reconciled_at   -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Set-PlanningState -IssueNumber $IssueNumber -State $State
}

# The warden's pass over the whole repository. Called hourly by afk.yml's schedule
# job, and runnable by hand (`reconcile.ps1`) to see the verdicts without waiting.
#
# -WhatIf reports what it would do and changes nothing — the intended way to check
# the grace period against real activity before trusting it unattended.
function Invoke-Reconciliation {
    param([switch]$WhatIf)

    $StuckAfterMinutes = $OrchestratorConfig.StuckAfterMinutes
    $MaxReconcile      = $OrchestratorConfig.MaxReconcile

    $rows = @(Get-StuckIssue)
    Write-Log "⚖ Reconciliation — $($rows.Count) open issue(s); stuck after ${StuckAfterMinutes}m, cap $MaxReconcile." -Color Cyan

    # agent:paused has its own time gate (the engine's reported reset time), which
    # Resume-PausedIssues owns. The warden only decides that it should run.
    $paused = @($rows | Where-Object { $_.Verdict -eq 'paused' })
    if ($paused.Count -gt 0 -and -not $WhatIf) { Resume-PausedIssues }

    $acted = [System.Collections.Generic.List[pscustomobject]]::new()
    $stuck = @($rows | Where-Object { $_.Verdict -eq 'stuck' })

    # One liveness check for the whole pass, and only when an in-flight state is
    # actually in question — agent:backlog and an unlabelled issue are dispatched
    # either way, because both entry points queue behind live work rather than
    # racing it (the implement-pipeline group is serial; refine's group is per issue).
    $busy = $false
    if (@($stuck | Where-Object { $_.Recovery -eq 'restart' -and $_.Label -ne '(none)' }).Count -gt 0) {
        $busy = Test-PipelineBusy
        if ($busy) { Write-Log "  ⏳ An AFK run is live — leaving in-flight states to it this pass." -Color DarkGray }
    }

    foreach ($row in $stuck) {
        $reason = "no activity for $($row.IdleMinutes) min at $($row.Label)"

        # A live run owns the in-flight states. Deferring costs nothing — the next
        # pass is an hour away — and must not spend the issue's re-entry budget,
        # or a long legitimate run would exhaust it and fail a healthy issue.
        if ($busy -and $row.Recovery -eq 'restart' -and $row.Label -ne '(none)') {
            Write-Log "  ⏸ #$($row.Number) $($row.Label) — a run is live; deferred to the next pass." -Color DarkGray
            $row | Add-Member -NotePropertyName Action -NotePropertyValue 'deferred' -Force
            $acted.Add($row)
            continue
        }

        $state  = Get-IssueState -IssueNumber $row.Number
        $count  = (Get-ReconcileCount -State $state -Label $row.Label) + 1

        # Reported before the cap is applied below, so -WhatIf names the decision the
        # real pass would take — including giving up — rather than always predicting
        # a re-entry.
        if ($WhatIf) {
            $would = if ($count -gt $MaxReconcile) { 'would-give-up' } else { "would-$($row.Recovery)" }
            Write-Log "  [WhatIf] #$($row.Number) $($row.Label) — $would (attempt $count/$MaxReconcile)." -Color DarkGray
            $row | Add-Member -NotePropertyName Action -NotePropertyValue $would -Force
            $acted.Add($row)
            continue
        }

        if ($count -gt $MaxReconcile) {
            # Re-entry is not working. Stop, and say exactly what was tried — an issue
            # the pipeline cannot move is the owner's call, not something to re-queue
            # on the hour forever.
            Set-AgentFailedState -IssueNumber $row.Number -FailedAt $row.Label `
                -Reason "Reconciliation gave up after $MaxReconcile attempts at $($row.Label)."
            Add-Comment -Number $row.Number -Body ("🤖❌ Stuck at **$($row.Label)** and re-entry is not working — needs you`n`n" +
                "The pipeline found this issue idle at ``$($row.Label)`` and restarted it $MaxReconcile time(s); " +
                "each time it stalled there again. It has stopped retrying rather than re-queue every hour.`n`n" +
                "The **Attempts** section lists every attempt. Fix what you can hands-on, or comment with what " +
                "should change — your comment starts a fresh round.")
            Write-Log "  ⛔ #$($row.Number) gave up at $($row.Label) after $MaxReconcile reconciliation(s)." -Color Red
            $row | Add-Member -NotePropertyName Action -NotePropertyValue 'gave-up' -Force
            $acted.Add($row)
            continue
        }

        # Record the attempt before acting. Re-entry may crash the same way the run
        # it is replacing did; an uncounted attempt would loop forever.
        Set-ReconcileCount -IssueNumber $row.Number -State $state -Label $row.Label -Count $count

        $entered = switch ($row.Recovery) {
            'implement' { Start-ImplementRun -IssueNumber $row.Number -Reason $reason }
            'restart'   { Restart-Issue      -IssueNumber $row.Number -Reason $reason }
            default     { '' }
        }

        if ($entered) {
            Write-Log "  ▶ #$($row.Number) $($row.Label) → re-entered at $entered (attempt $count/$MaxReconcile)." -Color Green
            $row | Add-Member -NotePropertyName Action -NotePropertyValue "re-entered:$entered" -Force
        } else {
            Write-Log "  ⚠️ #$($row.Number) $($row.Label) — could not re-enter; retrying next pass." -Color Yellow
            $row | Add-Member -NotePropertyName Action -NotePropertyValue 'dispatch-failed' -Force
        }
        $acted.Add($row)
    }

    Write-ReconcileSummary -Rows $rows -Acted $acted.ToArray() -Mode $(if ($WhatIf) { 'survey' } else { 'actions' })
    return $acted.ToArray()
}

# A table of every issue inspected and the verdict for each, in the GHA job
# summary. A quiet hour must be observably quiet: without this, "nothing was
# stuck" and "the job never ran" look identical in the Actions UI.
function Write-ReconcileSummary {
    param([object[]]$Rows, [object[]]$Acted, [string]$Mode = 'actions')

    $sb = [System.Text.StringBuilder]::new()
    # The hourly job surveys first (to decide whether to install the engine) and
    # then acts, so the summary carries two tables. Naming the pass keeps them from
    # reading as a contradiction.
    $null = $sb.AppendLine($(if ($Mode -eq 'survey') { '## Reconciliation — survey' } else { '## Reconciliation — actions taken' }))
    $null = $sb.AppendLine()
    if (@($Rows).Count -eq 0) {
        $null = $sb.AppendLine('No open issues.')
    } else {
        $null = $sb.AppendLine("$(@($Acted).Count) of $(@($Rows).Count) open issue(s) needed reconciling.")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('| Issue | State | Holder | Idle (min) | Verdict | Action |')
        $null = $sb.AppendLine('|---|---|---|---|---|---|')
        foreach ($r in $Rows) {
            $action = if ($r.PSObject.Properties['Action']) { $r.Action } else { '—' }
            $null = $sb.AppendLine("| #$($r.Number) | ``$($r.Label)`` | $($r.Holder) | $($r.IdleMinutes) | $($r.Verdict) | $action |")
        }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        $sb.ToString() | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    Write-Host $sb.ToString()
}
