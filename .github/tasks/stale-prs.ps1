#Requires -Version 7.0
<#
.SYNOPSIS
    Weekly sweep — surface PRs that have waited at agent:reviewing too long.

.DESCRIPTION
    Standalone runnable (no orchestrator module, no Claude, no uv): `gh` and
    PowerShell 7 are all this needs, same as the resume job in afk.yml when there
    is nothing to resume. Lists every open PR whose linked issue carries
    agent:reviewing, writes all of them to the GHA job summary, and — for any
    older than -StaleAfterDays — posts or updates (never duplicates) a single
    comment on the PR naming its age.

    Surfaces staleness only. Never touches a label, merges, or closes anything
    (#211) — the human:approval merge-authority boundary stays exactly as is.

.PARAMETER StaleAfterDays
    Age in days past which a PR gets a staleness comment. Everything found still
    appears in the job summary regardless of this threshold.

.PARAMETER Repo
    owner/repo to query. Required.

.EXAMPLE
    .github/tasks/stale-prs.ps1 -StaleAfterDays 7 -Repo ysuurme/my_template_repo
#>
param(
    [int]$StaleAfterDays = 7,
    [Parameter(Mandatory)][string]$Repo
)

$ErrorActionPreference = 'Stop'

$marker = '<!-- stale-pr-check -->'

# ── 1. Which issues are waiting on a human merge ──────────────────────────────
$issuesJson = gh issue list --repo $Repo --label 'agent:reviewing' --state open --json number 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "Could not list agent:reviewing issues: $issuesJson" }
$reviewingIssues = @(($issuesJson | ConvertFrom-Json) | ForEach-Object { [int]$_.number })

# ── 2. The matching open PR for each, by branch naming convention ────────────
# Get-BranchName (lib/GitHub.ps1) embeds the issue number as the branch's first
# path segment for every agent PR — feature/{n}-{slug} — so a head-branch search
# finds it without GraphQL or the Projects v2 board (ADR-012).
$rows = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($issueNumber in $reviewingIssues) {
    $prJson = gh pr list --repo $Repo --search "head:feature/$issueNumber-" --state open `
        --json number,title,createdAt,headRefName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { continue }
    $prs = @($prJson | ConvertFrom-Json)
    foreach ($pr in $prs) {
        $ageDays = [int]([datetime]::UtcNow - [datetime]$pr.createdAt).Days
        $rows.Add([pscustomobject]@{
            pr_number   = [int]$pr.number
            pr_title    = "$($pr.title)"
            issue_number = $issueNumber
            age_days    = $ageDays
        })
    }
}

# ── 3. Job summary — every matched PR, every run, threshold or not ───────────
$summary = [System.Text.StringBuilder]::new()
$null = $summary.AppendLine('## Stale PR sweep')
$null = $summary.AppendLine()
if ($rows.Count -eq 0) {
    $null = $summary.AppendLine('No PRs awaiting review.')
} else {
    $null = $summary.AppendLine('| PR | Title | Issue | Age (days) |')
    $null = $summary.AppendLine('|---|---|---|---|')
    foreach ($row in $rows) {
        $null = $summary.AppendLine("| #$($row.pr_number) | $($row.pr_title) | #$($row.issue_number) | $($row.age_days) |")
    }
}
if ($env:GITHUB_STEP_SUMMARY) {
    $summary.ToString() | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
Write-Output $summary.ToString()

# ── 4. Upsert a staleness comment on anything past the threshold ─────────────
foreach ($row in @($rows | Where-Object { $_.age_days -ge $StaleAfterDays })) {
    $body = "$marker`n🤖 This PR has been waiting for review for **$($row.age_days) day(s)** " +
        "(linked to #$($row.issue_number)). The human:approval gate is deliberate — this is a " +
        "nudge, not a push. The longer it waits, the more likely `main` has drifted and the merge " +
        "needs a rebase first."

    $commentsJson = gh api "repos/$Repo/issues/$($row.pr_number)/comments?per_page=100" 2>&1 | Out-String
    $existingId = $null
    if ($LASTEXITCODE -eq 0) {
        $existing = @($commentsJson | ConvertFrom-Json) | Where-Object { "$($_.body)" -like "*$marker*" } | Select-Object -First 1
        if ($existing) { $existingId = $existing.id }
    }

    $tmp = New-TemporaryFile
    try {
        $body | Out-File $tmp.FullName -Encoding utf8
        if ($existingId) {
            gh api --method PATCH "repos/$Repo/issues/comments/$existingId" -F "body=@$($tmp.FullName)" 2>&1 | Out-Null
        } else {
            gh api --method POST "repos/$Repo/issues/$($row.pr_number)/comments" -F "body=@$($tmp.FullName)" 2>&1 | Out-Null
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}
