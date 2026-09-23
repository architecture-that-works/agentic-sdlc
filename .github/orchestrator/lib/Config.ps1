#Requires -Version 7.0
<#
    Config.ps1 — settings, run context, and model selection for the Kanban module.

    Single source for "what are the settings for this run": loads .env, defines the
    orchestrator defaults, resolves the $Kanban* constants (project IDs, lanes,
    models, turn budgets) with env overrides, resolves the repo slug and default
    branch WITHOUT GraphQL, and exposes Get-OrchestratorContext — the per-run object
    (issue, retries, repo, branch, runtime) hydrated from the KANBAN_* env
    transport (ADR-013). Loaded first by Kanban.psm1.
#>

# ── Paths + .env loader ───────────────────────────────────────────────────────
# $_Root is the repo root (kanban/ is three levels deep under the repo).
$_Root    = "$PSScriptRoot\..\..\.."
$_EnvPath = "$_Root\.env"

if (Test-Path $_EnvPath) {
    foreach ($line in (Get-Content $_EnvPath)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$' -and $line -notmatch '^\s*#') {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim('"').Trim("'"), 'Process')
        }
    }
}

$KanbanLogFile = "$_Root\logs\kanban.log"

# ── Orchestrator defaults ─────────────────────────────────────────────────────
# All values are overridable per-machine via .env (KANBAN_* env vars take
# precedence). Estimate (Fibonacci SP) drives model + turn-budget selection:
#   Implement : SP > OpusImplementThreshold → Opus; else Sonnet
#   Review    : SP > OpusReviewThreshold    → Opus; else Sonnet
#   Aux tasks : always Haiku (commit messages, context updates)
$OrchestratorConfig = @{
    # Models
    ModelSonnet = 'claude-sonnet-4-6'          # implement (low-SP), review (low-SP), refine, context-update
    ModelOpus   = 'claude-opus-4-7'            # implement (high-SP), review (high-SP)
    ModelHaiku  = 'claude-haiku-4-5-20251001'  # commit messages, auxiliary one-shot calls

    ModelGeminiPro   = 'gemini-3.1-pro'
    ModelGeminiFlash = 'gemini-3.5-flash'

    # Model tier thresholds (story points): SP > threshold → Opus for that phase
    OpusImplementThreshold = 5   # 1–5 → Sonnet implement  |  8–21 → Opus implement
    OpusReviewThreshold    = 3   # 1–3 → Sonnet review     |  5–21 → Opus review

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
    MaxTurns_Refine        = 15   # structured output + label assignment — lightweight
    MaxTurns_Review        = 30   # read-only: inspect code + signal history, no writes
    MaxTurns_ContextUpdate = 15   # diff analysis + generate a unified patch

    # Governance files: a PR touching any of these is held for the owner's merge
    # (human:approval), never auto-merged — the agent's own review cannot be the last
    # word on the rules it is bound by. Matched with -like against the PR's paths.
    GovernancePaths = @(
        'AGENTS.md', 'CONTEXT.md', 'SECURITY.md', '.out-of-scope.md', '.github/CODEOWNERS',
        '.github/workflows/*', '.github/orchestrator/*', '.github/checks/*', '.github/tasks/*',
        'docs/adr/*', '.agents/skills/*'
    )

    # Orchestrator behaviour
    MaxRetries = 3    # failed attempts per round (implement, review, CI, refine) before agent:failed
}

# ── Project constants (env, with defaults) ────────────────────────────────────
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
#   1. GITHUB_DEFAULT_BRANCH env (set by orchestrator.yml from the GHA event)
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

# ── Models + turn budgets (env overrides over $OrchestratorConfig) ────────────
$KanbanEngine = if ($env:KANBAN_ENGINE) { $env:KANBAN_ENGINE } else { 'claude' }

$KanbanModel_Sonnet = if ($env:KANBAN_MODEL_SONNET) { $env:KANBAN_MODEL_SONNET } else { $OrchestratorConfig.ModelSonnet }
$KanbanModel_Opus   = if ($env:KANBAN_MODEL_OPUS)   { $env:KANBAN_MODEL_OPUS   } else { $OrchestratorConfig.ModelOpus   }
$KanbanModel_Aux    = if ($env:KANBAN_MODEL_AUX)     { $env:KANBAN_MODEL_AUX    } else { $OrchestratorConfig.ModelHaiku  }

$KanbanModel_GeminiPro   = if ($env:KANBAN_MODEL_GEMINI_PRO)   { $env:KANBAN_MODEL_GEMINI_PRO   } else { $OrchestratorConfig.ModelGeminiPro   }
$KanbanModel_GeminiFlash = if ($env:KANBAN_MODEL_GEMINI_FLASH) { $env:KANBAN_MODEL_GEMINI_FLASH } else { $OrchestratorConfig.ModelGeminiFlash }

$KanbanMaxTurns_Review        = if ($env:KANBAN_MAX_TURNS_REVIEW)  { [int]$env:KANBAN_MAX_TURNS_REVIEW  } else { $OrchestratorConfig.MaxTurns_Review        }
$KanbanMaxTurns_Refine        = if ($env:KANBAN_MAX_TURNS_REFINE)  { [int]$env:KANBAN_MAX_TURNS_REFINE  } else { $OrchestratorConfig.MaxTurns_Refine         }
$KanbanMaxTurns_ContextUpdate = if ($env:KANBAN_MAX_TURNS_CONTEXT) { [int]$env:KANBAN_MAX_TURNS_CONTEXT } else { $OrchestratorConfig.MaxTurns_ContextUpdate  }
$KanbanMaxRetries             = if ($env:KANBAN_MAX_RETRIES)       { [int]$env:KANBAN_MAX_RETRIES       } else { $OrchestratorConfig.MaxRetries              }

$KanbanEstimateFieldId = if ($env:KANBAN_ESTIMATE_FIELD_ID) { $env:KANBAN_ESTIMATE_FIELD_ID } else { '' }
$KanbanPriorityFieldId = if ($env:KANBAN_PRIORITY_FIELD_ID) { $env:KANBAN_PRIORITY_FIELD_ID } else { '' }

# ── Run context — single source of truth for this run's key parameters ───────
# Hydrated from environment variables: the ONLY transport stable across &-calls,
# dot-sourcing, nested pwsh and subprocesses. Entry points (orchestrator.yml,
# hitl.ps1) set KANBAN_ISSUE / KANBAN_MAX_RETRIES; everything downstream reads
# them via Get-OrchestratorContext rather than fragile script-scope variables, which a
# dot-sourced param() block can silently clobber (ADR-013). Add a new per-run key
# in one place here → every script gets it.

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
    if ($script:_KanbanContext) { return $script:_KanbanContext }
    $script:_KanbanContext = [pscustomobject]@{
        IssueNumber   = Get-EnvInt 'KANBAN_ISSUE'       -Default 0
        MaxRetries    = Get-EnvInt 'KANBAN_MAX_RETRIES' -Default $KanbanMaxRetries
        Repo          = $KanbanRepo
        DefaultBranch = $KanbanDefaultBranch
        ProjectNumber = $KanbanProjectNumber
        Runtime       = Get-RuntimeName
        Engine        = $KanbanEngine
    }
    return $script:_KanbanContext
}

# ── Model + turn-budget selectors (estimate-driven) ──────────────────────────

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
    if ($KanbanEngine -eq 'gemini') {
        switch ($Phase) {
            'implement' { if ($Estimate -gt $OrchestratorConfig.OpusImplementThreshold) { return $KanbanModel_GeminiPro } else { return $KanbanModel_GeminiFlash } }
            'review'    { if ($Estimate -gt $OrchestratorConfig.OpusReviewThreshold)    { return $KanbanModel_GeminiPro } else { return $KanbanModel_GeminiFlash } }
            default     { return $KanbanModel_GeminiFlash }
        }
    } else {
        switch ($Phase) {
            'implement' { if ($Estimate -gt $OrchestratorConfig.OpusImplementThreshold) { return $KanbanModel_Opus } else { return $KanbanModel_Sonnet } }
            'review'    { if ($Estimate -gt $OrchestratorConfig.OpusReviewThreshold)    { return $KanbanModel_Opus } else { return $KanbanModel_Sonnet } }
            default     { return $KanbanModel_Aux }
        }
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
