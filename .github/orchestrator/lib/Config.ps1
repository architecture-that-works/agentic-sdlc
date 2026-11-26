#Requires -Version 7.0
<#
    Config.ps1 — settings, run context, and model selection for the orchestrator
    module.

    Defines $OrchestratorConfig — the settings table, the one place every
    orchestrator setting has its value (the engine, its models per tier and each
    task's tier, read through Get-TaskModel; turn budgets; run limits; waits).
    Nothing overrides a key: to change a setting, edit it here. Reads the board's
    settings from the environment when they are used (Get-BoardSettings), resolves
    the repo slug and default branch WITHOUT GraphQL, and exposes
    Get-OrchestratorContext — the per-run object (issue, repo, branch, runtime)
    hydrated from the KANBAN_* env transport (ADR-013). Loaded first by
    Orchestrator.psm1.

    Reads no file: a Command a person runs loads the repository's .env into the
    process environment before it imports the module (.github/tasks/Settings.ps1),
    a workflow passes repository variables, and a test states the settings it needs.
#>

# ── Paths ─────────────────────────────────────────────────────────────────────
# $_Root is the repo root (this file is .github/orchestrator/lib/, three levels deep).
$_Root    = "$PSScriptRoot\..\..\.."

$KanbanLogFile = "$_Root\logs\kanban.log"

# ── Settings table ────────────────────────────────────────────────────────────
# Every orchestrator setting, with its one value. Code reads $OrchestratorConfig.<Key>
# where it uses the setting; no environment variable, module copy or parameter
# replaces a key.
$OrchestratorConfig = @{
    # ── Models ────────────────────────────────────────────────────────────────
    # Every model call is a named task. TaskTiers gives each task a tier, a class
    # of work; each Engines row gives that engine's model for each tier. The tiers
    # are the same for every engine:
    #
    #   routine   mechanical, one-shot text in a fixed format
    #   standard  bounded work against a clear specification
    #   complex   judgement on open or wide work: questions, design, trade-offs, a verdict
    #
    # Changing a model is one line in Engines; moving a task to another tier is one
    # line in TaskTiers. Get-TaskModel reads both and stops the run, naming the key
    # to fill, when a value is missing — it never falls back to a default model.

    # The engine this orchestrator runs on. The only thing that chooses it: the module
    # loads the adapter in engines/ of the same name (claude → engines/Claude.ps1) and
    # stops at import when there is none.
    Engine = 'claude'

    # One row per engine: its model for each tier.
    # Model IDs — Source: Anthropic models overview, checked 2026-11-20.
    # A further engine is added as one complete definition once it fits the whole flow:
    # its row here and its adapter file in engines/, which supplies Invoke-EngineTask.
    Engines = @{
        claude = @{
            routine  = 'claude-haiku-5-5'
            standard = 'claude-sonnet-5-5'
            complex  = 'claude-opus-5-5'
        }
    }

    # Task → tier. A task is one named model call.
    TaskTiers = @{
        Refine         = 'complex'    # refine, its questioning, judging the answers to its questions
        Plan           = 'complex'    # the plan, and splitting an epic into child issues
        ImplementLarge = 'complex'    # implement, estimate >= ImplementLargeFrom
        ImplementSmall = 'standard'   # implement, a smaller estimate or none
        Review         = 'complex'    # review
        CommitMessage  = 'routine'    # the commit message
        EngineCheck    = 'routine'    # the check before a run that the engine answers
    }

    # Story points from which implement is the ImplementLarge task (Get-ImplementTask):
    # 1–2 or no estimate → ImplementSmall  |  3+ → ImplementLarge
    ImplementLargeFrom = 3

    # Plan-step routing (story points): SP >= threshold → the issue is an epic and
    # the Plan step decomposes it into child issues (Lean PRD synthesis, Plan.ps1)
    # instead of writing a single implementation-plan section. 13 = "large multi-
    # area", 21 = "epic requiring human collaboration" on the refine Fibonacci scale.
    DecomposeThreshold = 13

    # Turn budgets — implement (scales with SP); key 0 = unknown-estimate fallback.
    MaxTurns_Implement = @{
        0  = 60; 1  = 60; 2  = 70; 3  = 80
        5  = 100; 8  = 130; 13 = 160; 21 = 200
    }

    # Turn budgets — other phases (flat)
    MaxTurns_Refine        = 40   # refine's questioning: reading CONTEXT, AGENTS, the skill, ADRs and sources takes turns
    MaxTurns_Review        = 30   # read-only: inspect code + signal history, no writes; formula base
    MaxTurns_Review_Cap    = 90   # ceiling for the per-PR scaled formula (base + changed files)

    # Governance files: a PR touching any of these is held for the owner's merge
    # (human:approval), never auto-merged — the agent's own review cannot be the last
    # word on the rules it is bound by. Matched with -like against the PR's paths.
    GovernancePaths = @(
        'AGENTS.md', 'CONTEXT.md', 'SECURITY.md', '.out-of-scope.md', '.github/CODEOWNERS',
        '.github/workflows/*', '.github/orchestrator/*', '.github/checks/*', '.github/tasks/*',
        'docs/adr/*', '.agents/skills/*'
    )

    # Required checks: the checks.yml job names branch protection requires
    # (.github/tasks/protect.ps1) and ship waits for on the commit it pushed — every
    # one must pass (or be skipped while nothing else failed) on that exact commit
    # before ship merges or calls the PR green (#373). The one place these names are
    # written; tests/repository/test_checks_workflow.py ties each to a job of checks.yml. Every
    # .github/checks/check-*.ps1 runs inside the `checks` job, so a check has no
    # name of its own here.
    RequiredChecks = @('lint', 'typecheck', 'test', 'audit', 'checks', 'eval')

    # Writable paths: what the agent may change *and have merged automatically*. This
    # is a classifier, not a bar on writing (#285) — a change outside it is committed
    # like any other, and ship then holds the PR at human:approval with the files and
    # their diffstat named, for the owner to merge or reject. Nothing outside this
    # list reaches the default branch without a human.
    #
    # So a PR auto-merges only when every changed path is inside WritablePaths AND
    # outside GovernancePaths — in practice src/, tests/, docs/ (bar docs/adr/),
    # pyproject.toml and uv.lock.
    #
    # An empty list is fail-safe, not fatal: with no allowlist every path is a
    # proposal and every PR is held. The one absolute bar is the secrets denylist in
    # Invoke-CommitAndPR (.env, *.key, *.pem, *secret*), which is never staged.
    # Matched with -like against changed relative paths (same operator as GovernancePaths).
    WritablePaths = @(
        'src/*', 'tests/*', 'docs/*', '.agents/skills/*',
        'CONTEXT.md', '.out-of-scope.md', 'SECURITY.md',
        'pyproject.toml', 'uv.lock'
    )

    # Trusted authors: the pipeline acts only on issues opened by these GitHub author
    # associations (#312). It runs with the owner's tokens, so a public repo's stranger
    # must never reach refine or implement — not through the workflow trigger, the
    # backfill, nor an owner comment on their issue. afk.yml's jobs check the same list.
    TrustedAuthors = @('OWNER', 'MEMBER', 'COLLABORATOR')

    # Orchestrator behaviour
    MaxRetries = 3    # failed attempts per round (implement, review, CI, refine) before agent:failed

    # Attempts for an engine call that fails on a non-zero exit (Invoke-EngineTask,
    # engines/): transient API errors — overloaded 529, rate limit, network blips —
    # exit the CLI non-zero after its own internal retries. 20s × attempt between them.
    EngineTaskMaxAttempts = 3

    # Reconciliation (the hourly warden, lib/Reconcile.ps1). An agent-held label
    # claims work in progress; when nothing has touched the issue for this long,
    # no runner is doing that work and the state is stale. Must stay comfortably
    # above the longest silent stretch of a live run — a complex-tier implement can go a
    # while between its `·` progress comments — or the warden re-enters live work.
    StuckAfterMinutes = 90

    # How many times one issue may be re-entered at the same label before the
    # warden stops and hands it to the owner on agent:failed. Prevents a
    # permanently broken issue from being re-dispatched every hour forever.
    MaxReconcile = 2

    # Usage-limit pause (lib/Util.ps1): the longest a run waits after the model's
    # usage allowance is spent, whatever reset time the CLI reports.
    MaxPauseHours = 5

    # Ship's wait for RequiredChecks on the commit it pushed (stages/Ship.ps1): how
    # long it waits in total, and how often it asks.
    RequiredChecksTimeoutSeconds = 900
    RequiredChecksPollSeconds    = 10
}

# ── The board's settings (env, read when used) ────────────────────────────────
# The GitHub Project the issues move on: written by `task setup` to .env and to the
# repository variables afk.yml passes. Read from the process environment each time
# they are used, never frozen when this file loads — so a setting made after the
# import counts, and a test that states a board gets it without re-importing.
# The lane option ids are read the same way (Get-LaneOptionId, lib/GitHub.ps1).
function Get-BoardSettings {
    # @me is not resolved by gh project in GHA context — use the repo owner from the GHA env var instead.
    $owner = if ($env:KANBAN_PROJECT_OWNER -and $env:KANBAN_PROJECT_OWNER -ne '@me') { $env:KANBAN_PROJECT_OWNER }
             elseif ($env:GITHUB_REPOSITORY_OWNER) { $env:GITHUB_REPOSITORY_OWNER }
             else { '@me' }
    return [pscustomobject]@{
        ProjectNumber   = Get-EnvInt 'KANBAN_PROJECT_NUMBER' -Default 0
        ProjectOwner    = $owner
        StatusFieldId   = "$env:KANBAN_STATUS_FIELD_ID"
        EstimateFieldId = "$env:KANBAN_ESTIMATE_FIELD_ID"
        PriorityFieldId = "$env:KANBAN_PRIORITY_FIELD_ID"
    }
}

$KanbanStopWords = @(
    'a','an','the','and','or','for','to','of','in','on','at','with','via','by','from',
    'fix','feat','add','update','remove'
)

# ── The pipeline state machine — one row per label ────────────────────────────
# The single table behind every state question. An issue carries exactly one of
# these labels (ADR-015, #225), and this is the only place that says what each one
# means:
#
#   LaneName         the board column the label implies. Set-AgentState reads it —
#                    it used to carry two parallel switch statements over the same
#                    label set, which is two copies of one mapping. The column's
#                    board option id is NOT here: those come from repository
#                    variables and must be read when the transition runs, not frozen
#                    when this file loads (Get-LaneOptionId in lib/GitHub.ps1).
#   Holder           who owes the next move while the label is set:
#                      agent — the pipeline owes progress, so a state that has gone
#                              quiet is stale and the warden may re-enter it
#                      human — a person owes the move; reconciliation never touches it
#                      none  — terminal; nothing is owed
#   Recovery         what re-entry means for an agent-held state that has stalled
#                    (Invoke-Reconciliation):
#                      implement — the label is already the go signal; dispatch the
#                                  implement job, which nothing is currently running
#                      restart   — re-enter from the carrier's stage (Restart-Issue)
#                      resume    — the time-gated usage-limit path (Resume-PausedIssues)
#                      none      — never re-entered
#   AllowedFrom      the set of pipeline labels (or $null for "no pipeline label")
#                    that may transition INTO this state. Set-AgentState throws when
#                    the current label is absent from this list — strict enforcement
#                    so callers never reach an invalid transition silently. Setting
#                    the label the issue already carries is no transition and is never
#                    listed. Only transitions on the designed path are listed, and
#                    each one is exercised by a journey or table
#                    (tests/journeys/StateMachine.Tests.ps1).
#   OnComment        routing action for the central comment router
#                    (Invoke-Orchestration -From comment):
#                      refine  — judge the owner's reply against open questions
#                      retry   — restart the failed stage (Restart-Issue)
#                      revise  — revision cycle on the existing branch + PR
#                      ack     — post "· comment noted", no further action
#                      ''      — skip (terminal or in-flight states)
#   StartsRun        the run that may start on an issue carrying the label — the one
#                    rule the conductor asks at its door (Test-RunMayStart), before it
#                    asks the engine, takes the lock or sets a label:
#                      refine    — a refine run starts
#                      implement — an implement run starts
#                      restart   — a refine run does not start; it re-enters the issue
#                                  through Restart-Issue, once (Restart-FailedIssue)
#                      ''        — no run starts; a run that finds it stops, changing nothing
#                    An issue with no pipeline label starts $UnlabelledStartsRun.
#
# Adding a state means adding one row. Nothing else in the module may switch on a
# label; a second mapping is how #252, #266 and #275 each shipped the same bug.
$PipelineStates = [ordered]@{
    'agent:refining' = @{
        LaneName    = 'Backlog'
        Holder      = 'agent'
        Recovery    = 'restart'
        AllowedFrom = @($null, 'human:decision', 'human:approval')
        OnComment   = 'refine'
        StartsRun   = 'refine'
    }
    'agent:backlog' = @{
        LaneName    = 'Backlog'
        Holder      = 'agent'
        Recovery    = 'implement'
        AllowedFrom = @($null, 'human:approval', 'human:decision', 'agent:failed', 'agent:implementing', 'agent:reviewing', 'agent:paused', 'agent:refining')
        OnComment   = 'ack'
        StartsRun   = 'implement'
    }
    'agent:implementing' = @{
        LaneName    = 'Implementing'
        Holder      = 'agent'
        Recovery    = 'restart'
        AllowedFrom = @('agent:backlog', 'agent:reviewing', 'human:approval')
        OnComment   = 'ack'
        StartsRun   = 'implement'
    }
    'agent:reviewing' = @{
        LaneName    = 'Review'
        Holder      = 'agent'
        Recovery    = 'restart'
        AllowedFrom = @('agent:implementing')
        OnComment   = 'ack'
        StartsRun   = ''
    }
    'agent:paused' = @{
        LaneName    = 'Backlog'
        Holder      = 'agent'
        Recovery    = 'resume'
        AllowedFrom = @($null, 'agent:backlog', 'agent:implementing', 'agent:reviewing', 'human:decision', 'human:approval', 'agent:failed', 'agent:refining')
        OnComment   = 'ack'
        StartsRun   = ''
    }
    'agent:shipped' = @{
        LaneName    = 'Shipped'
        Holder      = 'none'
        Recovery    = 'none'
        AllowedFrom = @('agent:implementing', 'agent:reviewing', 'human:approval', 'agent:failed')
        OnComment   = ''
        StartsRun   = ''
    }
    'agent:failed' = @{
        LaneName    = 'Backlog'
        Holder      = 'human'
        Recovery    = 'none'
        AllowedFrom = @($null, 'human:decision', 'agent:backlog', 'agent:implementing', 'agent:reviewing', 'human:approval', 'agent:refining')
        OnComment   = 'retry'
        StartsRun   = 'restart'
    }
    'human:decision' = @{
        LaneName    = 'Backlog'
        Holder      = 'human'
        Recovery    = 'none'
        AllowedFrom = @($null, 'agent:failed', 'agent:refining')
        OnComment   = 'refine'
        StartsRun   = 'refine'
    }
    'human:approval' = @{
        LaneName    = 'Review'
        Holder      = 'human'
        Recovery    = 'none'
        AllowedFrom = @('agent:implementing', 'agent:reviewing')
        OnComment   = 'revise'
        StartsRun   = 'refine'
    }
}

# The run an issue with no pipeline label starts: a new issue is refined first.
$UnlabelledStartsRun = 'refine'

# May this run start on the issue? Asked by the conductor at its door. Reads the
# issue's pipeline label over REST and answers from StartsRun in $PipelineStates
# only; changes nothing and calls no engine.
#   Allowed  the run may start
#   Label    the pipeline label read ($null for none)
#   ReEntry  a refine run that finds this label re-enters the issue instead
#            (StartsRun 'restart') — Restart-FailedIssue
function Test-RunMayStart {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][ValidateSet('refine', 'implement')][string]$Run)
    # An issue carries one pipeline label (ADR-015); the first in table order decides
    # a transient double label.
    $labels = @(Get-IssueLabel -IssueNumber $IssueNumber)
    $label  = @($PipelineStates.Keys | Where-Object { $labels -contains $_ }) | Select-Object -First 1
    $starts = if ($label) { $PipelineStates[$label].StartsRun } else { $UnlabelledStartsRun }
    return [pscustomobject]@{
        Allowed = $starts -eq $Run
        Label   = $label
        ReEntry = $Run -eq 'refine' -and $starts -eq 'restart'
    }
}

# Resolve the repo slug WITHOUT a GraphQL call. `gh repo view` hits the GraphQL
# API, which throttles independently of REST (5000 pts/hr each). When GraphQL is
# exhausted this returned an empty string, silently breaking every downstream
# `gh ... --repo ''` call. Prefer the GHA env var, then the git remote; fall back
# to gh repo view only if both are absent (ADR-012).
$KanbanRepo = $env:GITHUB_REPOSITORY
if (-not $KanbanRepo) {
    $_originUrl = git remote get-url origin 2>$null
    if ($_originUrl -match '([^/:]+/[^/]+?)(\.git)?$') {
        $KanbanRepo = $Matches[1]
    } else {
        $KanbanRepo = gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null   # last resort — one GraphQL call
    }
}
if (-not $KanbanRepo) {
    throw "Cannot resolve the repository slug — set GITHUB_REPOSITORY, add a git 'origin' remote, or check 'gh auth status'."
}

# Resolve the default branch WITHOUT a GraphQL call (ADR-012), cheapest first:
#   1. GITHUB_DEFAULT_BRANCH env (set by afk.yml from the GHA event)
#   2. local origin/HEAD symref (written by `git clone`)
#   3. `git ls-remote --symref` (git protocol, NOT the GraphQL API)
#   4. `gh repo view` (last resort, one GraphQL call)
$KanbanDefaultBranch = $env:GITHUB_DEFAULT_BRANCH
if (-not $KanbanDefaultBranch) {
    $_symref = git symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $_symref) {
        $KanbanDefaultBranch = ($_symref -replace '^origin/', '').Trim()
    }
}
if (-not $KanbanDefaultBranch) {
    $_lsRemote = git ls-remote --symref origin HEAD 2>$null |
        Select-String 'ref:\s+refs/heads/(\S+)\s+HEAD'
    if ($_lsRemote) {
        $KanbanDefaultBranch = $_lsRemote.Matches[0].Groups[1].Value
    }
}
if (-not $KanbanDefaultBranch) {
    $KanbanDefaultBranch = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null
    if ($KanbanDefaultBranch) { $KanbanDefaultBranch = $KanbanDefaultBranch.Trim() }
}
if (-not $KanbanDefaultBranch) {
    throw "Cannot resolve the default branch — set GITHUB_DEFAULT_BRANCH, configure an 'origin' remote, or check 'gh auth status'."
}

# ── Run context — single source of truth for this run's key parameters ───────
# Hydrated from environment variables: the ONLY transport stable across &-calls,
# dot-sourcing, nested pwsh and subprocesses. Entry points (afk.yml,
# hitl.ps1) set KANBAN_ISSUE; everything downstream reads
# it via Get-OrchestratorContext rather than fragile script-scope variables, which a
# dot-sourced param() block can silently clobber (ADR-013). Add a new per-run key
# in one place here → every script gets it. Built on every call, never cached:
# the environment it is read from is the one source.

# Read an integer from the environment, falling back cleanly (with a logged
# warning) when the variable is missing or not a valid integer.
function Get-EnvInt {
    param([Parameter(Mandatory)][string]$Name, [int]$Default = 0)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($raw.Trim(), [ref]$parsed)) { return $parsed }
    Write-Log "  ⚠️ Env $Name='$raw' is not an integer — falling back to $Default." -Color Yellow
    return $Default
}

function Get-OrchestratorContext {
    return [pscustomobject]@{
        IssueNumber    = Get-EnvInt 'KANBAN_ISSUE' -Default 0
        Repo           = $KanbanRepo
        DefaultBranch  = $KanbanDefaultBranch
        ProjectNumber  = (Get-BoardSettings).ProjectNumber
        Runtime        = Get-RuntimeName
        Engine         = $OrchestratorConfig.Engine
        RequiredChecks = @($OrchestratorConfig.RequiredChecks)
    }
}

# ── Model + turn-budget selectors ────────────────────────────────────────────

function Get-IssueEstimate {
    param([int]$IssueNumber)
    $fields = Get-ProjectFieldValues -IssueNumber $IssueNumber
    if ($fields -and $null -ne $fields.estimate -and "$($fields.estimate)" -ne '') {
        try { return [int]$fields.estimate } catch {}
    }
    return 0
}

# Which model does this task run on? The one answer to that question: the task's
# tier from TaskTiers, then that tier's model in the engine's Engines row. A
# missing value stops the run with the key to fill — never a fallback model, which
# once ran a mistyped phase on the smallest model without a word.
function Get-TaskModel {
    param(
        [Parameter(Mandatory)][string]$Task,
        [string]$Engine = $OrchestratorConfig.Engine
    )
    $cfg = 'lib/Config.ps1 $OrchestratorConfig'
    $row = $OrchestratorConfig.Engines[$Engine]
    if (-not $row) {
        throw "Get-TaskModel: task '$Task' runs on engine '$Engine', which has no row — fill Engines.$Engine in $cfg."
    }
    $tier = $OrchestratorConfig.TaskTiers[$Task]
    if (-not $tier) {
        throw "Get-TaskModel: task '$Task' has no tier — fill TaskTiers.$Task in $cfg."
    }
    $model = $row[$tier]
    if (-not $model) {
        throw "Get-TaskModel: task '$Task' is tier '$tier', and engine '$Engine' has no model for it — fill Engines.$Engine.$tier in $cfg."
    }
    return $model
}

# Implement is two tasks, split by the estimate: ImplementLarge from
# ImplementLargeFrom story points up, ImplementSmall below it and with no estimate (0).
function Get-ImplementTask {
    param([int]$Estimate)
    if ($Estimate -ge $OrchestratorConfig.ImplementLargeFrom) { return 'ImplementLarge' }
    return 'ImplementSmall'
}

function Get-ImplementMaxTurns {
    param([int]$Estimate)
    $table  = $OrchestratorConfig.MaxTurns_Implement
    if ($table.ContainsKey($Estimate)) { return $table[$Estimate] }
    $sorted = $table.Keys | Sort-Object
    $next   = $sorted | Where-Object { $_ -ge $Estimate } | Select-Object -First 1
    if ($next) { return $table[$next] }
    return $table[0]
}
