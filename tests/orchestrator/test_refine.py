"""Tests for the refine stage's decision loop (.github/orchestrator/stages/Refine.ps1).

A human answers an open question by commenting on its human:decision issue and
closing it; closing without a comment accepts the agent's recommendation.
Resolve-DecisionAnswers reads that back into the AGENT-STATE carrier so nobody
edits JSON by hand. Also covers Add-IssueToBoard (lib/GitHub.ps1), which puts an
issue that never went through `task sync` on the project board.

gh and the carrier helpers are replaced with in-memory fakes defined at module
script scope, so the tests run without GitHub.
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


def _run(body: str) -> dict:
    """Run `body` inside the module's session state; it must print one JSON line."""
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
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


# Parent #50 has three open questions: #11 answered with a comment and closed,
# #12 still open, #13 closed without a comment. Pipeline comments on #11 must
# never be taken as the answer.
_DECISION_FAKES = r"""
$script:Written  = $null
$script:Comments = @()
function script:Get-IssueState {
    param([int]$IssueNumber)
    [pscustomobject]@{
        issue_number      = 50
        readiness         = [pscustomobject]@{ refined = [pscustomobject]@{ done = $true } }
        open_questions    = @(
            [pscustomobject]@{ text = 'Q-comment'; raised_by = 'grill'; decision = 'rec A'; child_issue = 11 },
            [pscustomobject]@{ text = 'Q-open';    raised_by = 'grill'; decision = 'rec B'; child_issue = 12 },
            [pscustomobject]@{ text = 'Q-silent';  raised_by = 'grill'; decision = 'rec C'; child_issue = 13 }
        )
        decided_questions = @([pscustomobject]@{ text = 'Q-earlier'; decision = 'done before' })
    }
}
function script:Set-PlanningState { param([int]$IssueNumber, $State) $script:Written = $State }
function script:Add-Comment { param([int]$Number, [string]$Body) $script:Comments += $Body }
function script:gh {
    $global:LASTEXITCODE = 0
    $path = $args[1]
    switch -Regex ($path) {
        '/issues/11$'          { return '{"state":"closed","closed_by":"ysuurme"}' }
        '/issues/12$'          { return '{"state":"open","closed_by":""}' }
        '/issues/13$'          { return '{"state":"closed","closed_by":"ysuurme"}' }
        '/issues/11/comments$' { return '{"login":"ysuurme","body":"Use option A, but keep it behind a flag."}' }
        '/issues/13/comments$' { return 'null' }
    }
}
"""


def test_closed_decisions_move_to_decided_with_their_answer() -> None:
    out = _run(
        _DECISION_FAKES
        + r"""
$n = Resolve-DecisionAnswers -IssueNumber 50
[pscustomobject]@{
    resolved = $n
    open     = @($script:Written.open_questions | ForEach-Object { $_.text })
    decided  = @($script:Written.decided_questions | ForEach-Object {
        [pscustomobject]@{ text = $_.text; by = $_.decided_by; decision = $_.decision; child = $_.child_issue }
    })
    comments = $script:Comments
} | ConvertTo-Json -Depth 5 -Compress
"""
    )
    assert out["resolved"] == 2
    assert out["open"] == ["Q-open"]
    decided = {d["text"]: d for d in out["decided"]}
    # Earlier decisions are kept, not overwritten.
    assert decided["Q-earlier"]["decision"] == "done before"
    # A comment is the answer, attributed to its author.
    assert (
        decided["Q-comment"]["decision"] == "Use option A, but keep it behind a flag."
    )
    assert decided["Q-comment"]["by"] == "ysuurme"
    assert decided["Q-comment"]["child"] == 11
    # Closing without a comment accepts the recommendation, and says so.
    assert decided["Q-silent"]["decision"].startswith("Accepted the recommendation")
    assert "rec C" in decided["Q-silent"]["decision"]
    assert len(out["comments"]) == 1 and "2 answer(s)" in out["comments"][0]


def test_nothing_closed_writes_nothing() -> None:
    out = _run(
        _DECISION_FAKES
        + r"""
function script:gh { $global:LASTEXITCODE = 0; return '{"state":"open","closed_by":""}' }
$n = Resolve-DecisionAnswers -IssueNumber 50
[pscustomobject]@{ resolved = $n; written = ($null -ne $script:Written); comments = @($script:Comments).Count } |
    ConvertTo-Json -Compress
"""
    )
    assert out == {"resolved": 0, "written": False, "comments": 0}


def test_question_without_a_decision_issue_stays_open() -> None:
    out = _run(
        r"""
$script:Written = $null
function script:Get-IssueState {
    param([int]$IssueNumber)
    [pscustomobject]@{ open_questions = @([pscustomobject]@{ text = 'legacy'; decision = 'x' }); decided_questions = @() }
}
function script:Set-PlanningState { param([int]$IssueNumber, $State) $script:Written = $State }
function script:gh { throw 'gh must not be called for a question without child_issue' }
$n = Resolve-DecisionAnswers -IssueNumber 50
[pscustomobject]@{ resolved = $n; written = ($null -ne $script:Written) } | ConvertTo-Json -Compress
"""
    )
    assert out == {"resolved": 0, "written": False}


def test_issue_missing_from_the_board_is_added_and_cached() -> None:
    out = _run(
        r"""
$script:KanbanProjectNumber = 5
$script:_CachedItems = @([pscustomobject]@{
    id = 'PVTI_other'; content = [pscustomobject]@{ number = 1; repository = 'octocat/sandbox' }
})
function script:Get-ResolvedOwner { 'octocat' }
$script:Calls = @()
function script:gh { $script:Calls += ($args -join ' '); $global:LASTEXITCODE = 0; '{"id":"PVTI_new"}' }
$added  = Add-IssueToBoard -IssueNumber 42
$again  = Add-IssueToBoard -IssueNumber 42
[pscustomobject]@{
    added  = $added
    again  = $again
    itemId = (Get-ProjectItemId -IssueNumber 42)
    calls  = @($script:Calls).Count
    url    = ($script:Calls[0] -match 'issues/42')
} | ConvertTo-Json -Compress
"""
    )
    # Added once; the second call finds it in the cache instead of calling gh again.
    assert out == {
        "added": True,
        "again": True,
        "itemId": "PVTI_new",
        "calls": 1,
        "url": True,
    }


def test_board_unreadable_means_no_add() -> None:
    out = _run(
        r"""
$script:KanbanProjectNumber = 5
$script:_CachedItems = $null
$script:_ItemsFailed = $true
function script:gh { throw 'gh must not be called when the board could not be read' }
[pscustomobject]@{ added = (Add-IssueToBoard -IssueNumber 42) } | ConvertTo-Json -Compress
"""
    )
    assert out == {"added": False}


def test_pending_decisions_skip_the_llm_stages(tmp_path: Path) -> None:
    """An already-refined issue that still waits on a decision must not re-run
    refine/architect/plan: each closed decision issue then costs one cheap check.

    Runs in tmp_path — the conductor's finally block resets git, which must never
    touch the repository under test.
    """
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        r"""
function script:Write-Log { param($Message, $Color) }
function script:Assert-EngineReady {}
function script:Acquire-OrchestratorLock { param($IssueNumber) $true }
function script:Release-OrchestratorLock {}
function script:Add-IssueToBoard { param($IssueNumber) $true }
function script:Resolve-DecisionAnswers { param($IssueNumber) 1 }
function script:Get-IssueState {
    param($IssueNumber)
    [pscustomobject]@{
        readiness      = [pscustomobject]@{ refined = [pscustomobject]@{ done = $true } }
        open_questions = @([pscustomobject]@{ text = 'still open'; child_issue = 12 })
    }
}
function script:Invoke-Refine    { throw 'refine must not re-run while decisions are pending' }
function script:Invoke-Architect { throw 'architect must not re-run while decisions are pending' }
function script:Invoke-Plan      { throw 'plan must not re-run while decisions are pending' }
function script:Set-AgentFailedState { throw 'must not fail' }
function script:gh { $global:LASTEXITCODE = 0; '{"title":"t","labels":[],"state":"OPEN"}' }
function script:git { $global:LASTEXITCODE = 1 }
$r = Invoke-Orchestration -From refine -IssueNumber 50
[pscustomobject]@{ result = $r } | ConvertTo-Json -Compress
}
"""
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout.strip().splitlines()[-1]) == {"result": False}
