#Requires -Version 7.0
<#
.SYNOPSIS
    HITL orchestration — pick a Backlog issue and run the full orchestration in this terminal.

.DESCRIPTION
    Presents an interactive picker of Backlog issues (or accepts -Issue N directly).
    Runs the full orchestration in this terminal session.
    agent:backlog is set by the orchestrator as it enters each stage.

.PARAMETER Issue
    Issue number to start directly, skipping the interactive picker.

.NOTES
    Failed attempts per round before agent:failed: MaxRetries in
    .github/orchestrator/lib/Config.ps1.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/hitl.ps1              # interactive picker
    pwsh -NoProfile -File .github/tasks/hitl.ps1 -Issue 13     # run orchestration for issue #13 directly
#>
param(
    [int]$Issue = 0
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" -Force
$ctx                 = Get-OrchestratorContext
$KanbanRepo          = $ctx.Repo
$KanbanProjectNumber = $ctx.ProjectNumber


# ── Fetch Backlog items for this repo ─────────────────────────────────────────

$_owner = Get-ResolvedOwner
if (-not $_owner) {
    Write-Log "Cannot reach GitHub Project — check KANBAN_PROJECT_OWNER in .env. Run: task setup" -Color Red
    exit 1
}
$items = gh project item-list $KanbanProjectNumber `
    --owner $_owner --format json --limit 200 |
    ConvertFrom-Json |
    Select-Object -ExpandProperty items |
    Where-Object {
        $_.status -eq 'Backlog' -and
        $_.content.type -eq 'Issue' -and
        $_.content.repository -eq $KanbanRepo
    }

if (-not $items -or $items.Count -eq 0) {
    Write-Log "No Backlog issues found in project for $KanbanRepo." -Color Yellow
    exit 0
}

# ── Resolve target issue ──────────────────────────────────────────────────────

if ($Issue -gt 0) {
    $selected = $items | Where-Object { $_.content.number -eq $Issue } | Select-Object -First 1
    if (-not $selected) { throw "Issue #$Issue not found in Backlog for this repo." }
} else {
    Write-Host ""
    Write-Host "  Backlog — $KanbanRepo" -ForegroundColor Cyan
    Write-Host "  $('─' * 60)" -ForegroundColor DarkGray

    # Every Backlog-lane issue is selectable. Annotate by agent:* label so it is
    # visible which issues GHA would pick (agent:backlog) vs failed retries vs
    # board-only drift — the lane is a superset of the agent:backlog label.
    $backlogNums = gh issue list --repo $KanbanRepo --label 'agent:backlog' --state open `
        --json number --jq '[.[].number]' | ConvertFrom-Json
    $failedNums  = gh issue list --repo $KanbanRepo --label 'agent:failed'  --state open `
        --json number --jq '[.[].number]' | ConvertFrom-Json

    $i = 1
    foreach ($item in $items) {
        $n = $item.content.number
        if ($backlogNums -contains $n)    { $tag = '[backlog]'; $c = 'Green'    }
        elseif ($failedNums -contains $n) { $tag = '[failed] '; $c = 'Yellow'   }
        else                              { $tag = '[other]  '; $c = 'DarkGray' }
        Write-Host ("  {0,2}. {1} #{2,-4} {3}" -f $i, $tag, $n, $item.content.title) -ForegroundColor $c
        $i++
    }
    Write-Host ""
    $raw = Read-Host "  Pick a number (1-$($items.Count))"
    $idx = [int]$raw - 1
    if ($idx -lt 0 -or $idx -ge $items.Count) { throw "Invalid selection." }
    $selected = $items[$idx]
}

$num = $selected.content.number
$url = $selected.content.url

Write-Host ""
Write-Host "  Issue   : $url" -ForegroundColor Cyan
Write-Host "  Mode    : Local — running in terminal, GHA suppressed" -ForegroundColor Green
Write-Host ""

# ── Run the full orchestration ────────────────────────────────────────────────

Invoke-Orchestration -IssueNumber $num
