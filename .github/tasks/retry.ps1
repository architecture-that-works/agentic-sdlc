#Requires -Version 7.0
<#
.SYNOPSIS
    Recovery — resume a stuck or failed issue from where it left off.

.DESCRIPTION
    Reads the failed_at state from the issue's AGENT-STATE block and dispatches
    the appropriate AFK workflow stage to resume it. Clears the agent:failed label
    and any review counters.

.PARAMETER Issue
    Issue number to reset. Required.

.EXAMPLE
    task retry ISSUE=25
#>
param([int]$Issue = 0)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\orchestrator\Orchestrator.psd1" -Force

if ($Issue -eq 0) { throw "ISSUE is required. Usage: task retry ISSUE=N" }

Write-Log "▶ Retry — resuming issue #$Issue" -Color Cyan

$state = Get-IssueState -IssueNumber $Issue
$failedAt = if ($state -and $state.failed_at) { $state.failed_at } else { '' }

if (-not $failedAt) {
    Write-Log "  No failed_at state found — defaulting to backlog." -Color Yellow
    $failedAt = 'backlog'
}

Clear-IssueReviewCount -IssueNumber $Issue

$stage = switch ($failedAt) {
    'refine'    { 'refine' }
    'architect' { 'refine' }
    'plan'      { 'refine' }
    'implement' { 'implement' }
    'review'    { 'implement' }
    'ship'      { 'ship' }
    default     { 'implement' }
}

if ($stage -eq 'implement' -and $failedAt -eq 'backlog') {
    Set-AgentState -IssueNumber $Issue -Label 'agent:backlog'
    Add-Comment -Number $Issue -Body "· reset to backlog for retry"
    Write-Log "✅ Issue #$Issue queued in agent:backlog — GHA or 'task hitl' will pick it up." -Color Green
} else {
    Set-IssueLabel -Number $Issue -Remove 'agent:failed'
    
    $ghArgs = @('workflow', 'run', 'afk.yml', '--repo', $KanbanRepo, '-f', "stage=$stage", '-f', "issue_number=$Issue")
    gh @ghArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to dispatch afk.yml for issue #$Issue" }
    
    Add-Comment -Number $Issue -Body "· resuming $failedAt stage (dispatched $stage workflow)"
    Write-Log "✅ Issue #$Issue dispatched to afk.yml (stage: $stage) to resume $failedAt." -Color Green
}
