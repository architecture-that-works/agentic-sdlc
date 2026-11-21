"""Tests for pausing on the engine's usage limit instead of failing.

- lib/Util.ps1 — Get-UsageLimitResume reads the reset time from the engine's
  message (epoch, "resets 3pm", "resets at 15:30"), falls back to one hour, and
  never waits more than 5 hours; ordinary output is not a limit.
- Orchestrator.psm1 — a failure while the allowance is spent pauses the issue
  (agent:paused) and counts no attempt; a real failure still counts.
- lib/GitHub.ps1 — Resume-PausedIssues resumes only issues that are due, and only
  once a probe shows the engine answers again; it starts each through Restart-Issue,
  which decides from readiness (#380), so a pause on an owner's comment still
  reaches refine.

Fakes live at module script scope; conductor tests run in tmp_path because the
conductor's finally block resets git.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(body: str, cwd: Path | None = None) -> dict:
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


def test_resume_time_is_read_from_the_message_and_capped() -> None:
    out = _run(
        r"""
$now = [datetime]::SpecifyKind([datetime]'2026-09-23T10:00:00', 'Utc')
$epoch = [DateTimeOffset]::new($now.AddHours(2)).ToUnixTimeSeconds()
function f($t) { $r = Get-UsageLimitResume -Text $t -Now $now; if ($r) { $r.ToString('yyyy-MM-ddTHH:mm') } else { $null } }
[pscustomobject]@{
    epoch    = f "Claude AI usage limit reached|$epoch"
    pm       = f "5-hour limit reached ∙ resets 1pm"
    clock    = f "Usage limit reached. Resets at 11:30"
    tomorrow = f "limit reached, resets 9am"
    unknown  = f "Claude AI usage limit reached"
    far      = f "Claude AI usage limit reached|$([DateTimeOffset]::new($now.AddHours(20)).ToUnixTimeSeconds())"
    normal   = f "Pong! How can I help?"
} | ConvertTo-Json -Compress
"""
    )
    assert out == {
        "epoch": "2026-09-23T12:00",
        "pm": "2026-09-23T13:00",
        "clock": "2026-09-23T11:30",
        # "resets 9am" is tomorrow's 9am, beyond the cap — so the cap applies.
        "tomorrow": "2026-09-23T15:00",
        "unknown": "2026-09-23T11:00",
        "far": "2026-09-23T15:00",
        "normal": None,
    }


def test_spend_and_session_limit_wording_is_a_limit() -> None:
    """#229: Claude's spend/session-limit wording failed #225 three times instead of
    pausing it. The exact message must pause, with the reset time it names."""
    out = _run(
        r"""
$now = [datetime]::SpecifyKind([datetime]'2026-09-25T13:50:00', 'Utc')
function f($t) { $r = Get-UsageLimitResume -Text $t -Now $now; if ($r) { $r.ToString('yyyy-MM-ddTHH:mm') } else { $null } }
[pscustomobject]@{
    issue225 = f "Plan: the engine returned no implementation plan (exit code 1): You've hit your org's monthly spend limit · ask your admin to raise it at claude.ai/admin-settings/usage · your session limit resets 5:20pm (UTC)"
    session  = f "Your session limit resets 5:20pm"
    spend    = f "You've hit your monthly spend limit"
    daily    = f "You've hit your daily limit"
    team     = f "You've hit your team's limit · resets 6pm"
    auth     = f "Error: Invalid API key · Please run /login"
    engine   = f "Plan: the engine returned no implementation plan (exit code 1): timeout"
    apart    = f "Could not hit your endpoint. Retrying later. Note: the request size limit is 10MB"
} | ConvertTo-Json -Compress
"""
    )
    assert out == {
        "issue225": "2026-09-25T17:20",
        "session": "2026-09-25T17:20",
        "spend": "2026-09-25T14:50",  # no reset time named: one hour
        "daily": "2026-09-25T14:50",
        "team": "2026-09-25T18:00",
        "auth": None,
        "engine": None,
        # "hit your" and "limit" in different sentences are not one phrase.
        "apart": None,
    }


def test_probe_without_a_runnable_cli_is_not_a_limit() -> None:
    """A missing or crashing engine CLI is not a usage limit — and must not throw."""
    out = _run(
        r"""
function script:claude { throw "The term 'claude' is not recognized" }
function script:agy    { throw "The term 'agy' is not recognized" }
[pscustomobject]@{ limited = ($null -ne (Test-EngineUsageLimit)) } | ConvertTo-Json -Compress
"""
    )
    assert out == {"limited": False}


_CONDUCTOR = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:State = [pscustomobject]@{ attempts = @(); attempt_count = 0 }
function script:Assert-EngineReady {}
function script:Resume-PausedIssues {}
function script:Test-TrustedAuthor { param($IssueNumber) $true }
function script:Acquire-OrchestratorLock { param($IssueNumber) $true }
function script:Release-OrchestratorLock {}
function script:Get-IssueState { param($IssueNumber) $script:State }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Add-Comment { param($Number, $Body) }
function script:Add-FailedAttempt { param($IssueNumber, $Stage, $Reason, $Attempt, $Max) $script:Log.Add("attempt:$Attempt") }
function script:Suspend-ForUsageLimit { param($IssueNumber, $Until) $script:Log.Add("paused") }
function script:Set-AgentFailedState { param($IssueNumber, $FailedAt, $Reason) $script:Log.Add('failed') }
function script:Format-ErrorBlock { param($Raw) $Raw }
function script:gh { $global:LASTEXITCODE = 0; '{"title":"t","labels":[],"state":"OPEN"}' }
function script:git { $global:LASTEXITCODE = 1 }
function script:Invoke-Implement { param($IssueNumber, [switch]$Force) throw 'Agent CLI exited with code 1.' }
"""


def test_failure_during_a_usage_limit_pauses_without_an_attempt(tmp_path: Path) -> None:
    out = _run(
        _CONDUCTOR
        + r"""
function script:Test-EngineUsageLimit { (Get-Date).ToUniversalTime().AddHours(2) }
Invoke-Orchestration -IssueNumber 50 -MaxRetries 3
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert out["log"] == ["state:agent:implementing", "paused"]


def test_real_failure_still_counts_as_an_attempt(tmp_path: Path) -> None:
    out = _run(
        _CONDUCTOR
        + r"""
function script:Test-EngineUsageLimit { $null }
Invoke-Orchestration -IssueNumber 50 -MaxRetries 1
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert "attempt:1" in out["log"] and "failed" in out["log"]
    assert "paused" not in out["log"]


def test_spent_allowance_at_startup_pauses_the_issue(tmp_path: Path) -> None:
    out = _run(
        _CONDUCTOR
        + r"""
function script:Assert-EngineReady { throw 'USAGE-LIMIT|2026-09-23T15:00:00.0000000Z' }
function script:Test-TrustedAuthor { param($IssueNumber) $true }
$r = Invoke-Orchestration -From refine -IssueNumber 50
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert out == {"r": False, "log": ["paused"]}


def test_every_run_resumes_due_pauses_before_its_stage(tmp_path: Path) -> None:
    """#306: GitHub skips hourly schedules, so any run resumes a due pause first."""
    out = _run(
        _CONDUCTOR
        + r"""
function script:Resume-PausedIssues { $script:Log.Add('resume') }
function script:Test-EngineUsageLimit { $null }
Invoke-Orchestration -IssueNumber 50 -MaxRetries 1
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert out["log"][:2] == ["resume", "state:agent:implementing"]


def test_a_failing_resume_does_not_stop_the_run(tmp_path: Path) -> None:
    out = _run(
        _CONDUCTOR
        + r"""
function script:Resume-PausedIssues { throw 'gh api: HTTP 502' }
function script:Test-EngineUsageLimit { $null }
Invoke-Orchestration -IssueNumber 50 -MaxRetries 1
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert out["log"][0] == "state:agent:implementing"


_RESUME = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$past   = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
$future = (Get-Date).ToUniversalTime().AddHours(3).ToString('o')
function ready { [pscustomobject]@{ refined = @{ done = $true }; architected = @{ done = $true }; planned = @{ done = $true } } }
$script:States = @{
    # Ready: refined, architected, planned, nothing open.
    11 = [pscustomobject]@{ paused_until = $past;   readiness = (ready); open_questions = @() }
    # Paused while the owner's answer was being read: a question is still open.
    12 = [pscustomobject]@{ paused_until = $past;   readiness = (ready); open_questions = @(@{ text = 'Which?' }) }
    13 = [pscustomobject]@{ paused_until = $future; readiness = (ready); open_questions = @() }
}
$script:Labels = @{ 11 = @('agent:paused'); 12 = @('agent:paused', 'human:decision'); 13 = @('agent:paused') }
function script:Get-IssueState { param($IssueNumber) $script:States[$IssueNumber] }
function script:Set-PlanningState { param($IssueNumber, $State) $script:Log.Add("write:$IssueNumber") }
function script:Set-AttemptsSection { param($IssueNumber, $State, $Max) }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:${IssueNumber}:$Label") }
function script:Set-IssueLabel { param($Number, $Add, $Remove) $script:Log.Add("label:${Number}:-$Remove") }
function script:Get-IssueLabel { param($IssueNumber) $script:Labels[$IssueNumber] }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:${Number}:$Body") }
$script:Paused = @('11', '12', '13')
function script:gh { $global:LASTEXITCODE = 0
    # The paused listing is REST (ADR-012): one call on every run must not spend GraphQL.
    if ($args[0] -eq 'api' -and "$($args[1])" -like '*issues?labels=agent:paused*') { $script:Paused }
    else { $script:Log.Add('dispatch:' + ($args -join ' ')) } }
"""


def _for(log: list[str], n: int) -> list[str]:
    return [e for e in log if f":{n}:" in e or f"={n}" in e or e.endswith(f":{n}")]


def test_resume_waits_for_the_engine_and_the_due_time() -> None:
    out = _run(
        _RESUME
        + r"""
$script:Probe = (Get-Date).ToUniversalTime().AddHours(1)
function script:Test-EngineUsageLimit { $script:Probe }
Resume-PausedIssues
$stillLimited = @($script:Log)
$moved = [datetime]$script:States[11].paused_until -gt (Get-Date).ToUniversalTime()
# The engine answers again once the pause has passed.
$script:States[11].paused_until = $past; $script:States[12].paused_until = $past
$script:Log.Clear(); $script:Probe = $null
Resume-PausedIssues
[pscustomobject]@{ still = $stillLimited; moved = $moved; resumed = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    # Still limited: the two due issues get a later resume time, nothing restarts.
    assert out["still"] == ["write:11", "write:12"]
    assert out["moved"] is True
    resumed = out["resumed"]
    assert "state:11:agent:backlog" in resumed  # ready → label restarts implement
    assert not _for(resumed, 13)  # not due yet: left alone


def test_a_paused_issue_with_an_open_question_goes_to_refine() -> None:
    """#380: a pause taken on an owner's comment must reach refine, which reads the
    answer — agent:backlog refuses an issue with open questions."""
    out = _run(
        _RESUME
        + r"""
function script:Test-EngineUsageLimit { $null }
Resume-PausedIssues
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    log = _for(out["log"], 12)
    assert "label:12:-agent:paused" in log
    assert any(e.startswith("dispatch:") and "stage=refine" in e for e in log)
    assert not any(e.startswith("state:12:") for e in log)  # agent:backlog never set
    # The pause is cleared before the restart, so the restart's writes are the last.
    assert log.index("write:12") < log.index("label:12:-agent:paused")


def test_the_resume_posts_only_the_restart_comment() -> None:
    out = _run(
        _RESUME
        + r"""
function script:Test-EngineUsageLimit { $null }
Resume-PausedIssues
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    comments = [e for e in out["log"] if e.startswith("comment:")]
    assert comments == [
        "comment:11:· restarting from implement (usage limit lifted)",
        "comment:12:· restarting refine (usage limit lifted)",
    ]


def test_a_paused_issue_without_a_resume_time_is_resumed() -> None:
    out = _run(
        _RESUME
        + r"""
$script:States[12].PSObject.Properties.Remove('paused_until')
$script:Paused = @('12')
function script:Test-EngineUsageLimit { $null }
Resume-PausedIssues
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    log = out["log"]
    assert "label:12:-agent:paused" in log
    assert any(e.startswith("dispatch:") and "issue_number=12" in e for e in log)


def test_the_pause_stores_and_names_no_stage() -> None:
    out = _run(
        r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:St = [pscustomobject]@{ attempt_count = 0 }
function script:Get-IssueState { param($IssueNumber) $script:St }
function script:Set-PlanningState { param($IssueNumber, $State) }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add($Body) }
Suspend-ForUsageLimit -IssueNumber 7 -Until ([datetime]::SpecifyKind([datetime]'2026-09-23T15:00:00', 'Utc'))
[pscustomobject]@{ log = @($script:Log); keys = @($script:St.PSObject.Properties.Name) } | ConvertTo-Json -Compress
"""
    )
    assert out["keys"] == ["attempt_count", "paused_until"]
    assert out["log"][0] == "state:agent:paused"
    body = out["log"][1]
    assert "Work resumes after 2026-09-23 15:00 UTC" in body
    assert not any(s in body for s in ("implement", "refine", "comment"))


def test_no_paused_issue_means_no_engine_probe() -> None:
    out = _run(
        _RESUME
        + r"""
$script:Paused = @()
function script:Test-EngineUsageLimit { $script:Log.Add('probe') }
Resume-PausedIssues
[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["log"] == []
