#Requires -Version 7.0
<#
.SYNOPSIS
    Alignment — run the pre-backlog gate (refine → architect → plan) and grant
    agent:backlog when an issue is ready for processing.

.DESCRIPTION
    The Backlog-gate counterpart to `task hitl` / `task afk`. Imports the
    Kanban module and calls Invoke-Alignment, which structures the issue body,
    writes the architectural impact and an implementation plan INTO the issue
    (ADR-014 — no .planning/), and labels agent:backlog only when the readiness
    gate clears (refined + architected + planned + zero open questions).

    Two modes (mirrors start = single, runner = drain):
      ISSUE=N   align that one issue.
    (no arg)  align every open, un-aligned issue (no agent:* label, not human:decision).

    align.yml runs Invoke-Alignment automatically on issue creation in the cloud;
    this command is the local / backfill counterpart. Open questions are surfaced
    as human:decision child issues — resolve those, then re-run to grant agent:backlog.

.PARAMETER Issue
    Issue number to align directly. 0 (default) aligns the whole un-aligned backlog.

.EXAMPLE
    task refine ISSUE=87     # align one issue
    task refine              # align every un-aligned open issue
#>
param([int]$Issue = 0)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" -Force
$KanbanRepo = (Get-OrchestratorContext).Repo

if ($Issue -gt 0) {
    Invoke-Orchestration -From refine -IssueNumber $Issue
    exit 0
}

# ── Batch: every open issue that is not yet aligned and not a human:decision ────
$raw = gh issue list --repo $KanbanRepo --state open `
    --json number,labels --limit 200 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read open issues (gh exited $LASTEXITCODE):`n$raw"
}
$unaligned = $raw | ConvertFrom-Json | Where-Object {
    $names = @($_.labels.name)
    -not ($names | Where-Object { $_ -like 'agent:*' }) -and ($names -notcontains 'human:decision')
} | Sort-Object number

$count = @($unaligned).Count
if ($count -eq 0) {
    Write-Log "No un-aligned open issues — nothing to align." -Color Yellow
    exit 0
}

Write-Host ""
Write-Host "  Aligning $count un-aligned issue(s) — $KanbanRepo" -ForegroundColor Cyan
Write-Host "  $('─' * 60)" -ForegroundColor DarkGray

$granted = 0
$held    = 0
foreach ($item in $unaligned) {
    $ok = Invoke-Orchestration -From refine -IssueNumber $item.number
    if ($ok) { $granted++ } else { $held++ }
}

Write-Host ""
Write-Log "✅ Alignment pass complete — $granted granted agent:backlog, $held held for decisions." -Color Green
if ($held -gt 0) {
    Write-Log "   Resolve the linked human:decision child issue(s), then re-run 'task refine'." -Color DarkGray
}
