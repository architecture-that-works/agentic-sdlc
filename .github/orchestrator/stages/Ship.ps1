#Requires -Version 7.0
<#
.SYNOPSIS
    Ship stage — rebase, wait for green CI, then merge or hold for the owner.

.DESCRIPTION
    Orchestrator library — loaded by Orchestrator.psm1. Invoke-Ship is reached only
    after the review stage approved (the conductor) or by the owner's manual
    dispatch (afk.yml stage=ship), so it does not re-derive approval. It rebases the
    branch, waits for CI, and then either holds a PR that touches a governance file
    (human:approval) or squash-merges it, deletes the branch and updates CONTEXT.md
    (Complete-Ship). Complete-HeldPR reconciles the issue on every feature-branch PR
    close (afk.yml, pull_request closed) — merged ships it, closed-unmerged fails it —
    skipping only an issue already agent:shipped, so a direct `gh pr merge` that
    bypasses Invoke-Ship still lands the issue on agent:shipped / Shipped, even one
    the pipeline had already marked agent:failed before the owner fixed it by hand.
#>

$ErrorActionPreference = 'Stop'
# Module-internal library — loaded by Orchestrator.psm1 (which loads Config.ps1 first).
# Not dot-sourced individually; see ADR-013.

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
Produce targeted patches to either section below if new content is warranted:
  1. Glossary         — new domain terms introduced by this change
  2. Bounded Contexts — ownership changes if new modules or contexts were added
Deferred or rejected decisions belong in .out-of-scope.md, not CONTEXT.md — do not add them here.

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
    $response = if ($KanbanEngine -eq 'gemini') {
        Remove-GeminiNoise -Text ($prompt | agy --model $KanbanModel_GeminiFlash 2>&1 | Out-String)
    } else {
        Remove-ClaudeNoise -Text ($prompt | claude --model $KanbanModel_Sonnet 2>&1 | Out-String)
    }
    # This whole function is best-effort (the merge already happened) — every branch
    # below returns normally after logging, never throws. But a handled native-command
    # failure (claude, git apply, git commit) still leaves $LASTEXITCODE non-zero, and
    # the workflow step that calls Complete-HeldPR/Invoke-Ship reports THAT as its own
    # exit code even though nothing actually failed. Reset it on every early return.
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Claude invocation failed — skipping context update." -Color Yellow
        $global:LASTEXITCODE = 0
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
            $global:LASTEXITCODE = 0
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
        $global:LASTEXITCODE = 0
        return
    }

    # Push to default branch
    $defaultBranch = $KanbanDefaultBranch
    git push origin $defaultBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Push failed for context update — reverting local commit to keep $defaultBranch in sync." -Color Yellow
        git reset --hard --quiet "origin/$defaultBranch" 2>&1 | Out-Null
        $global:LASTEXITCODE = 0
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
function Get-GovernanceFiles {
    param([Parameter(Mandatory)][int]$PRNumber)
    $files = @(gh pr diff $PRNumber --repo $KanbanRepo --name-only 2>$null | Where-Object { "$_".Trim() })
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($files | Where-Object {
        $f = "$_".Trim()
        @($OrchestratorConfig.GovernancePaths | Where-Object { $f -like $_ }).Count -gt 0
    })
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

    Write-Log "  Waiting for CI checks on PR #$PRNumber..." -Color DarkGray

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
    $ciGreen            = $false
    $ciFailed           = $false
    $everRegistered     = $false
    $failedNames        = ''

    while ((Get-Date) -lt $completionDeadline) {
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
        # The owner's hold: the label, or — once a later state replaced it — the
        # carrier's approval_required (Set-AgentState, #225).
        $state      = Get-IssueState -IssueNumber $IssueNumber
        $manual     = (@(Get-IssueLabel -IssueNumber $IssueNumber) -contains 'human:approval') -or
                      ($state -and $state.PSObject.Properties['approval_required'] -and $state.approval_required)
        if ($governance.Count -gt 0 -or $manual) {
            Set-AgentState -IssueNumber $IssueNumber -Label 'human:approval'
            $why = if ($governance.Count -gt 0) {
                "it changes governance files, which a human merges:`n" + (($governance | ForEach-Object { "- ``$_``" }) -join "`n")
            } else { 'this issue is labelled ``human:approval``.' }
            Add-Comment -Number $IssueNumber -Body ("🤖⏸ Held for human approval`n`nPR #$PRNumber is green and self-reviewed, but " +
                "$why`n`nReview and merge PR #$PRNumber. To change it instead, close the PR and comment on this issue with what should change.")
            Write-Log "⏸ Issue #$IssueNumber held for human approval — PR #$PRNumber awaits a human merge." -Color Yellow
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
# reaches agent:shipped and CONTEXT.md learns what changed. The merge has already
# happened, so the CONTEXT.md update is best-effort.
function Complete-Ship {
    param([int]$IssueNumber, [int]$PRNumber, [string]$How)

    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:shipped'
    Add-Comment -Number $IssueNumber -Body "🤖✅ Merged`n`nPR #$PRNumber $How. Issue closed."

    $default = $KanbanDefaultBranch
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
# practice always wins: this handler's job has to cold-start (checkout, install uv,
# install the Claude CLI) before it ever reads a label. Whichever path gets there first
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
    $labels = @(Get-IssueLabel -IssueNumber $issue)
    if ($labels -contains 'agent:shipped') {
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
