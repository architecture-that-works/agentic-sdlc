#Requires -Version 7.0
<#
.SYNOPSIS
    Queue a Backlog issue for agent pickup by assigning the agent:start label.

.DESCRIPTION
    Lists all Backlog issues in the GitHub Project filtered to this repo.
    Prompts for selection (or accepts -Issue <N> directly), then assigns
    the agent:start label. Branch creation and implementation are handled
    by 'task implement' or 'task run'.

.PARAMETER Issue
    Issue number to queue directly, skipping the interactive picker.

.EXAMPLE
    task start              # interactive picker
    task start ISSUE=13     # queue issue #13 directly
#>
param([int]$Issue = 0)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

function Invoke-Start {
    param([int]$IssueNumber = 0)

    Ensure-AgentLabels

    # ── Fetch Backlog items for this repo ─────────────────────────────────────
    $items = gh project item-list $KanbanProjectNumber `
        --owner $KanbanProjectOwner --format json |
        ConvertFrom-Json |
        Select-Object -ExpandProperty items |
        Where-Object {
            $_.status -eq 'Backlog' -and
            $_.content.type -eq 'Issue' -and
            $_.content.repository -eq $KanbanRepo
        }

    if (-not $items -or $items.Count -eq 0) {
        Write-Log "No Backlog issues found in project for $KanbanRepo." -Color Yellow
        return $null
    }

    # ── Resolve target issue ──────────────────────────────────────────────────
    if ($IssueNumber -gt 0) {
        $selected = $items | Where-Object { $_.content.number -eq $IssueNumber } | Select-Object -First 1
        if (-not $selected) { throw "Issue #$IssueNumber not found in Backlog for this repo." }
    } else {
        Write-Host ""
        Write-Host "  Backlog — $KanbanRepo" -ForegroundColor Cyan
        Write-Host "  $('─' * 60)" -ForegroundColor DarkGray
        $i = 1
        foreach ($item in $items) {
            Write-Host ("  {0,2}. #{1,-4} {2}" -f $i, $item.content.number, $item.content.title) -ForegroundColor White
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

    Set-IssueLabel -Number $num -Remove 'agent:failed' -Add 'agent:start'

    Write-Host ""
    Write-Host "  Issue   : $url" -ForegroundColor Cyan
    Write-Host "  Queued  : agent:start assigned ✅" -ForegroundColor Green
    Write-Host "  Next    : run 'task run' to process." -ForegroundColor DarkGray
    Write-Host ""

    return @{ Number = $num }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Start -IssueNumber $Issue | Out-Null
}
