#Requires -Version 7.0
<#
.SYNOPSIS
    Ship stage — bring the branch up to date, wait for green CI, then merge or hold for the owner.

.DESCRIPTION
    Orchestrator library — loaded by Orchestrator.psm1. Invoke-Ship is reached only
    after the review stage approved (the conductor) or by the owner's manual
    dispatch (afk.yml stage=ship), so it does not re-derive approval. It merges the
    default branch into the branch (Update-Branch — a conflict ends the attempt and
    the next one settles it at implement), waits for every required check to pass
    on the commit it pushed (or, with KANBAN_LOCAL_CI, runs it locally and always holds
    the PR — #314), and then either holds a PR that touches a governance file
    (human:approval) or squash-merges it and deletes the branch
    (Complete-Ship). Complete-HeldPR reconciles the issue on every feature-branch PR
    close (afk.yml, pull_request closed) — merged ships it, closed-unmerged fails it —
    skipping only an issue already agent:shipped, so a direct `gh pr merge` that
    bypasses Invoke-Ship still lands the issue on agent:shipped / Shipped, even one
    the pipeline had already marked agent:failed before the owner fixed it by hand.
#>

$ErrorActionPreference = 'Stop'
# Module-internal library — loaded by Orchestrator.psm1 (which loads Config.ps1 first).
# Not dot-sourced individually; see ADR-013.

# ── CI on the pushed commit (#373) ────────────────────────────────────────────
# Ship calls a PR green only when every required check (RequiredChecks in
# lib/Config.ps1, the list branch protection requires) has passed on the exact
# commit it pushed. `gh pr checks` cannot say that: its answer carries no commit, so
# right after a push it still shows the previous commit's checks as passed.

# How long ship waits, from its push, for the required checks; and how often it asks.
$ShipCheckTimeoutSec = 900
$ShipCheckPollSec    = 10

# Every check run GitHub holds for one commit: id, name, status, conclusion,
# head_sha, details_url. @() when the API cannot be read (the poll asks again).
function Get-CommitCheckRuns {
    param([Parameter(Mandatory)][string]$Sha)
    $raw = gh api --paginate "repos/$KanbanRepo/commits/$Sha/check-runs?per_page=100" `
        --jq '.check_runs[] | {id, name, status, conclusion, head_sha, details_url} | tojson' 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read the check runs of $Sha — asking again." -Color Yellow
        return @()
    }
    return @($raw -split '\r?\n' | Where-Object { $_.Trim().StartsWith('{') } |
        ForEach-Object { $_ | ConvertFrom-Json })
}

# The verdict on one commit, from its check runs — a pure function. Runs on another
# commit are ignored; of several runs with one name (a re-run) the newest counts.
#   failed   any run on the commit ended failure, cancelled or timed_out, required or not
#   green    every required name completed as success, or as skipped (nothing failed)
#   missing  a required name has no run on the commit yet
#   pending  a required name has a run that has not passed yet
# Returns { State, Failed (names), FailedRuns, Missing, Pending }.
function Get-CheckVerdict {
    param([string[]]$RequiredNames, [object[]]$CheckRuns, [Parameter(Mandatory)][string]$Sha)

    $latest = [ordered]@{}
    foreach ($run in @($CheckRuns | Where-Object { $_ -and "$($_.head_sha)" -eq $Sha })) {
        $name = "$($run.name)"
        if (-not $latest.Contains($name) -or [long]$run.id -gt [long]$latest[$name].id) { $latest[$name] = $run }
    }
    $failedRuns = @($latest.Values | Where-Object {
        $_.status -eq 'completed' -and "$($_.conclusion)" -in @('failure', 'cancelled', 'timed_out') })
    $missing = @(); $pending = @()
    foreach ($name in @($RequiredNames | Where-Object { $_ })) {
        if (-not $latest.Contains($name)) { $missing += $name; continue }
        $run = $latest[$name]
        if ($run.status -ne 'completed' -or "$($run.conclusion)" -notin @('success', 'skipped')) { $pending += $name }
    }
    $state = if ($failedRuns.Count -gt 0) { 'failed' }
             elseif ($missing.Count -gt 0) { 'missing' }
             elseif ($pending.Count -gt 0) { 'pending' }
             else { 'green' }
    return [pscustomobject]@{
        State      = $state
        Failed     = @($failedRuns | ForEach-Object { "$($_.name)" })
        FailedRuns = $failedRuns
        Missing    = $missing
        Pending    = $pending
    }
}

# The last lines of each failed job's own log, as Markdown blocks ('' when none can
# be read). Read per job (actions/jobs/{id}/logs), so a job's log is there as soon as
# that job ends — `gh run view --log-failed` returns nothing until the whole run has.
# The job id is in the check run's details_url (…/job/{id}); for Actions it is also
# the check run's own id.
function Get-FailedJobLogs {
    param([object[]]$CheckRuns, [int]$Tail = 60)
    $blocks = foreach ($run in @($CheckRuns | Where-Object { $_ })) {
        $jobId = if ("$($run.details_url)" -match '/job/(\d+)') { $Matches[1] } else { "$($run.id)" }
        if (-not $jobId) { continue }
        $log = gh api "repos/$KanbanRepo/actions/jobs/$jobId/logs" 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $log.Trim()) { continue }
        $lines = @($log.TrimEnd() -split '\r?\n' | Select-Object -Last $Tail)
        "`n`n**$($run.name)** (job $jobId) — last $($lines.Count) log lines:`n``````text`n$($lines -join "`n")`n``````"
    }
    return ($blocks -join '')
}

# ── Local CI (#314) ───────────────────────────────────────────────────────────
# When GitHub Actions cannot run (observed: a spent Actions allowance on a private
# repo), KANBAN_LOCAL_CI makes ship run CI here instead of reading the commit's check runs.
# Mirrors checks.yml's lint / typecheck / test / audit jobs — keep the two in step;
# test_ship.py fails when a checks.yml `uv run` command is missing here. The checks
# job is every .github/checks/check-*.ps1, the same rule as CI. eval stays
# CI-only.
$LocalCiJobs = [ordered]@{
    'lint'      = @('uv', 'run', 'ruff', 'check', '.')
    'format'    = @('uv', 'run', 'ruff', 'format', '--check', '.')
    'typecheck' = @('uv', 'run', 'pyright')
    'test'      = @('uv', 'run', 'pytest', '--cov=src', '--cov-report=term-missing', '--cov-fail-under=80')
    'audit'     = @('uv', 'run', 'pip-audit')
}

function Test-LocalCI { return [bool]$env:KANBAN_LOCAL_CI }

# Runs every local CI job in the working tree; one row per job: Name, ExitCode, Tail.
function Invoke-LocalCI {
    param([int]$Tail = 30)
    $null = & uv sync 2>&1
    $jobs = [ordered]@{}
    foreach ($k in $LocalCiJobs.Keys) { $jobs[$k] = $LocalCiJobs[$k] }
    foreach ($c in Get-ChildItem (Join-Path $_Root '.github/checks') -Filter 'check-*.ps1' | Sort-Object Name) {
        $jobs["checks: $($c.BaseName)"] = @('pwsh', '-NoProfile', '-File', $c.FullName)
    }
    foreach ($name in $jobs.Keys) {
        $cmd  = $jobs[$name]
        $rest = @($cmd | Select-Object -Skip 1)
        $out  = & $cmd[0] @rest 2>&1 | Out-String
        [pscustomobject]@{
            Name     = $name
            ExitCode = $LASTEXITCODE
            Tail     = ((($out -split '\r?\n') | Where-Object { $_.Trim() } | Select-Object -Last $Tail) -join "`n")
        }
    }
}

# ── Bringing a branch up to date (#367) ───────────────────────────────────────
# The default branch is merged INTO the issue's branch, as GitHub's "Update branch"
# button does. Pull requests are squash-merged, so the branch's own history never
# reaches the default branch and nothing needs rewriting: every push is a plain
# fast-forward push. A conflict is left in place for the implementing agent
# (Invoke-Implement) instead of ending the round; ship aborts it and lets the next
# attempt, which starts at implement, settle it.

# The fixed message of the merge commit. Squash merges copy each commit's subject
# into the squash commit's body, so it follows <type>(#<issue>): <subject> too.
function Get-BranchUpdateMessage {
    param([int]$IssueNumber, [string]$Branch)
    return "chore(#${IssueNumber}): merge $KanbanDefaultBranch into $Branch"
}

# Fetches the default branch and merges it into HEAD. Returns
# { UpToDate, Merged, Conflicts }. A clean merge is committed and pushed (plain
# push); a conflicted one is left in progress — MERGE_HEAD and the unmerged paths
# stay — with Conflicts naming those paths.
function Update-Branch {
    param([int]$IssueNumber, [string]$Branch)

    $default = $KanbanDefaultBranch
    $result  = [pscustomobject]@{ UpToDate = $false; Merged = $false; Conflicts = @() }
    git fetch --quiet origin $default 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch $default from origin." }

    git merge-base --is-ancestor "origin/$default" HEAD 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Branch $Branch already contains $default — nothing to merge." -Color DarkGray
        $result.UpToDate = $true
        return $result
    }

    $behind = "$(git rev-list --count "HEAD..origin/$default" 2>$null)".Trim()
    Write-Log "  Branch $Branch is $behind commit(s) behind $default — merging..." -Color DarkGray
    Add-Comment -Number $IssueNumber -Body "· merging $default into $Branch ($behind commit(s) behind)"

    $mergeOut = git merge --no-ff --no-commit "origin/$default" 2>&1 | Out-String
    $mergeExit = $LASTEXITCODE
    $conflicts = @((git -c core.quotePath=false diff --name-only --diff-filter=U 2>$null) |
                   ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($conflicts.Count -gt 0) {
        Write-Log "  Merge conflict in: $($conflicts -join ', ')" -Color Yellow
        $result.Conflicts = $conflicts
        $global:LASTEXITCODE = 0
        return $result
    }
    if ($mergeExit -ne 0) {
        git merge --abort 2>&1 | Out-Null
        throw "git merge of $default into $Branch failed:`n$($mergeOut.Trim())"
    }

    $commitOut = git commit --quiet -m (Get-BranchUpdateMessage -IssueNumber $IssueNumber -Branch $Branch) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Could not commit the merge of $default into ${Branch}:`n$($commitOut.Trim())" }

    # Never push for an issue that shipped (#377): the push would re-create the branch
    # GitHub deleted at the merge.
    Assert-NotShipped -IssueNumber $IssueNumber
    $pushOut = git push --quiet origin "HEAD:refs/heads/$Branch" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git push after merging $default failed for branch ${Branch}:`n$($pushOut.Trim())" }

    Write-Log "  Merged $default into $Branch." -Color Green
    $result.Merged = $true
    return $result
}

# Completes a merge Update-Branch left in conflict, once the agent has edited the
# files. Scans only the files that were in conflict, for lines that begin a
# '<<<<<<< ' or '>>>>>>> ' marker ('=======' is also a Markdown heading underline).
# Markers left: returns them in MarkerFiles and commits nothing. Otherwise stages
# exactly those files and commits the merge with the fixed message — the agent's
# other edits stay unstaged, so they belong to the attempt's own commit.
function Complete-BranchUpdate {
    param([int]$IssueNumber, [string]$Branch, [string[]]$Conflicts)

    $root    = "$(git rev-parse --show-toplevel 2>$null)".Trim()
    $markers = @(foreach ($f in @($Conflicts | Where-Object { $_ })) {
        $path = Join-Path $root $f
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and
            @(Get-Content -LiteralPath $path | Where-Object { $_ -match '^(<{7}|>{7}) ' }).Count -gt 0) { $f }
    })
    if ($markers.Count -gt 0) {
        Write-Log "  Conflict markers left in: $($markers -join ', ')" -Color Red
        return [pscustomobject]@{ MarkerFiles = $markers }
    }

    foreach ($f in @($Conflicts | Where-Object { $_ })) {
        # A file the agent deleted to settle a modify/delete conflict is staged as deleted.
        git add -A -- $f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not stage the resolved file $f." }
    }
    $commitOut = git commit --quiet -m (Get-BranchUpdateMessage -IssueNumber $IssueNumber -Branch $Branch) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Could not commit the merge of $KanbanDefaultBranch into ${Branch}:`n$($commitOut.Trim())" }
    Write-Log "  Merge of $KanbanDefaultBranch into $Branch completed." -Color Green
    return [pscustomobject]@{ MarkerFiles = @() }
}

# True while a merge is in progress (MERGE_HEAD exists).
function Test-MergeInProgress {
    git rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
    $inProgress = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    return $inProgress
}

# ── Hold announcement ─────────────────────────────────────────────────────────

# The PR's changed paths that match GovernancePaths ($OrchestratorConfig).
function Get-PRPath {
    param([Parameter(Mandatory)][int]$PRNumber)
    $files = @(gh pr diff $PRNumber --repo $KanbanRepo --name-only 2>$null | Where-Object { "$_".Trim() })
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($files | ForEach-Object { "$_".Trim() })
}

function Get-GovernanceFiles {
    param([Parameter(Mandatory)][int]$PRNumber)
    return @(Get-PRPath -PRNumber $PRNumber | Where-Object {
        $f = $_
        @($OrchestratorConfig.GovernancePaths | Where-Object { $f -like $_ }).Count -gt 0
    })
}

# Files the PR changes that sit outside the agent write allowlist — the "proposal"
# half of the merge decision (#285). These are committed like any other change, but
# they are what makes the PR something the owner approves rather than something the
# pipeline merges. Delegates to Get-UnwritablePaths so the plan stage's early
# warning and this merge-time decision cannot disagree.
function Get-ProposedFiles {
    param([Parameter(Mandatory)][int]$PRNumber)
    return @(Get-UnwritablePaths -Paths (Get-PRPath -PRNumber $PRNumber))
}

# Paths that define the agent's own limits. Called out separately in the hold
# comment: a PR that widens the allowlist, edits CODEOWNERS or changes a workflow
# is altering the rules the next PR will be judged by, and that should not be one
# bullet among twenty in a long file list.
$KanbanBoundaryPaths = @(
    '.github/orchestrator/lib/Config.ps1', '.github/CODEOWNERS', '.github/workflows/*'
)

# filename → "+adds -dels", so the hold comment shows the size of what is proposed,
# not only its name. One REST call, and only on the hold path.
function Get-PRDiffstat {
    param([Parameter(Mandatory)][int]$PRNumber)
    $stat = @{}
    $raw = gh api "repos/$KanbanRepo/pulls/$PRNumber/files?per_page=100" `
        --jq '.[] | "\(.filename)\t+\(.additions) -\(.deletions)"' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $stat }
    foreach ($line in @($raw -split '\r?\n' | Where-Object { $_ -match "`t" })) {
        $parts = $line -split "`t", 2
        $stat[$parts[0].Trim()] = $parts[1].Trim()
    }
    return $stat
}

# The hold comment's file list: one line per file, with its diffstat, and a marker
# on anything that changes the agent's own boundary.
function Format-HeldFiles {
    param([string[]]$Files, [hashtable]$Diffstat)
    return (@($Files | Sort-Object -Unique | ForEach-Object {
        $f     = $_
        $size  = if ($Diffstat.ContainsKey($f)) { " — $($Diffstat[$f])" } else { '' }
        $flag  = if (@($KanbanBoundaryPaths | Where-Object { $f -like $_ }).Count -gt 0) { '  ⚠️ **changes the agent''s own boundary**' } else { '' }
        "- ``$f``$size$flag"
    }) -join "`n")
}

function Test-HoldAnnounced {
    <#
    .SYNOPSIS
        True when the human-approval hold has already been announced on this issue.
    .DESCRIPTION
        The hold posts one signal comment and must not repeat it on re-entry. The
        presence of that comment is the only durable record that a previous pass got
        that far — the agent:reviewing label is not, because the review stage sets it
        before the ship stage runs.
    #>
    param([int]$IssueNumber)

    $bodies = gh api "repos/$KanbanRepo/issues/$IssueNumber/comments" `
        --jq 'map(.body) | .[]' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        # Fail open: announcing twice is noise, announcing never is a PR nobody knows
        # is waiting — which is the failure this hold exists to prevent.
        Write-Log "  ⚠️ Could not read comments on #${IssueNumber}; assuming not yet announced." -Color Yellow
        return $false
    }
    return $bodies -match '🤖⏸ Held for human approval'
}

function Invoke-Ship {
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

    # ── Human-approval hold: already announced ────────────────────────────────
    # The hold itself happens after CI is green (below). Once it is announced, a
    # repeated run (e.g. a manual stage=ship) has nothing to add: the PR waits for a
    # human merge. Keyed off the hold comment, which exists only once a pass got there.
    if (-not $Force) {
        $labels = @(Get-IssueLabel -IssueNumber $IssueNumber)
        if ($labels -contains 'human:approval' -and (Test-HoldAnnounced -IssueNumber $IssueNumber)) {
            Write-Log "⏸ Issue #$IssueNumber already held for human approval — nothing to do." -Color DarkGray
            return $false
        }
    }

    # Checkout the feature branch (may not be on it when called standalone from the default branch).
    # The default branch is merged in (Update-Branch), never rebased onto: the PR is
    # squash-merged, so the branch's history need not be rewritten or force-pushed.
    $featureBranch = gh pr view $PRNumber --json headRefName --jq '.headRefName' 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    if ($currentBranch -ne $featureBranch) {
        git checkout --quiet $featureBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not switch to feature branch $featureBranch." }
    }
    # A conflict here is not resolved in ship: abort, name the files, and fail the
    # attempt. The next attempt starts at implement, where the agent settles it.
    $update = Update-Branch -IssueNumber $IssueNumber -Branch $featureBranch
    $conflicts = @($update.Conflicts | Where-Object { $_ })
    if ($conflicts.Count -gt 0) {
        git merge --abort 2>&1 | Out-Null
        $list = ($conflicts | ForEach-Object { "- ``$_``" }) -join "`n"
        Add-Comment -Number $IssueNumber -Body ("🤖❌ Merge Conflict`n`n``$KanbanDefaultBranch`` changed the same lines as " +
            "this branch in:`n`n$list`n`nThe next attempt merges ``$KanbanDefaultBranch`` again and settles these files first.")
        throw "Merge conflict between $featureBranch and $KanbanDefaultBranch in: $($conflicts -join ', ')"
    }

    # The commit the checks must pass on: HEAD after the update — the merge commit
    # Update-Branch pushed, or the head the implement stage pushed when the branch was
    # already up to date. Both are the PR's head.
    $sha = "$(git rev-parse HEAD 2>$null)".Trim()
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw "Could not read the HEAD commit of $featureBranch." }

    # Local CI (#314): run checks.yml's jobs here instead of reading GitHub's check runs.
    # A pass always ends in the owner's hold below — nothing merges on local CI alone.
    $localCi = Test-LocalCI
    if ($localCi) {
        Write-Log "  Running CI locally (KANBAN_LOCAL_CI) on PR #$PRNumber at $sha..." -Color DarkGray
        $rows   = @(Invoke-LocalCI)
        $failed = @($rows | Where-Object { $_.ExitCode -ne 0 })
        if ($failed.Count -gt 0) {
            $label = ($failed | ForEach-Object { $_.Name }) -join ', '
            $logs  = ($failed | ForEach-Object { "`n`n**$($_.Name)** — exit $($_.ExitCode):`n``````text`n$($_.Tail)`n``````" }) -join ''
            Add-Comment -Number $IssueNumber -Body "🤖❌ CI Failed`n`nFailed checks (run locally on commit $sha): $label$logs"
            throw "CI checks failed for PR #${PRNumber}: $label"
        }
        $table = ($rows | ForEach-Object { "| $($_.Name) | pass |" }) -join "`n"
        Add-Comment -Number $IssueNumber -Body ("🤖✅ Local CI passed`n`nGitHub Actions could not run, so ship ran " +
            "``checks.yml``'s jobs on commit $sha of this branch locally (``KANBAN_LOCAL_CI``):`n`n| Job | Result |`n|---|---|`n$table")
    } else {
        # Green only when every required name has passed on $sha (Get-CheckVerdict).
        # An empty or partial answer — the checks of a fresh push take seconds to
        # appear — means ask again, up to one ceiling counted from the push. There is
        # no path that merges without the required checks.
        $required = @((Get-OrchestratorContext).RequiredChecks)
        if ($required.Count -eq 0) { throw 'RequiredChecks in .github/orchestrator/lib/Config.ps1 is empty.' }
        Write-Log "  Waiting for the required checks ($($required -join ', ')) on $sha (PR #$PRNumber)..." -Color DarkGray

        $deadline = (Get-Date).AddSeconds($ShipCheckTimeoutSec)
        while ($true) {
            $verdict = Get-CheckVerdict -RequiredNames $required -CheckRuns @(Get-CommitCheckRuns -Sha $sha) -Sha $sha
            if ($verdict.State -in @('green', 'failed') -or (Get-Date) -ge $deadline) { break }
            $waiting = @($verdict.Missing) + @($verdict.Pending)
            Write-Log "  CI on ${sha}: waiting for $($waiting -join ', ') — asking again in ${ShipCheckPollSec}s..." -Color DarkGray
            Start-Sleep -Seconds $ShipCheckPollSec
        }

        if ($verdict.State -eq 'failed') {
            $label = $verdict.Failed -join ', '
            # The log tail is what lets the next attempt fix the failure rather than guess.
            $logs = Get-FailedJobLogs -CheckRuns $verdict.FailedRuns
            Add-Comment -Number $IssueNumber -Body "🤖❌ CI Failed`n`nFailed checks: $label — on commit $sha.$logs"
            throw "CI checks failed for PR #${PRNumber}: $label"
        }
        if ($verdict.State -ne 'green') {
            $names = @(@($verdict.Missing | ForEach-Object { "$_ (not reported)" }) +
                       @($verdict.Pending | ForEach-Object { "$_ (not passed)" }))
            $list  = ($names | ForEach-Object { "- ``$_``" }) -join "`n"
            Add-Comment -Number $IssueNumber -Body ("🤖⚠️ CI did not pass within ${ShipCheckTimeoutSec}s`n`n" +
                "These required checks have not passed on commit ${sha}:`n`n$list`n`nNothing was merged; the PR needs manual review.")
            throw "Required checks did not pass on $sha within ${ShipCheckTimeoutSec}s for PR #${PRNumber}: $($names -join ', ')"
        }
        Write-Log "  CI green on $sha ✅" -Color Green
    }

    # ── Human-approval hold ───────────────────────────────────────────────────
    # Decided here, from the actual diff, once CI is green: a PR that touches a
    # governance file (GovernancePaths) is held for the owner to merge, and the issue
    # is labelled human:approval — a state the pipeline sets, like human:decision.
    # The owner can also add the label by hand to hold any issue. The gate lives in
    # Invoke-Ship, not the conductor, because a manual stage=ship calls Invoke-Ship
    # directly. -Force overrides, for a deliberate merge from a local session.
    if (-not $Force) {
        $governance = @(Get-GovernanceFiles -PRNumber $PRNumber)
        $proposed   = @(Get-ProposedFiles   -PRNumber $PRNumber)
        # The owner's hold: the label, or — once a later state replaced it — the
        # carrier's approval_required (Set-AgentState, #225).
        $state      = Get-IssueState -IssueNumber $IssueNumber
        $manual     = (@(Get-IssueLabel -IssueNumber $IssueNumber) -contains 'human:approval') -or
                      ($state -and $state.PSObject.Properties['approval_required'] -and $state.approval_required)
        if ($governance.Count -gt 0 -or $proposed.Count -gt 0 -or $manual -or $localCi) {
            # Released to the owner (#377): ready is the PR to merge. Never merges it
            # and never enables auto-merge — only the owner merges a held PR.
            $null = Set-PRReady -PRNumber $PRNumber
            Set-AgentState -IssueNumber $IssueNumber -Label 'human:approval'

            # Only fetch the diffstat on the hold path — the owner is about to read
            # this list and decide on it, so it should say how big each change is.
            $held = @($governance) + @($proposed)
            $why  = if ($held.Count -gt 0) {
                $stat   = Get-PRDiffstat -PRNumber $PRNumber
                $reason = if ($proposed.Count -gt 0 -and $governance.Count -gt 0) {
                    'it changes governance files and files outside the agent write allowlist'
                } elseif ($proposed.Count -gt 0) {
                    'it changes files outside the agent write allowlist'
                } else {
                    'it changes governance files'
                }
                "$reason — these are proposals for you to approve:`n`n" + (Format-HeldFiles -Files $held -Diffstat $stat)
            } elseif ($localCi) {
                'its CI ran locally (``KANBAN_LOCAL_CI``) — the merge is yours.'
            } else { 'this issue is labelled ``human:approval``.' }
            if ($localCi -and $held.Count -gt 0) { $why += "`n`nIts CI ran locally (``KANBAN_LOCAL_CI``)." }

            Add-Comment -Number $IssueNumber -Body ("🤖⏸ Held for human approval`n`nPR #$PRNumber is green on commit $sha and self-reviewed, but " +
                "$why`n`n**Comment on this issue to change the PR; close the PR to reject it.** Merge PR #$PRNumber to accept. " +
                "The agent reads the issue, not PR review comments. Nothing reaches the default branch until you merge.`n`n" +
                "A draft pull request is the workflow's work in progress; the pull request marked ready for review — " +
                "this one, now — is the one to merge.")
            Write-Log "⏸ Issue #$IssueNumber held for human approval — $($governance.Count) governance, $($proposed.Count) proposed file(s)." -Color Yellow
            return $false
        }
    }

    # GitHub refuses to merge a draft (#377).
    $null = Set-PRReady -PRNumber $PRNumber
    gh pr merge $PRNumber --squash --delete-branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gh pr merge failed for PR #$PRNumber" }

    Complete-Ship -IssueNumber $IssueNumber -PRNumber $PRNumber -How 'squash-merged'
    return $true
}

# ── After the merge ───────────────────────────────────────────────────────────
# Shared by the pipeline's own merge and the owner's merge of a held PR: the issue
# reaches agent:shipped and gets its signal comment — nothing else. Ship makes no
# commit, push or branch switch after the merge: knowledge reaches the default branch
# only inside the reviewed PR (#349), and returning to a clean default branch is the
# conductor's final cleanup and New-FeatureBranch's job.
function Complete-Ship {
    param([int]$IssueNumber, [int]$PRNumber, [string]$How)

    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:shipped'
    Add-Comment -Number $IssueNumber -Body "🤖✅ Merged`n`nPR #$PRNumber $How. Issue closed."

    Write-Log "✅ Merged PR #$PRNumber — issue #$IssueNumber complete." -Color Green
}

# Reconciles the issue after ANY PR on a feature/{n}-* branch closes (afk.yml, on the
# PR's closed event) — a held PR the owner merged, a PR merged directly outside the
# pipeline (gh pr merge, bypassing Invoke-Ship), or one closed unmerged. This is the
# single deterministic backstop: whatever merged the PR, the issue must still reach
# agent:shipped / Shipped. Merged: ships it. Closed unmerged: agent:failed at review,
# so the owner's comment saying what should change starts the next attempt (retry.ps1).
#
# The only skip is an issue already agent:shipped. That is not a "was this held" check
# — it is an idempotency guard against the race with Invoke-Ship's own in-process
# Complete-Ship call, which runs synchronously right after its own `gh pr merge` and in
# practice always wins: this handler's job has to cold-start (checkout, install uv)
# before it ever reads a label. Whichever path gets there first
# wins; the other is a no-op. agent:failed is deliberately NOT a skip condition (#266):
# issues #223/#251/#256 all reached agent:failed from the pipeline's own blocked
# attempts, were then fixed hands-on and merged on the matching branch — exactly the
# case this handler exists to catch. Treating agent:failed as terminal left all three
# stuck, because the merge that should have shipped them saw the stale failed label and
# skipped.
function Complete-HeldPR {
    param([int]$PRNumber, [string]$Branch, [bool]$Merged)

    if ($Branch -notmatch '^feature/(\d+)-') { return }
    $issue = [int]$Matches[1]
    if (Test-IssueShipped -IssueNumber $issue) {
        Write-Log "PR #$PRNumber closed; issue #$issue already shipped — nothing to do." -Color DarkGray
        return
    }

    if ($Merged) {
        Complete-Ship -IssueNumber $issue -PRNumber $PRNumber -How 'merged'
        return
    }
    Set-AgentFailedState -IssueNumber $issue -FailedAt 'review' -Reason "PR #$PRNumber was closed without merging."
    Add-Comment -Number $issue -Body ("🤖⏸ PR #$PRNumber closed without merging`n`n" +
        'Comment on this issue with what should change; the next attempt starts from your comment.')
    Write-Log "⏸ Issue #$issue — PR #$PRNumber closed unmerged; waiting on the owner's comment." -Color Yellow
}
