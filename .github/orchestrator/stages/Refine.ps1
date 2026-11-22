#Requires -Version 7.0
<#
.SYNOPSIS
    Refine stage — structure the issue, self-grill it, and ask the owner what the
    codebase cannot answer.

.DESCRIPTION
    Orchestrator library — loaded by Orchestrator.psm1, whose conductor runs
    refine → architect → plan (Invoke-Orchestration -From refine) and grants
    agent:backlog when the readiness gate clears (refined + architected + planned,
    zero open questions).

        Invoke-Refine        structure the body, estimate and priority, self-grill:
                             Agent Brief plus open / decided questions
        Request-Decisions    ask the open questions in the issue (human:decision)
        Invoke-AnswerCheck   read the owner's reply back into decided_questions
        Invoke-Plan          the implementation plan (epics: Plan.ps1 decomposes)

    Every artefact lives in the issue body (ADR-011, ADR-014).
#>

$ErrorActionPreference = 'Stop'
# Module-internal library -- loaded by Orchestrator.psm1 (which loads Config.ps1 first).
# Not dot-sourced individually; see ADR-013.

# -- Refine (Backlog toll-gate) ------------------------------------------------
function Invoke-Refine {
    param([int]$Number)
    Write-Log "  Refine -- issue #$Number" -Color Yellow

    $issue    = gh issue view $Number --repo $KanbanRepo --json title,body,comments | ConvertFrom-Json
    # The issue template is the one source of an issue's headings (#369). A missing or
    # empty template throws here, out of Invoke-Refine, before anything is written.
    $template = Get-IssueTemplate

    # Determine what needs work: the body is missing a heading when it lacks **<Name>**.
    $missing         = @(@(Get-IssueHeadings).Name | Where-Object { "$($issue.body)" -notmatch [regex]::Escape("**$_**") })
    $needsBodyRefine = $missing.Count -gt 0

    # Short-circuit: a prior pass that completed refinement posts a "· refined —" comment
    # AND injects the AGENT-BRIEF marker via the self-grill subagent. Both must
    # be present — the marker proves the self-grill phase ran on the current
    # carrier (per ADR-011), the comment proves estimate/priority were addressed.
    $hasRefinedMarker = @($issue.comments | Where-Object { $_.body -like '* refined*' }).Count -gt 0
    $hasBriefMarker   = $issue.body -like "*$KanbanBriefBeginMarker*"
    if (-not $needsBodyRefine -and $hasRefinedMarker -and $hasBriefMarker) {
        Write-Log "  Issue already fully refined (body + Agent Brief present) — skipping." -Color DarkGray
        return
    }

    # Estimate and Priority are GitHub Project fields — not labels.
    # Get-ProjectFieldValues returns $null for two distinct cases:
    #   1. gh call failed (rate limit, network, missing scope) — we DON'T know the current values
    #   2. Issue is not on the project board — we can't write back anyway
    # In either case, refining estimate/priority via LLM would either overwrite
    # known-good manual values (case 1) or write to a board the issue isn't on
    # (case 2). Treat null as "skip field refine" — body refine still runs.
    $projectFields = Get-ProjectFieldValues -IssueNumber $Number
    if ($null -eq $projectFields) {
        Write-Log "  ⚠️ Could not read project fields — skipping estimate/priority refine (any manual values preserved)." -Color Yellow
        $needsEstimate = $false
        $needsPriority = $false
    } else {
        $needsEstimate = -not ($null -ne $projectFields.estimate -and "$($projectFields.estimate)" -ne '')
        $needsPriority = -not $projectFields.priority
    }

    # If body/estimate/priority are all set, skip the structured-output Claude
    # pass but still drive the self-grill phase so the Agent Brief gets
    # populated. The grill runs in its own try block at the bottom of this
    # function — fall through to it.
    $needsClaudeStructureCall = $needsBodyRefine -or $needsEstimate -or $needsPriority
    $parsed = $null

    if ($needsClaudeStructureCall) {
        $bodyInstruction = if ($needsBodyRefine) {
            "REWRITE the body to match this field structure exactly (fill all fields from the raw issue — do not invent requirements):`n`n$template"
        } else {
            "Body is already structured — copy it unchanged into the 'body' field."
        }

        $estimateInstruction = if ($needsEstimate) {
            'ASSIGN estimate: Fibonacci SP — 1=trivial single-file, 2=small bounded, 3=moderate multi-file, 5=clear multi-component, 8=complex architectural, 13=large multi-area, 21=epic requiring human collaboration.'
        } else {
            'Estimate already set — output null.'
        }

        # Discover the actual priority option names configured in this project.
        $priorityOpts = @([System.Environment]::GetEnvironmentVariables('Process').Keys) |
            Where-Object { $_ -match '^KANBAN_PRIORITY_OPT_' } |
            ForEach-Object { $_ -replace '^KANBAN_PRIORITY_OPT_', '' } |
            Sort-Object
        $priorityOptsStr = if ($priorityOpts) { $priorityOpts -join ', ' } else { 'P0, P1, P2, P3, P4' }

        $priorityInstruction = if ($needsPriority) {
            "ASSIGN priority using exactly one of the project's configured values: $priorityOptsStr"
        } else {
            'Priority already set — output null.'
        }

        $prompt = @"
You are refining a GitHub issue so it is fully specified before implementation begins.

ISSUE TITLE: $($issue.title)
CURRENT BODY:
$($issue.body)

TASKS:
1. Body: $bodyInstruction
2. Estimate: $estimateInstruction
3. Priority: $priorityInstruction

Return ONLY valid JSON — no markdown fences, no explanation:
{"body":"<full issue body>","estimate":<number or null>,"priority":"<one of the allowed values or null>"}
"@

        $run = Invoke-EngineTask -Task 'Refine' -Prompt $prompt -Label 'Refine body'
        if ($run.Outcome -ne 'finished') { throw "The engine's refinement failed: $($run.Cause)`n$($run.Output)" }
        $raw = $run.Reply

        $json = $raw.Trim()
        if ($json -match '(?s)```(?:json)?\s*(\{.+\})\s*```') { $json = $Matches[1] }
        $parsed = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $parsed) {
            Write-Log "  ⚠️ Refine: could not parse structured-output response — falling through to self-grill." -Color Yellow
        }

        if ($parsed -and $needsBodyRefine -and $parsed.body) {
            $tmp = New-TemporaryFile
            try {
                $parsed.body.Trim() | Out-File $tmp.FullName -Encoding utf8
                gh issue edit $Number --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-Null
            } finally {
                Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
            }
        }

        if ($parsed -and $needsEstimate -and $null -ne $parsed.estimate -and $parsed.estimate -ne 'null') {
            Set-ProjectEstimate -IssueNumber $Number -Estimate ([int]$parsed.estimate)
        }

        if ($parsed -and $needsPriority -and $parsed.priority -and $parsed.priority -ne 'null') {
            Set-ProjectPriority -IssueNumber $Number -Priority $parsed.priority
        }
    }

    $changes = @()
    if ($needsBodyRefine -and $parsed -and $parsed.body)                                                  { $changes += 'body structured' }
    if ($needsEstimate -and $parsed -and $null -ne $parsed.estimate -and $parsed.estimate -ne 'null')     { $changes += "estimate=$($parsed.estimate)" }
    if ($needsPriority -and $parsed -and $parsed.priority -and $parsed.priority -ne 'null')               { $changes += "priority=$($parsed.priority)" }

    # ── Self-grill subagent — AFK alignment phase (issue #85) ─────────────────
    # The subagent reads the codebase, writes the Agent Brief and splits the issue's
    # decisions into decided and open questions. Without it nobody has checked what
    # the owner must decide, so a failure fails this refine attempt (the conductor
    # retries it, then marks the issue agent:failed) — it never marks the issue refined.
    Write-Log "  ▶ Self-grill subagent for issue #$Number" -Color DarkGray
    $refreshed   = gh issue view $Number --repo $KanbanRepo --json title,body | ConvertFrom-Json
    $grillResult = Invoke-Grill -Title $refreshed.title `
        -Body ($refreshed.body + (Format-OwnerComments -IssueNumber $Number))
    if (-not $grillResult.agent_brief) { throw 'Self-grill subagent returned no Agent Brief.' }

    Set-AgentBrief -IssueNumber $Number -Brief $grillResult.agent_brief -PopulatedBy 'self-grill-subagent'
    $open    = @($grillResult.open_questions)
    $decided = @($grillResult.decided_questions)
    # Open questions stay IN this issue — the conductor renders them into the body
    # and asks the owner in a comment; no separate decision issues.
    Set-PlanningQuestions -IssueNumber $Number -Open $open -Decided $decided
    $changes += "open_questions=$($open.Count)"

    # Mark readiness.refined in the issue-carried state block (cross-runtime carrier).
    Set-PlanningReadiness -IssueNumber $Number -Stage 'refined' -StageLabel 'refine' -PopulatedBy 'self-grill-subagent'

    Add-Comment -Number $Number -Body "· refined — $($changes -join ', ')"
    Write-Log "  Issue #$Number refined: $($changes -join ', ')" -Color Green
}

# ── Asking the owner ──────────────────────────────────────────────────────────
# Puts the open questions to the owner IN the issue: stamps questions_asked_at (only
# later comments count as answers), renders the "## Decisions" body section, labels
# the issue human:decision and posts one 🤖⏸ comment listing what is needed.
function Request-Decisions {
    param([int]$IssueNumber, [int]$Answered = 0)

    $state = Get-IssueState -IssueNumber $IssueNumber
    if ($null -eq $state) { return }
    $open = @($state.open_questions | Where-Object { $_ })
    $state | Add-Member -NotePropertyName questions_asked_at `
        -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
    Set-PlanningState   -IssueNumber $IssueNumber -State $state
    Set-DecisionSection -IssueNumber $IssueNumber -State $state
    Set-AgentState -IssueNumber $IssueNumber -Label 'human:decision'

    $head = if ($Answered -gt 0) { "🤖⏸ Thanks — $Answered answer(s) recorded. Still needed:" }
            else { "🤖⏸ Needs your decision — $($open.Count) question(s) before this can be built:" }
    Add-Comment -Number $IssueNumber -Body "$head`n`n$(Format-DecisionQuestions -Questions $open)`n`n$KanbanReplyGuide"
}

# ── Answer check: the owner's reply, read back from the issue ────────────────
# The owner answers open questions with a plain comment on the issue (edits to the
# body count too — the whole body is part of the prompt). This reads the owner's
# comments posted since the questions were last asked and has the model judge each
# question: answered (the decision is recorded in decided_questions, attributed to
# the owner), or still open with a follow-up saying exactly what is missing. It
# never invents an answer. No new comment → no model call.
#
# Returns [pscustomobject]@{ Evaluated; Answered; Open; Error }.
function Invoke-AnswerCheck {
    param([int]$IssueNumber)

    $state = Get-IssueState -IssueNumber $IssueNumber
    $open  = if ($state -and $state.open_questions) { @($state.open_questions | Where-Object { $_ }) } else { @() }
    if ($open.Count -eq 0) {
        return [pscustomobject]@{ Evaluated = $false; Answered = 0; Open = 0; Error = $null }
    }
    $since = if ($state.PSObject.Properties['questions_asked_at']) { $state.questions_asked_at } else { $null }
    # A failed read is an error, never "no reply" — otherwise the owner's answer is
    # dropped silently and the issue waits forever.
    try   { $comments = @(Get-OwnerComments -IssueNumber $IssueNumber -Since $since -Strict) }
    catch { return [pscustomobject]@{ Evaluated = $false; Answered = 0; Open = $open.Count; Error = $_.Exception.Message } }
    if ($comments.Count -eq 0) {
        return [pscustomobject]@{ Evaluated = $false; Answered = 0; Open = $open.Count; Error = $null }
    }

    $issue = gh issue view $IssueNumber --repo $KanbanRepo --json title,body | ConvertFrom-Json
    $qText = for ($i = 0; $i -lt $open.Count; $i++) {
        $q = $open[$i]
        $line = "Q$($i + 1). $($q.text)`n    A (recommended): $($q.decision)"
        $letter = [int][char]'B'
        foreach ($alt in @($q.alternatives | Where-Object { $_ })) { $line += "`n    $([char]$letter): $alt"; $letter++ }
        if ($q.PSObject.Properties['follow_up'] -and $q.follow_up) { $line += "`n    Already asked as follow-up: $($q.follow_up)" }
        $line
    }
    $cText = $comments | ForEach-Object { "[$($_.login), $($_.created_at)]`n$($_.body)" }

    $prompt = @"
You check whether the owner of a GitHub issue has answered its open questions.

ISSUE TITLE: $($issue.title)
ISSUE BODY:
$($issue.body)

OPEN QUESTIONS:
$($qText -join "`n")

OWNER'S NEW COMMENTS (oldest first):
$($cText -join "`n---`n")

The owner was asked to reply with "ok" (accept every recommendation, option A), an option per
question such as "1B" or "2C", or their own words such as "2: only for src/" — or a mix.

RULES:
- A question is "answered" only when the comments (or the issue body) give a clear decision
  an engineer can act on. Restate that decision in one or two sentences: the chosen option's
  full text, adjusted by anything the owner added.
- "ok", "agree", "all recommended" and similar accept option A for every question the reply
  does not otherwise address.
- If a reply is ambiguous, defers the choice, contradicts itself, or opens a trade-off the owner
  has not settled, the question stays "open": write a short follow_up saying exactly what is
  still needed, offering the concrete options.
- If the replies raise a new decision, add it to new_questions with your recommendation and
  two genuine alternatives.
- Never invent an answer the owner did not give.

Return ONLY JSON, no fences:
{"answers":[{"id":1,"status":"answered","decision":"..."},{"id":2,"status":"open","follow_up":"..."}],"new_questions":[{"text":"...","recommendation":"...","alternatives":["...","..."]}]}
"@

    $run    = Invoke-EngineTask -Task 'Refine' -Prompt $prompt -Label 'Answer check'
    $raw    = if ($run.Outcome -eq 'finished') { $run.Reply } else { "$($run.Cause)`n$($run.Output)" }
    $parsed = $null
    if ($run.Outcome -eq 'finished') {
        try { $parsed = (ConvertFrom-ClaudeJsonResponse -Raw $raw) | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    }
    if (-not $parsed -or $null -eq $parsed.answers) {
        return [pscustomobject]@{ Evaluated = $false; Answered = 0; Open = $open.Count; Error = "answer check returned no usable result: $($raw.Trim())" }
    }

    $author    = $comments[-1].login
    $now       = (Get-Date).ToUniversalTime().ToString('o')
    $stillOpen = [System.Collections.Generic.List[object]]::new()
    $decided   = [System.Collections.Generic.List[object]]::new()
    foreach ($q in @($state.decided_questions)) { if ($q) { $decided.Add($q) } }

    for ($i = 0; $i -lt $open.Count; $i++) {
        $q   = $open[$i]
        $ans = @($parsed.answers) | Where-Object { [int]$_.id -eq ($i + 1) } | Select-Object -First 1
        if ($ans -and $ans.status -eq 'answered' -and $ans.decision) {
            $decided.Add([pscustomobject]@{
                text = $q.text; raised_by = $q.raised_by; decided_by = $author
                decision = "$($ans.decision)".Trim(); timestamp = $now
            })
        } else {
            if ($ans -and $ans.follow_up) {
                $q | Add-Member -NotePropertyName follow_up -NotePropertyValue "$($ans.follow_up)".Trim() -Force
            }
            $stillOpen.Add($q)
        }
    }
    foreach ($nq in @($parsed.new_questions)) {
        if ($nq -and $nq.text) {
            $stillOpen.Add([pscustomobject]@{
                text = "$($nq.text)".Trim(); raised_by = 'answer-check'; decided_by = $null
                decision = "$($nq.recommendation)".Trim(); timestamp = $null
                alternatives = @($nq.alternatives | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
            })
        }
    }
    $answered = $decided.Count - @($state.decided_questions | Where-Object { $_ }).Count

    $state | Add-Member -NotePropertyName open_questions     -NotePropertyValue @($stillOpen) -Force
    $state | Add-Member -NotePropertyName decided_questions  -NotePropertyValue @($decided)   -Force
    $state | Add-Member -NotePropertyName questions_asked_at -NotePropertyValue $now          -Force
    Set-PlanningState -IssueNumber $IssueNumber -State $state
    return [pscustomobject]@{ Evaluated = $true; Answered = $answered; Open = $stillOpen.Count; Error = $null }
}

# ── Plan (Backlog gate, third step) ───────────────────────────────────────────
# Dispatches on issue size:
#   * EPIC (estimate ≥ DecomposeThreshold) — too big to implement directly, so
#     decompose it into child issues via Lean PRD synthesis (Invoke-PlanDecomposition,
#     Plan.ps1). That path owns its own readiness/abort semantics.
#   * ordinary issue — write an ordered implementation plan into the body and mark
#     readiness.planned. A failure throws: the conductor's attempt loop retries it.
# The planned paths that $OrchestratorConfig.WritablePaths does not cover — same
# -like glob matching Invoke-CommitAndPR applies at commit time (#223). Moved here,
# earlier: an issue whose plan only touches e.g. .github/ used to be granted
# agent:backlog, implemented, and aborted at staging three times before landing on
# agent:failed, burning the whole retry budget on a predictable outcome.
# The one definition of "this path is outside the agent write allowlist". The plan
# stage calls it on the planned paths to warn early; the ship stage calls it on the
# PR's actual diff to decide whether the PR is a proposal (Get-ProposedFiles). Two
# copies of this predicate would be the same shape of bug as #252/#266/#275.
#
# An empty or missing allowlist returns every path: with nothing declared writable,
# nothing is auto-mergeable, which is the fail-safe direction.
function Get-UnwritablePaths {
    param([string[]]$Paths)
    $writable = @($OrchestratorConfig.WritablePaths)
    return @($Paths | Where-Object {
        $p = "$_".Trim()
        $p -and @($writable | Where-Object { $p -like $_ }).Count -eq 0
    })
}

function Invoke-Plan {
    param([int]$Number)
    Write-Log "  Plan — issue #$Number" -Color Yellow

    # Epic → hand off to decomposition (it sets readiness.planned on success, and
    # deliberately withholds it on a duplicate/zero-children abort so the gate stays
    # closed).
    $estimate = Get-IssueEstimate -IssueNumber $Number
    if ($estimate -ge $OrchestratorConfig.DecomposeThreshold) {
        Write-Log "  Estimate $estimate ≥ $($OrchestratorConfig.DecomposeThreshold) — epic; decomposing into child issues." -Color DarkGray
        $null = Invoke-PlanDecomposition -IssueNumber $Number
        return
    }

    $issue = gh issue view $Number --repo $KanbanRepo --json title,body | ConvertFrom-Json

    $prompt = @"
You are writing a concise implementation plan for a GitHub issue that has already
been refined and had its architectural impact analysed.

ISSUE TITLE: $($issue.title)
ISSUE BODY:
$($issue.body)
$(Format-OwnerComments -IssueNumber $Number)
Write an ordered implementation plan: the concrete steps an engineer (or coding
agent) will take to satisfy every requirement and acceptance criterion, in order.
Reference the files/modules likely to change (use the Architecture Impact section
above if present). Keep it tight — 3 to 8 numbered steps, no preamble.

Return ONLY valid JSON — no fences, no prose — matching this shape:
{
  "plan_markdown": "<the ordered implementation plan, Markdown, no preamble>",
  "paths_to_modify": ["<every relative repo path the plan will create or change>"]
}
"@

    # No plan, no readiness: a failure fails this attempt and the conductor retries.
    $run = Invoke-EngineTask -Task 'Plan' -Prompt $prompt -Label 'Plan'
    $raw = $run.Reply
    if ($run.Outcome -ne 'finished' -or -not "$raw".Trim()) {
        $why = if ($run.Cause) { $run.Cause } else { 'an empty reply' }
        throw "Plan: the engine returned no implementation plan ($why):`n$("$($run.Output)`n$raw".Trim())"
    }
    $json = $raw.Trim()
    if ($json -match '(?s)```(?:json)?\s*(\{.+\})\s*```') { $json = $Matches[1] }
    try {
        $result = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Plan: the engine's response was not valid JSON:`n$json"
    }
    $planMd = "$($result.plan_markdown)".Trim()
    if (-not $planMd) {
        throw "Plan: the engine returned no plan_markdown."
    }

    $section = "## Implementation Plan`n`n$planMd"
    $ok = Set-IssueBodySection -IssueNumber $Number `
        -BeginMarker $KanbanPlanBeginMarker -EndMarker $KanbanPlanEndMarker -Markdown $section
    if ($ok) { Write-Log "  Implementation Plan written to issue #$Number body." -Color DarkGray }

    Set-PlanningReadiness -IssueNumber $Number -Stage 'planned' -StageLabel 'plan' -PopulatedBy "plan ($($OrchestratorConfig.Engine))"

    # Writable-path gate: a plan that touches a path outside WritablePaths cannot be
    # auto-implemented. readiness.planned still goes true (the plan was written) —
    # the injected open question is what blocks Test-Readiness and routes to
    # Request-Decisions, the same human:decision flow an unresolved question uses.
    # Paths outside WritablePaths are a *proposal*, not a question (#285). The agent
    # implements them like anything else; ship then holds the PR at human:approval
    # with the files and their diffstat named, and the owner merges or rejects. The
    # PR is never auto-merged, so the change is a proposal the owner approves.
    #
    # This used to inject an open question, which was unanswerable by construction:
    # Invoke-Plan regenerates it from the plan on every run, so answering it re-ran
    # architect and plan, which re-created it. #273 looped three times that way, and
    # the question's own recommended answer was "implement it hands-on" — a question
    # whose best outcome is "the pipeline cannot help you" should not be asked.
    $plannedPaths = @($result.paths_to_modify | Where-Object { $_ })
    $proposed     = Get-UnwritablePaths -Paths $plannedPaths

    # Get-IssueState returns $null when the carrier cannot be parsed. Skip the write
    # rather than crash the stage: ship re-derives the proposal from the PR diff, so
    # an unwritten note costs an early warning, not the hold itself.
    $state = Get-IssueState -IssueNumber $Number
    if ($state) {
        # Drop the legacy question so issues the old gate parked unblock on their next
        # plan run instead of needing the carrier edited by hand.
        $open  = @($state.open_questions | Where-Object { $_ })
        $kept  = @($open | Where-Object { "$($_.text)" -notlike '*outside the agent-writable allowlist*' })
        $dirty = $kept.Count -ne $open.Count

        if ($proposed.Count -gt 0) {
            $state | Add-Member -NotePropertyName proposed_paths -NotePropertyValue $proposed -Force
            $dirty = $true
        }
        if ($dirty) {
            $state.open_questions = $kept
            Set-PlanningState -IssueNumber $Number -State $state
        }
    } else {
        Write-Log "  ⚠️ Carrier unreadable on #${Number} — skipping the proposal note; ship still derives it from the PR." -Color Yellow
    }
    if ($proposed.Count -gt 0) {
        Write-Log "  Plan proposes $($proposed.Count) path(s) outside the write allowlist — the PR will be held for approval." -Color DarkGray
    }

    if ($proposed.Count -gt 0) {
        Add-Comment -Number $Number -Body ("🤖 Proposal — this plan changes files outside the agent write allowlist`n`n" +
            (($proposed | ForEach-Object { "- ``$_``" }) -join "`n") +
            "`n`nThe agent will implement them, but the PR will **not** be merged automatically: it is held at " +
            "``human:approval`` with the exact diff for you to approve or reject. Nothing here reaches the default branch without you.")
    }

    Add-Comment -Number $Number -Body '· planned — implementation plan written to issue body'
    Write-Log "  Issue #$Number — readiness.planned ✓" -Color Green
}
