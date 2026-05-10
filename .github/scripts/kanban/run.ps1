#Requires -Version 7.0
<#
.SYNOPSIS
    End-to-end Kanban pipeline orchestrator.

.DESCRIPTION
    Default: polls GitHub every PollIntervalSeconds for issues labelled
    agent:backlog and runs the full pipeline on each (implement → review loop →
    merge). Also resumes stalled Implementing-lane items from interrupted runs.

    Direct mode (-Issue N): runs the pipeline once for the given issue and exits.

    Review loop: after implement, runs review. If REJECTED, re-runs implement
    (up to MaxRetries attempts) then reviews again. Stops on APPROVED.

.PARAMETER Issue
    Issue number for a single direct run. Omit to enter continuous polling mode.

.PARAMETER PollIntervalSeconds
    Seconds between polls in continuous mode. Default: 60.

.PARAMETER MaxRetries
    Maximum implement→review cycles before giving up. Default: 3.

.EXAMPLE
    task run                    # poll every 60s — runs indefinitely
    task run ISSUE=13           # run pipeline once for issue #13 and exit
    task run POLL=30 RETRIES=5  # custom poll interval and retry limit
#>
param(
    [int]$Issue               = 0,
    [int]$PollIntervalSeconds = 60,
    [int]$MaxRetries          = 3
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"
. "$PSScriptRoot\implement.ps1"
. "$PSScriptRoot\review.ps1"
. "$PSScriptRoot\merge.ps1"

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-BacklogIssues {
    $raw = gh issue list --repo $KanbanRepo --state open --label 'agent:backlog' `
        --json number,title --limit 50 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) { return @() }
    $issues = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $issues) { return @() }
    return $issues
}

function Get-StalledIssues {
    $items = gh project item-list $KanbanProjectNumber `
        --owner $KanbanProjectOwner --format json --limit 200 |
        ConvertFrom-Json |
        Select-Object -ExpandProperty items |
        Where-Object {
            $_.status -eq 'Implementing' -and
            $_.content.type -eq 'Issue' -and
            $_.content.repository -eq $KanbanRepo
        }

    $items | Where-Object {
        $raw    = gh issue view $_.content.number --repo $KanbanRepo --json labels `
            --jq '[.labels[].name]' 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
        $labels = if ($raw) { $raw } else { @() }
        $labels -contains 'agent:implementing'
    }
}

# ── Full pipeline for one issue ───────────────────────────────────────────────

function Invoke-Pipeline {
    param([int]$IssueNumber, [switch]$Force)

    $meta   = gh issue view $IssueNumber --repo $KanbanRepo --json title | ConvertFrom-Json
    $jq     = ".items[] | select(.content.number == $IssueNumber and .content.repository == `"$KanbanRepo`") | .status"
    $status = gh project item-list $KanbanProjectNumber `
        --owner $KanbanProjectOwner --format json --limit 200 --jq $jq 2>&1

    Write-Log "━━━ Pipeline: issue #$IssueNumber — $($meta.title)" -Color Cyan
    Write-Log "    Current lane: $status" -Color DarkGray

    Ensure-AgentLabels
    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:implementing'

    $stash   = git stash 2>&1
    $stashed = $stash -notmatch 'No local changes'

    try {
        Invoke-Implement -IssueNumber $IssueNumber -Force:$Force | Out-Null

        $branch = Get-BranchName -Number $IssueNumber -Title $meta.title
        $prList = gh pr list --head $branch --json number --limit 1 | ConvertFrom-Json
        if ($prList.Count -eq 0) { throw "No PR found for branch $branch after implement stage." }
        $prNum    = $prList[0].number
        $approved = $false

        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            Write-Log "  Review attempt $attempt / $MaxRetries" -Color DarkGray
            $approved = Invoke-Review -IssueNumber $IssueNumber -PRNumber $prNum

            if ($approved) { break }

            if ($attempt -lt $MaxRetries) {
                Write-Log "  Review rejected — re-running implement (attempt $($attempt + 1))..." -Color Yellow
                Invoke-Implement -IssueNumber $IssueNumber -Force | Out-Null
            }
        }

        if (-not $approved) {
            Set-AgentState -IssueNumber $IssueNumber -Label 'agent:failed'
            Add-Comment -Number $IssueNumber -Body "⛔ Pipeline gave up after $MaxRetries review cycles. Manual intervention required."
            Write-Log "⛔ Gave up after $MaxRetries cycles for issue #$IssueNumber." -Color Red
            return
        }

        Invoke-Merge -IssueNumber $IssueNumber -PRNumber $prNum

        Write-Log "🎉 Issue #$IssueNumber complete." -Color Green

    } catch {
        Set-AgentState -IssueNumber $IssueNumber -Label 'agent:failed'
        Add-Comment -Number $IssueNumber -Body "❌ **Pipeline error**`n``````$_``````"
        Write-Log "❌ Pipeline error for issue #$IssueNumber : $_" -Color Red
    } finally {
        if ($stashed) { git stash pop 2>&1 | Out-Null }

        # Always return to a clean, origin-synced master so the next issue can start fresh.
        $default = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null
        $curr    = git rev-parse --abbrev-ref HEAD 2>$null

        if ($curr -and $curr -ne $default) {
            # Re-stash any working-tree state (e.g. from stash pop) so checkout can succeed.
            if (git status --porcelain 2>$null) {
                git stash push --include-untracked --quiet `
                    -m "auto: pre-master-switch from issue #$IssueNumber pipeline" 2>$null
            }
            Write-Log "  ↩ Returning to $default (feature branch '$curr' preserved for human review)." -Color DarkGray
            git checkout --quiet $default 2>$null
        }
        git fetch --quiet origin $default 2>$null
        git reset --hard --quiet "origin/$default" 2>$null
    }
}

# ── Entry point ───────────────────────────────────────────────────────────────

if ($Issue -gt 0) {
    Invoke-Pipeline -IssueNumber $Issue
} else {
    Write-Log "▶ run — polling every ${PollIntervalSeconds}s for agent:backlog. Ctrl+C to stop." -Color Cyan
    while ($true) {
        try {
            $backlog = @(Get-BacklogIssues)
            $stalled = @(Get-StalledIssues)

            $backlog | Sort-Object { $_.number } | ForEach-Object {
                Write-Log "  🎯 agent:backlog on #$($_.number) '$($_.title)' — picking up." -Color Cyan
                Invoke-Pipeline -IssueNumber $_.number
            }

            $stalled | Sort-Object { $_.content.number } | ForEach-Object {
                Write-Log "  ⚠️ Stalled #$($_.content.number) in Implementing — resuming." -Color Yellow
                Invoke-Pipeline -IssueNumber $_.content.number -Force:$true
            }

            if ($backlog.Count -eq 0 -and $stalled.Count -eq 0) {
                Write-Log "  Idle." -Color DarkGray
            }
        } catch {
            Write-Log "⚠️  Loop error: $_" -Color Red
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
