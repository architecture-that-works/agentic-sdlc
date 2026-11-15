"""Tests for the review stage's error_max_turns handling, budget scaling, and prompt content.

- engines/Claude.ps1 — Invoke-ClaudeStreaming: a stream ending in error_max_turns throws
  once with 'ran out of turns'; any other non-zero exit retries per MaxAttempts.
- stages/Review.ps1 — Invoke-Review: the scaled turn budget (base + changed files, capped
  at MaxTurns_Review_Cap); the prompt names the read-only tools and the signal history as
  the source of test results.

gh, claude and helpers are replaced by in-memory fakes at module script scope.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
REPO_ROOT = Path(__file__).parent.parent.parent
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(body: str, cwd: Path | None = None) -> dict:
    """Run `body` inside the module's session state; it must print one JSON line last."""
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        f"{body}\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        cwd=str(cwd) if cwd else None,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


# ── (a) error_max_turns throws exactly once, no retry ────────────────────────


def test_error_max_turns_throws_once_no_retry() -> None:
    """A stream ending in error_max_turns throws immediately; Invoke-ClaudeStreaming
    does not iterate further retry attempts."""
    out = _run(
        r"""
$script:CallCount = 0
function script:claude {
    $script:CallCount++
    '{"type":"result","subtype":"error_max_turns"}'
    $global:LASTEXITCODE = 1
}
function script:Start-Sleep { param([int]$Seconds) }
$err = $null
try {
    Invoke-ClaudeStreaming -Prompt 'test' -Label 'Review' -MaxTurns 30 -MaxAttempts 3
} catch {
    $err = $_.Exception.Message
}
[pscustomobject]@{ err = $err; calls = $script:CallCount } | ConvertTo-Json -Compress
"""
    )
    assert out["calls"] == 1, "must throw on first attempt, never retry"
    assert "ran out of turns" in out["err"]
    assert "(30)" in out["err"]


# ── (b) other non-zero exit retries per MaxAttempts ──────────────────────────


def test_other_nonzero_exit_retries_per_max_attempts() -> None:
    """A non-zero exit without error_max_turns is treated as a transient API error
    and retried up to MaxAttempts times before the final throw."""
    out = _run(
        r"""
$script:CallCount = 0
function script:claude {
    $script:CallCount++
    $global:LASTEXITCODE = 1
}
function script:Start-Sleep { param([int]$Seconds) }
$err = $null
try {
    Invoke-ClaudeStreaming -Prompt 'test' -Label 'Review' -MaxTurns 30 -MaxAttempts 3
} catch {
    $err = $_.Exception.Message
}
[pscustomobject]@{ err = $err; calls = $script:CallCount } | ConvertTo-Json -Compress
"""
    )
    assert out["calls"] == 3, "must retry all MaxAttempts before giving up"
    assert "ran out of turns" not in out["err"]
    assert "exited non-zero" in out["err"]


# ── (c) review budget scales with changed files, capped at MaxTurns_Review_Cap ──


def test_review_budget_scales_with_changed_files() -> None:
    """Budget = min(MaxTurns_Review_Cap, MaxTurns_Review + changedFileCount):
    5 changed files → 35, 80 changed files → 90 (capped)."""
    out = _run(
        r"""
$env:KANBAN_MAX_TURNS_REVIEW = $null
$base = $OrchestratorConfig.MaxTurns_Review
$cap  = $OrchestratorConfig.MaxTurns_Review_Cap
[pscustomobject]@{
    f5  = [Math]::Min($cap, $base + 5)
    f80 = [Math]::Min($cap, $base + 80)
} | ConvertTo-Json -Compress
"""
    )
    assert out["f5"] == 35
    assert out["f80"] == 90


# ── (d) prompt contains read-only tool list and signal-history source clause ──

_REVIEW_FAKES = r"""
function script:Set-AgentState    { param($IssueNumber, $Label) }
function script:Add-Comment       { param($Number, $Body) }
function script:Format-OwnerComments { param($IssueNumber) '' }
function script:Get-IssueEstimate { param($IssueNumber) 3 }
function script:Get-PhaseModel    { param($Estimate, $Phase) 'mock-model' }
function script:Get-CurrentIssueNumber { 1 }
$script:CapturedPrompt = ''
$script:CapturedTurns  = 0
function script:Invoke-ClaudeStreaming {
    param($Prompt, $AllowedTools, $Label, $Model, $MaxTurns, $MaxAttempts)
    $script:CapturedPrompt = $Prompt
    $script:CapturedTurns  = $MaxTurns
    'APPROVED'
}
function script:gh {
    param()
    $global:LASTEXITCODE = 0
    $argsStr = $args -join ' '
    if ($argsStr -match 'pr diff') {
        # 5 changed files
        "diff --git a/a.py b/a.py`ndiff --git a/b.py b/b.py`ndiff --git a/c.py b/c.py`ndiff --git a/d.py b/d.py`ndiff --git a/e.py b/e.py"
    } elseif ($argsStr -match 'issue view' -and $argsStr -notmatch 'comments') {
        # PowerShell expands `--json title,body` as two args; match without the comma
        '{"title":"My Issue","body":"**Goal**: implement X"}'
    } else {
        $null
    }
}
"""


def test_review_prompt_has_tool_declaration_and_signal_source() -> None:
    """The review prompt states the read-only tool list and directs the reviewer to
    the signal history for test results, preventing wasted tool-call turns."""
    out = _run(
        _REVIEW_FAKES
        + r"""
$env:KANBAN_MAX_TURNS_REVIEW = $null
Invoke-Review -IssueNumber 1 -PRNumber 1
[pscustomobject]@{
    prompt = $script:CapturedPrompt
    turns  = $script:CapturedTurns
} | ConvertTo-Json -Compress
"""
    )
    prompt = out["prompt"]
    assert "Read, Glob, and Grep only" in prompt, "tool declaration missing from prompt"
    assert "do not attempt Bash" in prompt, "Bash prohibition missing from prompt"
    assert "signal history" in prompt, "signal-history clause missing from prompt"
    assert "Tests Passing" in prompt, "signal-history robot-emoji reference missing"
    assert out["turns"] == 35, (
        f"expected 35 turns for 5 changed files, got {out['turns']}"
    )


# ── (e) conductor fast-fails on "ran out of turns" without counting an attempt ──

_CONDUCTOR_FAKES = r"""
$script:Log  = [System.Collections.Generic.List[string]]::new()
$script:State = [pscustomobject]@{ attempts = @(); attempt_count = 0 }
function script:Assert-EngineReady {}
function script:Test-TrustedAuthor { param($IssueNumber) $true }
function script:Acquire-OrchestratorLock { param($IssueNumber) $true }
function script:Release-OrchestratorLock {}
function script:Get-IssueState     { param($IssueNumber) $script:State }
function script:Set-AgentState     { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Set-AgentFailedState { param($IssueNumber, $FailedAt, $Reason) $script:Log.Add("failed:$FailedAt") }
function script:Add-FailedAttempt  { param($IssueNumber, $Stage, $Reason, $Attempt, $Max) $script:Log.Add("attempt:$Attempt") }
function script:Add-Comment        { param($Number, $Body) }
function script:Format-ErrorBlock  { param($Raw) $Raw }
function script:Test-EngineUsageLimit { $null }
function script:git { $global:LASTEXITCODE = 1 }
function script:gh {
    $global:LASTEXITCODE = 0
    $argsStr = $args -join ' '
    if ($argsStr -match 'pr list') { '[{"number":99}]' }
    else { '{"title":"t","labels":[],"state":"OPEN"}' }
}
function script:Invoke-Implement { param($IssueNumber, [switch]$Force, [switch]$Revise) 'sha123' }
"""


def test_ran_out_of_turns_fast_fails_without_attempt_count(tmp_path: Path) -> None:
    """When Invoke-Review throws 'ran out of turns', the conductor calls
    Set-AgentFailedState for the review stage and returns immediately — no
    attempt counter increment, no retry — mirroring the USAGE-LIMIT fast-fail."""
    out = _run(
        _CONDUCTOR_FAKES
        + r"""
function script:Invoke-Review {
    param($IssueNumber, $PRNumber)
    throw 'Review ran out of turns on 5 changed file(s) — retry needs a larger budget or a smaller PR.'
}
Invoke-Orchestration -IssueNumber 50 -MaxRetries 3
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert "failed:review" in out["log"], (
        "conductor must call Set-AgentFailedState for the review stage"
    )
    assert not any(e.startswith("attempt:") for e in out["log"]), (
        "ran-out-of-turns must not increment the attempt counter"
    )
