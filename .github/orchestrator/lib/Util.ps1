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

# ── Engine Readiness Validation ───────────────────────────────────────────────

# ── Usage limit: a pause, not a failure ──────────────────────────────────────
# When the engine refuses because the subscription's usage allowance is spent, the
# work is paused (agent:paused) and resumed by afk.yml's hourly resume job — never
# counted as a failed attempt. Only a fresh probe decides that the limit is the
# cause: error text from a stage is not trusted, since test output or code under
# test can mention rate limits too.

$KanbanUsageLimitPattern = '(?i)usage limit|limit reached|rate_limit_error|hit your limit'
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

# One tiny engine call. $null when the engine answers (or fails for another
# reason); the UTC resume time when it reports a usage limit.
function Test-EngineUsageLimit {
    $ctx = Get-OrchestratorContext
    $out = if ($ctx.Engine -eq 'gemini') {
        "ping" | agy --model $KanbanModel_GeminiFlash 2>&1 | Out-String
    } else {
        "ping" | claude --model $KanbanModel_Aux 2>&1 | Out-String
    }
    return Get-UsageLimitResume -Text $out
}

# Throws 'USAGE-LIMIT|<iso resume time>' when the allowance is spent, so the
# conductor can pause instead of failing; any other engine failure throws as before.
function Assert-EngineReady {
    $ctx = Get-OrchestratorContext
    if ($ctx.Engine -eq 'gemini') {
        Write-Log "  Verifying Gemini (agy) authentication..." -Color DarkGray
        $out = "ping" | agy --model gemini-3.5-flash 2>&1 | Out-String
        $failed = $LASTEXITCODE -ne 0
        $resume = Get-UsageLimitResume -Text $out
        if ($resume) { throw "USAGE-LIMIT|$($resume.ToString('o'))" }
        if ($failed) { throw "Gemini (agy) authentication or execution failed:`n$out" }
    } else {
        Write-Log "  Verifying Claude authentication..." -Color DarkGray
        $out = "ping" | claude --model claude-haiku-4-5-20251001 2>&1 | Out-String
        $failed = $LASTEXITCODE -ne 0
        $resume = Get-UsageLimitResume -Text $out
        if ($resume) { throw "USAGE-LIMIT|$($resume.ToString('o'))" }
        if ($failed) { throw "Claude Code authentication or execution failed:`n$out" }
    }
}
