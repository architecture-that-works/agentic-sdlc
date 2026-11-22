#Requires -Version 7.0
<#
.SYNOPSIS
    Review lane — agent self-review of the open PR against acceptance criteria.

.DESCRIPTION
    Orchestrator library — loaded by Orchestrator.psm1; Invoke-Review is called by Orchestrator.psm1.

    Retrieves the PR diff and the linked issue's acceptance criteria, asks
    the engine to review the implementation, and posts the verdict as a
    comment on both the PR and the issue.

    The answer is checked by the engine against .agents/skills/review/answer.schema.json:
    verdict approved → label agent:reviewing; item stays in Review lane.
    verdict rejected → post the report; label agent:implementing; back to Implementing.
    No checked answer → throws; the conductor records a failed attempt.
#>

$ErrorActionPreference = 'Stop'
# Module-internal library — loaded by Orchestrator.psm1 (which loads Config.ps1 first).
# Not dot-sourced individually; see ADR-013.

function Resolve-PR {
    param([int]$IssueNumber, [int]$PRNumber)
    if ($PRNumber -gt 0) { return $PRNumber }

    $branch = git rev-parse --abbrev-ref HEAD
    $found  = gh pr list --head $branch --json number --limit 1 | ConvertFrom-Json
    if ($found.Count -gt 0) { return $found[0].number }

    if ($IssueNumber -gt 0) {
        $title       = gh issue view $IssueNumber --repo $KanbanRepo --json title --jq '.title' 2>&1
        $issueBranch = Get-BranchName -Number $IssueNumber -Title $title
        $found       = gh pr list --head $issueBranch --json number --limit 1 | ConvertFrom-Json
        if ($found.Count -gt 0) { return $found[0].number }
    }

    throw "Could not resolve PR. Pass PR=N or run from the feature branch."
}

function Invoke-Review {
    param([int]$IssueNumber = 0, [int]$PRNumber = 0)

    if ($IssueNumber -eq 0) { $IssueNumber = Get-CurrentIssueNumber }
    $PRNumber = Resolve-PR -IssueNumber $IssueNumber -PRNumber $PRNumber
    if ($IssueNumber -eq 0) {
        $prBody = gh pr view $PRNumber --json body --jq '.body' 2>&1
        if ($prBody -match '#(\d+)') { $IssueNumber = [int]$Matches[1] }
    }

    # The verdict is a checked field (answer.schema.json); only the claude engine gives one.
    if ($OrchestratorConfig.Engine -ne 'claude') {
        throw "the review needs a checked answer and the $($OrchestratorConfig.Engine) engine cannot give one"
    }

    $sp = Get-IssueEstimate -IssueNumber $IssueNumber
    Write-Log "▶ Review — issue #$IssueNumber / PR #$PRNumber  SP=$sp" -Color Cyan
    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:reviewing'
    Add-Comment -Number $IssueNumber -Body "· reviewing PR #$PRNumber"

    $issue            = gh issue view $IssueNumber --repo $KanbanRepo --json title,body | ConvertFrom-Json
    $diff             = gh pr diff $PRNumber 2>&1 | Out-String
    $changedFileCount = ([regex]::Matches($diff, '(?m)^diff --git')).Count
    $scaledTurns      = [Math]::Min($OrchestratorConfig.MaxTurns_Review_Cap, $OrchestratorConfig.MaxTurns_Review + $changedFileCount)

    # Retrieve signal history — includes 🤖✅ Tests Passing output and any prior rejections.
    $signal = (Get-SignalComments -IssueNumber $IssueNumber) -join "`n---`n"
    $signalSection = if ($signal.Trim()) {
        "`nSIGNAL HISTORY (test results, prior implementation notes, previous rejections — use this to verify correctness):`n$($signal.Trim())"
    } else { '' }

    $prompt = @"
You are performing a strict code review for a pull request in this repository.

ISSUE TITLE: $($issue.title)

ISSUE BODY (contains Acceptance Criteria):
$($issue.body)
$(Format-OwnerComments -IssueNumber $IssueNumber)
PR DIFF:
$diff
$signalSection

REVIEW INSTRUCTIONS:
Tools available: Read, Glob, and Grep only — do not attempt Bash commands or any shell invocation.
Test and check results come from the signal history (look for robot emoji Tests Passing comments) and from CI — do not re-run them.

- Read .agents/skills/review/SKILL.md and its REFERENCE.md first and review by that method: read
  the connected code (every caller of a changed function), not only the diff; every finding needs
  a concrete case; the verdict rule and the output shape are in the skill.
- Verify every requirement and acceptance criterion is fully met. The signal history holds the
  test run output (🤖✅ Tests Passing) and the implementation's ``Left undone:`` line — nothing
  left undone may be an acceptance criterion.
- Check that the conventions in AGENTS.md and .agents/skills/ are followed.
- Lint and format are CI's job — report no style findings.

Your answer has two fields, checked against the skill's answer.schema.json:
- ``verdict``: ``approved`` or ``rejected``, by the skill's verdict rule.
- ``report``: the review in markdown, in the shape of the skill's § Step 4 — Report. A rejected
  report opens by naming every finding that must be fixed (for example ``Fix 1 and 3.``).
"@

    $schema = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../../.agents/skills/review/answer.schema.json') |
              ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress

    $run = Invoke-EngineTask -Task 'Review' -Prompt $prompt -Label 'Review' `
        -Tools 'Read', 'Glob', 'Grep' -MaxTurns $scaledTurns -Schema $schema
    if ($run.Outcome -eq 'max_turns') {
        throw "Review ran out of turns on $changedFileCount changed file(s) — retry needs a larger budget or a smaller PR."
    }
    if ($run.Outcome -ne 'finished') {
        $why = if ("$($run.Cause)" -match 'no checked answer') { $run.Cause } else { "Review failed: $($run.Cause)" }
        throw $why
    }
    $answer = $run.Answer
    if ($answer.verdict -notin 'approved', 'rejected') {
        throw "Review produced no checked answer: verdict '$($answer.verdict)' is not approved or rejected"
    }
    $approved = $answer.verdict -eq 'approved'
    $report   = $answer.report

    $issueComment = if ($approved) {
        "🤖✅ Review Approved`n`n$report`n`n*Proceeding to merge.*"
    } else {
        "🤖❌ Review Rejected`n`n$report`n`n*Returning to Implementing for fixes.*"
    }

    Add-Comment -Number $IssueNumber -Body $issueComment
    $prComment = if ($approved) { "🤖✅ Review Approved — see issue #${IssueNumber}." }
                 else           { "🤖❌ Review Rejected — see issue #${IssueNumber} for details." }
    gh pr review $PRNumber --comment --body $prComment 2>&1 | Out-Null

    if ($approved) {
        Write-Log "✅ Review APPROVED — PR #$PRNumber — proceeding to merge." -Color Green
    } else {
        Set-AgentState -IssueNumber $IssueNumber -Label 'agent:implementing'
        Write-Log "❌ Review REJECTED — issue #$IssueNumber returned to Implementing." -Color Red
    }

    return $approved
}

