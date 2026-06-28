#Requires -Version 7.0
<#
.SYNOPSIS
    Self-grill subagent CLI — AFK alignment phase probe for the `refine` skill.

.DESCRIPTION
    Thin standalone wrapper around Invoke-Grill (defined in _grill.ps1). Spawns a
    Claude subagent that runs the Grill-Me protocol against one GitHub issue: it
    reads the issue + codebase, generates an Agent Brief, populates open_questions[]
    (and decided_questions[] where it self-resolves from the codebase), and proposes
    glossary diffs.

    Output is structured JSON validated against
    ``src/utils/m_planning.py::GrillResult`` before the orchestrator writes
    anything back.

      Standalone probe (developer machine) — dump the JSON to stdout:
          pwsh .agents/skills/refine/scripts/grill.ps1 -Issue 42
          pwsh .agents/skills/refine/scripts/grill.ps1 -Title T -Body B -DryRun

    AFK orchestration does NOT use this wrapper — it dot-sources the library
    directly (no param() to leak into its scope, see ADR-013):
          . .agents/skills/refine/scripts/_grill.ps1
          $result = Invoke-Grill -Title $t -Body $b

    The system prompt enforces grill-me Rules 1-4 from refine/SKILL.md:
        1. Codebase first — read before asking
        2. Always recommend — every question carries the agent's position
        3. No branch left open — partial resolution is not resolution
        4. Interface before implementation — no file paths or line numbers

.PARAMETER Issue
    GitHub issue number to grill. Fetches title/body via ``gh issue view``.

.PARAMETER Title
    Issue title for one-shot probes that do not exist on GitHub.

.PARAMETER Body
    Issue body for one-shot probes.

.PARAMETER DryRun
    Render the assembled prompt to stdout without invoking Claude. Useful when
    iterating on the grill-me system prompt itself.

.PARAMETER Model
    Override the Claude model. Defaults to the orchestrator's Sonnet tier when
    available; falls back to ``claude-sonnet-4-6`` for standalone runs.

.PARAMETER MaxTurns
    Maximum agentic turns for the subagent. Defaults to 25 — generous enough
    for codebase exploration but bounded to prevent runaway loops.

.NOTES
    Tracked in: https://github.com/ysuurme/my_template_repo/issues/85
    Schema:    src/utils/m_planning.py::GrillResult
    Skill:     .agents/skills/refine/SKILL.md § AFK invocation pattern
    Library:   _grill.ps1 (Invoke-Grill + helpers) — dot-source that, not this CLI.
#>

[CmdletBinding()]
param(
    [int]   $Issue    = 0,
    [string]$Body     = '',
    [string]$Title    = '(probe)',
    [switch]$DryRun,
    [string]$Model    = '',
    [int]   $MaxTurns = 25
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_grill.ps1"

if ($Issue -eq 0 -and (-not $Body)) {
    throw "grill.ps1 requires either -Issue <number> OR -Body <text> (-Title optional). See -? for help."
}

$invokeParams = @{
    Issue    = $Issue
    Body     = $Body
    Title    = $Title
    DryRun   = [bool]$DryRun
    Model    = $Model
    MaxTurns = $MaxTurns
}
$result = Invoke-Grill @invokeParams
if ($DryRun) {
    Write-Output $result.prompt
} else {
    $result | ConvertTo-Json -Depth 10
}
