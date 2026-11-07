"""Tests for the warden (.github/orchestrator/lib/Reconcile.ps1).

Every other recovery path in the orchestrator runs inside the conductor's
try/catch, which a killed process never reaches. Reconciliation is what notices
an issue holding a label that claims work nobody is doing, and re-enters the
owning stage — bounded, so an issue that cannot progress is handed to the owner
instead of being re-queued every hour (#278).

The rules come from $PipelineStates in lib/Config.ps1: Holder says who owes the
next move, Recovery says what re-entry means. gh is an in-memory fake at module
script scope.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(body: str) -> dict:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        "function script:Write-ReconcileSummary { param($Rows, $Acted) }\n"
        f"{body}\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _issues(*rows: tuple[int, str, int]) -> str:
    """A fake `gh api repos/.../issues` reply: (number, label, idle_minutes) each.

    One JSON line per issue, exactly as the --jq filter in Get-StuckIssue emits
    them. The timestamp is built in PowerShell so each row is genuinely that many
    minutes old relative to the run.
    """
    emit = []
    for number, label, idle in rows:
        labels = f'["{label}"]' if label else "[]"
        emit.append(
            f'        \'{{"n":{number},"u":"\' + '
            f"$now.AddMinutes(-{idle}).ToString('o')"
            f' + \'","l":{labels}}}\''
        )
    body = "\n".join(emit)
    return (
        "$now = (Get-Date).ToUniversalTime()\n"
        "function script:gh { $global:LASTEXITCODE = 0\n"
        "    if ($args[0] -eq 'api') {\n"
        f"{body}\n"
        "    } }\n"
    )


# ── The survey: which states the warden may act on ───────────────────────────


def test_only_agent_held_states_that_went_quiet_are_stuck() -> None:
    """Holder decides, not the clock: a human-held label is never stuck however
    long it waits, and an agent-held one is only stuck once it goes quiet."""
    out = _run(
        _issues(
            (1, "agent:implementing", 500),  # agent owes progress, silent  → stuck
            (2, "agent:reviewing", 500),  # same                          → stuck
            (3, "agent:backlog", 500),  # go signal, nothing ran        → stuck
            (4, "", 500),  # refine never labelled it      → stuck
            (5, "agent:implementing", 5),  # agent-held but live            → fresh
            (6, "human:decision", 99999),  # waiting on the owner           → held
            (7, "human:approval", 99999),  # a PR waiting for a merge       → held
            (8, "agent:failed", 99999),  # the owner's move next          → held
            (9, "agent:shipped", 99999),  # terminal                       → done
            (10, "agent:paused", 500),  # the usage-limit path owns it   → paused
        )
        + r"""
$rows = @(Get-StuckIssue -StuckAfterMinutes 90)
[pscustomobject]@{
    stuck  = @($rows | Where-Object { $_.Verdict -eq 'stuck'  } | ForEach-Object { $_.Number })
    fresh  = @($rows | Where-Object { $_.Verdict -eq 'fresh'  } | ForEach-Object { $_.Number })
    held   = @($rows | Where-Object { $_.Verdict -eq 'held'   } | ForEach-Object { $_.Number })
    done   = @($rows | Where-Object { $_.Verdict -eq 'done'   } | ForEach-Object { $_.Number })
    paused = @($rows | Where-Object { $_.Verdict -eq 'paused' } | ForEach-Object { $_.Number })
} | ConvertTo-Json -Compress
"""
    )
    assert out["stuck"] == [1, 2, 3, 4]
    assert out["fresh"] == [5]
    assert out["held"] == [6, 7, 8]
    assert out["done"] == [9]
    assert out["paused"] == [10]


def test_pull_requests_are_not_issues() -> None:
    """The REST /issues collection includes PRs; a PR must never be reconciled."""
    out = _run(
        r"""
function script:gh { $global:LASTEXITCODE = 0
    # --jq already drops anything with .pull_request, so a correct call emits
    # nothing for a PR-only repository state.
    if (($args -join ' ') -notlike '*pull_request == null*') { throw 'PRs were not filtered out' }
    @() }
[pscustomobject]@{ count = @(Get-StuckIssue -StuckAfterMinutes 1).Count } | ConvertTo-Json -Compress
"""
    )
    assert out["count"] == 0


def test_every_pipeline_label_has_a_rule() -> None:
    """A label Set-AgentState can write but $PipelineStates has no row for would
    read as unlabelled — and the warden would restart a perfectly healthy issue."""
    out = _run(
        r"""
[pscustomobject]@{
    labels   = @($PipelineStates.Keys)
    holders  = @($PipelineStates.Keys | ForEach-Object { $PipelineStates[$_].Holder })
    lanes    = @($PipelineStates.Keys | ForEach-Object { $PipelineStates[$_].LaneName })
} | ConvertTo-Json -Compress
"""
    )
    assert set(out["labels"]) == {
        "agent:backlog",
        "agent:implementing",
        "agent:reviewing",
        "agent:paused",
        "agent:shipped",
        "agent:failed",
        "human:decision",
        "human:approval",
    }
    assert set(out["holders"]) <= {"agent", "human", "none"}
    # Set-AgentState reads the lane from this table; an empty name moves no card.
    assert all(out["lanes"])


# ── Re-entry ──────────────────────────────────────────────────────────────────

_RESTART = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
function script:Reset-AttemptCount { param($IssueNumber) $script:Log.Add('reset') }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Set-IssueLabel { param($Number, $Add, $Remove) $script:Log.Add("label:-$Remove") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:" + ($Body -split "`n")[0]) }
function script:Get-IssueLabel { param($IssueNumber) $script:Labels }
function script:Get-IssueState { param($IssueNumber) $script:State }
function script:gh { $global:LASTEXITCODE = 0; $script:Log.Add("gh:$($args -join ' ')") }
"""

_READY = (
    "$script:State = [pscustomobject]@{ readiness = [pscustomobject]@{ "
    "refined = [pscustomobject]@{ done = $true }; "
    "architected = [pscustomobject]@{ done = $true }; "
    "planned = [pscustomobject]@{ done = $true } }; open_questions = @() }\n"
)

_NOT_READY = (
    "$script:State = [pscustomobject]@{ readiness = [pscustomobject]@{ "
    "refined = [pscustomobject]@{ done = $false }; "
    "architected = [pscustomobject]@{ done = $false }; "
    "planned = [pscustomobject]@{ done = $false } }; open_questions = @() }\n"
)


def test_a_planned_issue_re_enters_at_implement() -> None:
    out = _run(
        _RESTART
        + _READY
        + r"""
$script:Labels = @('agent:implementing')
$stage = Restart-Issue -IssueNumber 7 -Reason 'idle'
[pscustomobject]@{ stage = $stage; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["stage"] == "implement"
    assert "state:agent:backlog" in out["log"]
    assert "reset" in out["log"]


def test_an_unrefined_issue_re_enters_at_refine_not_backlog() -> None:
    """Readiness decides the entry point, not failed_at. A runner killed mid-stage
    records no failed_at, and the old rule then sent the issue to agent:backlog —
    where the readiness gate silently refuses it, leaving it just as stuck while a
    comment claimed it had been retried."""
    out = _run(
        _RESTART
        + _NOT_READY
        + r"""
$script:Labels = @('agent:implementing')
$stage = Restart-Issue -IssueNumber 7 -Reason 'idle'
[pscustomobject]@{ stage = $stage; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["stage"] == "refine"
    assert "state:agent:backlog" not in out["log"]
    # The stale label has to go, or Invoke-Orchestration -From refine skips the issue.
    assert "label:-agent:implementing" in out["log"]
    assert any("stage=refine" in line for line in out["log"])


def test_a_failed_dispatch_is_reported_not_claimed() -> None:
    out = _run(
        _RESTART
        + _NOT_READY
        + r"""
$script:Labels = @()
function script:gh { $global:LASTEXITCODE = 1; 'HTTP 502' }
$stage = Restart-Issue -IssueNumber 7
[pscustomobject]@{ stage = $stage } | ConvertTo-Json -Compress
"""
    )
    assert out["stage"] == ""


# ── The hourly pass ───────────────────────────────────────────────────────────

_PASS = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:Count = 0
$script:Busy = $false
function script:Get-IssueState { param($IssueNumber)
    [pscustomobject]@{ reconcile_count = $script:Count; reconciled_from = $script:From } }
function script:Set-PlanningState { param($IssueNumber, $State) $script:Log.Add("count:$($State.reconcile_count)") }
function script:Restart-Issue { param($IssueNumber, $Reason) $script:Log.Add("restart:$IssueNumber"); 'implement' }
function script:Start-ImplementRun { param($IssueNumber, $Reason) $script:Log.Add("dispatch:$IssueNumber"); 'implement' }
function script:Resume-PausedIssues { $script:Log.Add('resume') }
function script:Set-AgentFailedState { param($IssueNumber, $FailedAt, $Reason) $script:Log.Add("failed:$IssueNumber") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:$Number") }
function script:Test-PipelineBusy { $script:Log.Add('busy?'); $script:Busy }
"""


def test_each_stuck_state_re_enters_through_its_own_recovery() -> None:
    """agent:backlog is already the go signal, so it is dispatched — re-setting a
    label the issue already carries emits no `labeled` event and starts nothing.
    The in-flight states go back through re-entry instead."""
    out = _run(
        _PASS
        + "$script:From = ''\n"
        + _issues(
            (1, "agent:backlog", 500),
            (2, "agent:implementing", 500),
            (3, "agent:reviewing", 500),
            (4, "human:decision", 500),
            (5, "agent:failed", 500),
        )
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{ acted = @($acted | ForEach-Object { $_.Number }); log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["acted"] == [1, 2, 3]
    assert "dispatch:1" in out["log"]
    assert "restart:2" in out["log"]
    assert "restart:3" in out["log"]
    # A state a human holds is never touched, however long it has waited.
    assert not any(line.endswith((":4", ":5")) for line in out["log"])


def test_a_human_held_state_is_never_touched_however_long_it_waits() -> None:
    out = _run(
        _PASS
        + "$script:From = ''\n"
        + _issues(
            (1, "human:decision", 99999),
            (2, "human:approval", 99999),
            (3, "agent:failed", 99999),
            (4, "agent:shipped", 99999),
        )
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 1 -MaxReconcile 2)
[pscustomobject]@{ acted = @($acted).Count; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["acted"] == 0
    assert out["log"] == []


def test_a_live_run_inside_the_grace_period_is_left_alone() -> None:
    """Liveness is the issue's own activity: a run posts `·` progress comments as
    it works, so a recently touched issue has a runner on it. Re-entering it would
    queue a second pipeline behind the live one."""
    out = _run(
        _PASS
        + "$script:From = ''\n"
        + _issues((1, "agent:implementing", 10), (2, "agent:backlog", 89))
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{ acted = @($acted).Count; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["acted"] == 0
    assert out["log"] == []


def test_re_entry_is_counted_before_it_is_attempted() -> None:
    """Re-entry can die exactly the way the run it replaces did. An attempt counted
    only on success would loop forever."""
    out = _run(
        _PASS
        + "$script:From = 'agent:implementing'\n$script:Count = 0\n"
        + _issues((1, "agent:implementing", 500))
        + r"""
function script:Restart-Issue { param($IssueNumber, $Reason) $script:Log.Add('restart'); '' }
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{ action = $acted[0].Action; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["action"] == "dispatch-failed"
    # Counted first, then attempted.
    assert out["log"].index("count:1") < out["log"].index("restart")


def test_the_cap_hands_the_issue_to_the_owner_instead_of_looping() -> None:
    out = _run(
        _PASS
        + "$script:From = 'agent:implementing'\n$script:Count = 2\n"
        + _issues((1, "agent:implementing", 500))
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{ action = $acted[0].Action; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["action"] == "gave-up"
    assert "failed:1" in out["log"]
    assert "comment:1" in out["log"]
    # Gave up means gave up — no further re-entry.
    assert not any(line.startswith("restart") for line in out["log"])


def test_progress_to_a_new_state_earns_a_fresh_budget() -> None:
    """The count is per state. An issue that moved on — even if it later stalls
    somewhere else — is not punished for where it has already been."""
    out = _run(
        _PASS
        + "$script:From = 'agent:implementing'\n$script:Count = 2\n"
        + _issues((1, "agent:reviewing", 500))
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{ action = $acted[0].Action; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["action"] == "re-entered:implement"
    assert "count:1" in out["log"]


def test_whatif_reports_and_changes_nothing() -> None:
    out = _run(
        _PASS
        + "$script:From = ''\n"
        + _issues((1, "agent:implementing", 500), (2, "agent:paused", 500))
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2 -WhatIf)
[pscustomobject]@{ actions = @($acted | ForEach-Object { $_.Action }); log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["actions"] == ["would-restart"]
    # Reading is allowed — the liveness probe is a GET. Nothing may be written:
    # no carrier update, no re-entry, no label, no comment, no resume.
    assert out["log"] == ["busy?"]


def test_a_live_run_defers_the_in_flight_states_without_spending_their_budget() -> None:
    """The implement job is one serial concurrency group, so a single global "is
    anything running" answer tells us whether an in-flight state has a runner on
    it — the Actions API exposes no issue number to correlate per issue (#278 Q2).
    Deferring must not count against the re-entry budget, or a long legitimate run
    would exhaust it and fail a perfectly healthy issue."""
    out = _run(
        _PASS
        + "$script:From = ''\n$script:Busy = $true\n"
        + _issues(
            (1, "agent:implementing", 500),
            (2, "agent:reviewing", 500),
            (3, "agent:backlog", 500),
            (4, "", 500),
        )
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{
    actions = @($acted | ForEach-Object { "$($_.Number):$($_.Action)" })
    log     = @($script:Log)
} | ConvertTo-Json -Compress
"""
    )
    # In-flight states wait for the live run; the two entry points that queue
    # behind it rather than racing it still go.
    assert out["actions"] == [
        "1:deferred",
        "2:deferred",
        "3:re-entered:implement",
        "4:re-entered:implement",
    ]
    # No budget spent on a deferral.
    assert "count:1" in out["log"]
    assert out["log"].count("count:1") == 2  # only #3 and #4
    assert "restart:1" not in out["log"]


def test_liveness_is_not_checked_when_no_in_flight_state_is_in_question() -> None:
    """agent:backlog and an unlabelled issue are dispatched either way, so the pass
    must not pay for an Actions API call it cannot act on."""
    out = _run(
        _PASS
        + "$script:From = ''\n$script:Busy = $true\n"
        + _issues((3, "agent:backlog", 500), (4, "", 500))
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{ n = @($acted).Count; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["n"] == 2
    assert "busy?" not in out["log"]


def test_whatif_names_the_decision_including_giving_up() -> None:
    """A survey that always predicts a re-entry would hide the one outcome the
    owner most needs to see coming."""
    out = _run(
        _PASS
        + "$script:From = 'agent:implementing'\n$script:Count = 2\n"
        + _issues((1, "agent:implementing", 500))
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2 -WhatIf)
[pscustomobject]@{ action = $acted[0].Action; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["action"] == "would-give-up"
    assert out["log"] == ["busy?"]  # surveyed, nothing changed


def test_paused_issues_are_left_to_the_usage_limit_path() -> None:
    """agent:paused carries its own reset time in the carrier, so only
    Resume-PausedIssues knows whether it is due. The warden decides it should run."""
    out = _run(
        _PASS
        + "$script:From = ''\n"
        + _issues((1, "agent:paused", 500))
        + r"""
$acted = @(Invoke-Reconciliation -StuckAfterMinutes 90 -MaxReconcile 2)
[pscustomobject]@{ acted = @($acted).Count; log = @($script:Log) } | ConvertTo-Json -Compress
"""
    )
    assert out["log"] == ["resume"]
    # Resume owns the transition; the warden does not also re-enter it.
    assert out["acted"] == 0
