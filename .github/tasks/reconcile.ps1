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

    The grace period (idle minutes past which an agent-held state counts as stuck)
    is StuckAfterMinutes, and the re-entries allowed at one state before the issue
    is handed to the owner on agent:failed is MaxReconcile — both settings in
    .github/orchestrator/lib/Config.ps1.

.PARAMETER WhatIf
    Report the verdicts and change nothing.

.PARAMETER Root
    The repository root whose .env is read. Default: the repository this script is in.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/reconcile.ps1

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/reconcile.ps1 -WhatIf
#>
param(
    [switch]$WhatIf,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Settings.ps1"
Import-Settings -Root $Root
if (-not (Get-Module Orchestrator)) { Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" }

$null = Invoke-Reconciliation -WhatIf:$WhatIf
