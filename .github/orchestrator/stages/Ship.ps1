#Requires -Version 7.0
<#
.SYNOPSIS
    Ship stage — rebase, wait for green CI, then merge or hold for the owner.

.DESCRIPTION
    Orchestrator library — loaded by Orchestrator.psm1. Invoke-Ship is reached only
    after the review stage approved (the conductor) or by the owner's manual
    dispatch (afk.yml stage=ship), so it does not re-derive approval. It rebases the
    branch, waits for CI (or, with KANBAN_LOCAL_CI, runs it locally and always holds
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

# The last lines of each failed CI job's log, as a Markdown block ('' when none can
# be read). Job links from `gh pr checks` carry the run id; `gh run view --log-failed`
# returns only the failed steps.
function Get-FailedCheckLog {
    param([int]$PRNumber, [int]$Tail = 60)
    $checks = gh pr checks $PRNumber --json name,bucket,link 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $checks.Trim().StartsWith('[')) { return '' }
    $runIds = @($checks | ConvertFrom-Json |
        Where-Object { $_.bucket -eq 'fail' -and $_.link -match '/actions/runs/(\d+)' } |
        ForEach-Object { [regex]::Match($_.link, '/actions/runs/(\d+)').Groups[1].Value } |
        Select-Object -Unique)
    $blocks = foreach ($id in $runIds) {
        $log = gh run view $id --repo $KanbanRepo --log-failed 2>$null
        if ($LASTEXITCODE -eq 0 -and $log) {
            $lines = @($log) | Select-Object -Last $Tail
            "`n`n**Run $id** — last $($lines.Count) log lines:`n``````text`n$($lines -join "`n")`n``````"
        }
    }
    return ($blocks -join '')
}

# ── Local CI (#314) ───────────────────────────────────────────────────────────
# When GitHub Actions cannot run (observed: a spent Actions allowance on a private
# repo), KANBAN_LOCAL_CI makes ship run CI here instead of polling `gh pr checks`.
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

function Invoke-RebaseOnMaster {
    param([int]$IssueNumber, [string]$Branch)

    $default = $KanbanDefaultBranch
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
    # The default branch is authoritative — always rebase rather than merge forward.
    $featureBranch = gh pr view $PRNumber --json headRefName --jq '.headRefName' 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    if ($currentBranch -ne $featureBranch) {
        git checkout --quiet $featureBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not switch to feature branch $featureBranch." }
    }
    Invoke-RebaseOnMaster -IssueNumber $IssueNumber -Branch $featureBranch

    # Local CI (#314): run checks.yml's jobs here and skip the `gh pr checks` poll.
    # A pass always ends in the owner's hold below — nothing merges on local CI alone.
    $localCi = Test-LocalCI
    if ($localCi) {
        Write-Log "  Running CI locally (KANBAN_LOCAL_CI) on PR #$PRNumber..." -Color DarkGray
        $rows   = @(Invoke-LocalCI)
        $failed = @($rows | Where-Object { $_.ExitCode -ne 0 })
        if ($failed.Count -gt 0) {
            $label = ($failed | ForEach-Object { $_.Name }) -join ', '
            $logs  = ($failed | ForEach-Object { "`n`n**$($_.Name)** — exit $($_.ExitCode):`n``````text`n$($_.Tail)`n``````" }) -join ''
            Add-Comment -Number $IssueNumber -Body "🤖❌ CI Failed`n`nFailed checks (run locally): $label$logs"
            throw "CI checks failed for PR #${PRNumber}: $label"
        }
        $table = ($rows | ForEach-Object { "| $($_.Name) | pass |" }) -join "`n"
        Add-Comment -Number $IssueNumber -Body ("🤖✅ Local CI passed`n`nGitHub Actions could not run, so ship ran " +
            "``checks.yml``'s jobs on this branch locally (``KANBAN_LOCAL_CI``):`n`n| Job | Result |`n|---|---|`n$table")
    } else {
        Write-Log "  Waiting for CI checks on PR #$PRNumber..." -Color DarkGray
    }

    # Poll `gh pr checks --json name,bucket` instead of `--watch`. After
    # rebase + force-push, GitHub Actions needs 5-30s to register the rerun
    # and during that window `--watch` produces non-deterministic text on a
    # mixed stdout/stderr stream — previously this leaked into a downstream
    # ConvertFrom-Json and crashed the orchestrator (dropping the issue to
    # Backlog even though CI eventually passed).
    #
    # `--json` gives structured output that is unambiguous:
    #   - empty array        → no checks registered yet → keep polling
    #   - bucket=pending     → in progress → keep polling
    #   - bucket=fail|cancel → real failure → fail the merge
    #   - all bucket=pass    → CI green
    $CIRegisterTimeoutSec   = 60     # how long to wait for at least one check to register
    $CICompletionTimeoutSec = 900    # 15 min — hard ceiling for total CI duration
    $CIPollIntervalSec      = 10

    $registerDeadline   = (Get-Date).AddSeconds($CIRegisterTimeoutSec)
    $completionDeadline = (Get-Date).AddSeconds($CICompletionTimeoutSec)
    $ciGreen            = $localCi
    $ciFailed           = $false
    $everRegistered     = $false
    $failedNames        = ''

    while (-not $localCi -and (Get-Date) -lt $completionDeadline) {
        $jsonOut  = gh pr checks $PRNumber --json name,bucket 2>$null | Out-String
        $jsonTrim = $jsonOut.Trim()

        $checks = $null
        if ($jsonTrim.StartsWith('[')) {
            try { $checks = $jsonTrim | ConvertFrom-Json -ErrorAction Stop } catch { $checks = $null }
        }
        $arr = @($checks)

        if ($arr.Count -eq 0) {
            if (-not $everRegistered -and (Get-Date) -ge $registerDeadline) {
                Write-Log "  ⚠️ No CI checks registered after ${CIRegisterTimeoutSec}s — proceeding on approval gate alone." -Color Yellow
                Add-Comment -Number $IssueNumber -Body "🤖⚠️ No CI checks reported after ${CIRegisterTimeoutSec}s — merging on approval gate alone."
                break
            }
            Write-Log "  CI not yet registered — retrying in ${CIPollIntervalSec}s..." -Color DarkGray
            Start-Sleep -Seconds $CIPollIntervalSec
            continue
        }

        $everRegistered = $true
        $failed  = @($arr | Where-Object { $_.bucket -eq 'fail' -or $_.bucket -eq 'cancel' })
        $pending = @($arr | Where-Object { $_.bucket -eq 'pending' })

        if ($failed.Count -gt 0) {
            $failedNames = ($failed | ForEach-Object { $_.name }) -join ', '
            $ciFailed    = $true
            break
        }

        if ($pending.Count -eq 0) {
            $ciGreen = $true
            break
        }

        Write-Log "  CI in progress: $($pending.Count)/$($arr.Count) pending — retrying in ${CIPollIntervalSec}s..." -Color DarkGray
        Start-Sleep -Seconds $CIPollIntervalSec
    }

    if ($ciFailed) {
        $label = if ($failedNames) { $failedNames } else { 'unknown' }
        # The log tail is what lets the next attempt fix the failure rather than guess.
        $logs = Get-FailedCheckLog -PRNumber $PRNumber
        Add-Comment -Number $IssueNumber -Body "🤖❌ CI Failed`n`nFailed checks: $label$logs"
        throw "CI checks failed for PR #${PRNumber}: $label"
    }

    if ($ciGreen) {
        Write-Log "  CI green ✅" -Color Green
    } elseif ($everRegistered) {
        # Registered but never completed — don't auto-merge a PR with running CI.
        Add-Comment -Number $IssueNumber -Body "🤖⚠️ CI did not complete within ${CICompletionTimeoutSec}s — needs manual review."
        throw "CI did not complete within ${CICompletionTimeoutSec}s for PR #$PRNumber."
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

            Add-Comment -Number $IssueNumber -Body ("🤖⏸ Held for human approval`n`nPR #$PRNumber is green and self-reviewed, but " +
                "$why`n`n**Comment on this issue to change the PR; close the PR to reject it.** Merge PR #$PRNumber to accept. " +
                "The agent reads the issue, not PR review comments. Nothing reaches the default branch until you merge.")
            Write-Log "⏸ Issue #$IssueNumber held for human approval — $($governance.Count) governance, $($proposed.Count) proposed file(s)." -Color Yellow
            return $false
        }
    }

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
