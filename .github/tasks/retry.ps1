#Requires -Version 7.0
<#
.SYNOPSIS
    Recovery — resume a stuck or failed issue from where it left off.

.DESCRIPTION
    Starts a new round of attempts (the attempt history in the issue is kept) from
    the failed_at stage in the issue's AGENT-STATE block: a refine-stage failure
    re-runs refine; any later failure re-queues the issue to agent:backlog, which
    starts implement → review → ship again. The same thing happens when the owner
    comments on an agent:failed issue (afk.yml).

.PARAMETER Issue
    Issue number to reset. Required.

.EXAMPLE
    task retry ISSUE=25
#>
param([int]$Issue = 0)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" -Force

if ($Issue -eq 0) { throw "ISSUE is required. Usage: task retry ISSUE=N" }

Write-Log "▶ Retry — resuming issue #$Issue" -Color Cyan
$repo = (Get-OrchestratorContext).Repo

$state    = Get-IssueState -IssueNumber $Issue
$failedAt = if ($state -and $state.failed_at) { "$($state.failed_at)" } else { '' }

# A retry starts a new round of attempts; the history in the issue is kept.
Reset-AttemptCount -IssueNumber $Issue

if ($failedAt -in @('refine', 'architect', 'plan')) {
    # Not refined yet, so agent:backlog would be refused: run refine again.
    Set-IssueLabel -Number $Issue -Remove 'agent:failed'
    gh workflow run afk.yml --repo $repo --field stage=refine --field issue_number=$Issue 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to dispatch refine for issue #$Issue" }
    Add-Comment -Number $Issue -Body "· retrying refine (failed at $failedAt)"
    Write-Log "✅ Issue #$Issue — refine dispatched." -Color Green
} else {
    # Implement, review or ship: back to agent:backlog, which starts implement → review
    # → ship again on top of the existing branch, with the attempt history in view.
    Set-AgentState -IssueNumber $Issue -Label 'agent:backlog'
    Add-Comment -Number $Issue -Body "· retrying from implement (failed at $(if ($failedAt) { $failedAt } else { 'an unknown stage' }))"
    Write-Log "✅ Issue #$Issue re-queued on agent:backlog — implementation starts automatically." -Color Green
}
