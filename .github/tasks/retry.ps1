#Requires -Version 7.0
<#
.SYNOPSIS
    Recovery — resume a stuck or failed issue from where it left off.

.DESCRIPTION
    Thin wrapper over the module's single re-entry point. Starts a new round of
    attempts (the attempt history in the issue is kept) from where the issue got
    to: an issue that is not yet refined, architected and planned re-runs refine;
    anything past that re-queues to agent:backlog, which starts implement → review
    → ship again. The same path runs when the owner comments on an agent:failed
    issue (afk.yml), and when the hourly warden finds a state nothing is working
    on — one implementation, so all three behave identically.

.PARAMETER Issue
    Issue number to resume. Required.

.PARAMETER Root
    The repository root whose .env is read. Default: the repository this script is in.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/retry.ps1 -Issue 25
#>
param([int]$Issue = 0, [string]$Root = '')

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Settings.ps1"
Import-Settings -Root $Root
if (-not (Get-Module Orchestrator)) { Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" }

if ($Issue -eq 0) { throw "-Issue is required. Usage: pwsh -NoProfile -File .github/tasks/retry.ps1 -Issue N" }

Write-Log "▶ Retry — resuming issue #$Issue" -Color Cyan

$stage = Restart-Issue -IssueNumber $Issue -Reason 'retry requested'
if (-not $stage) { throw "Could not resume issue #$Issue — see the warning above." }

Write-Log "✅ Issue #$Issue re-entered at $stage." -Color Green
