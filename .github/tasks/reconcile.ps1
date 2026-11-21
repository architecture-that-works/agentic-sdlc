#Requires -Version 7.0
<#
.SYNOPSIS
    Reconcile — re-enter pipeline states that nothing is working on.

.DESCRIPTION
    Runs the warden over every open issue: a label whose holder is the agent, with
    no activity for longer than the grace period, means no runner is on it, so the
    owning stage is re-entered. States a human holds — human:decision,
    human:approval, agent:failed — are never touched.

    afk.yml runs this hourly on its schedule trigger. Run it by hand to recover
    now instead of waiting, or with -WhatIf to see the verdict for every issue
    without changing anything.

.PARAMETER StuckAfterMinutes
    Idle minutes past which an agent-held state counts as stuck. Defaults to the
    configured value (KANBAN_STUCK_AFTER_MINUTES, 90).

.PARAMETER MaxReconcile
    Re-entries allowed at one state before the issue is handed to the owner on
    agent:failed. Defaults to the configured value (KANBAN_MAX_RECONCILE, 2).

.PARAMETER WhatIf
    Report the verdicts and change nothing.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/reconcile.ps1

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/reconcile.ps1 -WhatIf
#>
param(
    [int]$StuckAfterMinutes = -1,
    [int]$MaxReconcile = -1,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" -Force

$null = Invoke-Reconciliation -StuckAfterMinutes $StuckAfterMinutes `
    -MaxReconcile $MaxReconcile -WhatIf:$WhatIf
