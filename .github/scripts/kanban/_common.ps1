#Requires -Version 7.0
# .github/scripts/kanban/_common.ps1
# Shared constants and utilities dot-sourced by every kanban stage script.

# ── .env loader ───────────────────────────────────────────────────────────────

$_Root    = "$PSScriptRoot\..\..\.."
$_EnvPath = "$_Root\.env"

if (Test-Path $_EnvPath) {
    foreach ($line in (Get-Content $_EnvPath)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$' -and $line -notmatch '^\s*#') {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim('"').Trim("'"), 'Process')
        }
    }
}

# ── Project constants (from .env) ─────────────────────────────────────────────

$KanbanProjectNumber    = if ($env:KANBAN_PROJECT_NUMBER)  { [int]$env:KANBAN_PROJECT_NUMBER }  else { 0 }
# @me is not resolved by gh project in GHA context — use the repo owner from the GHA env var instead.
$KanbanProjectOwner     = if ($env:KANBAN_PROJECT_OWNER -and $env:KANBAN_PROJECT_OWNER -ne '@me') {
                              $env:KANBAN_PROJECT_OWNER
                          } elseif ($env:GITHUB_REPOSITORY_OWNER) {
                              $env:GITHUB_REPOSITORY_OWNER
                          } else {
                              '@me'
                          }
$KanbanStatusFieldId    = if ($env:KANBAN_STATUS_FIELD_ID) { $env:KANBAN_STATUS_FIELD_ID }      else { '' }
$KanbanOpt_Backlog      = if ($env:KANBAN_OPT_BACKLOG)     { $env:KANBAN_OPT_BACKLOG }          else { '' }
$KanbanOpt_Implementing = if ($env:KANBAN_OPT_IMPLEMENTING){ $env:KANBAN_OPT_IMPLEMENTING }     else { '' }
$KanbanOpt_Review       = if ($env:KANBAN_OPT_REVIEW)      { $env:KANBAN_OPT_REVIEW }           else { '' }
$KanbanOpt_Merged       = if ($env:KANBAN_OPT_MERGED)      { $env:KANBAN_OPT_MERGED }           else { '' }

$KanbanStopWords = @(
    'a','an','the','and','or','for','to','of','in','on','at','with','via','by','from',
    'fix','feat','add','update','remove'
)

$KanbanLogFile = "$_Root\logs\kanban.log"

# Resolve the repo slug WITHOUT a GraphQL call. `gh repo view` hits the GraphQL
# API, which throttles independently of REST (5000 pts/hr each). When GraphQL is
# exhausted this returned an empty string, silently breaking every downstream
# `gh ... --repo ''` call (a blank --repo swallows the next flag). Prefer the GHA
# env var, then the git remote; fall back to gh repo view only if both are absent.
$KanbanRepo = $env:GITHUB_REPOSITORY
if (-not $KanbanRepo) {
    $_originUrl = git remote get-url origin 2>$null
    if ($_originUrl -match '([^/:]+/[^/]+?)(\.git)?$') {
        $KanbanRepo = $Matches[1]
    } else {
        # Last resort — costs one GraphQL call.
        $KanbanRepo = gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
    }
}
if (-not $KanbanRepo) {
    throw "Cannot resolve the repository slug — set GITHUB_REPOSITORY, add a git 'origin' remote, or check 'gh auth status'."
}

# Resolve the default branch WITHOUT a GraphQL call. Like the repo slug, `gh repo
# view --json defaultBranchRef` hits the GraphQL API (5000 pts/hr, shared with
# the cloud pipeline). The ~6 stage-script call sites that need it all `git
# fetch/reset/checkout` against it afterwards, so resolving it once per process
# and caching it here as $KanbanDefaultBranch removes those calls from the hot
# path. Order, cheapest first:
#   1. GITHUB_DEFAULT_BRANCH — set by orchestrator.yml from the GHA event (free).
#   2. Local origin/HEAD symref — written by `git clone` (no network at all).
#   3. `git ls-remote --symref` — a git-protocol query, NOT the GraphQL API, so
#      it does not draw down the API budget (covers CI checkouts lacking 1 & 2).
#   4. `gh repo view` — last resort, costs one GraphQL call.
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
    # Last resort — costs one GraphQL call.
    $KanbanDefaultBranch = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>$null
    if ($KanbanDefaultBranch) { $KanbanDefaultBranch = $KanbanDefaultBranch.Trim() }
}
if (-not $KanbanDefaultBranch) {
    throw "Cannot resolve the default branch — set GITHUB_DEFAULT_BRANCH, configure an 'origin' remote, or check 'gh auth status'."
}

# ── Orchestrator configuration (config.ps1 → .env overrides) ─────────────────
. "$PSScriptRoot\config.ps1"

$KanbanModel_Sonnet = if ($env:KANBAN_MODEL_SONNET) { $env:KANBAN_MODEL_SONNET } else { $OrchestratorConfig.ModelSonnet }
$KanbanModel_Opus   = if ($env:KANBAN_MODEL_OPUS)   { $env:KANBAN_MODEL_OPUS   } else { $OrchestratorConfig.ModelOpus   }
$KanbanModel_Aux    = if ($env:KANBAN_MODEL_AUX)     { $env:KANBAN_MODEL_AUX    } else { $OrchestratorConfig.ModelHaiku  }

$KanbanMaxTurns_Review        = if ($env:KANBAN_MAX_TURNS_REVIEW)  { [int]$env:KANBAN_MAX_TURNS_REVIEW  } else { $OrchestratorConfig.MaxTurns_Review        }
$KanbanMaxTurns_Refine        = if ($env:KANBAN_MAX_TURNS_REFINE)  { [int]$env:KANBAN_MAX_TURNS_REFINE  } else { $OrchestratorConfig.MaxTurns_Refine         }
$KanbanMaxTurns_ContextUpdate = if ($env:KANBAN_MAX_TURNS_CONTEXT) { [int]$env:KANBAN_MAX_TURNS_CONTEXT } else { $OrchestratorConfig.MaxTurns_ContextUpdate  }
$KanbanMaxRetries             = if ($env:KANBAN_MAX_RETRIES)       { [int]$env:KANBAN_MAX_RETRIES       } else { $OrchestratorConfig.MaxRetries              }

$KanbanEstimateFieldId = if ($env:KANBAN_ESTIMATE_FIELD_ID) { $env:KANBAN_ESTIMATE_FIELD_ID } else { '' }
$KanbanPriorityFieldId = if ($env:KANBAN_PRIORITY_FIELD_ID) { $env:KANBAN_PRIORITY_FIELD_ID } else { '' }

# ── Logging ───────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] $Message"
    Write-Host $entry -ForegroundColor $Color
    $null  = New-Item -ItemType Directory -Force -Path (Split-Path $KanbanLogFile)
    Add-Content -Path $KanbanLogFile -Value $entry -ErrorAction SilentlyContinue
}

# ── Run context — single source of truth for this run's key parameters ───────
# Hydrated from environment variables: the ONLY transport stable across &-calls,
# dot-sourcing, nested pwsh and subprocesses. Entry points (orchestrator.yml,
# start.ps1) set KANBAN_ISSUE / KANBAN_MAX_RETRIES; everything downstream reads
# them via Get-KanbanContext rather than fragile script-scope variables, which a
# dot-sourced param() block can silently clobber (see ADR-013). Add a new per-run
# key in one place here → every script gets it. Exposed as a function so the
# Phase-2 Kanban module can export it unchanged.

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

function Get-KanbanContext {
    if ($script:_KanbanContext) { return $script:_KanbanContext }
    $script:_KanbanContext = [pscustomobject]@{
        IssueNumber   = Get-EnvInt 'KANBAN_ISSUE'       -Default 0
        MaxRetries    = Get-EnvInt 'KANBAN_MAX_RETRIES' -Default $KanbanMaxRetries
        Repo          = $KanbanRepo
        DefaultBranch = $KanbanDefaultBranch
        Runtime       = Get-RuntimeName
    }
    return $script:_KanbanContext
}

# ── Label helpers ─────────────────────────────────────────────────────────────
# Base labels (agent:*, HITL, etc.) are provisioned once by setup.ps1 § "Provision
# base labels". The pipeline assumes a configured project and never re-creates them
# per issue.

function Set-IssueLabel {
    param([int]$Number, [string]$Add = '', [string]$Remove = '')
    # Route label add/remove through REST (issues/{n}/labels), NOT `gh issue edit`
    # which is GraphQL. This runs on every state transition — the single most
    # frequent gh call in a drain — so moving it onto the near-idle REST budget is
    # the biggest GraphQL lever. A swap is two REST calls (DELETE then POST) rather
    # than one GraphQL edit; REST capacity is plentiful, so that trade is worth it.
    # All labels passed here are agent:* (colon, no spaces), which the REST path
    # accepts unencoded.
    if ($Remove) {
        # URL-encode the label name — it is a path segment. agent:* labels work
        # unencoded, but a future label with a space or slash would not; gh api
        # passes the path through without re-encoding (%3A stays %3A).
        $removeEnc = [uri]::EscapeDataString($Remove)
        $out = gh api --method DELETE "repos/$KanbanRepo/issues/$Number/labels/$removeEnc" 2>&1 | Out-String
        # 404 just means the label was already absent — not worth surfacing.
        if ($LASTEXITCODE -ne 0 -and $out -notmatch 'HTTP 404|Not Found') {
            Write-Log "  ⚠️ Failed to remove label '$Remove' on #${Number}: $($out.Trim())" -Color Yellow
        }
    }
    if ($Add) {
        $out = gh api --method POST "repos/$KanbanRepo/issues/$Number/labels" -f "labels[]=$Add" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to add label '$Add' on #${Number}: $($out.Trim())" -Color Yellow
        }
    }
}

# ── Issue-carried planning state (Cloud-Run-ready cross-runtime carrier) ────
# State lives inside the issue body as a fenced JSON block between two HTML
# comment markers. Human-readable Markdown sections coexist outside the block
# and are never touched by Get/Set-PlanningState. This is the single source of
# truth across runtimes — no local files, no regex over freeform comments.

$KanbanStateBeginMarker = '<!-- AGENT-STATE:BEGIN -->'
$KanbanStateEndMarker   = '<!-- AGENT-STATE:END -->'

# AGENT-BRIEF is the self-grill subagent's structured Agent Brief, rendered
# as a Markdown section inside the issue body (same carrier as AGENT-STATE,
# different markers so each can be regex-replaced independently). The brief
# is the human-readable face of the JSON state — humans review it, plan
# consumes it, and HITL child issues link to its section anchor.
$KanbanBriefBeginMarker = '<!-- AGENT-BRIEF:BEGIN -->'
$KanbanBriefEndMarker   = '<!-- AGENT-BRIEF:END -->'

# 4-lane FSM. Failure recovery (agent:failed) returns the issue to the
# 'backlog' lane — it is an in-Backlog label, not a separate lane.
$KanbanAllowedTransitions = @{
    'backlog'      = @('implementing')
    'implementing' = @('review', 'backlog')
    'review'       = @('merged', 'implementing', 'backlog')
    'merged'       = @()
}

# Maps an agent:* label to its FSM lane. agent:failed is the recovery
# variant of the backlog lane.
function Get-LaneFromLabel {
    param([string]$Label)
    switch ($Label) {
        'agent:backlog'      { 'backlog'      }
        'agent:implementing' { 'implementing' }
        'agent:review'       { 'review'       }
        'agent:merged'       { 'merged'       }
        'agent:failed'       { 'backlog'      }
        default              { ''             }
    }
}

function Get-PlanningState {
    param([int]$IssueNumber)

    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $body) { return $null }

    $pattern = [regex]::Escape($KanbanStateBeginMarker) +
               '\s*```json\s*\r?\n(?<json>.+?)\r?\n```\s*' +
               [regex]::Escape($KanbanStateEndMarker)
    $match = [regex]::Match($body, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        return [pscustomobject]@{
            issue_number       = $IssueNumber
            lane               = 'backlog'
            readiness          = [pscustomobject]@{
                refined     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
                architected = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
                planned     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
            }
            open_questions    = @()
            decided_questions = @()
            transitions       = @()
        }
    }

    try {
        return $match.Groups['json'].Value | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "  ⚠️ Could not parse AGENT-STATE block on #${IssueNumber}: $_" -Color Yellow
        return $null
    }
}

function Set-PlanningState {
    param([int]$IssueNumber, [pscustomobject]$State)

    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read issue body for #${IssueNumber} — skipping state write." -Color Yellow
        return
    }
    $body = $body.TrimEnd("`r", "`n")

    $json  = $State | ConvertTo-Json -Depth 10
    $block = "$KanbanStateBeginMarker`n``````json`n$json`n```````n$KanbanStateEndMarker"

    $pattern = [regex]::Escape($KanbanStateBeginMarker) +
               '.*?' +
               [regex]::Escape($KanbanStateEndMarker)
    $opts    = [System.Text.RegularExpressions.RegexOptions]::Singleline
    if ([regex]::IsMatch($body, $pattern, $opts)) {
        # Callback-based Replace sidesteps $1/$& substitution in the replacement string.
        $newBody = [regex]::Replace($body, $pattern, { param($m) $block }, $opts)
    } else {
        $newBody = "$body`n`n$block"
    }

    $tmp = New-TemporaryFile
    try {
        $newBody | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue edit $IssueNumber --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to write planning state on #${IssueNumber}: $($out.Trim())" -Color Yellow
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

function Test-StateTransition {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    if (-not $KanbanAllowedTransitions.ContainsKey($From)) {
        throw "Unknown source lane '$From'. Must be one of: $($KanbanAllowedTransitions.Keys -join ', ')"
    }
    if ($KanbanAllowedTransitions[$From] -notcontains $To) {
        throw "Illegal transition '$From' → '$To'. Allowed targets from '$From': $($KanbanAllowedTransitions[$From] -join ', ')"
    }
    return $true
}

function Test-Readiness {
    param([pscustomobject]$State)
    if ($null -eq $State) { return $false }
    if ($null -eq $State.readiness) { return $false }
    $refined     = [bool]$State.readiness.refined.done
    $architected = [bool]$State.readiness.architected.done
    $planned     = [bool]$State.readiness.planned.done
    $openCount   = if ($null -ne $State.open_questions) { @($State.open_questions).Count } else { 0 }
    return ($refined -and $architected -and $planned -and $openCount -eq 0)
}

# Detects the current runtime so the audit trail records *where* a transition
# was applied — laptop, GHA runner, or future Cloud Run service. The fixed
# label set keeps the schema stable across Phase 2/3 runtime additions.
function Get-RuntimeName {
    if ($env:GITHUB_ACTIONS -eq 'true') { return 'github-actions' }
    if ($env:CLOUD_RUN_SERVICE)         { return 'cloud-run' }
    return 'laptop'
}

# Marks a pre-backlog stage (refine|architect|plan) complete in the
# issue-carried state. Used by Invoke-Refine and the architect/plan stubs.
function Set-PlanningReadiness {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][ValidateSet('refined','architected','planned')][string]$Stage,
        [string]$StageLabel,
        [string]$PopulatedBy
    )
    if (-not $StageLabel) {
        $StageLabel = switch ($Stage) {
            'refined'     { 'refine' }
            'architected' { 'architect' }
            'planned'     { 'plan' }
        }
    }
    # `(phase-1 stub)` remains the default provenance for the architect/plan
    # stubs that have not yet been replaced. The self-grill subagent (issue #85)
    # passes -PopulatedBy 'self-grill-subagent' so audit trails distinguish the
    # real alignment phase from the stub copies.
    if (-not $PopulatedBy) {
        $PopulatedBy = "$StageLabel (phase-1 stub)"
    }

    $state = Get-PlanningState -IssueNumber $IssueNumber
    if ($null -eq $state) {
        Write-Log "  ⚠️ Could not load planning state for #${IssueNumber} — skipping readiness update." -Color Yellow
        return
    }

    $ts = (Get-Date).ToUniversalTime().ToString('o')

    if ($null -eq $state.readiness) {
        $state | Add-Member -NotePropertyName readiness -NotePropertyValue ([pscustomobject]@{
            refined     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
            architected = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
            planned     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
        }) -Force
    }
    $flag = [pscustomobject]@{
        done         = $true
        populated_by = $PopulatedBy
        timestamp    = $ts
    }
    $state.readiness | Add-Member -NotePropertyName $Stage -NotePropertyValue $flag -Force

    if ($null -eq $state.issue_number) {
        $state | Add-Member -NotePropertyName issue_number -NotePropertyValue $IssueNumber -Force
    }
    if ($null -eq $state.lane) {
        $state | Add-Member -NotePropertyName lane -NotePropertyValue 'backlog' -Force
    }
    if ($null -eq $state.open_questions) {
        $state | Add-Member -NotePropertyName open_questions -NotePropertyValue @() -Force
    }
    if ($null -eq $state.decided_questions) {
        $state | Add-Member -NotePropertyName decided_questions -NotePropertyValue @() -Force
    }
    if ($null -eq $state.transitions) {
        $state | Add-Member -NotePropertyName transitions -NotePropertyValue @() -Force
    }
    # Seed an initial transitions[] entry so the audit log is never empty after
    # the first stage completes — Phase 3 schedulers parse this on resume.
    if (@($state.transitions).Count -eq 0) {
        $state.transitions = @([pscustomobject]@{
            from      = $null
            to        = [string]$state.lane
            runtime   = (Get-RuntimeName)
            timestamp = $ts
        })
    }

    Set-PlanningState -IssueNumber $IssueNumber -State $state
}

# Merges the self-grill subagent's open_questions[] and decided_questions[]
# into the issue-carried planning state. Open questions are REPLACED on each
# refine run (the latest grill is the authoritative open set); decided
# questions are APPENDED so the audit history grows monotonically.
function Set-PlanningQuestions {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [pscustomobject[]]$Open    = @(),
        [pscustomobject[]]$Decided = @()
    )

    $state = Get-PlanningState -IssueNumber $IssueNumber
    if ($null -eq $state) {
        Write-Log "  ⚠️ Could not load planning state for #${IssueNumber} — skipping question merge." -Color Yellow
        return
    }

    if ($null -eq $state.open_questions)    { $state | Add-Member -NotePropertyName open_questions    -NotePropertyValue @() -Force }
    if ($null -eq $state.decided_questions) { $state | Add-Member -NotePropertyName decided_questions -NotePropertyValue @() -Force }

    $state.open_questions    = @($Open)
    $state.decided_questions = @(@($state.decided_questions) + @($Decided))

    Set-PlanningState -IssueNumber $IssueNumber -State $state
}

# ── Agent Brief writer (self-grill subagent output → issue body) ─────────────
# Renders the AgentBrief pydantic model into a Markdown section bounded by the
# AGENT-BRIEF markers. Frontmatter records `populated_by` so a future reader
# (human or agent) can tell at a glance whether the brief is the phase-1 copy
# or the self-grill subagent's output.

function Set-AgentBrief {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][pscustomobject]$Brief,
        [string]$PopulatedBy = 'self-grill-subagent'
    )

    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read issue body for #${IssueNumber} — skipping Agent Brief write." -Color Yellow
        return
    }
    $body = $body.TrimEnd("`r", "`n")

    $ts = (Get-Date).ToUniversalTime().ToString('o')

    $interfaces  = if ($Brief.interfaces)  { ($Brief.interfaces  | ForEach-Object { "- $_" }) -join "`n" } else { '- _(none stated)_' }
    $constraints = if ($Brief.constraints) { ($Brief.constraints | ForEach-Object { "- $_" }) -join "`n" } else { '- _(none stated)_' }
    $outOfScope  = if ($Brief.out_of_scope){ ($Brief.out_of_scope| ForEach-Object { "- $_" }) -join "`n" } else { '- _(none stated)_' }
    $tracer      = if ($Brief.tracer_bullet) { $Brief.tracer_bullet } else { '_(not yet identified)_' }

    $section = @"
$KanbanBriefBeginMarker
## Agent Brief

``````yaml
feature_name: $($Brief.feature_name)
populated_by: $PopulatedBy
timestamp:    $ts
``````

**Problem Statement**
$($Brief.problem_statement)

**Interfaces**
$interfaces

**Constraints**
$constraints

**Out of Scope**
$outOfScope

**Tracer Bullet**
$tracer
$KanbanBriefEndMarker
"@

    $pattern = [regex]::Escape($KanbanBriefBeginMarker) + '.*?' + [regex]::Escape($KanbanBriefEndMarker)
    $opts    = [System.Text.RegularExpressions.RegexOptions]::Singleline
    if ([regex]::IsMatch($body, $pattern, $opts)) {
        $newBody = [regex]::Replace($body, $pattern, { param($m) $section }, $opts)
    } else {
        $newBody = "$body`n`n$section"
    }

    $tmp = New-TemporaryFile
    try {
        $newBody | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue edit $IssueNumber --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to write Agent Brief on #${IssueNumber}: $($out.Trim())" -Color Yellow
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# Spawns one HITL child issue per unresolvable open_question. Each child links
# back to the parent and frames the question as "decision needed" so a human
# reviewer can act on it directly. Returns the created issue URLs for the
# caller to surface in a parent-issue summary comment.
function New-HitlChildIssue {
    param(
        [Parameter(Mandatory)][int]$ParentNumber,
        [Parameter(Mandatory)][string]$ParentTitle,
        [Parameter(Mandatory)][pscustomobject]$Question
    )

    $shortText = ($Question.text -replace '\s+', ' ').Trim()
    if ($shortText.Length -gt 70) { $shortText = $shortText.Substring(0, 67) + '...' }
    $title = "HITL decision needed (#${ParentNumber}): $shortText"

    $recommendation = if ($Question.decision) { $Question.decision } else { '_(no recommendation supplied)_' }
    $body = @"
**Decision needed** — surfaced by the self-grill subagent while refining #$ParentNumber ($ParentTitle).

**Question**
$($Question.text)

**Agent's recommendation**
$recommendation

**Why this needs a human**
The self-grill subagent could not resolve this branch from the codebase alone — it requires user judgement (taste, policy, deadline, or strategic trade-off). Once resolved, paste the decision into the parent issue's ``decided_questions[]`` and re-run refine.

**Parent**: #$ParentNumber
"@

    $tmp = New-TemporaryFile
    try {
        $body | Out-File $tmp.FullName -Encoding utf8
        $url = gh issue create `
            --repo $KanbanRepo `
            --title $title `
            --body-file $tmp.FullName `
            --label 'HITL' 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Could not create HITL child for #${ParentNumber}: $($url.Trim())" -Color Yellow
            return $null
        }
        return $url.Trim()
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── Atomic state transition (label + lane in one call) ───────────────────────

function Set-AgentState {
    param([int]$IssueNumber, [string]$Label)

    $laneId   = switch ($Label) {
        'agent:backlog'      { $KanbanOpt_Backlog      }
        'agent:implementing' { $KanbanOpt_Implementing }
        'agent:review'       { $KanbanOpt_Review       }
        'agent:merged'       { $KanbanOpt_Merged       }
        'agent:failed'       { $KanbanOpt_Backlog      }
        default              { ''                      }
    }
    $laneName = switch ($Label) {
        'agent:backlog'      { 'Backlog'      }
        'agent:implementing' { 'Implementing' }
        'agent:review'       { 'Review'       }
        'agent:merged'       { 'Merged'       }
        'agent:failed'       { 'Backlog'      }
        default              { ''             }
    }

    # Readiness gate: backlog entry requires refined + architected + planned and zero open questions.
    if ($Label -eq 'agent:backlog') {
        $state = Get-PlanningState -IssueNumber $IssueNumber
        if (-not (Test-Readiness -State $state)) {
            Write-Log "  ⚠️ Readiness gate FAILED for #${IssueNumber} — refusing entry to Backlog. Run refine/architect/plan first." -Color Yellow
            return
        }
    }

    # Read the current agent:* label via REST (issues/{n}/labels), not the GraphQL
    # `gh issue view`. Hot path — runs on every Set-AgentState call.
    $current = gh api "repos/$KanbanRepo/issues/$IssueNumber/labels" `
        --jq 'map(.name) | map(select(startswith("agent:"))) | first // empty' 2>&1 |
        Out-String | ForEach-Object { $_.Trim() }

    if ($current -and $current -ne 'null' -and $current -ne $Label) {
        Set-IssueLabel -Number $IssueNumber -Remove $current -Add $Label
    } elseif (-not $current -or $current -eq 'null') {
        Set-IssueLabel -Number $IssueNumber -Add $Label
    }

    if ($laneId -and $laneName) {
        Move-ToLane -IssueNumber $IssueNumber -OptionId $laneId -LaneName $laneName
    }
}

# ── Comment helper ────────────────────────────────────────────────────────────

function Add-Comment {
    param([int]$Number, [string]$Body)
    $tmp = New-TemporaryFile
    try {
        $Body | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue comment $Number --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to post comment on #${Number}: $($out.Trim())" -Color Yellow
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── Branch helpers ────────────────────────────────────────────────────────────

function Get-BranchName {
    param([int]$Number, [string]$Title)
    $words = ($Title -replace '[^a-zA-Z0-9\s]', '' -split '\s+') |
        Where-Object { $_ -and $KanbanStopWords -notcontains $_.ToLower() } |
        Select-Object -First 3 |
        ForEach-Object { $_.ToLower() }
    "feature/$Number-$($words -join '-')"
}

function Get-CurrentIssueNumber {
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($branch -match 'feature/(\d+)') { return [int]$Matches[1] }
    return 0
}

function New-FeatureBranch {
    param([int]$Number, [string]$Title)
    $branch  = Get-BranchName -Number $Number -Title $Title
    $default = $KanbanDefaultBranch
    $current = git rev-parse --abbrev-ref HEAD

    if (git branch --list $branch) {
        if ($current -ne $branch) { git checkout --quiet $branch }
    } else {
        if ($current -ne $default) {
            git checkout --quiet $default
            if ($LASTEXITCODE -ne 0) { throw "Could not switch to $default before creating feature branch" }
        }
        git fetch --quiet origin $default 2>$null
        git reset --hard --quiet "origin/$default" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not sync $default with origin" }

        gh issue develop $Number --name $branch --base $default --checkout 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  gh issue develop failed — falling back to git checkout -b" -Color Yellow
            git checkout --quiet -b $branch
        }
        Write-Log "  Created branch $branch (linked to issue #$Number)" -Color DarkGray
    }

    $dirty = git status --porcelain 2>$null
    if ($dirty) {
        git stash push --include-untracked -m "auto-stash before retry of issue #$Number" 2>&1 | Out-Null
        Write-Log "  Stashed leftover changes on $branch before retry." -Color DarkGray
    }

    $assignee = if ($env:GITHUB_ACTOR) { $env:GITHUB_ACTOR } else { '@me' }
    gh issue edit $Number --repo $KanbanRepo --add-assignee $assignee 2>&1 | Out-Null
    Write-Log "  Branch $branch — ready." -Color DarkGray
    return $branch
}

# ── Project board helpers ─────────────────────────────────────────────────────

$script:_CachedProjectId  = $null
$script:_CachedItems      = $null
$script:_ProjectIdFailed  = $false
$script:_ItemsFailed      = $false
$script:_ResolvedOwner    = $null
$script:_AuthDiagPrinted  = $false

# Trusts the configured owner. Setup resolves and validates it once; runtime
# probing was masking the real gh error from callers when something failed.
# If KANBAN_PROJECT_OWNER is wrong, downstream calls (gh project list/item-list/
# item-edit) surface their actual error message instead of a generic "cannot
# resolve owner" — that's the diagnostic signal we want.
function Get-ResolvedOwner {
    if ($script:_ResolvedOwner) { return $script:_ResolvedOwner }

    if (-not $script:_AuthDiagPrinted) {
        Write-Log "── gh auth diagnostic (once per run) ──" -Color DarkGray
        $authOut  = (gh auth status 2>&1 | Out-String).Trim()
        foreach ($l in ($authOut -split "`r?`n")) { Write-Log "  $l" -Color DarkGray }
        $viewer   = (gh api user --jq '.login' 2>&1 | Out-String).Trim()
        Write-Log "  gh api user → '[$viewer]'" -Color DarkGray
        Write-Log "  KANBAN_PROJECT_OWNER = '[$KanbanProjectOwner]' (length=$($KanbanProjectOwner.Length))" -Color DarkGray
        $script:_AuthDiagPrinted = $true
    }

    if ($KanbanProjectOwner) {
        $script:_ResolvedOwner = $KanbanProjectOwner
        return $KanbanProjectOwner
    }
    Write-Log "  ⚠️ KANBAN_PROJECT_OWNER not configured — run: task setup" -Color Yellow
    return $null
}

# Retries transient GraphQL/5xx failures from `gh project ...` calls.
# GitHub's Projects v2 GraphQL endpoint occasionally returns "Something went wrong
# while executing your query" with an incident reference — these clear within seconds.
function Invoke-GhProjectRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Block,
        [string]$Description = 'gh project',
        [int]$MaxAttempts = 3
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $out = & $Block
        if ($LASTEXITCODE -eq 0) { return $out }
        $text = ($out | Out-String)
        $isTransient = $text -match 'GraphQL: Something went wrong|HTTP 5\d\d|Bad gateway|service unavailable|timeout|i/o timeout'
        if (-not $isTransient -or $attempt -eq $MaxAttempts) { return $out }
        $delayMs = [int](500 * [Math]::Pow(2, $attempt - 1))
        Write-Log "  ⚠️ $Description transient failure (attempt $attempt/$MaxAttempts) — retrying in ${delayMs}ms" -Color DarkYellow
        Start-Sleep -Milliseconds $delayMs
    }
}

function Get-ProjectId {
    if ($script:_CachedProjectId) { return $script:_CachedProjectId }
    if ($script:_ProjectIdFailed) { return $null }

    if ($env:KANBAN_PROJECT_ID) {
        # Use the setup-time resolved node ID — avoids a gh project list call every run.
        $script:_CachedProjectId = $env:KANBAN_PROJECT_ID
        return $script:_CachedProjectId
    }
    $owner = Get-ResolvedOwner
    if (-not $owner) { $script:_ProjectIdFailed = $true; return $null }
    $out = Invoke-GhProjectRetry -Description 'gh project list' -Block {
        gh project list --owner $owner --format json --jq `
            ".projects[] | select(.number == $KanbanProjectNumber) | .id" 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ gh project list failed: $($out.Trim())" -Color Yellow
        $script:_ProjectIdFailed = $true
        return $null
    }
    $script:_CachedProjectId = $out.Trim()
    return $script:_CachedProjectId
}

# Fetches all project items once per process and caches the result. A GitHub
# Project board's item set is effectively static during a single orchestrator
# pass; one fetch serves every downstream Get-ProjectItemId / Get-ProjectStatus
# / Get-ProjectFieldValues lookup, dropping ~5 GraphQL queries per pass to 1.
#
# $script:_CachedItems = $null means "not yet fetched"; an empty array means
# "fetched but board is empty" (do not re-fetch).
#
# On failure we set $script:_ItemsFailed and return $null on every subsequent
# call this pass — without that flag, each Move-ToLane / Get-ProjectFieldValues
# call retriggers the full 3-attempt retry sequence, turning one outage into
# ~12 GraphQL hits per issue.
function Get-AllProjectItems {
    if ($null -ne $script:_CachedItems) { return $script:_CachedItems }
    if ($script:_ItemsFailed) { return $null }

    $owner = Get-ResolvedOwner
    if (-not $owner) { $script:_ItemsFailed = $true; return $null }
    $out = Invoke-GhProjectRetry -Description 'gh project item-list' -Block {
        gh project item-list $KanbanProjectNumber --owner $owner --format json --limit 200 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ gh project item-list failed: $($out.Trim())" -Color Yellow
        $script:_ItemsFailed = $true
        return $null
    }
    $parsed = $null
    try { $parsed = $out | ConvertFrom-Json } catch {
        Write-Log "  ⚠️ gh project item-list returned malformed JSON — skipping project-board ops this pass." -Color Yellow
        $script:_ItemsFailed = $true
        return $null
    }
    $script:_CachedItems = @($parsed.items)
    return $script:_CachedItems
}

function Get-ProjectStatus {
    param([int]$IssueNumber)
    $items = Get-AllProjectItems
    if ($null -eq $items) { return $null }
    $match = $items | Where-Object {
        $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
    } | Select-Object -First 1
    if (-not $match) { return $null }
    return $match.status
}

function Get-ProjectItemId {
    param([int]$IssueNumber)
    $items = Get-AllProjectItems
    if ($null -eq $items) { return $null }
    $match = $items | Where-Object {
        $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
    } | Select-Object -First 1
    if (-not $match) { return $null }
    return $match.id
}

function Move-ToLane {
    param([int]$IssueNumber, [string]$OptionId, [string]$LaneName)
    if (-not $OptionId) {
        Write-Log "  Lane option ID not configured for '$LaneName' — skipping. Run: task setup" -Color Yellow
        return
    }
    $itemId    = Get-ProjectItemId -IssueNumber $IssueNumber
    $projectId = Get-ProjectId
    if (-not $itemId -or -not $projectId) {
        Write-Log "  Could not resolve project item for issue #$IssueNumber — skipping lane move." -Color Yellow
        return
    }

    # Skip the GraphQL write when the lane is already correct — saves one
    # item-edit per Set-AgentState call in steady state, and is essential
    # during transient GraphQL outages to avoid pointless mutations.
    $current = Get-ProjectStatus -IssueNumber $IssueNumber
    if ($current -eq $LaneName) {
        Write-Log "  Issue #$IssueNumber already in lane $LaneName — skipping." -Color DarkGray
        return
    }

    $ghArgs = @('project','item-edit','--id',$itemId,'--field-id',$KanbanStatusFieldId,'--project-id',$projectId,'--single-select-option-id',$OptionId)
    $out = Invoke-GhProjectRetry -Description 'gh project item-edit' -Block {
        gh @ghArgs 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Lane move failed for issue #$IssueNumber → $LaneName : $($out.Trim())" -Color Yellow
    } else {
        Write-Log "  Issue #$IssueNumber → $LaneName" -Color DarkGray
        # Reflect the new lane in the cache so a subsequent same-pass call
        # to Move-ToLane (e.g. via Set-AgentState) sees the update and skips.
        if ($null -ne $script:_CachedItems) {
            $cached = $script:_CachedItems | Where-Object {
                $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
            } | Select-Object -First 1
            if ($cached) { $cached.status = $LaneName }
        }
    }
}

# ── Project field helpers ─────────────────────────────────────────────────────

function Get-ProjectFieldValues {
    param([int]$IssueNumber)
    $items = Get-AllProjectItems
    if ($null -eq $items) { return $null }
    $match = $items | Where-Object {
        $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
    } | Select-Object -First 1
    if (-not $match) { return $null }
    return [pscustomobject]@{ estimate = $match.estimate; priority = $match.priority }
}

function Get-PriorityOptionId {
    param([string]$Priority)
    $vars = [System.Environment]::GetEnvironmentVariables('Process')
    foreach ($key in @($vars.Keys | Where-Object { $_ -match '^KANBAN_PRIORITY_OPT_' })) {
        if (($key -replace '^KANBAN_PRIORITY_OPT_', '') -ieq $Priority) { return $vars[$key] }
    }
    return $null
}

function Set-ProjectEstimate {
    param([int]$IssueNumber, [int]$Estimate)
    if (-not $KanbanEstimateFieldId) {
        Write-Log "  ⚠️ KANBAN_ESTIMATE_FIELD_ID not configured — run: task setup" -Color Yellow
        return
    }
    $itemId    = Get-ProjectItemId -IssueNumber $IssueNumber
    $projectId = Get-ProjectId
    if (-not $itemId -or -not $projectId) { return }
    $out = gh project item-edit --id $itemId --field-id $KanbanEstimateFieldId --project-id $projectId --number $Estimate 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not set Estimate field: $($out.Trim())" -Color Yellow
    } else {
        Write-Log "  Project field Estimate = $Estimate" -Color DarkGray
    }
}

function Set-ProjectPriority {
    param([int]$IssueNumber, [string]$Priority)
    if (-not $KanbanPriorityFieldId) {
        Write-Log "  ⚠️ KANBAN_PRIORITY_FIELD_ID not configured — run: task setup" -Color Yellow
        return
    }
    $optionId = Get-PriorityOptionId -Priority $Priority
    if (-not $optionId) {
        Write-Log "  ⚠️ No option ID for priority '$Priority' — check project options and run: task setup" -Color Yellow
        return
    }
    $itemId    = Get-ProjectItemId -IssueNumber $IssueNumber
    $projectId = Get-ProjectId
    if (-not $itemId -or -not $projectId) { return }
    $out = gh project item-edit --id $itemId --field-id $KanbanPriorityFieldId --project-id $projectId --single-select-option-id $optionId 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not set Priority field: $($out.Trim())" -Color Yellow
    } else {
        Write-Log "  Project field Priority = $Priority" -Color DarkGray
    }
}

# ── Streaming Claude output helper ───────────────────────────────────────────

function Format-ToolLine {
    param([string]$Name, $ToolInput)
    switch ($Name) {
        'Read'  { "📖 Read:  $($ToolInput.file_path)" }
        'Write' { "✏️  Write: $($ToolInput.file_path)" }
        'Edit'  { "✏️  Edit:  $($ToolInput.file_path)" }
        'Glob'  { "🔍 Glob:  $($ToolInput.pattern)" }
        'Grep'  { "🔍 Grep:  $($ToolInput.pattern)" }
        'Bash'  { "⚡ Bash:  $([string]$ToolInput.command -replace '\r?\n.*','' -replace '\s+',' ')" }
        default { "🔧 $Name" }
    }
}

# ── Model + turn-budget selectors ─────────────────────────────────────────────

function Get-IssueEstimate {
    param([int]$IssueNumber)
    $fields = Get-ProjectFieldValues -IssueNumber $IssueNumber
    if ($fields -and $null -ne $fields.estimate -and "$($fields.estimate)" -ne '') {
        try { return [int]$fields.estimate } catch {}
    }
    return 0
}

function Get-PhaseModel {
    param([int]$Estimate, [string]$Phase)
    switch ($Phase) {
        'implement' { if ($Estimate -gt $OrchestratorConfig.OpusImplementThreshold) { return $KanbanModel_Opus } else { return $KanbanModel_Sonnet } }
        'review'    { if ($Estimate -gt $OrchestratorConfig.OpusReviewThreshold)    { return $KanbanModel_Opus } else { return $KanbanModel_Sonnet } }
        default     { return $KanbanModel_Aux }
    }
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

# Invoke Claude with streaming JSON output, printing tool use and text to the terminal.
# Returns the full text response as a string. Throws if Claude exits non-zero.
# Callers must pass -Model (use Get-PhaseModel) and -MaxTurns explicitly.
function Invoke-ClaudeStreaming {
    param(
        [string]$Prompt,
        [string]$AllowedTools = 'Read,Glob,Grep',
        [string]$Label = 'Claude',
        [string]$Model = $KanbanModel_Sonnet,
        [int]$MaxTurns = $KanbanMaxTurns_Review
    )

    Write-Log "  ▶ $Label — model=$Model turns=$MaxTurns" -Color DarkGray

    $allText    = [System.Text.StringBuilder]::new()
    $toolCalls  = [System.Collections.Generic.List[string]]::new()

    $Prompt | claude --model $Model --allowedTools $AllowedTools --max-turns $MaxTurns --output-format stream-json --verbose 2>&1 |
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
                        # Append a trailing newline so consecutive text blocks
                        # (separated by tool_use in the stream) are not joined
                        # flush. Without this, downstream regex like
                        # "(?im)^APPROVED" miss verdicts that started a block
                        # because they end up mid-line in $allText.
                        $null = $allText.Append($block.text)
                        $null = $allText.Append("`n")
                    }
                    'tool_use' {
                        $inputReady = ($block.input.PSObject.Properties | Measure-Object).Count -gt 0
                        if ($inputReady) {
                            $line = Format-ToolLine -Name $block.name -ToolInput $block.input
                            Write-Host "`n  $line" -ForegroundColor DarkCyan
                            $toolCalls.Add($line)
                        }
                    }
                }
            }

            if ($ev.type -eq 'result') { Write-Host '' }
        } catch {
            if ($raw.Trim()) { Write-Host $raw -ForegroundColor DarkGray }
        }
    }

    if ($LASTEXITCODE -ne 0) { throw "$Label exited with code $LASTEXITCODE." }

    $summary = if ($allText.Length -gt 0) { ($allText.ToString() -split "`n")[0].Trim() } else { '(no text output)' }
    Write-Log "  ✓ $Label — $($toolCalls.Count) tool call(s). First line: $summary" -Color DarkGray

    return $allText.ToString()
}

# ── Orchestrator lock (prevents concurrent terminal instances) ────────────────

$OrchestratorLockFile = "$_Root\logs\orchestrator.lock"

function Acquire-OrchestratorLock {
    param([int]$IssueNumber)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $OrchestratorLockFile) -ErrorAction SilentlyContinue

    if (Test-Path $OrchestratorLockFile) {
        try {
            $d    = Get-Content $OrchestratorLockFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $proc = Get-Process -Id $d.pid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Log "  Lock held by PID $($d.pid) (issue #$($d.issue), started $($d.started))" -Color Yellow
                return $false
            }
            Write-Log "  Removing stale lock (PID $($d.pid) no longer running)" -Color Yellow
        } catch {
            Write-Log "  Removing corrupt lock file" -Color Yellow
        }
        Remove-Item $OrchestratorLockFile -Force -ErrorAction SilentlyContinue
    }

    @{ pid = $PID; issue = $IssueNumber; started = (Get-Date -Format 'o') } |
        ConvertTo-Json -Compress | Set-Content $OrchestratorLockFile -Encoding utf8 -NoNewline
    return $true
}

function Release-OrchestratorLock {
    Remove-Item $OrchestratorLockFile -Force -ErrorAction SilentlyContinue
}

# ── Persistent review-cycle counter (file-based — no labels) ─────────────────

function Get-IssueReviewCount {
    param([int]$IssueNumber)
    $path = "$_Root\logs\cycle-$IssueNumber.txt"
    if (Test-Path $path) {
        try { return [int](Get-Content $path -Raw -ErrorAction Stop).Trim() } catch {}
    }
    return 0
}

function Set-IssueReviewCount {
    param([int]$IssueNumber, [int]$Count)
    $null = New-Item -ItemType Directory -Force -Path "$_Root\logs" -ErrorAction SilentlyContinue
    "$Count" | Set-Content "$_Root\logs\cycle-$IssueNumber.txt" -Encoding utf8 -NoNewline
}

function Clear-IssueReviewCount {
    param([int]$IssueNumber)
    Remove-Item "$_Root\logs\cycle-$IssueNumber.txt" -Force -ErrorAction SilentlyContinue
}

# ── Issue template reader (from ISSUES.md header) ─────────────────────────────

function Get-IssueTemplate {
    $path = "$_Root\ISSUES.md"
    if (-not (Test-Path $path)) { return $null }

    $content  = Get-Content $path -Raw
    $sentinel = $content.IndexOf('<!-- ISSUES -->')
    $header   = if ($sentinel -ge 0) { $content.Substring(0, $sentinel) } else { $content }

    if ($header -match '(?s)```\s*\r?\n(ISSUE:.*?END_ISSUE)\s*\r?\n```') {
        $block  = $Matches[1]
        $fields = ($block -split '\r?\n' | Select-Object -Skip 1 |
            Where-Object { $_ -notmatch '^END_ISSUE' }) -join "`n"
        return $fields.Trim()
    }
    return $null
}

# ── Commit message — Claude primary, fallback to issue title ──────────────────
# Future: add Gemini as secondary between Claude and fallback.

function Get-CommitMessage {
    param([string]$Diff, [string]$FallbackMessage)

    $prompt = @"
Generate a conventional commit message for the following staged diff.

Rules:
- Format: <type>(<scope>): <description>
- Types: feat, fix, refactor, test, docs, chore, perf, ci, build, revert
- Scope: the module, file, or area changed (omit if not obvious)
- Description: imperative mood, <= 72 chars, no trailing period
- Add a blank line + body only if the change is complex or non-obvious
- Return ONLY the commit message — no explanation, no markdown fences

DIFF:
$Diff
"@

    $msg = $prompt | claude --model $KanbanModel_Aux 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $msg.Trim()) {
        Write-Log "  Commit message via Claude." -Color DarkGray
        return $msg.Trim()
    }

    Write-Log "  Claude unavailable — using issue title fallback." -Color Yellow
    return $FallbackMessage
}
