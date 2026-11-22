#Requires -Version 7.0
<#
    GitHub.ps1 — the one fake GitHub for the orchestrator's journeys.

    Holds issues, labels, comments, pull requests, check runs and the project board
    in memory, answers the `gh` calls the orchestrator makes, and records what they
    changed. A test sets a starting state (New-FakeGitHub, Add-FakeIssue,
    Add-FakeComment, Set-FakeChecks / Set-FakeCheckRuns for CI and its job logs), acts
    as the owner on a pull request (Complete-FakePullRequest: merge or close it), runs a
    journey, and reads the end state (Get-FakeIssue, Get-FakeComments,
    Get-FakePullRequest, Get-FakePrTimeline, Get-FakePipelineLabel).

    It also holds one project board (its fields, options and items: Get-FakeBoardItem;
    Get-FakeBoardSettings gives the KANBAN_* settings a journey states for it), the
    repository's settings, branch protection, Actions variables and labels — what the
    Commands a person runs (setup, sync, protect) read and write.

    Install-FakeGitHub mocks `gh` in the Orchestrator module's scope and in the
    caller's, so the orchestrator's own code and a Command run in-process with `&` both
    reach it unchanged, and the real CLI is never reached. A `gh`
    argument shape this file does not know throws `Unknown gh call: gh <args>` and is
    kept, so Assert-FakeGitHubClean fails the test and names it even when the
    orchestrator caught the throw.

    Every label change on an issue becomes a transition { Issue, From, To } — From and
    To are pipeline labels or $null — appended to $global:OrchestratorJourneyTransitions,
    which lasts for the whole Pester run and is read by StateMachine.Tests.ps1. Set-AgentState
    removes the old label (DELETE) before it adds the new one (POST); the fake pairs a
    removal with the add that follows it, and a removal nothing follows becomes
    { From = <label>; To = $null }.

    The pull requests' diffs are read from the bare remote of the fake repo
    (tests/fakes/Repo.ps1), the way GitHub reads them from the repository it hosts.

    Dot-sourced by the journeys; no top-level param() (ADR-013).
#>

if ($null -eq $global:OrchestratorJourneyTransitions) {
    $global:OrchestratorJourneyTransitions = [System.Collections.Generic.List[object]]::new()
}

# Flags of the gh calls the orchestrator makes that take no value.
$global:FakeGhSwitches = @('--paginate', '--draft', '--undo', '--name-only', '--comment', '--squash', '--delete-branch', '--checkout', '--force', '--show-token')

# The jq filters the orchestrator passes, by the call that passes them. A different
# filter is a different call: the fake refuses it rather than guess its output.
$global:FakeGhJq = @{
    Association = '.author_association'
    Labels      = 'map(.name) | .[]'
    Owner       = '.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") | select((.body | startswith("🤖") or startswith("·")) | not) | {login: .user.login, created_at: .created_at, body: .body} | @json'
    Bodies      = 'map(.body) | .[]'
    Issues      = '.[] | select(.pull_request == null) | .number'
    CheckRuns   = '.check_runs[] | {id, name, status, conclusion, head_sha, details_url} | tojson'
    Files       = '.[] | "\(.filename)\t+\(.additions) -\(.deletions)"'
    Login       = '.login'
    Survey      = '.[] | select(.pull_request == null) | {n: .number, u: .updated_at, l: [.labels[].name]} | @json'
    LiveRuns    = '[.workflow_runs[] | select((.status == "in_progress" or .status == "queued") and .id != 0)] | length'
}

# ── Starting state ───────────────────────────────────────────────────────────

# A fresh, empty GitHub. -Remote is the bare repository pull request diffs are read
# from; -Journey names the journey in every transition it records.
function New-FakeGitHub {
    param([string]$Remote = '', [string]$Journey = '', [string]$Login = 'owner')
    $module = Get-Module Orchestrator
    if (-not $module) { throw 'New-FakeGitHub: import the Orchestrator module first.' }
    $facts = & $module { @{
        Repo          = $KanbanRepo
        DefaultBranch = $KanbanDefaultBranch
        States        = @($PipelineStates.Keys)
        Required      = @($OrchestratorConfig.RequiredChecks)
    } }
    $global:FakeGitHub = @{
        Repo           = $facts.Repo
        DefaultBranch  = $facts.DefaultBranch
        PipelineLabels = $facts.States
        RequiredChecks = $facts.Required
        Remote         = $Remote
        Journey        = $Journey
        Login          = $Login
        Issues         = [ordered]@{}
        Comments       = [System.Collections.Generic.List[object]]::new()
        PullRequests   = [System.Collections.Generic.List[object]]::new()
        CheckRuns      = @{}          # sha → runs; a sha without runs gets the default runs
        CheckConclusion = 'success'   # every required check on every pushed commit, unless set
        CheckDefaults  = @{ Conclusions = @{}; Missing = @(); Runs = @() }   # Set-FakeChecks
        LiveRuns       = 0            # afk.yml runs in progress or queued (the warden's liveness check)
        JobLogs        = @{}          # job id → the log `gh api …/actions/jobs/<id>/logs` answers
        Board          = [System.Collections.Generic.List[object]]::new()
        Project        = (New-FakeProject)
        RepoSettings   = [ordered]@{
            visibility = 'public'; allow_squash_merge = $true; allow_merge_commit = $true; allow_rebase_merge = $true
            squash_merge_commit_title = 'COMMIT_OR_PR_TITLE'; squash_merge_commit_message = 'COMMIT_MESSAGES'
            delete_branch_on_merge = $false; allow_update_branch = $false
            security_and_analysis = [ordered]@{ secret_scanning = @{ status = 'disabled' }; secret_scanning_push_protection = @{ status = 'disabled' } }
        }
        Protection     = $null        # branch protection of the default branch, as PUT
        RefuseSecretScanning = $false # a public repository refuses it too (a private one always does)
        Variables      = [ordered]@{} # Actions repository variables
        RepoLabels     = [ordered]@{} # label name → @{ Color; Description }
        Dispatches     = [System.Collections.Generic.List[object]]::new()
        Calls          = [System.Collections.Generic.List[string]]::new()
        Changes        = [System.Collections.Generic.List[string]]::new()
        Unknown        = [System.Collections.Generic.List[string]]::new()
        Transitions    = [System.Collections.Generic.List[object]]::new()
        Pending        = @{}          # issue → pipeline label removed, waiting for its successor
        Clock          = 0
    }
    return $global:FakeGitHub
}

# Mocks `gh` for the current Pester block: in the Orchestrator module's scope, and in
# the caller's, which a Command run with `&` inherits.
function Install-FakeGitHub {
    # Pester mocks only a command that exists; a machine without the CLI gets a
    # stand-in that the mock then replaces.
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        function global:gh { throw 'gh is not installed — the fake GitHub replaces it in the journeys.' }
    }
    Mock gh -ModuleName Orchestrator -MockWith { Invoke-FakeGh -Arguments $args }
    Mock gh -MockWith { Invoke-FakeGh -Arguments $args }
}

# The board a fresh GitHub holds: project 5 of 'octo' with a Status field holding the
# four lanes, a number field Estimate and a single-select Priority (P0–P4). -Fields
# replaces the field list (setup creates a missing Estimate or Priority).
function New-FakeProject {
    param([object[]]$Fields = $null)
    $option = { param($Field, $Name) [pscustomobject]@{ id = "OPT_${Field}_$Name"; name = $Name } }
    if ($null -eq $Fields) {
        $Fields = @(
            [pscustomobject]@{ id = 'FIELD_status'; name = 'Status'; type = 'ProjectV2SingleSelectField'
                options = @('Backlog', 'Implementing', 'Review', 'Shipped' | ForEach-Object { & $option 'status' $_ }) }
            [pscustomobject]@{ id = 'FIELD_estimate'; name = 'Estimate'; type = 'ProjectV2Field' }
            [pscustomobject]@{ id = 'FIELD_priority'; name = 'Priority'; type = 'ProjectV2SingleSelectField'
                options = @('P0', 'P1', 'P2', 'P3', 'P4' | ForEach-Object { & $option 'priority' $_ }) }
        )
    }
    return [pscustomobject]@{
        Number = 5; Owner = 'octo'; Id = 'PROJECT_FAKE'; Title = 'Sandbox board'
        Fields = [System.Collections.Generic.List[object]]::new([object[]]@($Fields))
    }
}

# The KANBAN_* settings that point the orchestrator at the fake board — what `task
# setup` writes to .env for it. A journey that needs a board sets them in the process
# environment (Start-Journey clears them again afterwards).
function Get-FakeBoardSettings {
    $p = $global:FakeGitHub.Project
    $field = { param($Name) $p.Fields | Where-Object name -eq $Name | Select-Object -First 1 }
    $lane = { param($Name) ((& $field 'Status').options | Where-Object name -eq $Name).id }
    $settings = [ordered]@{
        KANBAN_PROJECT_NUMBER   = "$($p.Number)"
        KANBAN_PROJECT_OWNER    = $p.Owner
        KANBAN_PROJECT_ID       = $p.Id
        KANBAN_STATUS_FIELD_ID  = (& $field 'Status').id
        KANBAN_OPT_BACKLOG      = & $lane 'Backlog'
        KANBAN_OPT_IMPLEMENTING = & $lane 'Implementing'
        KANBAN_OPT_REVIEW       = & $lane 'Review'
        KANBAN_OPT_MERGED       = & $lane 'Shipped'
    }
    $estimate = & $field 'Estimate'
    if ($estimate) { $settings['KANBAN_ESTIMATE_FIELD_ID'] = $estimate.id }
    $priority = & $field 'Priority'
    if ($priority) {
        $settings['KANBAN_PRIORITY_FIELD_ID'] = $priority.id
        foreach ($o in $priority.options) { $settings["KANBAN_PRIORITY_OPT_$($o.name)"] = $o.id }
    }
    return $settings
}

# Puts an issue on the board as it already stands there: its lane, estimate and priority.
function Add-FakeBoardItem {
    param([Parameter(Mandatory)][int]$Issue, [string]$Status = 'Backlog', $Estimate = $null, [string]$Priority = $null)
    $global:FakeGitHub.Board.Add([pscustomobject]@{
        id = "ITEM_$Issue"; content = [pscustomobject]@{ number = $Issue; repository = $global:FakeGitHub.Repo }
        status = $Status; estimate = $Estimate; priority = $Priority
    })
}

# The board item of an issue: { id; status; estimate; priority } ($null when not on the board).
function Get-FakeBoardItem {
    param([Parameter(Mandatory)][int]$Issue)
    return @($global:FakeGitHub.Board | Where-Object { $_.content.number -eq $Issue }) | Select-Object -First 1
}

function Add-FakeIssue {
    param(
        [Parameter(Mandatory)][int]$Number,
        [string]$Title = "Issue $Number",
        [string]$Body = '',
        [string[]]$Labels = @(),
        [string]$AuthorAssociation = 'OWNER',
        [string]$State = 'OPEN',
        [int]$IdleMinutes = 0
    )
    $global:FakeGitHub.Issues["$Number"] = [pscustomobject]@{
        Number            = $Number
        Title             = $Title
        Body              = $Body
        State             = $State
        AuthorAssociation = $AuthorAssociation
        # When anything last touched it (-IdleMinutes ago): the warden reads it as updated_at.
        UpdatedAt         = (Get-Date).ToUniversalTime().AddMinutes(-$IdleMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Labels            = [System.Collections.Generic.List[string]]::new([string[]]@($Labels))
        Assignees         = [System.Collections.Generic.List[string]]::new()
    }
}

# A comment as the owner writes it (or anyone, with -AuthorAssociation). The fake's
# clock makes every comment newer than everything before it.
function Add-FakeComment {
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$Body,
        [string]$AuthorAssociation = 'OWNER',
        [string]$Login = $global:FakeGitHub.Login
    )
    Get-FakeIssueRecord -Number $Issue | Out-Null
    $global:FakeGitHub.Comments.Add([pscustomobject]@{
        Id                = $global:FakeGitHub.Comments.Count + 1
        Issue             = $Issue
        Body              = $Body
        AuthorAssociation = $AuthorAssociation
        Login             = $Login
        CreatedAt         = Get-FakeNow
    })
}

# Check runs for one commit: @{ name = conclusion }. Without them a commit gets the
# default runs (Set-FakeChecks). -Logs @{ name = '<log text>' } is what the failed
# job's log read answers for that run.
function Set-FakeCheckRuns {
    param([Parameter(Mandatory)][string]$Sha, [Parameter(Mandatory)][hashtable]$Conclusions, [hashtable]$Logs = @{})
    $id = 1000
    $global:FakeGitHub.CheckRuns[$Sha] = @($Conclusions.Keys | ForEach-Object {
        $id++
        if ($Logs.ContainsKey($_)) { $global:FakeGitHub.JobLogs["$id"] = $Logs[$_] }
        New-FakeCheckRun -Id $id -Name $_ -Conclusion $Conclusions[$_] -Sha $Sha
    })
}

# The check runs every pushed commit gets, whatever its sha — a journey cannot know
# the sha before the orchestrator pushes. Each required check (RequiredChecks, read
# from the orchestrator) concludes CheckConclusion unless:
#   -Conclusions @{ name = 'failure' | 'neutral' | $null }  — $null: still running
#   -Missing     @('name')                                   — no run at all
#   -Logs        @{ name = '<log text>' }                    — that job's log
#   -Runs        @(@{ Name; Conclusion; Status; Age; OtherCommit }) — more runs beside
#                those: any check name; Age 'older' or 'newer' than the required runs
#                (default newer); OtherCommit for a run on another commit; Status for a
#                status GitHub reports beside the conclusion (default from the conclusion)
function Set-FakeChecks {
    param([hashtable]$Conclusions = @{}, [string[]]$Missing = @(), [hashtable]$Logs = @{}, [object[]]$Runs = @())
    $fake = $global:FakeGitHub
    foreach ($name in @($Conclusions.Keys) + @($Missing) + @($Logs.Keys)) {
        if ($name -notin $fake.RequiredChecks) { throw "Set-FakeChecks: '$name' is not a required check ($($fake.RequiredChecks -join ', '))." }
    }
    $fake.CheckDefaults = @{ Conclusions = $Conclusions; Missing = @($Missing); Runs = @($Runs) }
    foreach ($name in $Logs.Keys) { $fake.JobLogs["$(Get-FakeDefaultJobId -Name $name)"] = $Logs[$name] }
}

# Changes the owner makes to a pull request by hand, as GitHub's pull-request page does:
# -Merged squash-merges it on the remote and deletes its branch; otherwise it is closed
# unmerged. -Ready first marks a draft ready (GitHub refuses to merge a draft).
# Returns what the workflow's pull_request-closed step passes to Complete-HeldPR:
# @{ PRNumber; Branch; Merged } — splat it.
function Complete-FakePullRequest {
    param([Parameter(Mandatory)][int]$Number, [switch]$Merged, [switch]$Ready)
    $fake = $global:FakeGitHub
    $pr = Get-FakePullRequest -Number $Number
    if (-not $pr) { throw "The fake GitHub holds no pull request #$Number." }
    if ($pr.State -ne 'OPEN') { throw "Pull request #$Number is $($pr.State), not open." }
    $sha = @(Invoke-FakeRemoteGit -GitArgs @('for-each-ref', '--format=%(objectname)', "refs/heads/$($pr.Head)"))[0]
    if ($sha) { $pr.HeadSha = $sha }
    if ($Ready -and $pr.IsDraft) {
        $pr.IsDraft = $false
        $fake.Changes.Add("PR #$Number marked ready by the owner")
    }
    if ($Merged) {
        if ($pr.IsDraft) { throw "Pull request #$Number is still a draft — GitHub refuses to merge it (pass -Ready)." }
        Merge-FakePullRequest -PR $pr -DeleteBranch
        $fake.Changes.Add("PR #$Number merged by the owner")
    } else {
        $pr.State = 'CLOSED'
        $fake.Changes.Add("PR #$Number closed by the owner")
    }
    return @{ PRNumber = $Number; Branch = $pr.Head; Merged = [bool]$Merged }
}

# ── End state ─────────────────────────────────────────────────────────────────

function Get-FakeIssue {
    param([Parameter(Mandatory)][int]$Number)
    return Get-FakeIssueRecord -Number $Number
}

# The one pipeline label the issue carries ($null for none). Throws when it carries
# more than one — the orchestrator promises exactly one (ADR-015).
function Get-FakePipelineLabel {
    param([Parameter(Mandatory)][int]$Number)
    $labels = @((Get-FakeIssueRecord -Number $Number).Labels | Where-Object { $_ -in $global:FakeGitHub.PipelineLabels })
    if ($labels.Count -gt 1) { throw "Issue #$Number carries more than one pipeline label: $($labels -join ', ')" }
    return $labels | Select-Object -First 1
}

function Get-FakeComments {
    param([Parameter(Mandatory)][int]$Issue)
    return @($global:FakeGitHub.Comments | Where-Object { $_.Issue -eq $Issue })
}

# The first line of every pipeline comment on the issue, oldest first — what the
# owner sees in the timeline: a 🤖 signal with its heading, or a · noise line.
function Get-FakeCommentHeadings {
    param([Parameter(Mandatory)][int]$Issue)
    return @(Get-FakeComments -Issue $Issue |
        Where-Object { $_.Body.StartsWith('🤖') -or $_.Body.StartsWith('·') } |
        ForEach-Object { ($_.Body -split '\r?\n')[0].Trim() })
}

function Get-FakePullRequest {
    param([string]$Head = '', [int]$Number = 0)
    return @($global:FakeGitHub.PullRequests | Where-Object {
        ($Head -and $_.Head -eq $Head) -or ($Number -and $_.Number -eq $Number)
    }) | Select-Object -First 1
}

# What happened to one pull request, oldest first, as its timeline shows it:
# 'opened as draft from <branch>', 'review comment', 'marked ready', 'back to draft',
# 'description rewritten', 'squash-merged', 'merged by the owner', …
function Get-FakePrTimeline {
    param([Parameter(Mandatory)][int]$Number)
    $prefix = "PR #$Number "
    return @($global:FakeGitHub.Changes | Where-Object { $_.StartsWith($prefix) } | ForEach-Object { $_.Substring($prefix.Length) })
}

# The transitions this fake recorded since New-FakeGitHub, removals nothing followed included.
function Get-FakeTransitions {
    Complete-FakeTransitions
    return @($global:FakeGitHub.Transitions)
}

# Throws, naming each call, when the orchestrator made a gh call the fake does not know.
function Assert-FakeGitHubClean {
    Complete-FakeTransitions
    if ($global:FakeGitHub.Unknown.Count -gt 0) {
        throw "The fake GitHub was asked calls it does not know:`n$($global:FakeGitHub.Unknown -join "`n")"
    }
}

# ── Internals ─────────────────────────────────────────────────────────────────

function Get-FakeNow {
    # Seconds apart, so a comment is never in the same second as what came before it
    # (GitHub's `since` has a one-second resolution).
    $global:FakeGitHub.Clock++
    return (Get-Date).ToUniversalTime().AddSeconds($global:FakeGitHub.Clock).ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-FakeIssueRecord {
    param([int]$Number)
    $issue = $global:FakeGitHub.Issues["$Number"]
    if (-not $issue) { throw "The fake GitHub holds no issue #$Number." }
    return $issue
}

function Add-FakeTransition {
    param([int]$Issue, $From, $To)
    $t = [pscustomobject]@{ Journey = $global:FakeGitHub.Journey; Issue = $Issue; From = $From; To = $To }
    $global:FakeGitHub.Transitions.Add($t)
    $global:OrchestratorJourneyTransitions.Add($t)
}

# A removal no add followed: the issue was left without that pipeline label.
function Complete-FakeTransitions {
    param([int]$Except = 0)
    foreach ($n in @($global:FakeGitHub.Pending.Keys)) {
        if ([int]$n -eq $Except) { continue }
        Add-FakeTransition -Issue ([int]$n) -From $global:FakeGitHub.Pending[$n] -To $null
        $global:FakeGitHub.Pending.Remove($n)
    }
}

function Remove-FakeLabel {
    param([int]$Number, [string]$Label)
    $issue = Get-FakeIssueRecord -Number $Number
    if (-not $issue.Labels.Remove($Label)) { return $false }
    $global:FakeGitHub.Changes.Add("#${Number}: label - $Label")
    if ($Label -in $global:FakeGitHub.PipelineLabels -and -not $global:FakeGitHub.Pending.ContainsKey("$Number")) {
        $global:FakeGitHub.Pending["$Number"] = $Label
    }
    return $true
}

function Add-FakeLabel {
    param([int]$Number, [string]$Label)
    $issue = Get-FakeIssueRecord -Number $Number
    if ($issue.Labels.Contains($Label)) { return }
    if ($Label -in $global:FakeGitHub.PipelineLabels) {
        $from = if ($global:FakeGitHub.Pending.ContainsKey("$Number")) { $global:FakeGitHub.Pending["$Number"] }
                else { @($issue.Labels | Where-Object { $_ -in $global:FakeGitHub.PipelineLabels }) | Select-Object -First 1 }
        $global:FakeGitHub.Pending.Remove("$Number")
        Add-FakeTransition -Issue $Number -From $from -To $Label
    }
    $issue.Labels.Add($Label)
    $global:FakeGitHub.Changes.Add("#${Number}: label + $Label")
}

function Read-FakeBodyFile {
    param([string]$Path)
    return "$(Get-Content -LiteralPath $Path -Raw -Encoding utf8)".TrimEnd("`r", "`n")
}

function Get-FakePrUrl {
    param([int]$Number)
    return "https://github.com/$($global:FakeGitHub.Repo)/pull/$Number"
}

function Get-FakeNextNumber {
    $numbers = @($global:FakeGitHub.Issues.Values | ForEach-Object { $_.Number }) +
               @($global:FakeGitHub.PullRequests | ForEach-Object { $_.Number }) + 0
    return ([int]($numbers | Measure-Object -Maximum).Maximum) + 1
}

# git against the bare remote; the caller's exit code is set afterwards.
function Invoke-FakeRemoteGit {
    param([string[]]$GitArgs)
    $remote = $global:FakeGitHub.Remote
    if (-not $remote) { throw 'The fake GitHub has no remote — pass New-FakeGitHub -Remote.' }
    $out = & git --git-dir $remote @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') on the fake remote failed: $($out | Out-String)" }
    return @($out | ForEach-Object { "$_" })
}

function New-FakeCheckRun {
    param([int]$Id, [string]$Name, $Conclusion, [string]$Sha)
    return [pscustomobject]@{
        id = $Id; name = $Name; head_sha = $Sha
        status = if ($null -eq $Conclusion) { 'in_progress' } else { 'completed' }; conclusion = $Conclusion
        details_url = "https://github.com/$($global:FakeGitHub.Repo)/actions/runs/1/job/$Id"
    }
}

# A default run's job id: the same for one check name on every commit.
function Get-FakeDefaultJobId {
    param([string]$Name)
    return 2001 + [array]::IndexOf([string[]]@($global:FakeGitHub.RequiredChecks), $Name)
}

# The runs a commit without its own (Set-FakeCheckRuns) gets: Set-FakeChecks.
function Get-FakeDefaultCheckRuns {
    param([string]$Sha)
    $fake = $global:FakeGitHub
    $defaults = $fake.CheckDefaults
    $i = 0
    $extra = @(foreach ($r in @($defaults.Runs)) {
        $i++
        $id  = if ($r.Age -eq 'older') { 1000 + $i } else { 3000 + $i }
        $run = New-FakeCheckRun -Id $id -Name $r.Name -Conclusion $r.Conclusion -Sha $(if ($r.OtherCommit) { 'f' * 40 } else { $Sha })
        if ($r.Status) { $run.status = $r.Status }
        $run
    })
    return @($extra) + @($fake.RequiredChecks | Where-Object { $_ -notin $defaults.Missing } | ForEach-Object {
        $conclusion = if ($defaults.Conclusions.ContainsKey($_)) { $defaults.Conclusions[$_] } else { $fake.CheckConclusion }
        New-FakeCheckRun -Id (Get-FakeDefaultJobId -Name $_) -Name $_ -Conclusion $conclusion -Sha $Sha
    })
}

# A squash merge on the remote: the merged tree as one commit on the base.
function Merge-FakePullRequest {
    param($PR, [switch]$DeleteBranch)
    $tree = @(Invoke-FakeRemoteGit -GitArgs @('merge-tree', '--write-tree', "refs/heads/$($PR.Base)", $PR.HeadSha))[0]
    $base = @(Invoke-FakeRemoteGit -GitArgs @('rev-parse', "refs/heads/$($PR.Base)"))[0]
    $commit = @(Invoke-FakeRemoteGit -GitArgs @('commit-tree', $tree, '-p', $base, '-m', "$($PR.Title) (#$($PR.Number))"))[0]
    Invoke-FakeRemoteGit -GitArgs @('update-ref', "refs/heads/$($PR.Base)", $commit) | Out-Null
    if ($DeleteBranch) { Invoke-FakeRemoteGit -GitArgs @('update-ref', '-d', "refs/heads/$($PR.Head)") | Out-Null }
    $PR.State = 'MERGED'
}

function Get-FakePrDiff {
    param($PR, [ValidateSet('patch', 'names', 'numstat')][string]$Shape)
    $range = "refs/heads/$($PR.Base)...$($PR.HeadSha)"
    switch ($Shape) {
        'names'   { return Invoke-FakeRemoteGit -GitArgs @('diff', '--name-only', $range) }
        'numstat' { return Invoke-FakeRemoteGit -GitArgs @('diff', '--numstat', $range) }
        default   { return Invoke-FakeRemoteGit -GitArgs @('diff', $range) }
    }
}

# The PR as `gh pr list/view --json` shows it: only the fields asked for.
function ConvertTo-FakePrJson {
    param($PR, [string[]]$Fields)
    $all = @{
        number            = $PR.Number
        url               = (Get-FakePrUrl -Number $PR.Number)
        isDraft           = $PR.IsDraft
        headRefName       = $PR.Head
        baseRefName       = $PR.Base
        isCrossRepository = $false
        title             = $PR.Title
        body              = $PR.Body
        state             = $PR.State
    }
    $o = [ordered]@{}
    foreach ($f in $Fields) {
        if (-not $all.ContainsKey($f)) { throw "pr field '$f'" }
        $o[$f] = $all[$f]
    }
    return [pscustomobject]$o
}

function ConvertTo-FakeIssueJson {
    param($Issue, [string[]]$Fields)
    $o = [ordered]@{}
    foreach ($f in $Fields) {
        $o[$f] = switch ($f) {
            'number'   { $Issue.Number }
            'title'    { $Issue.Title }
            'body'     { $Issue.Body }
            'state'    { $Issue.State }
            'labels'   { @($Issue.Labels | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
            'comments' {
                @(Get-FakeComments -Issue $Issue.Number | ForEach-Object {
                    [pscustomobject]@{ author = [pscustomobject]@{ login = $_.Login }; authorAssociation = $_.AuthorAssociation; body = $_.Body; createdAt = $_.CreatedAt }
                })
            }
            default    { throw "issue field '$f'" }
        }
    }
    return [pscustomobject]$o
}

# Applies `--jq '.<field>'` the way gh does for one scalar field: the raw value.
function Select-FakeJqField {
    param($Object, [string]$Jq)
    if ($Jq -notmatch '^\.(\w+)$') { throw "jq '$Jq'" }
    return "$($Object.($Matches[1]))"
}

# ── The dispatcher: one gh call ───────────────────────────────────────────────

function Invoke-FakeGh {
    param([object[]]$Arguments)
    # An unquoted list (`--json title,labels,state`) reaches a native command as one
    # comma-joined argument, and the mock as an array.
    $argv = @(foreach ($a in $Arguments) { if ($a -is [array]) { $a -join ',' } else { "$a" } })
    $line = "gh $($argv -join ' ')"
    $fake = $global:FakeGitHub
    if (-not $fake) { throw "The fake GitHub is not set up (New-FakeGitHub) — $line" }
    $fake.Calls.Add($line)

    # Split into positionals and flags (a flag given twice keeps every value).
    $pos   = [System.Collections.Generic.List[string]]::new()
    $flags = @{}
    for ($i = 0; $i -lt $argv.Count; $i++) {
        $a = $argv[$i]
        if ($a -match '^-{1,2}[A-Za-z]') {
            $value = if ($a -in $global:FakeGhSwitches) { $true } else { $i++; $argv[$i] }
            if ($flags.ContainsKey($a)) { $flags[$a] = @($flags[$a]) + $value } else { $flags[$a] = $value }
        } else {
            $pos.Add($a)
        }
    }

    # A label add pairs with the removal before it; anything else settles that removal.
    $labelAdd = ($pos.Count -ge 2 -and $pos[0] -eq 'api' -and $flags['--method'] -eq 'POST' -and $pos[1] -match '/issues/(\d+)/labels$')
    Complete-FakeTransitions -Except $(if ($labelAdd) { [int]$Matches[1] } else { 0 })

    try {
        $global:LASTEXITCODE = 0
        $out = Invoke-FakeGhRoute -Pos $pos -Flags $flags
        return $out
    } catch {
        if ("$($_.Exception.Message)" -like 'FAKE-EXIT|*') {
            $parts = "$($_.Exception.Message)" -split '\|', 3
            $global:LASTEXITCODE = [int]$parts[1]
            return $parts[2]
        }
        $message = "Unknown gh call: $line$(if ($_.Exception.Message -notlike 'unknown') { " ($($_.Exception.Message))" })"
        $fake.Unknown.Add($message)
        $global:LASTEXITCODE = 1
        throw $message
    }
}

# A gh call that fails the way gh fails: a non-zero exit and its message.
function Stop-FakeGh {
    param([int]$Exit, [string]$Message)
    throw "FAKE-EXIT|$Exit|$Message"
}

function Invoke-FakeGhRoute {
    param([System.Collections.Generic.List[string]]$Pos, [hashtable]$Flags)
    $fake = $global:FakeGitHub
    $jq   = $Flags['--jq']
    $cmd  = "$($Pos[0]) $(if ($Pos.Count -gt 1) { $Pos[1] })".Trim()

    switch -Regex ($cmd) {
        '^auth status$' { return "github.com`n  ✓ Logged in to github.com account $($fake.Login) (fake)`n  - Token scopes: 'project', 'read:org', 'repo', 'user', 'workflow'" }

        '^api ' {
            $path   = $Pos[1]
            $method = if ($Flags['--method']) { $Flags['--method'] } else { 'GET' }
            $query  = @{}
            if ($path -match '^([^?]+)\?(.*)$') {
                $path = $Matches[1]
                foreach ($kv in ($Matches[2] -split '&')) { $k, $v = $kv -split '=', 2; $query[$k] = [uri]::UnescapeDataString("$v") }
            }
            if ($path -eq 'user' -and $jq -eq $global:FakeGhJq.Login) { return $fake.Login }
            if ($path -eq "repos/$($fake.Repo)" -and -not $jq) {
                if ($method -eq 'GET') { return ($fake.RepoSettings | ConvertTo-Json -Depth 6 -Compress) }
                if ($method -eq 'PATCH' -and $Flags['--input']) {
                    $patch = Get-Content -LiteralPath $Flags['--input'] -Raw | ConvertFrom-Json -AsHashtable
                    if ($patch.Contains('security_and_analysis') -and ($fake.RepoSettings.visibility -ne 'public' -or $fake.RefuseSecretScanning)) {
                        Stop-FakeGh 1 'gh: Advanced security has not been purchased (HTTP 422)'
                    }
                    foreach ($k in $patch.Keys) { $fake.RepoSettings[$k] = $patch[$k] }
                    $fake.Changes.Add("repository settings: $(@($patch.Keys) -join ', ')")
                    return ($fake.RepoSettings | ConvertTo-Json -Depth 6 -Compress)
                }
                throw 'unknown'
            }
            if ($path -notmatch '^repos/[^/]+/[^/]+/(.+)$') { throw 'unknown' }
            $rest = $Matches[1]

            if ($rest -eq "branches/$($fake.DefaultBranch)/protection" -and -not $jq) {
                if ($method -eq 'PUT' -and $Flags['--input']) {
                    $fake.Protection = Get-Content -LiteralPath $Flags['--input'] -Raw | ConvertFrom-Json -AsHashtable
                    $fake.Changes.Add("branch protection of $($fake.DefaultBranch)")
                    return '{}'
                }
                if ($method -eq 'GET') {
                    if (-not $fake.Protection) { Stop-FakeGh 1 'gh: Branch not protected (HTTP 404)' }
                    $put = $fake.Protection
                    # GitHub answers a read in its own shape: enforce_admins as an object.
                    return ([ordered]@{
                        required_status_checks        = $put.required_status_checks
                        enforce_admins                = @{ enabled = [bool]$put.enforce_admins }
                        required_pull_request_reviews = $put.required_pull_request_reviews
                        allow_force_pushes            = @{ enabled = [bool]$put.allow_force_pushes }
                    } | ConvertTo-Json -Depth 6 -Compress)
                }
                throw 'unknown'
            }
            if ($rest -match '^issues/(\d+)$' -and $method -eq 'GET' -and $jq -eq $global:FakeGhJq.Association) {
                $issue = $fake.Issues[$Matches[1]]
                if (-not $issue) { Stop-FakeGh 1 'gh: Not Found (HTTP 404)' }
                return $issue.AuthorAssociation
            }
            if ($rest -match '^issues/(\d+)/labels$' -and $method -eq 'GET' -and $jq -eq $global:FakeGhJq.Labels) {
                return @((Get-FakeIssueRecord -Number ([int]$Matches[1])).Labels)
            }
            if ($rest -match '^issues/(\d+)/labels$' -and $method -eq 'POST' -and $Flags['-f'] -match '^labels\[\]=(.+)$') {
                $label = $Matches[1]
                Add-FakeLabel -Number ([int]($rest -replace '^issues/(\d+)/labels$', '$1')) -Label $label
                return '[]'
            }
            if ($rest -match '^issues/(\d+)/labels/(.+)$' -and $method -eq 'DELETE') {
                $n = [int]$Matches[1]; $label = [uri]::UnescapeDataString($Matches[2])
                if (-not (Remove-FakeLabel -Number $n -Label $label)) { Stop-FakeGh 1 'gh: Label does not exist (HTTP 404)' }
                return '[]'
            }
            if ($rest -match '^issues/(\d+)/comments$' -and $method -eq 'GET' -and $jq -eq $global:FakeGhJq.Owner) {
                $since = if ($query['since']) { [datetimeoffset]::Parse($query['since']).UtcDateTime } else { [datetime]::MinValue }
                return @(Get-FakeComments -Issue ([int]$Matches[1]) | Where-Object {
                    $_.AuthorAssociation -in @('OWNER', 'MEMBER', 'COLLABORATOR') -and
                    -not ($_.Body.StartsWith('🤖') -or $_.Body.StartsWith('·')) -and
                    [datetimeoffset]::Parse($_.CreatedAt).UtcDateTime -ge $since
                } | ForEach-Object { [ordered]@{ login = $_.Login; created_at = $_.CreatedAt; body = $_.Body } | ConvertTo-Json -Compress })
            }
            if ($rest -match '^issues/(\d+)/comments$' -and $method -eq 'GET' -and $jq -eq $global:FakeGhJq.Bodies) {
                return @(Get-FakeComments -Issue ([int]$Matches[1]) | ForEach-Object { $_.Body })
            }
            if ($rest -eq 'issues' -and $method -eq 'GET' -and $jq -eq $global:FakeGhJq.Survey) {
                return @($fake.Issues.Values | Where-Object State -eq 'OPEN' | ForEach-Object {
                    [ordered]@{ n = $_.Number; u = $_.UpdatedAt; l = @($_.Labels) } | ConvertTo-Json -Compress
                })
            }
            if ($rest -eq 'actions/workflows/afk.yml/runs' -and $method -eq 'GET' -and $jq -eq $global:FakeGhJq.LiveRuns) {
                return "$($fake.LiveRuns)"
            }
            if ($rest -eq 'issues' -and $method -eq 'GET' -and $jq -eq $global:FakeGhJq.Issues) {
                $state = if ($query['state']) { $query['state'].ToUpper() } else { 'OPEN' }
                return @($fake.Issues.Values | Where-Object {
                    $_.State -eq $state -and (-not $query['labels'] -or $_.Labels.Contains($query['labels']))
                } | ForEach-Object { "$($_.Number)" })
            }
            if ($rest -match '^commits/([0-9a-f]{40})/check-runs$' -and $jq -eq $global:FakeGhJq.CheckRuns) {
                $sha  = $Matches[1]
                $runs = if ($fake.CheckRuns.ContainsKey($sha)) { $fake.CheckRuns[$sha] }
                        elseif ($fake.CheckConclusion) { Get-FakeDefaultCheckRuns -Sha $sha }
                        else { @() }
                return @($runs | ForEach-Object { $_ | Select-Object id, name, status, conclusion, head_sha, details_url | ConvertTo-Json -Compress })
            }
            # A job's own log, as plain text (no --jq): 404 for a job with no log scripted.
            if ($rest -match '^actions/jobs/(\d+)/logs$' -and $method -eq 'GET' -and -not $jq) {
                if (-not $fake.JobLogs.ContainsKey($Matches[1])) { Stop-FakeGh 1 'gh: Not Found (HTTP 404)' }
                return $fake.JobLogs[$Matches[1]]
            }
            if ($rest -match '^pulls/(\d+)/files$' -and $jq -eq $global:FakeGhJq.Files) {
                $pr = Get-FakePullRequest -Number ([int]$Matches[1])
                if (-not $pr) { Stop-FakeGh 1 'gh: Not Found (HTTP 404)' }
                return @(Get-FakePrDiff -PR $pr -Shape numstat | ForEach-Object {
                    $add, $del, $file = $_ -split "`t", 3
                    "$file`t+$add -$del"
                })
            }
            throw 'unknown'
        }

        '^issue list$' {
            $fields = "$($Flags['--json'])" -split ','
            if ($jq -or $Flags['--label']) { throw 'unknown' }
            $state = if ($Flags['--state']) { $Flags['--state'].ToUpper() } else { 'OPEN' }
            $issues = @($fake.Issues.Values | Where-Object { $state -eq 'ALL' -or $_.State -eq $state } | ForEach-Object {
                $issue = $_
                $o = [ordered]@{}
                foreach ($f in $fields) {
                    $o[$f] = switch ($f) {
                        'number' { $issue.Number }
                        'title'  { $issue.Title }
                        'url'    { "https://github.com/$($fake.Repo)/issues/$($issue.Number)" }
                        'labels' { @($issue.Labels | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
                        default  { throw "issue field '$f'" }
                    }
                }
                [pscustomobject]$o
            })
            return (ConvertTo-Json -InputObject @($issues) -Depth 5 -Compress)
        }
        '^issue create$' {
            if (-not $Flags['--title'] -or -not $Flags['--body-file']) { throw 'unknown' }
            $n = Get-FakeNextNumber
            $labels = if ($Flags['--label']) { @("$($Flags['--label'])" -split ',') } else { @() }
            Add-FakeIssue -Number $n -Title $Flags['--title'] -Body (Read-FakeBodyFile -Path $Flags['--body-file']) -Labels $labels
            $fake.Changes.Add("#${n}: opened")
            return "https://github.com/$($fake.Repo)/issues/$n"
        }
        '^issue view$' {
            $issue = $fake.Issues[$Pos[2]]
            if (-not $issue) { Stop-FakeGh 1 "GraphQL: Could not resolve to an issue or pull request with the number of $($Pos[2])." }
            $json = ConvertTo-FakeIssueJson -Issue $issue -Fields ("$($Flags['--json'])" -split ',')
            if ($jq) { return Select-FakeJqField -Object $json -Jq $jq }
            return ($json | ConvertTo-Json -Depth 8 -Compress)
        }
        '^issue edit$' {
            $issue = Get-FakeIssueRecord -Number ([int]$Pos[2])
            if ($Flags['--body-file']) {
                $issue.Body = Read-FakeBodyFile -Path $Flags['--body-file']
                $fake.Changes.Add("#$($issue.Number): body edited")
                return "https://github.com/$($fake.Repo)/issues/$($issue.Number)"
            }
            if ($Flags['--add-assignee']) {
                $issue.Assignees.Add($Flags['--add-assignee'])
                $fake.Changes.Add("#$($issue.Number): assigned $($Flags['--add-assignee'])")
                return "https://github.com/$($fake.Repo)/issues/$($issue.Number)"
            }
            throw 'unknown'
        }
        '^issue comment$' {
            $n = [int]$Pos[2]
            Get-FakeIssueRecord -Number $n | Out-Null
            if (-not $Flags['--body-file']) { throw 'unknown' }
            # The pipeline posts with the owner's token.
            Add-FakeComment -Issue $n -Body (Read-FakeBodyFile -Path $Flags['--body-file'])
            $fake.Changes.Add("#${n}: comment")
            return "https://github.com/$($fake.Repo)/issues/$n#issuecomment-$($fake.Comments.Count)"
        }
        '^issue close$' {
            $issue = Get-FakeIssueRecord -Number ([int]$Pos[2])
            $issue.State = 'CLOSED'
            $fake.Changes.Add("#$($issue.Number): closed")
            return ''
        }
        '^issue develop$' {
            # Linked branches are not modelled: the orchestrator falls back to git.
            Stop-FakeGh 1 'gh issue develop: linked branches are not modelled by the fake GitHub'
        }

        '^pr list$' {
            $state  = if ($Flags['--state']) { $Flags['--state'].ToUpper() } else { 'OPEN' }
            $fields = "$($Flags['--json'])" -split ','
            $limit  = if ($Flags['--limit']) { [int]$Flags['--limit'] } else { 30 }
            $prs = @($fake.PullRequests | Where-Object {
                ($state -eq 'ALL' -or $_.State -eq $state) -and (-not $Flags['--head'] -or $_.Head -eq $Flags['--head'])
            } | Select-Object -First $limit | ForEach-Object { ConvertTo-FakePrJson -PR $_ -Fields $fields })
            return (ConvertTo-Json -InputObject @($prs) -Depth 5 -Compress)
        }
        '^pr create$' {
            $head = $Flags['--head']
            if (-not $head -or -not $Flags['--title'] -or -not $Flags['--body-file']) { throw 'unknown' }
            $sha = @(Invoke-FakeRemoteGit -GitArgs @('for-each-ref', '--format=%(objectname)', "refs/heads/$head"))[0]
            if (-not $sha) { Stop-FakeGh 1 "pull request create failed: GraphQL: Head sha can't be blank (createPullRequest)" }
            if (@($fake.PullRequests | Where-Object { $_.Head -eq $head -and $_.State -eq 'OPEN' }).Count -gt 0) {
                Stop-FakeGh 1 "a pull request for branch `"$head`" already exists"
            }
            $pr = [pscustomobject]@{
                Number  = Get-FakeNextNumber
                Title   = $Flags['--title']
                Body    = Read-FakeBodyFile -Path $Flags['--body-file']
                Head    = $head
                HeadSha = $sha
                Base    = $fake.DefaultBranch
                State   = 'OPEN'
                IsDraft = [bool]$Flags['--draft']
                Reviews = [System.Collections.Generic.List[string]]::new()
            }
            $fake.PullRequests.Add($pr)
            $fake.Changes.Add("PR #$($pr.Number) opened$(if ($pr.IsDraft) { ' as draft' }) from $head")
            return "Creating pull request for $head into $($pr.Base)`n`n$(Get-FakePrUrl -Number $pr.Number)"
        }
        '^pr (edit|view|ready|review|merge|diff)$' {
            $ref = $Pos[2]
            $pr  = if ($ref -match '/pull/(\d+)$') { Get-FakePullRequest -Number ([int]$Matches[1]) } else { Get-FakePullRequest -Number ([int]$ref) }
            if (-not $pr) { Stop-FakeGh 1 "no pull requests found for $ref" }
            # A PR's head follows its branch on the remote.
            $sha = @(Invoke-FakeRemoteGit -GitArgs @('for-each-ref', '--format=%(objectname)', "refs/heads/$($pr.Head)"))[0]
            if ($sha -and $pr.State -eq 'OPEN') { $pr.HeadSha = $sha }
            switch ($Pos[1]) {
                'edit' {
                    if (-not $Flags['--body-file']) { throw 'unknown' }
                    $pr.Body = Read-FakeBodyFile -Path $Flags['--body-file']
                    $fake.Changes.Add("PR #$($pr.Number) description rewritten")
                    return Get-FakePrUrl -Number $pr.Number
                }
                'view' {
                    $json = ConvertTo-FakePrJson -PR $pr -Fields ("$($Flags['--json'])" -split ',')
                    if ($jq) { return Select-FakeJqField -Object $json -Jq $jq }
                    return ($json | ConvertTo-Json -Depth 5 -Compress)
                }
                'ready' {
                    $pr.IsDraft = [bool]$Flags['--undo']
                    $fake.Changes.Add("PR #$($pr.Number) $(if ($pr.IsDraft) { 'back to draft' } else { 'marked ready' })")
                    return ''
                }
                'review' {
                    if (-not $Flags['--comment'] -or -not $Flags['--body']) { throw 'unknown' }
                    $pr.Reviews.Add($Flags['--body'])
                    $fake.Changes.Add("PR #$($pr.Number) review comment")
                    return ''
                }
                'merge' {
                    if (-not $Flags['--squash']) { throw 'unknown' }
                    if ($pr.IsDraft) { Stop-FakeGh 1 "Pull request #$($pr.Number) is still a draft" }
                    Merge-FakePullRequest -PR $pr -DeleteBranch:([bool]$Flags['--delete-branch'])
                    $fake.Changes.Add("PR #$($pr.Number) squash-merged")
                    return ''
                }
                'diff' {
                    if ($Flags['--name-only']) { return Get-FakePrDiff -PR $pr -Shape names }
                    return Get-FakePrDiff -PR $pr -Shape patch
                }
            }
        }

        '^project list$' {
            $p = $fake.Project
            if ($jq) { return $p.Id }
            return (@{ projects = @(@{ number = $p.Number; id = $p.Id; title = $p.Title }); totalCount = 1 } | ConvertTo-Json -Depth 4 -Compress)
        }
        '^project view$' {
            if ($jq -ne '.title') { throw 'unknown' }
            return $fake.Project.Title
        }
        '^project field-list$' {
            return (@{ fields = @($fake.Project.Fields); totalCount = $fake.Project.Fields.Count } | ConvertTo-Json -Depth 6 -Compress)
        }
        '^project field-create$' {
            $name = $Flags['--name']
            $type = switch ($Flags['--data-type']) { 'NUMBER' { 'ProjectV2Field' } 'SINGLE_SELECT' { 'ProjectV2SingleSelectField' } default { throw 'unknown' } }
            $field = [pscustomobject]@{ id = "FIELD_$($name.ToLower())"; name = $name; type = $type }
            if ($Flags['--single-select-options']) {
                $field | Add-Member -NotePropertyName options -NotePropertyValue @("$($Flags['--single-select-options'])" -split ',' |
                    ForEach-Object { [pscustomobject]@{ id = "OPT_$($name.ToLower())_$_"; name = $_ } })
            }
            $fake.Project.Fields.Add($field)
            $fake.Changes.Add("board field $name created")
            return ''
        }
        '^project item-list$' {
            return (@{ items = @($fake.Board); totalCount = $fake.Board.Count } | ConvertTo-Json -Depth 6 -Compress)
        }
        '^project item-add$' {
            if ($Flags['--url'] -notmatch '/issues/(\d+)$') { throw 'unknown' }
            $n = [int]$Matches[1]
            $item = [pscustomobject]@{ id = "ITEM_$n"; content = [pscustomobject]@{ number = $n; repository = $fake.Repo }; status = $null; estimate = $null; priority = $null }
            $fake.Board.Add($item)
            $fake.Changes.Add("#${n}: added to the board")
            return ($item | Select-Object id | ConvertTo-Json -Compress)
        }
        '^project item-edit$' {
            $item  = @($fake.Board | Where-Object id -eq $Flags['--id']) | Select-Object -First 1
            $field = @($fake.Project.Fields | Where-Object id -eq $Flags['--field-id']) | Select-Object -First 1
            if (-not $item -or -not $field) { Stop-FakeGh 1 "gh: Could not resolve to a node (item $($Flags['--id']), field $($Flags['--field-id']))" }
            if ($null -ne $Flags['--number']) {
                $value = [int]$Flags['--number']
            } else {
                $option = @($field.options | Where-Object id -eq $Flags['--single-select-option-id']) | Select-Object -First 1
                if (-not $option) { Stop-FakeGh 1 "gh: '$($Flags['--single-select-option-id'])' is not an option of $($field.name)" }
                $value = $option.name
            }
            $key = switch ($field.name) { 'Status' { 'status' } 'Estimate' { 'estimate' } 'Priority' { 'priority' } default { throw 'unknown' } }
            $item.$key = $value
            $fake.Changes.Add("board item $($item.id) $($field.name) = $value")
            return ''
        }

        '^variable set$' {
            if ($null -eq $Flags['--body']) { throw 'unknown' }
            $fake.Variables[$Pos[2]] = "$($Flags['--body'])"
            return ''
        }
        '^label create$' {
            if (-not $Flags['--force']) { throw 'unknown' }
            $fake.RepoLabels[$Pos[2]] = @{ Color = $Flags['--color']; Description = $Flags['--description'] }
            return ''
        }

        '^workflow run$' {
            $fake.Dispatches.Add([pscustomobject]@{ Workflow = $Pos[2]; Fields = @($Flags['--field']) })
            $fake.Changes.Add("workflow $($Pos[2]) dispatched: $(@($Flags['--field']) -join ' ')")
            return ''
        }
    }
    throw 'unknown'
}
