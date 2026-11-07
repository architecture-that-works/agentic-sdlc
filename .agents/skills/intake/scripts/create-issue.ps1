#Requires -Version 7.0
<#
.SYNOPSIS
    Intake skill harness probe — creates a GitHub Issue with no labels.

.DESCRIPTION
    Thin standalone harness probe for the `intake` skill. Accepts a pre-drafted
    title and body, calls `gh issue create` with no --label flags, and prints the
    returned URL to stdout.

    This script is the deterministic leg of the intake flow. The agent (interactive
    Claude Code session) handles the draft-and-confirm conversation; this script is
    invoked only after the owner has typed `yes` and the agent has assembled the
    final title and body.

    Standalone probe (developer machine):

        pwsh .agents/skills/intake/scripts/create-issue.ps1 `
            -Title "Add dark mode support to the dashboard" `
            -Body  "**Goal**: ..."

    Pass -DryRun to print the assembled gh command without executing it.

.PARAMETER Title
    Issue title. Short, action-oriented (matches the ISSUES.md block format).

.PARAMETER Body
    Issue body. Must contain all four headings:
        **Goal** / **Description** / **Requirements** / **Acceptance Criteria**
    No --label flags are added regardless of body content.

.PARAMETER DryRun
    Print the gh command that would be executed without calling gh.

.NOTES
    Skill:  .agents/skills/intake/SKILL.md
    Ref:    .agents/skills/intake/REFERENCE.md § gh issue create Reference
    ADRs:   ADR-015 (2026-09-23 amendment) — labels are the pipeline's output;
            ADR-011 — issue body is the cross-runtime state carrier.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Title,

    [Parameter(Mandatory)]
    [string] $Body,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# Validate that all four required headings are present.
$requiredHeadings = @('**Goal**', '**Description**', '**Requirements**', '**Acceptance Criteria**')
$missing = $requiredHeadings | Where-Object { $Body -notlike "*$_*" }
if ($missing) {
    throw "Body is missing required heading(s): $($missing -join ', '). " +
          "All four headings are mandatory (intake SKILL.md C-3)."
}

$ghArgs = @(
    'issue', 'create',
    '--title', $Title,
    '--body',  $Body
    # No --label flags — labels are the pipeline's exclusive output (ADR-015).
)

if ($DryRun) {
    Write-Output "DRY RUN — command that would be executed:"
    Write-Output "gh $($ghArgs -join ' ')"
    return
}

$url = gh @ghArgs
if (-not $url) {
    throw "gh issue create returned no output. The issue may not have been created."
}

Write-Output $url
