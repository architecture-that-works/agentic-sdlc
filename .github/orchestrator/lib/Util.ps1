#Requires -Version 7.0
<#
    Util.ps1 — cross-cutting local utilities for the Kanban module.

    Logging, runtime detection, the orchestrator lock, and the ISSUES.md template
    reader. These touch only the local
    filesystem / process environment (no gh, no Claude). Loaded after Config.ps1
    (it reads $KanbanLogFile / $_Root from there).
#>

# ── Logging ───────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] $Message"
    Write-Host $entry -ForegroundColor $Color
    $null  = New-Item -ItemType Directory -Force -Path (Split-Path $KanbanLogFile)
    Add-Content -Path $KanbanLogFile -Value $entry -ErrorAction SilentlyContinue
}

# ── Runtime detection ─────────────────────────────────────────────────────────
# Records *where* a transition was applied — laptop, GHA runner, or future Cloud
# Run service — for the issue-carried audit trail. Fixed label set keeps the
# schema stable across Phase 2/3 runtime additions.
function Get-RuntimeName {
    if ($env:GITHUB_ACTIONS -eq 'true') { return 'github-actions' }
    if ($env:CLOUD_RUN_SERVICE)         { return 'cloud-run' }
    return 'laptop'
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

# ── Procedure-derivation from agent stream events ────────────────────────────
# Pure function: inspects tool_use blocks in the parsed stream and returns four
# booleans that describe what the agent did (read which files, ran pytest).
# Used by Invoke-Develop to build the Procedure: line in the Implementation comment.
function Get-ProcedureRecord {
    param([array]$StreamEvents)
    $agentsMdRead  = $false
    $contextMdRead = $false
    $skillRead     = $false
    $pytestRun     = $false

    foreach ($ev in @($StreamEvents | Where-Object { $_ })) {
        $blocks = if ($ev.message.content) { $ev.message.content }
                  elseif ($ev.content)      { $ev.content }
                  else                      { @() }
        foreach ($block in @($blocks | Where-Object { $_ })) {
            if ($block.type -ne 'tool_use') { continue }
            if ($block.name -eq 'Read') {
                $fp = "$($block.input.file_path)"
                if ($fp -match '(^|[/\\])AGENTS\.md$')                      { $agentsMdRead  = $true }
                if ($fp -match '(^|[/\\])CONTEXT\.md$')                     { $contextMdRead = $true }
                if ($fp -match '(^|[/\\])\.agents[/\\]skills[/\\]')          { $skillRead     = $true }
            }
            if ($block.name -eq 'Bash' -and "$($block.input.command)" -match 'pytest') {
                $pytestRun = $true
            }
        }
    }

    return [pscustomobject]@{
        agentsMdRead  = $agentsMdRead
        contextMdRead = $contextMdRead
        skillRead     = $skillRead
        pytestRun     = $pytestRun
    }
}

# ── Edits the engine refused (#346) ──────────────────────────────────────────
# Pure function: the repo-relative paths of the file edits the engine refused,
# unique and in order. Read only from what the engine reports — the
# `permission_denials[]` of its last `result` stream event — never from the agent's
# prose. A denied tool that edits no file (a Bash command) is not an edit refusal.
# Claude Code refuses writes to its protected paths (.devcontainer/, .claude/, ...)
# in an unattended run whatever the allow rules say, so a retry cannot help.
function Get-RefusedFiles {
    param([array]$StreamEvents, [string]$RepoRoot = '')
    $result = @($StreamEvents | Where-Object { $_ -and $_.type -eq 'result' }) | Select-Object -Last 1
    if (-not $result -or -not $result.PSObject.Properties['permission_denials']) { return @() }

    $root  = "$RepoRoot".Replace('\', '/').TrimEnd('/')
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($d in @($result.permission_denials | Where-Object { $_ })) {
        if ("$($d.tool_name)" -notin @('Write', 'Edit', 'NotebookEdit')) { continue }
        $fp = "$($d.tool_input.file_path)"
        if (-not $fp) { $fp = "$($d.tool_input.notebook_path)" }
        if (-not $fp) { continue }
        $fp = $fp.Replace('\', '/')
        if ($root -and [System.IO.Path]::IsPathRooted($fp)) {
            $rel = [System.IO.Path]::GetRelativePath($root, $fp).Replace('\', '/')
            if (-not $rel.StartsWith('..')) { $fp = $rel }
        }
        $fp = $fp -replace '^\./', ''
        if (-not $paths.Contains($fp)) { $paths.Add($fp) }
    }
    return $paths.ToArray()
}

# ── LLM-optimized error formatter (issue #119) ────────────────────────────────
# Wraps raw error output (pytest failures, ruff output, tracebacks) into a
# structured Markdown block so the verification loop can self-correct, via
# src/utils/m_error_formatter.py. Falls back to a raw fenced block when the
# formatter is unavailable — raw output is never dropped.
function Format-ErrorBlock {
    param([string]$Raw)
    if (-not $Raw.Trim()) { return '' }
    try {
        Push-Location $_Root
        try {
            $formatted = $Raw | uv run python -m src.utils.m_error_formatter 2>$null
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -eq 0 -and $formatted -and $formatted.Trim()) {
            return $formatted.Trim()
        }
    } catch {}
    # Fallback: preserve raw output in a fenced block (never drop it).
    return "``````text`n$($Raw.Trim())`n``````"
}

# ── Engine readiness and the usage limit ─────────────────────────────────────
# When the engine refuses because the subscription's usage allowance is spent, the
# work is paused (agent:paused) and resumed by afk.yml's hourly resume job — never
# counted as a failed attempt. Only a fresh probe decides that the limit is the
# cause: error text from a stage is not trusted, since test output or code under
# test can mention rate limits too.

# Spend and session limits are how Claude words a spent subscription allowance (#229).
# "hit your … limit" allows a few words between ("hit your org's monthly spend limit",
# "hit your daily limit") but stays inside one sentence, so an unrelated "hit your" and
# a later "limit" in a long error log never pair up.
$KanbanUsageLimitPattern = '(?i)usage limit|limit reached|rate_limit_error|hit your\b[^.·\n]{0,40}?\blimit|spend limit|session limit'
$KanbanMaxPauseHours     = 5

# The UTC time to resume after a usage-limit message, or $null when $Text is not
# one. Reads the reset time the engine reports (an epoch after '|', or "resets
# 3pm" / "resets at 15:30", taken as UTC — the runner's clock), falls back to one
# hour, and never waits more than $KanbanMaxPauseHours.
function Get-UsageLimitResume {
    param([string]$Text, [datetime]$Now = (Get-Date).ToUniversalTime())
    if ("$Text" -notmatch $KanbanUsageLimitPattern) { return $null }
    $until = $null
    if ($Text -match '\|(\d{10})\b') {
        $until = [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).UtcDateTime
    } elseif ($Text -match '(?i)resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?') {
        $h  = [int]$Matches[1]
        $m  = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        $ap = $Matches[3]
        if ($ap -ieq 'pm' -and $h -lt 12) { $h += 12 }
        if ($ap -ieq 'am' -and $h -eq 12) { $h = 0 }
        if ($h -le 23 -and $m -le 59) {
            $until = [datetime]::SpecifyKind($Now.Date, 'Utc').AddHours($h).AddMinutes($m)
            if ($until -le $Now) { $until = $until.AddDays(1) }
        }
    }
    if (-not $until) { $until = $Now.AddHours(1) }
    $cap = $Now.AddHours($KanbanMaxPauseHours)
    if ($until -gt $cap) { $until = $cap }
    return $until
}

# One tiny call to the configured engine: the reply text and whether it failed.
# A CLI that cannot run at all reads as a failure, never a throw.
function Invoke-EnginePing {
    $ctx = Get-OrchestratorContext
    try {
        $out = if ($ctx.Engine -eq 'gemini') {
            "ping" | agy --model $KanbanModel_GeminiFlash 2>&1 | Out-String
        } else {
            "ping" | claude --model $KanbanModel_Aux 2>&1 | Out-String
        }
        return [pscustomobject]@{ Output = $out; Failed = ($LASTEXITCODE -ne 0) }
    } catch {
        return [pscustomobject]@{ Output = "$_"; Failed = $true }
    }
}

# $null when the engine answers or fails for another reason — a CLI that cannot
# run is not a usage limit; the UTC resume time when it reports a limit.
function Test-EngineUsageLimit {
    return Get-UsageLimitResume -Text (Invoke-EnginePing).Output
}

# Fails fast before any stage runs. Throws 'USAGE-LIMIT|<iso resume time>' when the
# allowance is spent, so the conductor pauses instead of failing.
function Assert-EngineReady {
    $engine = (Get-OrchestratorContext).Engine
    Write-Log "  Verifying $engine authentication..." -Color DarkGray
    $ping   = Invoke-EnginePing
    $resume = Get-UsageLimitResume -Text $ping.Output
    if ($resume) { throw "USAGE-LIMIT|$($resume.ToString('o'))" }
    if ($ping.Failed) { throw "$engine authentication or execution failed:`n$($ping.Output)" }
}
