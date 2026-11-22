#Requires -Version 7.0
<#
.SYNOPSIS
    Self-grill subagent CLI — a hand-run probe of refine's questioning.

.DESCRIPTION
    Imports the orchestrator module and calls Invoke-Grill, the same function the
    refine stage runs, so a probe and the refine eval see what the stage sees: the
    model of the Refine task and the one questioning turn budget,
    the MaxTurns_Refine setting. Both are set in .github/orchestrator/lib/Config.ps1;
    this script takes neither as a parameter.

    Invoke-Grill starts a read-only subagent on the configured engine that runs the Grill-Me protocol
    against one issue: it reads the issue and the codebase, writes an Agent Brief,
    fills open_questions[] (and decided_questions[] where the codebase answers),
    and proposes glossary diffs. The answer is validated against
    ``src/utils/m_planning.py::GrillResult`` and printed as JSON.

          pwsh .agents/skills/refine/scripts/grill.ps1 -Issue 42
          pwsh .agents/skills/refine/scripts/grill.ps1 -Body probe -DryRun

.PARAMETER Issue
    GitHub issue number to grill. Fetches title and body via ``gh issue view``.

.PARAMETER Title
    Issue title for a probe that does not exist on GitHub.

.PARAMETER Body
    Issue body for a probe.

.PARAMETER DryRun
    Print the assembled prompt and stop, without a model call. Useful when
    iterating on the grill-me system prompt itself.

.PARAMETER Trace
    Emit { result, tools_called } instead of the bare GrillResult: the tools the
    subagent called, in order. The refine eval (tests/evals) checks Rule 1 with it.

.NOTES
    Tracked:  https://github.com/architecture-that-works/agentic-sdlc/issues/85
    Schema:   src/utils/m_planning.py::GrillResult
    Skill:    .agents/skills/refine/SKILL.md § Unattended invocation pattern
    Library:  .github/orchestrator/lib/Grill.ps1 (Invoke-Grill + helpers)
#>

[CmdletBinding()]
param(
    [int]   $Issue = 0,
    [string]$Title = '(probe)',
    [string]$Body  = '',
    [switch]$DryRun,
    [switch]$Trace
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\..\..\.github\orchestrator\Orchestrator.psd1" -Force

if ($Issue -eq 0 -and (-not $Body)) {
    throw "grill.ps1 requires either -Issue <number> OR -Body <text> (-Title optional). See -? for help."
}

# Stdout carries only the answer (the refine eval parses it as JSON): the engine's live
# rendering of the run goes to the information stream, dropped here; Write-Log still
# records the run in logs/kanban.log.
$result = Invoke-Grill -Issue $Issue -Title $Title -Body $Body -DryRun:$DryRun -Trace:$Trace 6>$null
if ($DryRun) {
    Write-Output $result.prompt
} else {
    $result | ConvertTo-Json -Depth 10
}
