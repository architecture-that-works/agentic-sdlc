#Requires -Version 7.0
<#
.SYNOPSIS
    Implementing lane -- Develop -> PR.

.DESCRIPTION
    Kanban library -- loaded by Kanban.psm1; Invoke-Implement is called by
    Orchestrator.ps1 for an issue in the Implementing lane.

    Refine, Architect and Plan are NOT run here -- they are the pre-backlog
    alignment gate (Refine.ps1) that already granted agent:backlog. By the time an
    issue reaches Implementing it is refined, architected and planned, so this lane
    only builds and ships:

    Phase 1 Develop -- Claude Code implements every requirement; verifies with
                       uv run pytest.
    Phase 2 PR      -- commits (Claude-generated message), pushes, opens PR.

    Invoke-Implement opens with a thin readiness re-check (belt-and-suspenders):
    it warns if an issue somehow reached Implementing without full alignment, but
    does not re-run alignment -- that belongs before the backlog.
#>

$ErrorActionPreference = 'Stop'
# Module-internal library -- loaded by Kanban.psm1, which loads Config.ps1 and
# GitHub.ps1 before this file. See ADR-013.
# ── Phase 1: Develop ──────────────────────────────────────────────────────────

function Invoke-Develop {
    param([int]$Number, [string]$Branch)
    Write-Log "  Phase 1 — Develop issue #$Number on $Branch" -Color Yellow
    Move-ToLane -IssueNumber $Number -OptionId $KanbanOpt_Implementing -LaneName 'Implementing'
    Add-Comment -Number $Number -Body "· branch checked out — starting"

    if ((Get-ChildItem .agents/skills -Recurse -Filter *.md -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-Log "⚠️ Skills directory is empty — agent constraints will not be applied." -Color Yellow
    }

    $issue = gh issue view $Number --repo $KanbanRepo --json title,body | ConvertFrom-Json

    # Retrieve all agent signal comments (🤖-prefixed) — full decision history for this issue.
    # Includes review rejections, CI failures, prior implementation summaries, and errors.
    $signal = gh issue view $Number --repo $KanbanRepo --json comments `
        --jq '[.comments[] | select(.body | startswith("🤖"))] | map(.body) | join("\n---\n")' 2>&1 | Out-String
    $signalSection = if ($LASTEXITCODE -eq 0 -and $signal.Trim() -and $signal.Trim() -ne 'null') {
        "`nISSUE SIGNAL HISTORY (agent decisions and outcomes — address all rejections and failures before finishing):`n$($signal.Trim())"
    } else { '' }

    $prompt = @"
You are implementing GitHub issue #$Number on branch $Branch in this repository.

ISSUE TITLE: $($issue.title)

ISSUE BODY:
$($issue.body)
$signalSection
INSTRUCTIONS:
1. Read AGENTS.md and CONTEXT.md first to understand the project boundaries and constraints.
2. Read the relevant parts of the codebase before writing any code.
3. Implement every requirement listed in the issue body completely.
4. Follow all conventions in AGENTS.md. The skill files in ``.agents/skills/`` are your constraint documents — locate the relevant skill via the Skills index in AGENTS.md, then read its SKILL.md (and REFERENCE.md / EXAMPLES.md if linked) before implementing.
5. After implementation run ``uv run pytest`` to verify the test suite passes.
6. If tests fail, diagnose and fix the root cause before stopping.
7. Do NOT commit any changes — only implement.
8. End your response with a concise bullet-point summary of every file you changed.
"@

    $sp       = Get-IssueEstimate -IssueNumber $Number
    $devModel = Get-PhaseModel -Estimate $sp -Phase 'implement'
    $devTurns = Get-ImplementMaxTurns -Estimate $sp
    Write-Log "  Model: $devModel  SP=$sp  max-turns=$devTurns" -Color DarkGray

    $allText           = [System.Text.StringBuilder]::new()
    $modifiedFiles     = [System.Collections.Generic.List[string]]::new()
    $explorationPosted = $false
    $writingPosted     = $false
    $testedOnce        = $false

    $prompt | claude --model $devModel --allowedTools "Read,Write,Edit,Bash,Glob,Grep" --max-turns $devTurns --output-format stream-json --verbose 2>&1 |
    ForEach-Object {
        $raw = [string]$_
        try {
            $ev = $raw | ConvertFrom-Json -ErrorAction Stop

            $blocks = if ($ev.message.content) { $ev.message.content }
                      elseif ($ev.content)      { $ev.content }
                      else                      { @() }

            foreach ($block in $blocks) {
                switch ($block.type) {
                    'text' {
                        Write-Host $block.text -NoNewline
                        $null = $allText.Append($block.text)
                    }
                    'tool_use' {
                        $inputReady = ($block.input.PSObject.Properties | Measure-Object).Count -gt 0
                        if ($inputReady) {
                            Write-Host "`n  $(Format-ToolLine -Name $block.name -ToolInput $block.input)" -ForegroundColor DarkCyan
                        }

                        if ($block.name -in @('Read','Glob','Grep') -and -not $explorationPosted) {
                            $explorationPosted = $true
                            Add-Comment -Number $Number -Body "· exploring codebase"
                        }
                        if ($block.name -in @('Write','Edit') -and $block.input.file_path) {
                            if (-not $writingPosted) {
                                $writingPosted = $true
                                Add-Comment -Number $Number -Body "· writing implementation"
                            }
                            $fp = $block.input.file_path
                            if (-not $modifiedFiles.Contains($fp)) { $modifiedFiles.Add($fp) }
                        }
                        if ($block.name -eq 'Bash' -and $block.input.command -match 'pytest' -and -not $testedOnce) {
                            $testedOnce = $true
                            Add-Comment -Number $Number -Body "· running tests"
                        }
                    }
                }
            }

            if ($ev.type -eq 'result') { Write-Host '' }
        } catch {
            if ($raw.Trim()) { Write-Host $raw -ForegroundColor DarkGray }
        }
    }

    if ($LASTEXITCODE -ne 0) { throw "Claude Code exited with code $LASTEXITCODE." }

    $bullets     = ($allText.ToString() -split '\r?\n') |
                   Where-Object { $_ -match '^\s*[-*•]' } |
                   Select-Object -Last 20
    $summaryText = if ($bullets) { $bullets -join "`n" } else { '(see PR diff for details)' }
    $fileSection = if ($modifiedFiles.Count -gt 0) {
        $fileLines = ($modifiedFiles | Select-Object -Unique |
                      ForEach-Object { "- ``$(Split-Path $_ -Leaf)``" }) -join "`n"
        "`n`n**Files changed ($($modifiedFiles.Count)):**`n$fileLines"
    } else { '' }
    Add-Comment -Number $Number -Body "🤖 Implementation$fileSection`n`n$summaryText"
    Write-Log "  Implementation finished for issue #$Number." -Color Green

    # Independent verification — output posted as signal so the reviewer can read exact results
    Write-Log "  Running test suite independently..." -Color DarkGray
    $testOutput = uv run pytest --tb=short -q 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $errBlock = Format-ErrorBlock -Raw $testOutput
        Add-Comment -Number $Number -Body "🤖⚠️ Tests Failing`n`n$errBlock"
        throw "Test suite failed after implementation for issue #$Number"
    }
    $testSummary = (($testOutput -split '\r?\n') | Where-Object { $_.Trim() } | Select-Object -Last 4) -join "`n"
    Add-Comment -Number $Number -Body "🤖✅ Tests Passing`n``````text`n$($testSummary.Trim())`n``````"
    Write-Log "  Tests passing ✅" -Color Green
}

# ── Phase 2: Commit + PR ──────────────────────────────────────────────────────

function Invoke-CommitAndPR {
    param([int]$Number, [string]$Title, [string]$Branch)
    Write-Log "  Phase 2 — Commit + PR for issue #$Number" -Color Yellow

    # Auto-format before staging so ruff format --check in CI always passes.
    $fmtOut = uv run ruff format . 2>&1 | Out-String
    Write-Log "  ruff format: $($fmtOut.Trim())" -Color DarkGray

    # Stage only known-safe paths rather than git add . — an agent implementation
    # can create .env files, credentials, or other sensitive artefacts; the allowlist
    # ensures nothing outside these directories ever reaches the index.
    # Stage every tracked + untracked change that .gitignore allows. The denylist
    # below is the final safety net for sensitive leaf names. Previously a static
    # allowlist silently dropped legitimate edits to files like SECURITY.md and
    # .devcontainer/devcontainer.json, leading to "Already implemented — no new
    # changes" false positives and PR-creation failures despite real work on disk.
    git add -A 2>&1 | Out-Null

    # Guard: inspect every staged path against a denylist and silently unstage any match.
    # docs/adr/ is exempt — ADR filenames legitimately contain words like "secret" or
    # "credential" (e.g. ADR-008-secrets-management.md) and must never be dropped.
    $denyPatterns = @('.env', '*.key', '*.pem', '*.pfx', '*secret*', '*credential*')
    foreach ($file in @(git diff --staged --name-only 2>&1)) {
        if ($file -like 'docs/adr/*') { continue }
        $leaf = Split-Path $file -Leaf
        if ($denyPatterns | Where-Object { $leaf -like $_ }) {
            git reset HEAD -- $file 2>&1 | Out-Null
            Write-Log "  WARNING: sensitive file unstaged from index: $file" -Color Red
        }
    }

    if (git diff --cached --name-only 2>&1) {
        $diff    = git diff --staged 2>&1 | Out-String
        $message = Get-CommitMessage -Diff $diff -FallbackMessage "feat(#${Number}): $Title"
        $msgFile = New-TemporaryFile
        try {
            $message | Out-File $msgFile.FullName -Encoding utf8
            $commitOut = git commit -F $msgFile.FullName 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "git commit failed for issue #${Number}:`n$commitOut" }
        } finally {
            Remove-Item $msgFile.FullName -ErrorAction SilentlyContinue
        }
    } else {
        # No new changes this run. Determine whether the branch as a whole has any
        # commits vs the default branch — if not, there is nothing to PR. This is
        # the typical state for tracker/coordinator issues whose acceptance criteria
        # are satisfied by previously-merged child PRs: the implement phase correctly
        # produces no diff, and forcing a PR here would fail with "no commits between
        # branches". Return $null so the caller (Invoke-Orchestration) closes the
        # issue as merged without invoking the review/merge stages.
        $defaultBranch = $KanbanDefaultBranch
        git fetch --quiet origin $defaultBranch 2>$null
        $aheadCount = [int]((git rev-list --count "origin/${defaultBranch}..HEAD" 2>$null) | Out-String).Trim()

        if ($aheadCount -eq 0) {
            Write-Log "  ✅ Already implemented — branch has no commits ahead of $defaultBranch. Skipping PR." -Color Green
            Add-Comment -Number $Number -Body "🤖✅ Already Implemented`n`nAll acceptance criteria are satisfied without code changes — branch ``$Branch`` has no commits ahead of ``$defaultBranch``. Tests pass. Closing as merged without raising a PR."
            return $null
        }

        Write-Log "  ✅ No new changes this run — prior commits on branch. Proceeding to PR." -Color Green
        Add-Comment -Number $Number -Body "🤖 Implementation`n`nNo new changes this run — branch already carries prior commits implementing this issue. Proceeding to PR and review."
    }

    # Capture stderr so any push rejection (workflow scope, branch protection,
    # secret scanning) surfaces in the thrown message. Previously `2>$null`
    # turned every push failure into a useless generic "git push failed" —
    # observed when issue #42 modified .github/workflows/ci.yml and the PAT
    # lacked the `workflow` scope; the real GitHub error never made it to logs.
    #
    # When origin already has this branch, push under a lease. A resumed retry or an
    # implement-time rebase (see Invoke-Implement) both leave HEAD unable to
    # fast-forward, which is what rejected issue #154's push outright. The lease still
    # refuses to overwrite commits this clone has not seen, so it is not a blind
    # --force; Merge.ps1 has used the same guard on its post-rebase push all along.
    # A brand-new branch has no remote-tracking ref for a lease to compare against,
    # so it takes the plain push.
    if (Test-RemoteBranch -Branch $Branch) {
        $pushOut = git push --force-with-lease --quiet origin "HEAD:refs/heads/$Branch" 2>&1 | Out-String
    } else {
        $pushOut = git push --quiet origin "HEAD:refs/heads/$Branch" 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed for branch ${Branch}:`n$($pushOut.Trim())"
    }

    $existing = gh pr list --head $Branch --json url --limit 1 | ConvertFrom-Json
    if ($existing.Count -gt 0) {
        $prUrl = $existing[0].url
        Write-Log "  PR already exists: $prUrl" -Color DarkGray
    } else {
        $body = @"
## Summary
Automated implementation for issue #$Number by Claude Code agent.

## Validation
- ``uv run pytest`` — ✅ passed (verified by orchestrator)

## Linked Issue
Closes #$Number
"@
        $tmp = New-TemporaryFile
        try {
            $body | Out-File $tmp.FullName -Encoding utf8
            $prUrl = gh pr create `
                --title "feat(#${Number}): $Title" `
                --body-file $tmp.FullName `
                --head $Branch 2>$null
            if ($LASTEXITCODE -ne 0) { throw "PR creation failed for issue #$Number" }
            $prUrl = $prUrl.Trim()
        } finally {
            Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
        }
        Write-Log "  PR created: $prUrl" -Color Green
    }

    Add-Comment -Number $Number -Body "· PR opened — $prUrl"
    return $prUrl
}

# ── Orchestrator entry point ──────────────────────────────────────────────────

function Invoke-Implement {
    param([int]$IssueNumber = 0, [switch]$Force)

    if ($IssueNumber -eq 0) { $IssueNumber = Get-CurrentIssueNumber }
    if ($IssueNumber -eq 0) {
        throw "No issue found — Invoke-Implement must be called with an explicit IssueNumber."
    }

    # Thin readiness re-check — alignment (refine/architect/plan) is a pre-backlog
    # gate; the orchestrator only picks agent:backlog issues, so a fully-aligned
    # state is expected here. Warn (don't re-align) if it is missing, e.g. an issue
    # was dispatched manually or its state block was hand-edited.
    $state = Get-PlanningState -IssueNumber $IssueNumber
    if (-not (Test-Readiness -State $state)) {
        Write-Log "  ⚠️ Issue #$IssueNumber reached Implementing without full alignment (refined+architected+planned). Proceeding; run 'task align' next time to align before backlog." -Color Yellow
    }

    $meta           = gh issue view $IssueNumber --repo $KanbanRepo --json title | ConvertFrom-Json
    $expectedBranch = Get-BranchName -Number $IssueNumber -Title $meta.title
    $branch         = git rev-parse --abbrev-ref HEAD

    if ($branch -ne $expectedBranch) {
        Write-Log "  Creating feature branch for issue #$IssueNumber..." -Color DarkGray
        Add-Comment -Number $IssueNumber -Body "· picked up — branch ``$expectedBranch``"
        $branch = New-FeatureBranch -Number $IssueNumber -Title $meta.title
    }

    # Reconcile with the default branch BEFORE writing code, not only at merge time.
    # Invoke-Merge rebases too (Merge.ps1), but by then the agent has finished and a
    # conflict lands on a human — PR #175 sat seven weeks and acquired a pyproject.toml
    # conflict that had to be resolved by hand. Rebasing here means drift surfaces
    # while the agent is still in the loop, and the implementation is written against
    # current main rather than a stale snapshot.
    #
    # A freshly-created branch is already at origin/<default>, so the rebase
    # short-circuits on the merge-base check and costs nothing. Only resumed branches
    # do real work here.
    #
    # The dirty-tree check matters for local runs: when the caller is ALREADY on the
    # feature branch, New-FeatureBranch (and its auto-stash) never ran, so `task start`
    # from a branch with uncommitted work would otherwise hit a hard
    # "cannot rebase: You have unstaged changes". Skipping is safe — Invoke-Merge still
    # rebases before merging, so this is an earlier opportunity, not the only one.
    if (Test-RemoteBranch -Branch $branch) {
        $dirtyTree = git status --porcelain 2>$null
        if ($dirtyTree) {
            Write-Log "  Working tree has uncommitted changes — skipping implement-time rebase (merge will still rebase)." -Color Yellow
        } else {
            Invoke-RebaseOnMaster -IssueNumber $IssueNumber -Branch $branch
        }
    }

    if (-not $Force) {
        $existingPR = gh pr list --head $branch --json number,url --limit 1 | ConvertFrom-Json
        if ($existingPR.Count -gt 0) {
            Write-Log "  PR #$($existingPR[0].number) already exists — skipping implement." -Color DarkGray
            return $existingPR[0].url
        }
    }

    Write-Log "▶ Implement — issue #$IssueNumber on $branch" -Color Cyan

    try {
        Invoke-Develop       -Number $IssueNumber -Branch $branch
        $prUrl = Invoke-CommitAndPR -Number $IssueNumber -Title $meta.title -Branch $branch

        if ($null -eq $prUrl) {
            # Invoke-CommitAndPR returned the no-diff sentinel — branch has no commits
            # ahead of the default branch. Skip the PR/review/merge stages; the caller
            # (Invoke-Orchestration) will mark this as merged and close the issue.
            Write-Log "✅ Implement complete — issue already satisfied; no PR needed." -Color Green
            return $null
        }

        Write-Log "✅ Implement complete — PR at $prUrl" -Color Green
        return $prUrl
    } catch {
        $errBlock = Format-ErrorBlock -Raw "$_"
        Add-Comment -Number $IssueNumber -Body "🤖❌ Implement Failed`n`n$errBlock"
        throw
    }
}
