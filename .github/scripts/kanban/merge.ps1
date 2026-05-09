#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 4 — Merge PR after CI gate + approval check.

.DESCRIPTION
    Confirms an approval signal exists (agent:review label on the issue OR at
    least one human-approved PR review), waits for CI to pass, then squash-
    merges and deletes the remote branch.

.PARAMETER Issue
    Issue number. Defaults to 0 — auto-detected from the current branch.

.PARAMETER PR
    PR number. Defaults to 0 — auto-detected from the current branch.

.PARAMETER Force
    Skip the approval guard and merge regardless. Use with caution.

.EXAMPLE
    task merge                  # auto-detects from current branch
    task merge ISSUE=13         # explicit issue
    task merge ISSUE=13 PR=42   # explicit both
#>
param([int]$Issue = 0, [int]$PR = 0, [switch]$Force)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

function Test-HasApproval {
    param([int]$IssueNumber, [int]$PRNumber)

    $labels = gh issue view $IssueNumber --repo $KanbanRepo --json labels --jq '[.labels[].name]' |
        ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($labels -contains 'agent:review') { return $true }

    $reviews = gh pr view $PRNumber --json reviews --jq '[.reviews[] | select(.state=="APPROVED")]' |
        ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($reviews -and $reviews.Count -gt 0) { return $true }

    return $false
}

function Invoke-Merge {
    param([int]$IssueNumber = 0, [int]$PRNumber = 0, [switch]$Force)

    if ($IssueNumber -eq 0) { $IssueNumber = Get-CurrentIssueNumber }

    if ($PRNumber -eq 0) {
        $branch = git rev-parse --abbrev-ref HEAD
        $found  = gh pr list --head $branch --json number --limit 1 | ConvertFrom-Json
        if ($found.Count -gt 0) {
            $PRNumber = $found[0].number
        } else {
            throw "Could not resolve PR. Pass PR=N or run from the feature branch."
        }
    }

    Write-Log "▶ Merge — issue #$IssueNumber / PR #$PRNumber" -Color Cyan

    if (-not $Force) {
        $approved = Test-HasApproval -IssueNumber $IssueNumber -PRNumber $PRNumber
        if (-not $approved) {
            Write-Log "⛔ No approval found for PR #$PRNumber." -Color Red
            Write-Log "   Run 'task review' first, or pass -Force to bypass." -Color Yellow
            exit 1
        }
    }

    Write-Log "  Waiting for CI checks on PR #$PRNumber..." -Color DarkGray
    gh pr checks $PRNumber --watch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "CI checks failed for PR #$PRNumber. Fix the pipeline before merging."
    }
    Write-Log "  CI green ✅" -Color Green

    gh pr merge $PRNumber --merge --delete-branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gh pr merge failed for PR #$PRNumber" }

    Set-IssueLabel -Number $IssueNumber -Remove 'agent:review' -Add 'agent:merged'
    Add-Comment -Number $IssueNumber -Body "✅ PR #$PRNumber merged. Issue complete."

    $default = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
    git checkout --quiet $default
    git pull --ff-only --quiet origin $default 2>$null

    Write-Log "✅ Merged PR #$PRNumber — issue #$IssueNumber complete." -Color Green
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Merge -IssueNumber $Issue -PRNumber $PR -Force:$Force
}
