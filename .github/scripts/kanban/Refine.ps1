#Requires -Version 7.0
<#
.SYNOPSIS
    Backlog gate -- Refine: make an issue ready for processing.

.DESCRIPTION
    Kanban library -- loaded by Kanban.psm1. Invoke-Refine is the toll-gate for
    the Backlog lane: agent:backlog means "refined and ready for processing".

    Structures the issue body against the ISSUES.md template, assigns estimate +
    priority, runs the self-grill alignment subagent (Agent Brief, open/decided
    questions, HITL child issues), and records readiness flags in the
    issue-carried state (ADR-011). The architect/plan readiness stubs live here.

    NOTE: today Invoke-Implement also calls Invoke-Refine as a thin safety pass
    at the start of the Implementing lane. The intent is for refinement to gate
    Backlog entry -- see memory project_pipeline_lane_scripts; that is future work.
#>

$ErrorActionPreference = 'Stop'
# Module-internal library -- loaded by Kanban.psm1 (which loads Config.ps1 first).
# Not dot-sourced individually; see ADR-013.

# -- Refine (Backlog toll-gate) ------------------------------------------------
function Invoke-Refine {
    param([int]$Number)
    Write-Log "  Refine -- issue #$Number" -Color Yellow
    Set-PipelineState -IssueNumber $Number -Phase 'refining'

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

        $raw = $prompt | claude --model $KanbanModel_Sonnet 2>&1 | Out-String
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

            $hitlCount = 0
            foreach ($q in $open) {
                $url = New-HitlChildIssue -ParentNumber $Number -ParentTitle $refreshed.title -Question $q
                if ($url) { $hitlCount++ }
            }
            if ($hitlCount -gt 0) {
                $changes += "HITL children=$hitlCount"
                Add-Comment -Number $Number -Body "· self-grill — $hitlCount HITL child issue(s) emitted; resolve before backlog entry"
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

# ── Phase A.5 / A.6 stubs — write readiness flags into the issue-carried state ─
# Architect and Plan stages are stubbed for phase 1: they record the readiness
# flag with provenance ('<stage> (phase-1 stub)') so the readiness gate can
# clear. Phase 2 will swap in real architect/plan logic without changing the
# state contract.

function Invoke-Architect {
    param([int]$Number)
    Write-Log "  Architect readiness stub for issue #$Number" -Color Yellow

    # Append a Markdown section to the issue body if not already present.
    $body = gh issue view $Number --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $body -notmatch '(?m)^##\s*Architecture\s*$') {
        $section = "`n`n## Architecture`n`n_phase-1 stub — populated by the orchestrator after the architecture pass runs._"
        $newBody = ($body.TrimEnd("`r","`n")) + $section
        $tmp = New-TemporaryFile
        try {
            $newBody | Out-File $tmp.FullName -Encoding utf8
            gh issue edit $Number --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-Null
        } finally {
            Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
        }
    }

    Set-PlanningReadiness -IssueNumber $Number -Stage 'architected' -StageLabel 'architect'
    Write-Log "  Issue #$Number — readiness.architected ✓" -Color DarkGray
}

function Invoke-Plan {
    param([int]$Number)
    Write-Log "  Plan readiness stub for issue #$Number" -Color Yellow

    $body = gh issue view $Number --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $body -notmatch '(?m)^##\s*Plan\s*$') {
        $section = "`n`n## Plan`n`n_phase-1 stub — populated by the orchestrator after the plan pass runs._"
        $newBody = ($body.TrimEnd("`r","`n")) + $section
        $tmp = New-TemporaryFile
        try {
            $newBody | Out-File $tmp.FullName -Encoding utf8
            gh issue edit $Number --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-Null
        } finally {
            Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
        }
    }

    Set-PlanningReadiness -IssueNumber $Number -Stage 'planned' -StageLabel 'plan'
    Write-Log "  Issue #$Number — readiness.planned ✓" -Color DarkGray
}
