#Requires -Version 7.0
<#
.SYNOPSIS
    Backlog gate -- the pre-backlog alignment that grants agent:backlog.

.DESCRIPTION
    Kanban library -- loaded by Kanban.psm1. This file owns the Backlog lane: an
    issue lands on the board un-aligned and only earns agent:backlog ("refined,
    architected, planned, ready for processing") once it passes this gate.

    Invoke-Alignment is the conductor (called by align.yml on issue creation and
    by tasks/align.ps1). It runs the three alignment steps in order, then grants
    agent:backlog only when the readiness gate clears:

        Refine       Invoke-Refine        structure body, estimate, priority,
                                           self-grill Agent Brief + open questions
        Architect    Invoke-Architect  blast-radius impact into the body
                                           (Architecture.ps1)
        Plan         Invoke-Plan          implementation plan into the body
        ── gate ──   Test-Readiness       refined + architected + planned and
                                           zero open questions → Set-AgentState
                                           agent:backlog

    Every artefact lives IN the issue body (ADR-011/ADR-014) -- there is no
    .planning/ directory. Processing (Implement → Review → Merge) is a separate,
    human-triggered flow (task runner / task start); see Orchestrator.ps1.
#>

$ErrorActionPreference = 'Stop'
# Module-internal library -- loaded by Kanban.psm1 (which loads Config.ps1 first).
# Not dot-sourced individually; see ADR-013.

# -- Refine (Backlog toll-gate) ------------------------------------------------
function Invoke-Refine {
    param([int]$Number)
    Write-Log "  Refine -- issue #$Number" -Color Yellow

    $issue    = gh issue view $Number --repo $KanbanRepo --json title,body,comments | ConvertFrom-Json
    $template = Get-IssueTemplate

    # Determine what needs work
    $needsBodyRefine = $false
    if ($template) {
        $headings        = $template -split '\r?\n' |
            Where-Object { $_ -match '^\*\*\w' } |
            ForEach-Object { ($_ -split ':')[0] }
        $missing         = @($headings | Where-Object { $issue.body -notmatch [regex]::Escape($_) })
        $needsBodyRefine = $missing.Count -gt 0
    } else {
        $needsBodyRefine = $true
    }

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
        $bodyInstruction = if ($needsBodyRefine -and $template) {
            "REWRITE the body to match this field structure exactly (fill all fields from the raw issue — do not invent requirements):`n`n$template"
        } elseif ($needsBodyRefine) {
            "REWRITE the body with: **Goal**, **Description**, **Requirements** (numbered), **Acceptance Criteria** (bulleted)."
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

        $raw = if ($KanbanEngine -eq 'gemini') {
            Remove-GeminiNoise -Text ($prompt | agy --model $KanbanModel_GeminiFlash 2>&1 | Out-String)
        } else {
            Remove-ClaudeNoise -Text ($prompt | claude --model $KanbanModel_Sonnet 2>&1 | Out-String)
        }
        if ($LASTEXITCODE -ne 0) { throw "Claude refinement failed: $raw" }

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
    # Spawn the Grill-Me protocol against the refined body. The subagent reads
    # the codebase, generates an Agent Brief, populates open/decided questions,
    # and surfaces glossary diffs — see .agents/skills/refine/scripts/grill.ps1.
    $populatedBy = 'self-grill-subagent'
    try {
        Write-Log "  ▶ Self-grill subagent for issue #$Number" -Color DarkGray
        $refreshed   = gh issue view $Number --repo $KanbanRepo --json title,body | ConvertFrom-Json
        $grillResult = Invoke-Grill -Title $refreshed.title -Body $refreshed.body

        if ($grillResult -and $grillResult.agent_brief) {
            Set-AgentBrief -IssueNumber $Number -Brief $grillResult.agent_brief -PopulatedBy $populatedBy

            $open    = @($grillResult.open_questions)
            $decided = @($grillResult.decided_questions)
            Set-PlanningQuestions -IssueNumber $Number -Open $open -Decided $decided

            $decisionCount = 0
            foreach ($q in $open) {
                $url = New-DecisionChildIssue -ParentNumber $Number -ParentTitle $refreshed.title -Question $q
                if ($url) { $decisionCount++ }
            }
            if ($decisionCount -gt 0) {
                $changes += "human:decision children=$decisionCount"
                Add-Comment -Number $Number -Body "· self-grill — $decisionCount human:decision child issue(s) emitted; resolve before backlog entry"
            } else {
                $changes += 'agent-brief written, open_questions=0'
            }
        } else {
            Write-Log "  ⚠️ Self-grill returned no agent_brief — falling back to phase-1 stub provenance." -Color Yellow
            $populatedBy = 'refine (fallback)'
        }
    } catch {
        Write-Log "  ⚠️ Self-grill subagent failed: $_" -Color Yellow
        $populatedBy = 'refine (fallback)'
    }

    # Mark readiness.refined in the issue-carried state block (cross-runtime carrier).
    Set-PlanningReadiness -IssueNumber $Number -Stage 'refined' -StageLabel 'refine' -PopulatedBy $populatedBy

    Add-Comment -Number $Number -Body "· refined — $($changes -join ', ')"
    Write-Log "  Issue #$Number refined: $($changes -join ', ')" -Color Green
}

# ── Plan (Backlog gate, third step) ───────────────────────────────────────────
# Dispatches on issue size:
#   * EPIC (estimate ≥ DecomposeThreshold) — too big to implement directly, so
#     decompose it into child issues via Lean PRD synthesis (Invoke-PlanDecomposition,
#     Plan.ps1). That path owns its own readiness/abort semantics.
#   * ordinary issue — write an ordered implementation plan into the body and mark
#     readiness.planned. Claude-backed; degrades to a placeholder (still setting
#     readiness) so forks without a Claude token can still align — mirrors the
#     self-grill fallback in Invoke-Refine.
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

Write an ordered implementation plan: the concrete steps an engineer (or coding
agent) will take to satisfy every requirement and acceptance criterion, in order.
Reference the files/modules likely to change (use the Architecture Impact section
above if present). Keep it tight — 3 to 8 numbered steps, no preamble, Markdown only.
"@

    $populatedBy = 'plan (claude)'
    $planMd      = $null
    try {
        $planMd = if ($KanbanEngine -eq 'gemini') {
            Remove-GeminiNoise -Text ($prompt | agy --model $KanbanModel_GeminiFlash 2>&1 | Out-String)
        } else {
            Remove-ClaudeNoise -Text ($prompt | claude --model $KanbanModel_Sonnet 2>&1 | Out-String)
        }
        if ($LASTEXITCODE -ne 0 -or -not $planMd.Trim()) { $planMd = $null }
    } catch {
        $planMd = $null
    }
    if (-not $planMd) {
        Write-Log "  ⚠️ Plan: Claude unavailable — writing placeholder, readiness still set." -Color Yellow
        $planMd      = '_Implementation plan to be detailed during the Develop phase (automatic generation unavailable)._'
        $populatedBy = 'plan (fallback)'
    }

    $section = "## Implementation Plan`n`n$($planMd.Trim())"
    $ok = Set-IssueBodySection -IssueNumber $Number `
        -BeginMarker $KanbanPlanBeginMarker -EndMarker $KanbanPlanEndMarker -Markdown $section
    if ($ok) { Write-Log "  Implementation Plan written to issue #$Number body." -Color DarkGray }

    Set-PlanningReadiness -IssueNumber $Number -Stage 'planned' -StageLabel 'plan' -PopulatedBy $populatedBy
    Add-Comment -Number $Number -Body '· planned — implementation plan written to issue body'
    Write-Log "  Issue #$Number — readiness.planned ✓" -Color Green
}
