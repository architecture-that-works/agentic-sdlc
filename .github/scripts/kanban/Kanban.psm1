#Requires -Version 7.0
<#
    Kanban — the AFK orchestrator library (ADR-013).

    Import-Module Kanban exposes the orchestration functions; the module's private
    $Kanban* variables and any internal param() defaults stay in module scope and
    never reach the caller, so the dot-source scope leak that once ran the pipeline
    against issue #0 is impossible by construction.

    The thin trigger scripts in ../tasks/ (run/start/runner/retry) import this
    module and call its functions — chiefly Get-KanbanContext and
    Invoke-Orchestration.

    Load order (dependencies first):

        Config        settings, run context (Get-KanbanContext), model selection
        Util          logging, runtime, lock, review counter, ISSUES.md reader
        GitHub        labels, lanes, comments, board, branches, issue-body state
        ../Claude     generic Claude helpers (Invoke-ClaudeStreaming, commit msg)
        _grill        refine self-grill subagent (Invoke-Grill)
        Refine        Backlog gate — Invoke-Refine + Invoke-Plan + Invoke-Alignment
        Architecture  Backlog gate, Architect step — blast radius
        Plan          Backlog gate, Plan decomposition — Lean PRD + child issues
        Implement     Implementing lane — develop → PR
        Review        Review lane — self-review loop
        Merge         Merged lane — squash-merge → CONTEXT.md
        Orchestrator  conducts the agent:* state machine across the lanes
#>

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\Util.ps1"
. "$PSScriptRoot\GitHub.ps1"
. "$PSScriptRoot\..\Claude.ps1"   # generic helper, shared across .github/scripts
. "$PSScriptRoot\..\Gemini.ps1"   # generic helper, shared across .github/scripts
. "$PSScriptRoot\..\..\..\.agents\skills\refine\scripts\_grill.ps1"
. "$PSScriptRoot\Refine.ps1"
. "$PSScriptRoot\Architecture.ps1"
. "$PSScriptRoot\Plan.ps1"
. "$PSScriptRoot\Implement.ps1"
. "$PSScriptRoot\Review.ps1"
. "$PSScriptRoot\Merge.ps1"
. "$PSScriptRoot\Orchestrator.ps1"

# Export functions only — NOT variables. Withholding $Kanban* from the caller's
# scope is the whole point (see the module header); run parameters are read via
# the exported Get-KanbanContext instead.
Export-ModuleMember -Function *
