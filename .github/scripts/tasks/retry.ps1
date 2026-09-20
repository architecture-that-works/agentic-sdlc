#Requires -Version 7.0
<#
.SYNOPSIS
    Recovery — reset a stuck or failed issue back to agent:backlog.

.DESCRIPTION
    Clears the persistent review-cycle counter (agent:cycle:N labels), removes
    all agent:* labels, and sets agent:backlog so the GHA orchestrator or 'task start'
    picks it up from the beginning.

    Works from any intermediate state: agent:failed, agent:implementing,
    agent:reviewing, or even agent:backlog already set (idempotent).

.PARAMETER Issue
    Issue number to reset. Required.

.EXAMPLE
    task retry ISSUE=25
#>
param([int]$Issue = 0)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\kanban\Kanban.psd1" -Force

if ($Issue -eq 0) { throw "ISSUE is required. Usage: task retry ISSUE=N" }

Write-Log "▶ Retry — resetting issue #$Issue to agent:backlog" -Color Cyan

Clear-IssueReviewCount -IssueNumber $Issue
Set-AgentState -IssueNumber $Issue -Label 'agent:backlog'
Add-Comment -Number $Issue -Body "· reset to backlog for retry"

Write-Log "✅ Issue #$Issue queued in agent:backlog — GHA or 'task start' will pick it up." -Color Green
