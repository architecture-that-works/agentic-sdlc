#Requires -Version 7.0
<#
.SYNOPSIS
    Implementing lane -- Develop -> PR.

.DESCRIPTION
    Orchestrator library -- loaded by Orchestrator.psm1; Invoke-Implement is called by
    Orchestrator.psm1 for an issue in the Implementing lane.

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
# Module-internal library -- loaded by Orchestrator.psm1, which loads Config.ps1 and
# GitHub.ps1 before this file. See ADR-013.
# ── The record of what changed (#346) ─────────────────────────────────────────
# The "Files changed" list comes from git, never from the edits the agent asked for:
# an edit the engine refused changed nothing, and a file deleted by a shell command
# never appears as an edit. Every path that differs from the commit the attempt
# started from — commits made during the run, uncommitted changes, untracked files.
# Rename detection is off, so a rename reads as one deleted and one added path.
function Get-AttemptChangedFiles {
    param([string]$BaseCommit)
    $files = [System.Collections.Generic.List[object]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new()

    if ($BaseCommit) {
        $tokens = @((git -c core.quotePath=false diff --name-status --no-renames -z $BaseCommit 2>$null) -join '' -split [char]0 |
                    Where-Object { $_ })
        for ($i = 0; $i + 1 -lt $tokens.Count; $i += 2) {
            $change = switch -Regex ($tokens[$i]) {
                '^A'    { 'added' }
                '^D'    { 'deleted' }
                default { 'changed' }   # M, T (and anything rename-free git reports)
            }
            $path = $tokens[$i + 1]
            if ($seen.Add($path)) { $files.Add([pscustomobject]@{ path = $path; change = $change }) }
        }
    }

    $untracked = @((git -c core.quotePath=false ls-files --others --exclude-standard -z 2>$null) -join '' -split [char]0 |
                   Where-Object { $_ })
    foreach ($path in $untracked) {
        if ($seen.Add($path)) { $files.Add([pscustomobject]@{ path = $path; change = 'added' }) }
    }
    $global:LASTEXITCODE = 0
    return $files.ToArray()
}

# The "Files changed" section of the 🤖 Implementation record, or '' when nothing did.
function Format-ChangedFiles {
    param([array]$ChangedFiles)
    $entries = @($ChangedFiles | Where-Object { $_ })
    if ($entries.Count -eq 0) { return '' }
    $lines = ($entries | ForEach-Object { "- ``$($_.path)`` — $($_.change)" }) -join "`n"
    return "`n`n**Files changed ($($entries.Count)):**`n$lines"
}

# The five dense lines of the 🤖 Implementation record, shared by every way an
# attempt ends: Commands and Procedure are returned too, for the Attempts entry.
function New-ImplementationRecord {
    param([hashtable]$DevResult, [array]$Commands)
    $commandsLine  = (@($Commands | Where-Object { $_ }) | ForEach-Object { "$($_.Name) → $($_.Exit)" }) -join '  '
    $procedureLine = "AGENTS.md $(if ($DevResult.AgentsMdRead)  {'✓'} else {'✗'})  " +
                     "CONTEXT.md $(if ($DevResult.ContextMdRead) {'✓'} else {'✗'})  " +
                     "skill $(if ($DevResult.SkillRead)          {'✓'} else {'✗'})  " +
                     "pytest $(if ($DevResult.TestedOnce)        {'✓'} else {'✗'})"
    $body = "🤖 Implementation$($DevResult.FileSection)" +
            "`n`nImplemented: $($DevResult.Implemented)" +
            "`nLeft undone: $($DevResult.LeftUndone)" +
            "`nIssues discovered: $($DevResult.IssuesDiscovered)" +
            "`nCommands: $commandsLine" +
            "`nProcedure: $procedureLine"
    return @{ Body = $body; Commands = $commandsLine; Procedure = $procedureLine }
}

# The 🤖 signal that ends a round on a refused edit: each file, why a retry cannot
# help, and what the owner does next. SECURITY.md § Protected paths explains it.
function Format-RefusalComment {
    param([string[]]$RefusedFiles, [string]$Branch, [string]$PushNote = '')
    $list = ($RefusedFiles | ForEach-Object { "- ``$_`` — the engine protects this path" }) -join "`n"
    $body = "🤖❌ Engine refused an edit — needs you`n`n" +
            "The engine would not change these file(s). It protects them in an unattended run, whatever the " +
            "allow rules say, so another attempt cannot help and none was started:`n`n$list`n`n" +
            "The change to these files is yours to make: commit it on branch ``$Branch``, then comment on this " +
            "issue — that starts a new round, which builds on the branch and opens the PR."
    if ($PushNote) { $body += "`n`n$PushNote" }
    $body += "`n`nWhy: [SECURITY.md — Protected paths](https://github.com/$KanbanRepo/blob/$KanbanDefaultBranch/SECURITY.md#protected-paths)."
    return $body
}

# ── Phase 1: Develop ──────────────────────────────────────────────────────────

function Invoke-Develop {
    param([int]$Number, [string]$Branch, [string]$BaseCommit = '')
    Write-Log "  Phase 1 — Develop issue #$Number on $Branch" -Color Yellow
    Move-ToLane -IssueNumber $Number -OptionId $KanbanOpt_Implementing -LaneName 'Implementing'
    Add-Comment -Number $Number -Body "· branch checked out — starting"

    if ((Get-ChildItem .agents/skills -Recurse -Filter *.md -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-Log "⚠️ Skills directory is empty — agent constraints will not be applied." -Color Yellow
    }

    $issue = gh issue view $Number --repo $KanbanRepo --json title,body | ConvertFrom-Json

    # Retrieve all agent signal comments (🤖-prefixed) — full decision history for this issue.
    # Includes review rejections, CI failures, prior implementation summaries, and errors.
    $signal = (Get-SignalComments -IssueNumber $Number) -join "`n---`n"
    $signalSection = if ($signal.Trim()) {
        "`nISSUE SIGNAL HISTORY (agent decisions and outcomes — address all rejections and failures before finishing):`n$($signal.Trim())"
    } else { '' }

    $prompt = @"
You are implementing GitHub issue #$Number on branch $Branch in this repository.

ISSUE TITLE: $($issue.title)

ISSUE BODY:
$($issue.body)
$(Format-OwnerComments -IssueNumber $Number)$signalSection
INSTRUCTIONS:
0. If the issue body has an "Attempts" section, earlier attempts failed. Read each failure there
   and in the signal history (test output, review rejections, CI logs), find the root cause with the
   ``diagnosis`` skill (``.agents/skills/diagnosis/SKILL.md``), and fix it — do not repeat an approach
   that already failed. The branch may already hold earlier work; build on it.
1. Read AGENTS.md and CONTEXT.md first to understand the project boundaries and constraints.
2. Read the relevant parts of the codebase before writing any code.
3. Implement every requirement listed in the issue body completely.
4. Follow all conventions in AGENTS.md. The skill files in ``.agents/skills/`` are your constraint documents — locate the relevant skill via the Skills index in AGENTS.md, then read its SKILL.md (and REFERENCE.md / EXAMPLES.md if linked) before implementing.
5. After implementation run ``uv run pytest`` to verify the test suite passes.
6. If tests fail, diagnose and fix the root cause before stopping.
7. Do NOT commit any changes — only implement.
8. End your response with bullets — the orchestrator posts them to the issue: one per file you
   changed, then ``- Left undone:`` (what you skipped or did not check) and ``- Issues discovered:``
   (what the owner must know — a risk, a bug outside scope, a stale document). Write ``none``
   rather than omitting either.
"@

    $sp       = Get-IssueEstimate -IssueNumber $Number
    $devModel = Get-PhaseModel -Estimate $sp -Phase 'implement'
    $devTurns = Get-ImplementMaxTurns -Estimate $sp
    Write-Log "  Model: $devModel  SP=$sp  max-turns=$devTurns" -Color DarkGray

    $allText           = [System.Text.StringBuilder]::new()
    $streamEvents      = [System.Collections.Generic.List[object]]::new()
    $explorationPosted = $false
    $writingPosted     = $false
    $testedOnce        = $false

    $stream = if ($KanbanEngine -eq 'gemini') {
        $prompt | agy --model $devModel --allowedTools "Read,Write,Edit,Bash,Glob,Grep" --max-turns $devTurns --output-format stream-json --verbose 2>&1
    } else {
        $prompt | claude --model $devModel --allowedTools "Read,Write,Edit,Bash,Glob,Grep" --max-turns $devTurns --output-format stream-json --verbose 2>&1
    }

    $stream | ForEach-Object {
        $raw = [string]$_
        try {
            $ev = $raw | ConvertFrom-Json -ErrorAction Stop
            $streamEvents.Add($ev)

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
                        if ($block.name -in @('Write','Edit') -and $block.input.file_path -and -not $writingPosted) {
                            $writingPosted = $true
                            Add-Comment -Number $Number -Body "· writing implementation"
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

    if ($LASTEXITCODE -ne 0) { throw "Agent CLI exited with code $LASTEXITCODE." }

    # Split the last 20 agent bullets into Implemented / Left undone / Issues discovered.
    $bullets  = ($allText.ToString() -split '\r?\n') |
                Where-Object { $_ -match '^\s*[-*•]' } |
                Select-Object -Last 20
    $implLines = @($bullets | Where-Object { $_ -notmatch '^\s*[-*•]\s+Left undone:' -and
                                              $_ -notmatch '^\s*[-*•]\s+Issues discovered:' })
    $luLine    = $bullets | Where-Object { $_ -match '^\s*[-*•]\s+Left undone:' }    | Select-Object -First 1
    $idLine    = $bullets | Where-Object { $_ -match '^\s*[-*•]\s+Issues discovered:' } | Select-Object -First 1

    $implementedText = if ($implLines) {
        ($implLines | ForEach-Object { ($_ -replace '^\s*[-*•]\s+', '').Trim() }) -join '; '
    } else { 'none' }
    $leftUndoneText  = if ($luLine)  { ($luLine  -replace '^\s*[-*•]\s+Left undone:\s*',     '').Trim() } else { 'none' }
    $issuesDiscText  = if ($idLine)  { ($idLine  -replace '^\s*[-*•]\s+Issues discovered:\s*', '').Trim() } else { 'none' }

    # What really changed (git) and what the engine refused (its result event).
    $changedFiles = @(Get-AttemptChangedFiles -BaseCommit $BaseCommit)
    $fileSection  = Format-ChangedFiles -ChangedFiles $changedFiles
    $repoRoot     = "$(git rev-parse --show-toplevel 2>$null)".Trim()
    $refusedFiles = @(Get-RefusedFiles -StreamEvents $streamEvents.ToArray() -RepoRoot $repoRoot)
    if ($refusedFiles.Count -gt 0) {
        Write-Log "  ⛔ The engine refused edits to: $($refusedFiles -join ', ')" -Color Red
    }

    Write-Log "  Implementation finished for issue #$Number." -Color Green

    # Independent verification — output posted as signal so the reviewer can read exact results.
    Write-Log "  Running test suite independently..." -Color DarkGray
    $testOutput = uv run pytest --tb=short -q 2>&1 | Out-String
    $pytestExit = $LASTEXITCODE
    $phaseOneCommands = @([pscustomobject]@{ Name = 'pytest'; Exit = $pytestExit })

    if ($pytestExit -ne 0) {
        $errBlock = Format-ErrorBlock -Raw $testOutput
        Add-Comment -Number $Number -Body "🤖⚠️ Tests Failing`n`n$errBlock"
    } else {
        $testSummary = (($testOutput -split '\r?\n') | Where-Object { $_.Trim() } | Select-Object -Last 4) -join "`n"
        Add-Comment -Number $Number -Body "🤖✅ Tests Passing`n``````text`n$($testSummary.Trim())`n``````"
        Write-Log "  Tests passing ✅" -Color Green
    }

    $proc = Get-ProcedureRecord -StreamEvents $streamEvents.ToArray()

    return @{
        FileSection      = $fileSection
        ChangedFiles     = $changedFiles
        RefusedFiles     = $refusedFiles
        Implemented      = $implementedText
        LeftUndone       = $leftUndoneText
        IssuesDiscovered = $issuesDiscText
        PhaseOneCommands = $phaseOneCommands
        AgentsMdRead     = $proc.agentsMdRead
        ContextMdRead    = $proc.contextMdRead
        SkillRead        = $proc.skillRead
        TestedOnce       = $testedOnce
        TestsPassed      = ($pytestExit -eq 0)
    }
}

# ── Phase 2: Commit + PR ──────────────────────────────────────────────────────

function Invoke-CommitAndPR {
    # -NoPR commits and pushes only (#346): a round the engine's refusal ended keeps
    # the rest of its work on the branch for the owner, without a PR or a review.
    param([int]$Number, [string]$Title, [string]$Branch, [switch]$NoPR)
    Write-Log "  Phase 2 — Commit $(if ($NoPR) { '+ push (no PR)' } else { '+ PR' }) for issue #$Number" -Color Yellow

    $commands = [System.Collections.Generic.List[object]]::new()

    # Auto-format before staging so ruff format --check in CI always passes.
    $fmtOut = uv run ruff format . 2>&1 | Out-String
    $commands.Add([pscustomobject]@{ Name = 'ruff'; Exit = $LASTEXITCODE })
    Write-Log "  ruff format: $($fmtOut.Trim())" -Color DarkGray

    # ── Allowlist classification ──────────────────────────────────────────────────
    # WritablePaths decides whether a PR can auto-merge, not whether the agent may
    # write (#285). A change outside it is staged and committed like any other, and
    # ship then holds the PR at human:approval with the diff named, so the owner
    # approves or rejects it. Blocking the commit instead meant the agent could not
    # even produce a diff for the owner to read — and the owner had to write every
    # pipeline change by hand.
    #
    # A missing or empty WritablePaths is fail-safe, not fatal: with no allowlist
    # nothing is auto-mergeable, so every path counts as a proposal and ship holds.
    $writablePaths = if ($OrchestratorConfig.ContainsKey('WritablePaths')) { @($OrchestratorConfig.WritablePaths) } else { @() }
    if ($writablePaths.Count -eq 0) {
        Write-Log "  ⚠️ WritablePaths is missing or empty — treating every change as a proposal." -Color Yellow
    }

    # Enumerate all changed paths before any git add.
    $changedPaths = @(@(git status --porcelain 2>&1) |
        Where-Object { $_.Trim() } |
        ForEach-Object {
            $entry = $_.Substring(3).Trim()
            if ($entry -match ' -> ') { ($entry -split ' -> ')[1] } else { $entry }
        } | Where-Object { $_ })

    # Name them in the issue when they exist. Ship re-derives this from the PR diff —
    # the diff is the truth, and this is only the early warning.
    $outOfBounds = @($changedPaths | Where-Object {
        $p = $_
        -not ($writablePaths | Where-Object { $p -like $_ })
    })
    if ($outOfBounds.Count -gt 0) {
        Write-Log "  $($outOfBounds.Count) changed path(s) outside the write allowlist — the PR will be held for approval." -Color Yellow
        foreach ($p in $outOfBounds) { Write-Log "    proposal: $p" -Color DarkGray }
    }

    # Stage every changed path. The secrets denylist below is the one absolute bar.
    foreach ($p in $changedPaths) {
        git add -- $p 2>&1 | Out-Null
    }

    # Guard: inspect staged additions/modifications (deletions excluded) against a denylist;
    # unstage any match and report each dropped path in a 🤖 signal comment.
    # .md files are never dropped by name pattern — a document named after secrets is not a secret.
    # Extension-based patterns (.env, *.key, *.pem, *.pfx) remain unconditional for all extensions.
    $denyPatterns  = @('.env', '*.key', '*.pem', '*.pfx')
    $namePatterns  = @('*secret*', '*credential*')
    $unstagedPaths = @()
    $stagedAddMod  = @((git diff --staged --name-only --diff-filter=d -z 2>&1) -split [char]0 | Where-Object { $_ })
    foreach ($file in $stagedAddMod) {
        $leaf    = Split-Path $file -Leaf
        $blocked = $false
        if ($denyPatterns | Where-Object { $leaf -like $_ }) { $blocked = $true }
        elseif ($leaf -notlike '*.md' -and ($namePatterns | Where-Object { $leaf -like $_ })) { $blocked = $true }
        if ($blocked) {
            git reset HEAD -- $file 2>&1 | Out-Null
            Write-Log "  WARNING: sensitive file unstaged from index: $file" -Color Red
            $unstagedPaths += $file
        }
    }
    if ($unstagedPaths.Count -gt 0) {
        $lines = $unstagedPaths | ForEach-Object { "Unstaged by the secrets denylist: $_" }
        Add-Comment -Number $Number -Body ("🤖 Secrets Denylist`n`n" + ($lines -join "`n"))
    }

    if (git diff --cached --name-only 2>&1) {
        $diff    = git diff --staged 2>&1 | Out-String
        $message = if ($KanbanEngine -eq 'gemini') {
            Get-GeminiCommitMessage -Diff $diff -FallbackMessage "feat(#${Number}): $Title"
        } else {
            Get-CommitMessage -Diff $diff -FallbackMessage "feat(#${Number}): $Title"
        }
        $msgFile = New-TemporaryFile
        try {
            $message | Out-File $msgFile.FullName -Encoding utf8
            $commitOut = git commit -F $msgFile.FullName 2>&1 | Out-String
            $commands.Add([pscustomobject]@{ Name = 'git commit'; Exit = $LASTEXITCODE })
            if ($LASTEXITCODE -ne 0) { throw "git commit failed for issue #${Number}:`n$commitOut" }
        } finally {
            Remove-Item $msgFile.FullName -ErrorAction SilentlyContinue
        }
    } elseif ($NoPR) {
        Write-Log "  No changes to commit — nothing to push." -Color DarkGray
        return @{ PrUrl = $null; Commands = $commands.ToArray(); Pushed = $false }
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
            return @{ PrUrl = $null; Commands = $commands.ToArray() }
        }

        Write-Log "  ✅ No new changes this run — prior commits on branch. Proceeding to PR." -Color Green
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
    # --force; Ship.ps1 has used the same guard on its post-rebase push all along.
    # A brand-new branch has no remote-tracking ref for a lease to compare against,
    # so it takes the plain push.
    if (Test-RemoteBranch -Branch $Branch) {
        $pushOut = git push --force-with-lease --quiet origin "HEAD:refs/heads/$Branch" 2>&1 | Out-String
    } else {
        $pushOut = git push --quiet origin "HEAD:refs/heads/$Branch" 2>&1 | Out-String
    }
    $commands.Add([pscustomobject]@{ Name = 'git push'; Exit = $LASTEXITCODE })
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed for branch ${Branch}:`n$($pushOut.Trim())"
    }
    if ($NoPR) {
        Write-Log "  Pushed to $Branch — no PR opened." -Color DarkGray
        return @{ PrUrl = $null; Commands = $commands.ToArray(); Pushed = $true }
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
    return @{ PrUrl = $prUrl; Commands = $commands.ToArray() }
}

# ── Orchestrator entry point ──────────────────────────────────────────────────

function Invoke-Implement {
    param([int]$IssueNumber = 0, [switch]$Force, [switch]$Revise)

    if ($IssueNumber -eq 0) { $IssueNumber = Get-CurrentIssueNumber }
    if ($IssueNumber -eq 0) {
        throw "No issue found — Invoke-Implement must be called with an explicit IssueNumber."
    }

    # Thin readiness re-check — alignment (refine/architect/plan) is a pre-backlog
    # gate; the orchestrator only picks agent:backlog issues, so a fully-aligned
    # state is expected here. Warn (don't re-align) if it is missing, e.g. an issue
    # was dispatched manually or its state block was hand-edited.
    $state = Get-IssueState -IssueNumber $IssueNumber
    if (-not (Test-Readiness -State $state)) {
        Write-Log "  ⚠️ Issue #$IssueNumber reached Implementing without full alignment (refined+architected+planned). Proceeding; run 'task refine' next time to align before backlog." -Color Yellow
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
    # Invoke-Ship rebases too (Ship.ps1), but by then the agent has finished and a
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
    # feature branch, New-FeatureBranch (and its auto-stash) never ran, so `task hitl`
    # from a branch with uncommitted work would otherwise hit a hard
    # "cannot rebase: You have unstaged changes". Skipping is safe — Invoke-Ship still
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

    $headBefore  = git rev-parse HEAD 2>$null
    $devResult   = $null
    $testsFailed = $false   # set when this stage already posted and recorded the failure
    try {
        $devResult = Invoke-Develop -Number $IssueNumber -Branch $branch -BaseCommit $headBefore

        $stateForAttempt = Get-IssueState -IssueNumber $IssueNumber
        $runAttempt      = if ($stateForAttempt -and $stateForAttempt.PSObject.Properties['attempt_count']) { [int]$stateForAttempt.attempt_count + 1 } else { 1 }
        $maxR            = (Get-OrchestratorContext).MaxRetries

        $refused = @($devResult.RefusedFiles | Where-Object { $_ })
        if ($refused.Count -gt 0) {
            # The engine refused an edit to a path it protects (#346). The refusal is a
            # property of the path, not of the attempt, so the round ends here, before
            # the tests-failed retry and without a review. The rest of the work is
            # pushed to the branch (no PR) so the owner can add the protected change.
            $pushNote = ''
            $commitCmds = @()
            try {
                $commitResult = Invoke-CommitAndPR -Number $IssueNumber -Title $meta.title -Branch $branch -NoPR
                $commitCmds   = @($commitResult.Commands)
                if (-not $commitResult.Pushed) { $pushNote = "The attempt changed nothing else, so nothing was pushed." }
            } catch {
                Write-Log "  ⚠️ Could not push the attempt's other work: $_" -Color Yellow
                $pushNote = "⚠️ The attempt's other work could not be pushed to the branch:`n``````text`n$("$_".Trim())`n``````"
            }

            $record = New-ImplementationRecord -DevResult $devResult -Commands (@($devResult.PhaseOneCommands) + $commitCmds)
            Add-Comment -Number $IssueNumber -Body $record.Body

            $reason = "Engine refused edits to protected path(s): $($refused -join ', ')"
            Add-ImplementAttempt -IssueNumber $IssueNumber -Stage 'implement' -Reason $reason `
                -Attempt $runAttempt -Max $maxR `
                -Implemented $devResult.Implemented -LeftUndone $devResult.LeftUndone `
                -IssuesDiscovered $devResult.IssuesDiscovered -Commands $record.Commands -Procedure $record.Procedure

            Add-Comment -Number $IssueNumber -Body (Format-RefusalComment -RefusedFiles $refused -Branch $branch -PushNote $pushNote)

            $testsFailed = $true
            throw "ATTEMPT-RECORDED|ENGINE-REFUSED|$reason"
        }

        if (-not $devResult.TestsPassed) {
            # Post a partial Implementation comment, then throw for retry.
            $record = New-ImplementationRecord -DevResult $devResult -Commands @($devResult.PhaseOneCommands)
            Add-Comment -Number $IssueNumber -Body $record.Body
            Add-ImplementAttempt -IssueNumber $IssueNumber -Stage 'implement' -Reason 'Tests failed' `
                -Attempt $runAttempt -Max $maxR `
                -Implemented $devResult.Implemented -LeftUndone $devResult.LeftUndone `
                -IssuesDiscovered $devResult.IssuesDiscovered -Commands $record.Commands -Procedure $record.Procedure

            $testsFailed = $true
            throw "ATTEMPT-RECORDED|Test suite failed after implementation for issue #$IssueNumber"
        }

        $commitResult = Invoke-CommitAndPR -Number $IssueNumber -Title $meta.title -Branch $branch
        $prUrl        = $commitResult.PrUrl

        # The unified 🤖 Implementation comment with five dense lines.
        $record = New-ImplementationRecord -DevResult $devResult -Commands (@($devResult.PhaseOneCommands) + @($commitResult.Commands))
        Add-Comment -Number $IssueNumber -Body $record.Body
        Add-ImplementAttempt -IssueNumber $IssueNumber -Stage 'implement' -Reason '' `
            -Attempt $runAttempt -Max $maxR `
            -Implemented $devResult.Implemented -LeftUndone $devResult.LeftUndone `
            -IssuesDiscovered $devResult.IssuesDiscovered -Commands $record.Commands -Procedure $record.Procedure

        if ($null -eq $prUrl) {
            # Invoke-CommitAndPR returned the no-diff sentinel — branch has no commits
            # ahead of the default branch. Skip the PR/review/merge stages; the caller
            # (Invoke-Orchestration) will mark this as merged and close the issue.
            Write-Log "✅ Implement complete — issue already satisfied; no PR needed." -Color Green
            return $null
        }

        if ($Revise) {
            # Only a revision reads "no new commits" as an answered question. A retry also
            # runs with -Force and may find nothing left to commit (the owner fixed it by
            # hand); it must go on to review with the existing PR, not close the issue.
            $newCommits = [int](git rev-list --count "${headBefore}..HEAD" 2>$null)
            if ($newCommits -eq 0) {
                # The revision produced no new commits — the owner asked a question.
                Write-Log "✅ Implement complete — question answered, no new commits." -Color Green
                return $null
            }
        }

        Write-Log "✅ Implement complete — PR at $prUrl" -Color Green
        return $prUrl
    } catch {
        if (-not $testsFailed) {
            $errBlock = Format-ErrorBlock -Raw "$_"
            Add-Comment -Number $IssueNumber -Body "🤖❌ Implement Failed`n`n$errBlock"
        }
        throw
    }
}
