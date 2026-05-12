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
$KanbanRepo    = gh repo view --json nameWithOwner --jq '.nameWithOwner'

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
    Ensure-Label 'agent:backlog'      '0075ca' 'Queued in Backlog for orchestrator pickup'
    Ensure-Label 'agent:implementing' 'e4e669' 'Agent is actively implementing (refine + develop)'
    Ensure-Label 'agent:review'       '969696' 'Agent self-review passed — awaiting human approval'
    Ensure-Label 'agent:merged'       '0e8a16' 'Merged and closed by orchestrator'
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

    $current = gh issue view $IssueNumber --repo $KanbanRepo --json labels `
        --jq '[.labels[].name | select(startswith("agent:"))] | first' 2>&1 |
        Out-String | ForEach-Object { $_.Trim().Trim('"') }

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
    $default = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
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

function Get-ProjectId {
    if (-not $script:_CachedProjectId) {
        if ($env:KANBAN_PROJECT_ID) {
            # Use the setup-time resolved node ID — avoids a gh project list call every run.
            $script:_CachedProjectId = $env:KANBAN_PROJECT_ID
        } else {
            $owner = Get-ResolvedOwner
            if (-not $owner) { return $null }
            $out = gh project list --owner $owner --format json --jq `
                ".projects[] | select(.number == $KanbanProjectNumber) | .id" 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Log "  ⚠️ gh project list failed: $($out.Trim())" -Color Yellow
                return $null
            }
            $script:_CachedProjectId = $out.Trim()
        }
    }
    return $script:_CachedProjectId
}

function Get-ProjectItemId {
    param([int]$IssueNumber)
    $owner = Get-ResolvedOwner
    if (-not $owner) { return $null }
    $jq = ".items[] | select(.content.number == $IssueNumber and .content.repository == `"$KanbanRepo`") | .id"
    $out = gh project item-list $KanbanProjectNumber --owner $owner --format json --limit 200 --jq $jq 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ gh project item-list failed: $($out.Trim())" -Color Yellow
        return $null
    }
    return $out.Trim()
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
    $ghArgs = @('project','item-edit','--id',$itemId,'--field-id',$KanbanStatusFieldId,'--project-id',$projectId,'--single-select-option-id',$OptionId)
    $out = gh @ghArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Lane move failed for issue #$IssueNumber → $LaneName : $($out.Trim())" -Color Yellow
    } else {
        Write-Log "  Issue #$IssueNumber → $LaneName" -Color DarkGray
    }
}

# ── Project field helpers ─────────────────────────────────────────────────────

function Get-ProjectFieldValues {
    param([int]$IssueNumber)
    $owner = Get-ResolvedOwner
    if (-not $owner) { return $null }
    $jq = ".items[] | select(.content.number == $IssueNumber and .content.repository == `"$KanbanRepo`") | {estimate: .estimate, priority: .priority}"
    $out = gh project item-list $KanbanProjectNumber --owner $owner --format json --limit 200 --jq $jq 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $out.Trim()) { return $null }
    return $out.Trim() | ConvertFrom-Json -ErrorAction SilentlyContinue
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
