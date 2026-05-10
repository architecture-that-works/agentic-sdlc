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
$KanbanProjectOwner     = if ($env:KANBAN_PROJECT_OWNER)   { $env:KANBAN_PROJECT_OWNER }        else { '@me' }
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
$KanbanRepo    = gh repo view --json nameWithOwner --jq '.nameWithOwner'

# ── Logging ───────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] $Message"
    Write-Host $entry -ForegroundColor $Color
    $null  = New-Item -ItemType Directory -Force -Path (Split-Path $KanbanLogFile)
    Add-Content -Path $KanbanLogFile -Value $entry -ErrorAction SilentlyContinue
}

# ── Label helpers ─────────────────────────────────────────────────────────────

function Ensure-Label {
    param([string]$Name, [string]$Color, [string]$Description)
    $exists = gh label list --repo $KanbanRepo --json name |
        ConvertFrom-Json | Where-Object { $_.name -eq $Name }
    if (-not $exists) {
        $out = gh label create $Name --color $Color --description $Description --repo $KanbanRepo 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to create label '$Name': $($out.Trim())" -Color Yellow
        } else {
            Write-Log "  Created label '$Name'" -Color DarkGray
        }
    }
}

function Ensure-AgentLabels {
    Ensure-Label 'agent:start'        '0075ca' 'Queued for agent pipeline pickup'
    Ensure-Label 'agent:implementing' 'e4e669' 'Agent is actively implementing (refine + develop)'
    Ensure-Label 'agent:review'       '969696' 'Agent self-review passed — awaiting human approval'
    Ensure-Label 'agent:merged'       '0e8a16' 'Merged and closed by agent pipeline'
    Ensure-Label 'agent:failed'       'd73a4a' 'Agent error — see issue comments'
}

function Set-IssueLabel {
    param([int]$Number, [string]$Add = '', [string]$Remove = '')
    if ($Remove -and $Add) {
        $out = gh issue edit $Number --repo $KanbanRepo --remove-label $Remove --add-label $Add 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to swap label '$Remove' → '$Add' on #${Number}: $($out.Trim())" -Color Yellow
        }
    } elseif ($Remove) {
        $out = gh issue edit $Number --repo $KanbanRepo --remove-label $Remove 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to remove label '$Remove' on #${Number}: $($out.Trim())" -Color Yellow
        }
    } elseif ($Add) {
        $out = gh issue edit $Number --repo $KanbanRepo --add-label $Add 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to add label '$Add' on #${Number}: $($out.Trim())" -Color Yellow
        }
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
    $default = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
    $current = git rev-parse --abbrev-ref HEAD

    if (git branch --list $branch) {
        if ($current -ne $branch) { git checkout --quiet $branch }
    } else {
        if ($current -ne $default) { git checkout --quiet $default }
        git pull --ff-only --quiet origin $default 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed on $default" }

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

    gh issue edit $Number --repo $KanbanRepo --add-assignee '@me' 2>&1 | Out-Null
    Set-IssueLabel -Number $Number -Remove 'agent:start' -Add 'agent:implementing'
    Write-Log "  Branch $branch — moved to Implementing." -Color DarkGray
    return $branch
}

# ── Project board helpers ─────────────────────────────────────────────────────

$script:_CachedProjectId = $null
function Get-ProjectId {
    if (-not $script:_CachedProjectId) {
        $script:_CachedProjectId = gh project list --owner $KanbanProjectOwner --format json --jq `
            ".projects[] | select(.number == $KanbanProjectNumber) | .id" 2>&1 | Out-String | ForEach-Object { $_.Trim() }
    }
    return $script:_CachedProjectId
}

function Get-ProjectItemId {
    param([int]$IssueNumber)
    $jq = ".items[] | select(.content.number == $IssueNumber and .content.repository == `"$KanbanRepo`") | .id"
    gh project item-list $KanbanProjectNumber --owner $KanbanProjectOwner --format json --limit 200 --jq $jq 2>&1
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
    gh project item-edit `
        --id $itemId `
        --field-id $KanbanStatusFieldId `
        --project-id $projectId `
        --single-select-option-id $OptionId 2>&1 | Out-Null
    Write-Log "  Issue #$IssueNumber → $LaneName" -Color DarkGray
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

    $msg = claude -p $prompt 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $msg.Trim()) {
        Write-Log "  Commit message via Claude." -Color DarkGray
        return $msg.Trim()
    }

    Write-Log "  Claude unavailable — using issue title fallback." -Color Yellow
    return $FallbackMessage
}
