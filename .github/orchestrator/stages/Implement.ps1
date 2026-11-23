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

    Phase 1 Develop -- the engine implements every requirement; verifies with
                       the full test command (.github/tasks/test.ps1).
    Phase 2 PR      -- commits (engine-generated message), pushes, opens the PR or
                       rewrites its description, from the pull request template.

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

# The 🤖 signal that ends a round on conflict markers left after the agent's turn
# (#367): each file, and what the owner does next.
function Format-MarkersLeftComment {
    param([string[]]$MarkerFiles, [string]$Branch)
    $list = ($MarkerFiles | ForEach-Object { "- ``$_``" }) -join "`n"
    return "🤖❌ Conflict markers left — needs you`n`n" +
           "Merging ``$KanbanDefaultBranch`` into ``$Branch`` conflicted, and after the agent's turn these file(s) " +
           "still hold conflict markers, so the merge was aborted, nothing was pushed and no retry was started:`n`n$list`n`n" +
           "Resolve these files on branch ``$Branch`` — with GitHub's conflict editor on the pull request, or by " +
           "merging ``$KanbanDefaultBranch`` locally — then comment on this issue. That starts a new round with " +
           "your comment in the agent's instructions."
}

# ── Phase 1: Develop ──────────────────────────────────────────────────────────

# The MERGE CONFLICT section of the agent prompt (#367), '' when nothing conflicts.
# It comes before the numbered instructions: settling the merge is the first task.
function Format-ConflictInstructions {
    param([string[]]$Conflicts)
    $files = @($Conflicts | Where-Object { $_ })
    if ($files.Count -eq 0) { return '' }
    $list = ($files | ForEach-Object { "- $_" }) -join "`n"
    return @"

MERGE CONFLICT:
The orchestrator merged $KanbanDefaultBranch into this branch, and these files conflict:
$list
Resolving these conflicts is your FIRST task, before anything else. In each file, keep what
both sides changed — combine the two versions rather than choosing one — and remove every
conflict marker line (``<<<<<<<``, ``=======``, ``>>>>>>>``). Edit the files only: never run
``git merge``, ``git commit``, ``git merge --abort`` or ``git push``. The orchestrator completes the
merge, runs the tests and pushes. Conflict markers left in any of these files end the round.

"@
}

function Invoke-Develop {
    param([int]$Number, [string]$Branch, [string]$BaseCommit = '', [string[]]$Conflicts = @())
    Write-Log "  Phase 1 — Develop issue #$Number on $Branch" -Color Yellow
    Move-ToLane -IssueNumber $Number -OptionId (Get-LaneOptionId -LaneName 'Implementing') -LaneName 'Implementing'
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
$(Format-ConflictInstructions -Conflicts $Conflicts)INSTRUCTIONS:
0. If the issue body has an "Attempts" section, earlier attempts failed. Read each failure there
   and in the signal history (test output, review rejections, CI logs), find the root cause with the
   ``diagnosis`` skill (``.agents/skills/diagnosis/SKILL.md``), and fix it — do not repeat an approach
   that already failed. The branch may already hold earlier work; build on it.
1. Read AGENTS.md and CONTEXT.md first to understand the project boundaries and constraints.
2. Read the relevant parts of the codebase before writing any code.
3. Implement every requirement listed in the issue body completely.
4. Follow all conventions in AGENTS.md. The skill files in ``.agents/skills/`` are your constraint documents — locate the relevant skill via the Skills index in AGENTS.md, then read its SKILL.md (and REFERENCE.md / EXAMPLES.md if linked) before implementing.
5. After implementation run the tests of what you changed (a test, a test file or a folder) with ``uv run pytest <target>``, and run ``uv run ruff check``. Do not run the whole suite: the orchestrator runs it after you finish.
6. If the tests you ran fail, diagnose and fix the root cause before stopping.
7. Do NOT commit any changes — only implement.
8. End your response with bullets — the orchestrator posts them to the issue: one per file you
   changed, then ``- Left undone:`` (what you skipped or did not check) and ``- Issues discovered:``
   (what the owner must know — a risk, a bug outside scope, a stale document). Write ``none``
   rather than omitting either.
"@

    $sp       = Get-IssueEstimate -IssueNumber $Number
    $devTask  = Get-ImplementTask -Estimate $sp
    $devTurns = Get-ImplementMaxTurns -Estimate $sp
    Write-Log "  Task: $devTask  SP=$sp  max-turns=$devTurns" -Color DarkGray

    # Progress while the run is going: the engine hands each tool call to the callback,
    # which posts the three progress comments once each and keeps the calls for the
    # Procedure line. A hashtable, so the callback's changes outlive its scope.
    $implementProgress = @{
        Explored = $false; Writing = $false; Tested = $false
        Calls    = [System.Collections.Generic.List[object]]::new()
    }
    $onToolCall = {
        param($call)
        $implementProgress.Calls.Add($call)
        if ($call.Name -in @('Read', 'Glob', 'Grep') -and -not $implementProgress.Explored) {
            $implementProgress.Explored = $true
            Add-Comment -Number $Number -Body "· exploring codebase"
        }
        if ($call.Name -in @('Write', 'Edit') -and $call.Input.file_path -and -not $implementProgress.Writing) {
            $implementProgress.Writing = $true
            Add-Comment -Number $Number -Body "· writing implementation"
        }
        if ($call.Name -eq 'Bash' -and "$($call.Input.command)" -match 'pytest' -and -not $implementProgress.Tested) {
            $implementProgress.Tested = $true
            Add-Comment -Number $Number -Body "· running tests"
        }
    }

    $run = Invoke-EngineTask -Task $devTask -Prompt $prompt -Label 'Implement' `
        -Tools 'Read', 'Write', 'Edit', 'Bash', 'Glob', 'Grep' -MaxTurns $devTurns -OnToolCall $onToolCall
    if ($run.Outcome -eq 'max_turns') {
        throw "Implement used its whole turn budget ($devTurns) before it finished."
    }
    if ($run.Outcome -ne 'finished') { throw "The engine failed to implement: $($run.Cause)" }
    $testedOnce = $implementProgress.Tested
    $toolCalls  = $implementProgress.Calls.ToArray()

    # Split the last 20 agent bullets into Implemented / Left undone / Issues discovered.
    $bullets  = ("$($run.Reply)" -split '\r?\n') |
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

    # A merge left in conflict at the start of the attempt (#367) is completed before
    # anything is measured: the merge commit — with the agent's resolution — becomes
    # the attempt's base, so nothing that came in from the default branch is counted
    # as the attempt's change. Markers left behind end here, before the tests.
    $conflicts   = @($Conflicts | Where-Object { $_ })
    $markerFiles = @()
    if ($conflicts.Count -gt 0) {
        $completion  = Complete-BranchUpdate -IssueNumber $Number -Branch $Branch -Conflicts $conflicts
        $markerFiles = @($completion.MarkerFiles | Where-Object { $_ })
        if ($markerFiles.Count -eq 0) { $BaseCommit = "$(git rev-parse HEAD 2>$null)".Trim() }
    }
    if ($markerFiles.Count -gt 0) {
        $proc = Get-ProcedureRecord -ToolCalls $toolCalls
        return @{
            FileSection      = ''
            ChangedFiles     = @()
            RefusedFiles     = @()
            MarkerFiles      = $markerFiles
            AttemptBase      = $BaseCommit
            Implemented      = $implementedText
            LeftUndone       = $leftUndoneText
            IssuesDiscovered = $issuesDiscText
            PhaseOneCommands = @()
            AgentsMdRead     = $proc.agentsMdRead
            ContextMdRead    = $proc.contextMdRead
            SkillRead        = $proc.skillRead
            TestedOnce       = $testedOnce
            TestsPassed      = $false
        }
    }

    # What really changed (git) and what the engine refused (its result event).
    # The conflicted files the agent resolved are the attempt's work too, even though
    # the merge commit already holds them.
    $changedFiles = @(Get-AttemptChangedFiles -BaseCommit $BaseCommit)
    $listed       = @($changedFiles | ForEach-Object { $_.path })
    foreach ($f in $conflicts) {
        if ($listed -notcontains $f) { $changedFiles += [pscustomobject]@{ path = $f; change = 'changed' } }
    }
    $fileSection  = Format-ChangedFiles -ChangedFiles $changedFiles
    $refusedFiles = @($run.RefusedEdits)
    if ($refusedFiles.Count -gt 0) {
        Write-Log "  ⛔ The engine refused edits to: $($refusedFiles -join ', ')" -Color Red
    }

    Write-Log "  Implementation finished for issue #$Number." -Color Green

    # Independent verification — the one full test command (pytest, then Pester), run
    # in the working tree it verifies; its output is posted as signal so the reviewer
    # can read exact results. The command ends with one summary line per runner.
    Write-Log "  Running the full test command independently..." -Color DarkGray
    $testOutput = pwsh -NoProfile -File .github/tasks/test.ps1 2>&1 | Out-String
    $testExit   = $LASTEXITCODE
    $phaseOneCommands = @([pscustomobject]@{ Name = 'test'; Exit = $testExit })

    if ($testExit -ne 0) {
        $errBlock = Format-ErrorBlock -Raw $testOutput
        Add-Comment -Number $Number -Body "🤖⚠️ Tests Failing`n`n$errBlock"
    } else {
        $testSummary = (($testOutput -split '\r?\n') | Where-Object { $_.Trim() } | Select-Object -Last 4) -join "`n"
        Add-Comment -Number $Number -Body "🤖✅ Tests Passing`n``````text`n$($testSummary.Trim())`n``````"
        Write-Log "  Tests passing ✅" -Color Green
    }

    $proc = Get-ProcedureRecord -ToolCalls $toolCalls

    return @{
        FileSection      = $fileSection
        ChangedFiles     = $changedFiles
        RefusedFiles     = $refusedFiles
        MarkerFiles      = @()
        AttemptBase      = $BaseCommit
        Implemented      = $implementedText
        LeftUndone       = $leftUndoneText
        IssuesDiscovered = $issuesDiscText
        PhaseOneCommands = $phaseOneCommands
        AgentsMdRead     = $proc.agentsMdRead
        ContextMdRead    = $proc.contextMdRead
        SkillRead        = $proc.skillRead
        TestedOnce       = $testedOnce
        TestsPassed      = ($testExit -eq 0)
    }
}

# ── Phase 2: Commit + PR ──────────────────────────────────────────────────────

function Invoke-CommitAndPR {
    # -NoPR commits and pushes only (#346): a round the engine's refusal ended keeps
    # the rest of its work on the branch for the owner, without a PR or a review.
    #
    # The PR description is filled from the pull request template (#375) with the
    # round's facts: the closing note's three values and every command run — those
    # before this step (-PriorCommands) and this step's own. The template is read and
    # checked before anything is staged, so a broken one stops the round before any
    # commit or push; it is filled after the push, so Validation lists the push too.
    param(
        [int]$Number, [string]$Title, [string]$Branch, [switch]$NoPR,
        [string]$Implemented = '', [string]$LeftUndone = '', [string]$IssuesDiscovered = '',
        [array]$PriorCommands = @()
    )
    Write-Log "  Phase 2 — Commit $(if ($NoPR) { '+ push (no PR)' } else { '+ PR' }) for issue #$Number" -Color Yellow

    $prTemplate = $null
    if (-not $NoPR) {
        $prTemplate = Get-PullRequestTemplate
        $null = Format-PullRequestBody -Template $prTemplate -Number $Number
    }

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
    # An empty WritablePaths is fail-safe, not fatal: with no allowlist
    # nothing is auto-mergeable, so every path counts as a proposal and ship holds.
    $writablePaths = @($OrchestratorConfig.WritablePaths)
    if ($writablePaths.Count -eq 0) {
        Write-Log "  ⚠️ WritablePaths is empty — treating every change as a proposal." -Color Yellow
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

    # The pull request's title is the first line of the message written for the commit
    # it is opened on (#417); without a new commit of this round, the fallback's.
    $prTitle = $null
    if (git diff --cached --name-only 2>&1) {
        $diff    = git diff --staged 2>&1 | Out-String
        $message = (Get-CommitMessage -Diff $diff -Number $Number -Title $Title).Message
        $prTitle = @($message -split '\r?\n')[0]
        $msgFile = New-TemporaryFile
        try {
            $message | Out-File $msgFile.FullName -Encoding utf8
            $commitOut = git commit -F $msgFile.FullName 2>&1 | Out-String
            $commands.Add([pscustomobject]@{ Name = 'git commit'; Exit = $LASTEXITCODE })
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

        # -NoPR: commits the agent made during the run still need the push below (#346).
        if ($aheadCount -eq 0 -and $NoPR) { return @{ PrUrl = $null; Commands = $commands.ToArray(); Pushed = $false } }
        if ($aheadCount -eq 0) {
            Write-Log "  ✅ Already implemented — branch has no commits ahead of $defaultBranch. Skipping PR." -Color Green
            Add-Comment -Number $Number -Body "🤖✅ Already Implemented`n`nAll acceptance criteria are satisfied without code changes — branch ``$Branch`` has no commits ahead of ``$defaultBranch``. Tests pass. Closing as merged without raising a PR."
            return @{ PrUrl = $null; Commands = $commands.ToArray() }
        }

        Write-Log "  ✅ No new changes this run — prior commits on branch. Proceeding to PR." -Color Green
        $prTitle = @((Get-CommitFallback -Number $Number -Title $Title) -split '\r?\n')[0]
    }

    # Capture stderr so any push rejection (workflow scope, branch protection,
    # secret scanning) surfaces in the thrown message. Previously `2>$null`
    # turned every push failure into a useless generic "git push failed" —
    # observed when issue #42 modified .github/workflows/ci.yml and the PAT
    # lacked the `workflow` scope; the real GitHub error never made it to logs.
    #
    # Always a plain push (#367). The branch is never rewritten: the default branch is
    # merged in (Update-Branch), not rebased onto, and a resumed branch is checked out
    # from origin (New-FeatureBranch, #154), so HEAD always descends from the pushed tip
    # and the push fast-forwards. A rejection means someone else pushed — surface it.
    #
    # Never push for an issue that shipped while the agent ran (#377): GitHub deleted
    # the branch at the merge, and the push would re-create it.
    Assert-NotShipped -IssueNumber $Number
    $pushOut = git push --quiet origin "HEAD:refs/heads/$Branch" 2>&1 | Out-String
    $commands.Add([pscustomobject]@{ Name = 'git push'; Exit = $LASTEXITCODE })
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed for branch ${Branch}:`n$($pushOut.Trim())"
    }
    if ($NoPR) {
        Write-Log "  Pushed to $Branch — no PR opened." -Color DarkGray
        return @{ PrUrl = $null; Commands = $commands.ToArray(); Pushed = $true }
    }

    # A merged PR is not open, so the lookup would find none and a second PR would be
    # opened for a shipped issue (#377).
    Assert-NotShipped -IssueNumber $Number
    $body = Format-PullRequestBody -Template $prTemplate -Number $Number `
        -Implemented $Implemented -LeftUndone $LeftUndone -IssuesDiscovered $IssuesDiscovered `
        -Commands (@($PriorCommands) + $commands.ToArray())
    $existing = gh pr list --head $Branch --json url --limit 1 | ConvertFrom-Json
    $notDraft = $false
    $tmp = New-TemporaryFile
    try {
        $body | Out-File $tmp.FullName -Encoding utf8
        if ($existing.Count -gt 0) {
            # A later round rewrites the description from its own facts (#375) and
            # leaves the title as it is (#417).
            $prUrl = $existing[0].url
            $editOut = gh pr edit $prUrl --body-file $tmp.FullName 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "Updating the description of $prUrl failed for issue #${Number}:`n$($editOut.Trim())" }
            Write-Log "  PR already exists, description rewritten: $prUrl" -Color DarkGray
        } else {
            # Opened as a draft (#377): GitHub refuses to merge a draft, so nobody merges
            # the PR before the workflow releases it (ship marks it ready). A repository
            # without drafts refuses --draft; only then is it opened ready.
            Assert-NotShipped -IssueNumber $Number
            $createArgs = @('pr', 'create', '--title', $prTitle, '--body-file', $tmp.FullName, '--head', $Branch)
            $createOut  = gh @createArgs --draft 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -and (Test-DraftUnsupported -Output $createOut)) {
                Write-Log "  ⚠️ This repository does not support draft pull requests — opening the PR ready for review." -Color Yellow
                $notDraft  = $true
                $createOut = gh @createArgs 2>&1 | Out-String
            }
            if ($LASTEXITCODE -ne 0) { throw "PR creation failed for issue #${Number}:`n$($createOut.Trim())" }
            $prUrl = @($createOut -split '\r?\n' | Where-Object { $_ -match '^\s*https?://' } | Select-Object -Last 1)[0]
            $prUrl = if ($prUrl) { $prUrl.Trim() } else { $createOut.Trim() }
            Write-Log "  PR created: $prUrl" -Color Green
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }

    $opened = "· PR opened — $prUrl"
    if ($notDraft) {
        $opened += "`n`nThis pull request is not a draft — the repository does not support drafts — so nothing " +
                   "stops a merge before the workflow releases it. Merge it only once the workflow holds it for you."
    }
    Add-Comment -Number $Number -Body $opened
    return @{ PrUrl = $prUrl; Commands = $commands.ToArray() }
}

# ── Orchestrator entry point ──────────────────────────────────────────────────

function Invoke-Implement {
    param([int]$IssueNumber = 0, [switch]$Force, [switch]$Revise)

    if ($IssueNumber -eq 0) { $IssueNumber = Get-CurrentIssueNumber }
    if ($IssueNumber -eq 0) {
        throw "No issue found — Invoke-Implement must be called with an explicit IssueNumber."
    }
    # Every attempt starts here: an issue that shipped since the last one gets no more work (#377).
    Assert-NotShipped -IssueNumber $IssueNumber

    # Thin readiness re-check — alignment (refine/architect/plan) is a pre-backlog
    # gate; the orchestrator only picks agent:backlog issues, so a fully-aligned
    # state is expected here. Warn (don't re-align) if it is missing, e.g. an issue
    # was dispatched manually or its state block was hand-edited.
    $state = Get-IssueState -IssueNumber $IssueNumber
    if (-not (Test-Readiness -State $state)) {
        Write-Log "  ⚠️ Issue #$IssueNumber reached Implementing without full alignment (refined+architected+planned). Proceeding; run 'pwsh -NoProfile -File .github/tasks/refine.ps1' next time to align before backlog." -Color Yellow
    }

    $meta           = gh issue view $IssueNumber --repo $KanbanRepo --json title | ConvertFrom-Json
    $expectedBranch = Get-BranchName -Number $IssueNumber -Title $meta.title
    $branch         = git rev-parse --abbrev-ref HEAD

    if ($branch -ne $expectedBranch) {
        Write-Log "  Creating feature branch for issue #$IssueNumber..." -Color DarkGray
        Add-Comment -Number $IssueNumber -Body "· picked up — branch ``$expectedBranch``"
        $branch = New-FeatureBranch -Number $IssueNumber -Title $meta.title
    }

    # Take the PR back before anything changes it (#377): a PR marked ready is the one
    # to merge, and this round is about to change it. Ship marks it ready again when it
    # holds the PR for the owner or merges it. Every entry, so a PR opened ready before
    # drafts existed, or a held PR under revision, is covered too.
    $prRaw  = "$(gh pr list --head $branch --json number,url,isDraft --limit 1 2>$null)".Trim()
    $openPR = if ($prRaw.StartsWith('[')) { @($prRaw | ConvertFrom-Json) } else { @() }
    if ($openPR.Count -gt 0 -and $openPR[0].PSObject.Properties['isDraft'] -and -not $openPR[0].isDraft) {
        Write-Log "  PR #$($openPR[0].number) is ready for review — back to draft while the workflow works on it." -Color DarkGray
        $null = Set-PRReady -PRNumber $openPR[0].number -Undo
    }

    # Bring the branch up to date with the default branch BEFORE writing code, not
    # only at merge time. Invoke-Ship merges too (Ship.ps1), but by then the agent has
    # finished — PR #175 sat seven weeks and acquired a pyproject.toml conflict that
    # had to be resolved by hand. Merging here means drift surfaces while the agent is
    # still in the loop, and the implementation is written against current main.
    #
    # The default branch is merged in (Update-Branch, #367), never rebased onto: a
    # conflict is left in place and becomes the agent's first task, instead of ending
    # the round before the agent runs. A freshly-created branch already contains
    # origin/<default>, so the update is a no-op; only resumed branches do real work.
    #
    # The dirty-tree check matters for local runs: when the caller is ALREADY on the
    # feature branch, New-FeatureBranch (and its auto-stash) never ran, and git merge
    # refuses to start over local changes. Skipping is safe — Invoke-Ship still brings
    # the branch up to date before merging, so this is an earlier opportunity.
    $conflicts = @()
    if (Test-RemoteBranch -Branch $branch) {
        $dirtyTree = git status --porcelain 2>$null
        if ($dirtyTree) {
            Write-Log "  Working tree has uncommitted changes — skipping the update from $KanbanDefaultBranch (ship will still merge it)." -Color Yellow
        } else {
            $update    = Update-Branch -IssueNumber $IssueNumber -Branch $branch
            $conflicts = @($update.Conflicts | Where-Object { $_ })
        }
    }

    if ($conflicts.Count -gt 0) {
        # The agent runs even when a PR exists and the run is not forced: review must
        # never start on a half-merged tree.
        $list = ($conflicts | ForEach-Object { "- ``$_``" }) -join "`n"
        Add-Comment -Number $IssueNumber -Body ("🤖⚠️ Merge conflict with $KanbanDefaultBranch — the agent resolves it first`n`n" +
            "Merging ``$KanbanDefaultBranch`` into ``$branch`` conflicts in:`n`n$list")
    } elseif (-not $Force -and $openPR.Count -gt 0) {
        Write-Log "  PR #$($openPR[0].number) already exists — skipping implement." -Color DarkGray
        return $openPR[0].url
    }

    Write-Log "▶ Implement — issue #$IssueNumber on $branch" -Color Cyan

    $headBefore  = git rev-parse HEAD 2>$null
    $devResult   = $null
    $testsFailed = $false   # set when this stage already posted and recorded the failure
    try {
        $devResult = Invoke-Develop -Number $IssueNumber -Branch $branch -BaseCommit $headBefore -Conflicts $conflicts
        # The merge commit when a conflict was completed, else the pre-attempt HEAD.
        $attemptBase = if ($devResult.AttemptBase) { $devResult.AttemptBase } else { $headBefore }

        $stateForAttempt = Get-IssueState -IssueNumber $IssueNumber
        $runAttempt      = if ($stateForAttempt -and $stateForAttempt.PSObject.Properties['attempt_count']) { [int]$stateForAttempt.attempt_count + 1 } else { 1 }
        $maxR            = $OrchestratorConfig.MaxRetries

        $markerFiles = @($devResult.MarkerFiles | Where-Object { $_ })
        if ($markerFiles.Count -gt 0) {
            # Conflict markers left after the agent's turn (#367). The same merge retried
            # unchanged would end the same way, so the round ends here, like a refused
            # edit. The merge is aborted and nothing is pushed: a commit with markers
            # would put broken files in the PR and break CI.
            git merge --abort 2>&1 | Out-Null
            $record = New-ImplementationRecord -DevResult $devResult -Commands @()
            Add-Comment -Number $IssueNumber -Body $record.Body

            $reason = "Conflict markers left in: $($markerFiles -join ', ')"
            Add-ImplementAttempt -IssueNumber $IssueNumber -Stage 'implement' -Reason $reason `
                -Attempt $runAttempt -Max $maxR `
                -Implemented $devResult.Implemented -LeftUndone $devResult.LeftUndone `
                -IssuesDiscovered $devResult.IssuesDiscovered -Commands $record.Commands -Procedure $record.Procedure

            Add-Comment -Number $IssueNumber -Body (Format-MarkersLeftComment -MarkerFiles $markerFiles -Branch $branch)

            $testsFailed = $true
            throw "ATTEMPT-RECORDED|CONFLICT-MARKERS|$reason"
        }

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
                if ("$($_.Exception.Message)" -like 'ISSUE-SHIPPED|*') { throw }
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

        $commitResult = Invoke-CommitAndPR -Number $IssueNumber -Title $meta.title -Branch $branch `
            -Implemented $devResult.Implemented -LeftUndone $devResult.LeftUndone `
            -IssuesDiscovered $devResult.IssuesDiscovered -PriorCommands @($devResult.PhaseOneCommands)
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
            # Counted from the attempt's base, so a merge of the default branch alone is
            # not new work.
            $newCommits = [int](git rev-list --count "${attemptBase}..HEAD" 2>$null)
            if ($newCommits -eq 0) {
                # The revision produced no new commits — the owner asked a question.
                Write-Log "✅ Implement complete — question answered, no new commits." -Color Green
                return $null
            }
        }

        Write-Log "✅ Implement complete — PR at $prUrl" -Color Green
        return $prUrl
    } catch {
        # Never leave a merge half done for the next attempt: it would start on a tree
        # with conflict markers and no instructions about them. The next attempt merges
        # again and sees the conflict fresh.
        if (Test-MergeInProgress) { git merge --abort 2>&1 | Out-Null }
        # The shipped stop is the conductor's to announce (#377), once.
        if (-not $testsFailed -and "$($_.Exception.Message)" -notlike 'ISSUE-SHIPPED|*') {
            $errBlock = Format-ErrorBlock -Raw "$_"
            Add-Comment -Number $IssueNumber -Body "🤖❌ Implement Failed`n`n$errBlock"
        }
        throw
    }
}
