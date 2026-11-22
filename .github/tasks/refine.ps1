#Requires -Version 7.0
<#
.SYNOPSIS
    Alignment — run the pre-backlog gate (refine → architect → plan) and grant
    agent:backlog when an issue is ready for processing.

.DESCRIPTION
    The Backlog-gate counterpart to `hitl.ps1` / `afk.ps1`. Imports the
    Orchestrator module and calls Invoke-Orchestration -From refine, which structures the issue body,
    writes the architectural impact and an implementation plan INTO the issue
    (ADR-014 — no .planning/), and labels agent:backlog only when the readiness
    gate clears (refined + architected + planned + zero open questions).

    Two modes (mirrors start = single, runner = drain):
      ISSUE=N   align that one issue.
    (no arg)  align every open issue with no agent:* label — including human:decision
              issues, whose owner replies are checked (no model call without a reply).

    afk.yml refines automatically when an issue is opened or the owner comments;
    this command is the local / backfill counterpart. Open questions are asked in
    the issue itself (label human:decision); the owner answers with a comment.

.PARAMETER Issue
    Issue number to align directly. 0 (default) aligns the whole un-aligned backlog.

.PARAMETER Root
    The repository root whose .env is read. Default: the repository this script is in.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/refine.ps1 -Issue 87     # align one issue
    pwsh -NoProfile -File .github/tasks/refine.ps1              # align every un-aligned open issue
#>
param([int]$Issue = 0, [string]$Root = '')

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Settings.ps1"
Import-Settings -Root $Root
if (-not (Get-Module Orchestrator)) { Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" }
$KanbanRepo = (Get-OrchestratorContext).Repo

if ($Issue -gt 0) {
    Invoke-Orchestration -From refine -IssueNumber $Issue
    exit 0
}

# ── Batch: every open issue with no agent:* label ──────────────────────────────
$raw = gh issue list --repo $KanbanRepo --state open `
    --json number,labels --limit 200 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to read open issues (gh exited $LASTEXITCODE):`n$raw"
}
$unaligned = $raw | ConvertFrom-Json | Where-Object {
    $names = @($_.labels.name)
    -not ($names | Where-Object { $_ -like 'agent:*' })
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
    Write-Log "   Answer the questions on the human:decision issue(s) with a comment." -Color DarkGray
}
