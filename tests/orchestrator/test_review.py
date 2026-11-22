"""Tests for the review stage's error_max_turns handling, budget scaling, prompt content and
checked verdict.

- engines/Claude.ps1 — Invoke-ClaudeStreaming: a stream ending in error_max_turns throws
  once with 'ran out of turns'; any other non-zero exit retries per MaxAttempts. With
  -JsonSchema it returns the result's structured_output, throws once when there is none,
  and neither shows nor counts the engine's StructuredOutput tool call.
- stages/Review.ps1 — Invoke-Review: the scaled turn budget (base + changed files, capped
  at MaxTurns_Review_Cap); the prompt names the read-only tools and the signal history as
  the source of test results; the verdict is the checked `verdict` field.

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
    Invoke-ClaudeStreaming -Prompt 'test' -Label 'Review' -Model 'mock-model' -MaxTurns 30 -MaxAttempts 3
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
    Invoke-ClaudeStreaming -Prompt 'test' -Label 'Review' -Model 'mock-model' -MaxTurns 30 -MaxAttempts 3
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
function script:Get-TaskModel     { param($Task, $Engine) 'mock-model' }
function script:Get-CurrentIssueNumber { 1 }
$script:CapturedPrompt = ''
$script:CapturedTurns  = 0
function script:Invoke-ClaudeStreaming {
    param($Prompt, $AllowedTools, $Label, $Model, $MaxTurns, $MaxAttempts, $JsonSchema)
    $script:CapturedPrompt = $Prompt
    $script:CapturedTurns  = $MaxTurns
    [pscustomobject]@{ verdict = 'approved'; report = 'Looks good.' }
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
$script:Comments = [System.Collections.Generic.List[string]]::new()
function script:Add-Comment { param($Number, $Body) $script:Comments.Add($Body) }
Invoke-Orchestration -IssueNumber 50
[pscustomobject]@{ log = @($script:Log); comments = @($script:Comments) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert "failed:review" in out["log"], (
        "conductor must call Set-AgentFailedState for the review stage"
    )
    assert not any(e.startswith("attempt:") for e in out["log"]), (
        "ran-out-of-turns must not increment the attempt counter"
    )
    failed = [c for c in out["comments"] if c.startswith("🤖❌")]
    assert failed, "the out-of-turns failure must be posted"
    assert "MaxTurns_Review_Cap" in failed[0], (
        "the out-of-turns comment must name the setting to raise"
    )
    assert "fewer changed files" in failed[0]


# ── (f) the verdict is the checked field of the result's structured_output ───

_SCHEMA = REPO_ROOT / ".agents" / "skills" / "review" / "answer.schema.json"


def test_answer_schema_has_two_required_fields() -> None:
    schema = json.loads(_SCHEMA.read_text(encoding="utf-8"))
    assert schema["required"] == ["verdict", "report"]
    assert schema["additionalProperties"] is False
    assert schema["properties"]["verdict"]["enum"] == ["approved", "rejected"]
    assert schema["properties"]["report"]["type"] == "string"


def test_answer_schema_declares_no_meta_schema_the_engine_cannot_load() -> None:
    # The CLI's --json-schema validator rejects a "$schema" it has not loaded
    # (draft 2020-12 failed every review eval run before the model was called).
    # The schema uses only keywords every draft shares, so it declares none.
    schema = json.loads(_SCHEMA.read_text(encoding="utf-8"))
    assert "$schema" not in schema


def _result_event(**fields) -> str:
    return json.dumps({"type": "result", **fields})


def _stage_fakes(events: list[str], exit_code: int = 0) -> str:
    """Fakes for Invoke-Review that stub the claude CLI itself with stored stream events."""
    lines = "\n".join(f"    '{e}'" for e in events)
    return (
        r"""
$script:Comments = [System.Collections.Generic.List[string]]::new()
$script:States   = [System.Collections.Generic.List[string]]::new()
$script:CliArgs  = @()
$script:CallCount = 0
function script:Set-AgentState    { param($IssueNumber, $Label) $script:States.Add($Label) }
function script:Add-Comment       { param($Number, $Body) $script:Comments.Add($Body) }
function script:Format-OwnerComments { param($IssueNumber) '' }
function script:Get-SignalComments { param($IssueNumber) @() }
function script:Get-IssueEstimate { param($IssueNumber) 3 }
function script:Get-TaskModel     { param($Task, $Engine) 'mock-model' }
function script:Start-Sleep { param([int]$Seconds) }
function script:gh {
    $global:LASTEXITCODE = 0
    $argsStr = $args -join ' '
    if ($argsStr -match 'pr diff') { "diff --git a/a.py b/a.py" }
    elseif ($argsStr -match 'issue view') { '{"title":"My Issue","body":"**Goal**: X"}' }
    else { $null }
}
function script:claude {
    $script:CallCount++
    $script:CliArgs = $args
"""
        + lines
        + f"\n    $global:LASTEXITCODE = {exit_code}\n}}\n"
    )


_REPORT_STAGE = r"""
$ret = $null; $err = $null
try { $ret = Invoke-Review -IssueNumber 1 -PRNumber 1 } catch { $err = $_.Exception.Message }
[pscustomobject]@{
    ret      = $ret
    err      = $err
    calls    = $script:CallCount
    comments = @($script:Comments)
    states   = @($script:States)
    args     = @($script:CliArgs)
} | ConvertTo-Json -Compress -Depth 5
"""


def test_approved_verdict_approves_and_posts_the_report() -> None:
    out = _run(
        _stage_fakes(
            [
                _result_event(
                    subtype="success",
                    structured_output={"verdict": "approved", "report": "Looks good."},
                )
            ]
        )
        + _REPORT_STAGE
    )
    assert out["ret"] is True
    assert out["err"] is None
    verdict = [c for c in out["comments"] if c.startswith("🤖")]
    assert verdict == ["🤖✅ Review Approved\n\nLooks good.\n\n*Proceeding to merge.*"]
    assert "agent:implementing" not in out["states"]
    schema_arg = out["args"][out["args"].index("--json-schema") + 1]
    assert json.loads(schema_arg) == json.loads(_SCHEMA.read_text(encoding="utf-8"))
    assert "-p" in out["args"]


def test_rejected_verdict_rejects_even_with_an_approved_line() -> None:
    report = "Fix 1.\n\nAPPROVED\n\n1. **Bug**"
    out = _run(
        _stage_fakes(
            [
                _result_event(
                    subtype="success",
                    structured_output={"verdict": "rejected", "report": report},
                )
            ]
        )
        + _REPORT_STAGE
    )
    assert out["ret"] is False
    assert (
        f"🤖❌ Review Rejected\n\n{report}\n\n*Returning to Implementing for fixes.*"
        in (out["comments"])
    )
    assert out["states"][-1] == "agent:implementing"


@pytest.mark.parametrize(
    ("event", "exit_code", "cause"),
    [
        (
            _result_event(subtype="success", is_error=False, result="APPROVED"),
            0,
            "no structured_output",
        ),
        (
            _result_event(subtype="error_max_structured_output_retries", is_error=True),
            1,
            "error_max_structured_output_retries",
        ),
    ],
    ids=["no-structured-output", "max-structured-output-retries"],
)
def test_run_without_a_checked_answer_fails_the_attempt(
    event: str, exit_code: int, cause: str
) -> None:
    """No valid answer is a thrown failure naming the cause — never a rejection, never
    retried by the engine helper, never the out-of-turns fast-fail."""
    out = _run(_stage_fakes([event], exit_code) + _REPORT_STAGE)
    assert out["ret"] is None
    assert cause in out["err"]
    assert "ran out of turns" not in out["err"]
    assert out["calls"] == 1, "must not retry a run that produced no checked answer"
    assert not any(c.startswith("🤖") for c in out["comments"]), "no verdict comment"
    assert "agent:implementing" not in out["states"]


def test_structured_output_tool_call_is_not_shown_or_counted() -> None:
    events = [
        json.dumps(
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Read",
                            "input": {"file_path": "a.py"},
                        },
                        {
                            "type": "tool_use",
                            "name": "StructuredOutput",
                            "input": {"verdict": "approved", "report": "ok"},
                        },
                    ]
                },
            }
        ),
        _result_event(
            subtype="success", structured_output={"verdict": "approved", "report": "ok"}
        ),
    ]
    lines = "\n".join(f"    '{e}'" for e in events)
    script = (
        r"""
$script:Logs = [System.Collections.Generic.List[string]]::new()
function script:Write-Log { param($Message, $Color) $script:Logs.Add($Message) }
function script:claude {
"""
        + lines
        + r"""
    $global:LASTEXITCODE = 0
}
$shown = Invoke-ClaudeStreaming -Prompt 't' -Label 'Review' -Model 'm' -JsonSchema '{}' 6>&1 |
    Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | Out-String
$answer = Invoke-ClaudeStreaming -Prompt 't' -Label 'Review' -Model 'm' -JsonSchema '{}' 6>$null
[pscustomobject]@{ shown = $shown; logs = @($script:Logs); verdict = $answer.verdict } |
    ConvertTo-Json -Compress
"""
    )
    out = _run(script)
    assert out["verdict"] == "approved"
    assert "Read:" in out["shown"]
    assert "StructuredOutput" not in out["shown"]
    assert any("1 tool call(s)" in m for m in out["logs"]), out["logs"]


def test_non_claude_engine_fails_the_review_with_an_explicit_reason() -> None:
    out = _run(
        _stage_fakes([]) + "$OrchestratorConfig.Engine = 'gemini'\n" + _REPORT_STAGE
    )
    assert out["err"] == (
        "the review needs a checked answer and the gemini engine cannot give one"
    )
    assert out["calls"] == 0
    assert out["comments"] == []


def test_no_checked_answer_is_a_counted_failed_attempt(tmp_path: Path) -> None:
    out = _run(
        _CONDUCTOR_FAKES
        + r"""
function script:Invoke-Review {
    param($IssueNumber, $PRNumber)
    throw 'Review produced no checked answer: error_max_structured_output_retries'
}
Invoke-Orchestration -IssueNumber 50
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert any(e.startswith("attempt:") for e in out["log"]), out["log"]
