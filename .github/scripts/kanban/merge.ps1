#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 4 — Merge PR after CI gate + approval check.

.DESCRIPTION
    Internal function library — dot-sourced by run.ps1 and review.ps1. Not a direct Taskfile target.

    Confirms an approval signal exists (agent:review label on the issue OR at
    least one human-approved PR review), waits for CI to pass, then squash-
    merges and deletes the remote branch. Updates CONTEXT.md post-merge.
#>

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

function Invoke-ContextUpdate {
    param([int]$IssueNumber)

    $contextPath = "$_Root\CONTEXT.md"

    # Collect inputs
    $issueData  = gh issue view $IssueNumber --repo $KanbanRepo --json title,body 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
    $issueTitle = if ($issueData -and $issueData.title) { $issueData.title.Trim() } else { "issue #$IssueNumber" }
    $issueBody  = if ($issueData -and $issueData.body)  { $issueData.body }          else { '' }

    $diff = git diff HEAD~1 HEAD -- src/ 2>&1 | Out-String

    if (-not (Test-Path $contextPath)) {
        Write-Log "  ⚠️ CONTEXT.md not found — skipping context update." -Color Yellow
        return
    }
    $contextContent = Get-Content $contextPath -Raw

    $prompt = @"
You are updating CONTEXT.md for a software project after a PR was merged.

Analyse the merged diff (src/ only), the issue body, and the current CONTEXT.md.
Produce targeted patches to any of the three sections below if new content is warranted:
  1. Glossary         — new domain terms introduced by this change
  2. Bounded Contexts — ownership changes if new modules or contexts were added
  3. Out of Scope     — decisions explicitly deferred or rejected during implementation

STRICT OUTPUT RULES:
- Return ONLY a valid unified diff for CONTEXT.md, starting with "--- a/CONTEXT.md" and "+++ b/CONTEXT.md".
- OR return the exact string NO_CHANGES (and nothing else) if no section needs updating.
- Do NOT include markdown code fences, explanations, or any other text.
- Do NOT reword or duplicate existing entries.
- The patch MUST be directly applicable via: git apply

MERGED DIFF (src/ only):
$diff

ISSUE BODY:
$issueBody

CURRENT CONTEXT.md:
$contextContent
"@

    Write-Log "  Calling Claude for CONTEXT.md update (issue #$IssueNumber)..." -Color DarkGray
    $response = claude -p $prompt --model $KanbanModel_Sonnet 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Claude invocation failed — skipping context update." -Color Yellow
        return
    }
    $response = $response.Trim()

    if ($response -eq 'NO_CHANGES') {
        Write-Log "  CONTEXT.md — no changes needed." -Color DarkGray
        return
    }

    # Detect which sections are being updated and collect added content per section
    $updatedSections = [System.Collections.Generic.List[string]]::new()
    $sectionLines    = @{}   # section name -> list of added lines (leading '+' stripped)
    $currentSection  = ''
    foreach ($line in ($response -split '\r?\n')) {
        $content = $line -replace '^[ +]', ''
        if     ($content -match '^## Glossary')         { $currentSection = 'Glossary' }
        elseif ($content -match '^## Bounded Contexts') { $currentSection = 'Bounded Contexts' }
        elseif ($content -match '^## Out of Scope')     { $currentSection = 'Out of Scope' }
        elseif ($content -match '^## ')                 { $currentSection = '' }

        if ($line -match '^\+[^\+]' -and $currentSection) {
            if (-not $updatedSections.Contains($currentSection)) {
                $updatedSections.Add($currentSection)
                $sectionLines[$currentSection] = [System.Collections.Generic.List[string]]::new()
            }
            $added = $line.Substring(1).Trim()
            if ($added) { $sectionLines[$currentSection].Add($added) }
        }
    }

    # Apply the patch
    $patchFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($patchFile, $response, [System.Text.Encoding]::UTF8)
        git apply $patchFile 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ git apply failed — malformed Claude response. Logging raw output." -Color Yellow
            Write-Log "  [RAW CLAUDE RESPONSE] $response" -Color DarkGray
            return
        }
    } finally {
        if (Test-Path $patchFile) { Remove-Item $patchFile -ErrorAction SilentlyContinue }
    }

    # Stage and commit
    git add CONTEXT.md 2>&1 | Out-Null
    $commitMsg = "chore(context): update after merge of #$IssueNumber — $issueTitle"
    git commit -m $commitMsg 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Context update commit failed — original merge unaffected." -Color Yellow
        return
    }

    # Push to default branch
    $defaultBranch = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
    git push origin $defaultBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Push failed for context update — reverting local commit to keep $defaultBranch in sync." -Color Yellow
        git reset --hard --quiet "origin/$defaultBranch" 2>&1 | Out-Null
    } else {
        Write-Log "  ✅ CONTEXT.md updated — $commitMsg" -Color Green
    }

    # Post comment listing updated sections and what was added
    $sectionsText = if ($updatedSections.Count -gt 0) { $updatedSections -join ', ' } else { 'CONTEXT.md' }
    $commentParts = [System.Collections.Generic.List[string]]::new()
    $commentParts.Add("· CONTEXT.md updated — $sectionsText")
    foreach ($section in $updatedSections) {
        if ($sectionLines.ContainsKey($section) -and $sectionLines[$section].Count -gt 0) {
            $commentParts.Add("")
            $commentParts.Add("**$section**")
            foreach ($entry in $sectionLines[$section]) {
                $commentParts.Add("- $entry")
            }
        }
    }
    $commentBody = $commentParts -join "`n"
    Add-Comment -Number $IssueNumber -Body $commentBody
}

function Invoke-RebaseOnMaster {
    param([int]$IssueNumber, [string]$Branch)

    $default = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    git fetch --quiet origin $default 2>&1 | Out-Null

    $mergeBase  = git merge-base HEAD "origin/$default" 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    $masterHead = git rev-parse "origin/$default"         2>&1 | Out-String | ForEach-Object { $_.Trim() }

    if ($mergeBase -eq $masterHead) {
        Write-Log "  Branch $Branch is up-to-date with $default — skipping rebase." -Color DarkGray
        return
    }

    $behind = git rev-list --count "HEAD..origin/$default" 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    Write-Log "  Branch $Branch is $behind commit(s) behind $default — rebasing..." -Color DarkGray
    Add-Comment -Number $IssueNumber -Body "· rebasing onto $default ($behind commit(s) behind)"

    git rebase "origin/$default" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $conflicts = git diff --name-only --diff-filter=U 2>&1 | Out-String
        git rebase --abort 2>&1 | Out-Null
        Add-Comment -Number $IssueNumber -Body "🤖❌ Rebase Conflict`n`nConflicting files:`n``````text`n$($conflicts.Trim())`n``````"
        throw "Rebase conflict on $Branch against $default — manual resolution required."
    }

    git push --force-with-lease --quiet origin $Branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Force push after rebase failed for branch $Branch." }

    Write-Log "  Rebased $Branch onto $default." -Color Green
    Add-Comment -Number $IssueNumber -Body "· rebased onto $default"
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
            Write-Log "   Approval required: run 'task start ISSUE=$IssueNumber' to drive the full pipeline, or pass -Force to bypass." -Color Yellow
            exit 1
        }
    }

    # Checkout the feature branch (may not be on it when called standalone from master).
    # master is authoritative — always rebase rather than merge forward.
    $featureBranch = gh pr view $PRNumber --json headRefName --jq '.headRefName' 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    if ($currentBranch -ne $featureBranch) {
        git checkout --quiet $featureBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not switch to feature branch $featureBranch." }
    }
    Invoke-RebaseOnMaster -IssueNumber $IssueNumber -Branch $featureBranch

    Write-Log "  Waiting for CI checks on PR #$PRNumber..." -Color DarkGray
    $checkOutput = gh pr checks $PRNumber --watch 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $failedChecks = gh pr checks $PRNumber --json name,conclusion `
            --jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "failure")] | map(.name) | join(", ")' 2>&1 | Out-String
        $failedLabel = if ($failedChecks.Trim() -and $failedChecks.Trim() -ne 'null') { $failedChecks.Trim() } else { 'unknown' }
        Add-Comment -Number $IssueNumber -Body "🤖❌ CI Failed`n`nFailed checks: $failedLabel`n``````text`n$($checkOutput.Trim())`n``````"
        throw "CI checks failed for PR #$PRNumber."
    }
    Write-Log "  CI green ✅" -Color Green

    gh pr merge $PRNumber --merge --delete-branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gh pr merge failed for PR #$PRNumber" }

    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:merged'
    Add-Comment -Number $IssueNumber -Body "🤖✅ Merged`n`nPR #$PRNumber squash-merged. Issue closed."

    $default = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
    git checkout --quiet $default
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not switch to $default after merge — context update skipped." -Color Yellow
        return
    }
    git fetch --quiet origin $default 2>$null
    git reset --hard --quiet "origin/$default" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not sync $default with origin — context update skipped." -Color Yellow
        return
    }

    Invoke-ContextUpdate -IssueNumber $IssueNumber

    Write-Log "✅ Merged PR #$PRNumber — issue #$IssueNumber complete." -Color Green
}

