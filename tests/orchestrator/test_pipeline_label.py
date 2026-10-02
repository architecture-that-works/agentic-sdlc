"""One pipeline label per issue (#225) — lib/GitHub.ps1 Set-AgentState.

The pipeline labels are the `agent:*` states plus the two `human:*` holds
(`human:decision`, `human:approval`). An issue carries exactly one of them: setting
one replaces whichever the issue has, other labels are untouched, and the board lane
follows. An owner's `human:approval` is a merge-hold request: when a later state
replaces the label, the request is kept in the carrier (`approval_required`) so the
ship stage still holds the PR.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")

_FAKES = r"""
$script:Current = @()
$script:Lanes = [System.Collections.Generic.List[string]]::new()
$script:State = [pscustomobject]@{ open_questions = @() }
function script:Write-Log { param($Message, $Color) }
function script:Get-IssueLabel { param($IssueNumber) @($script:Current) }
function script:Set-IssueLabel { param($Number, $Add = '', $Remove = '')
    if ($Remove) { $script:Current = @($script:Current | Where-Object { $_ -ne $Remove }) }
    if ($Add)    { $script:Current = @($script:Current) + $Add } }
function script:Move-ToLane { param($IssueNumber, $OptionId, $LaneName) $script:Lanes.Add($LaneName) }
function script:Get-IssueState { param($IssueNumber) $script:State }
function script:Set-PlanningState { param($IssueNumber, $State) $script:State = $State }
function script:Test-Readiness { param($State) $true }
$script:KanbanOpt_Backlog = 'b'; $script:KanbanOpt_Implementing = 'i'
$script:KanbanOpt_Review = 'r';  $script:KanbanOpt_Merged = 'm'
function Pipeline { @($script:Current | Where-Object { $_ -like 'agent:*' -or $_ -like 'human:*' }) }
"""


def _run(body: str) -> dict:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        f"{_FAKES}\n{body}\n"
        "}\n"
    )
    out = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert out.returncode == 0, out.stderr
    lines = [ln for ln in out.stdout.splitlines() if ln.startswith("{")]
    assert lines, out.stdout + out.stderr
    return json.loads(lines[-1])


def test_every_transition_leaves_exactly_one_pipeline_label() -> None:
    out = _run(
        r"""
$script:Current = @('human:decision', 'enhancement')
$after = foreach ($l in 'agent:backlog', 'agent:implementing', 'agent:reviewing', 'human:approval', 'agent:shipped') {
    Set-AgentState -IssueNumber 1 -Label $l
    (Pipeline) -join ','
}
[pscustomobject]@{ after = @($after); all = @($script:Current); lanes = @($script:Lanes) } | ConvertTo-Json -Compress
"""
    )
    assert out["after"] == [
        "agent:backlog",
        "agent:implementing",
        "agent:reviewing",
        "human:approval",
        "agent:shipped",
    ]
    assert out["all"] == ["enhancement", "agent:shipped"]  # other labels untouched
    assert out["lanes"] == ["Backlog", "Implementing", "Review", "Review", "Shipped"]


def test_a_human_hold_replaces_the_agent_state() -> None:
    out = _run(
        r"""
$script:Current = @('agent:failed')
Set-AgentState -IssueNumber 1 -Label 'human:decision'
[pscustomobject]@{ labels = @(Pipeline); lanes = @($script:Lanes) } | ConvertTo-Json -Compress
"""
    )
    assert out == {"labels": ["human:decision"], "lanes": ["Backlog"]}


def test_an_owner_hold_survives_a_later_state() -> None:
    """An owner adds human:approval while the issue is in flight; the next state
    replaces the label, and the hold request moves into the carrier."""
    out = _run(
        r"""
$script:Current = @('agent:implementing', 'human:approval')
Set-AgentState -IssueNumber 1 -Label 'agent:reviewing'
[pscustomobject]@{ labels = @(Pipeline); required = [bool]$script:State.approval_required } | ConvertTo-Json -Compress
"""
    )
    assert out == {"labels": ["agent:reviewing"], "required": True}


def test_shipping_a_held_issue_does_not_carry_the_hold() -> None:
    out = _run(
        r"""
$script:Current = @('human:approval')
Set-AgentState -IssueNumber 1 -Label 'agent:shipped'
[pscustomobject]@{ labels = @(Pipeline); required = [bool]$script:State.approval_required } | ConvertTo-Json -Compress
"""
    )
    assert out == {"labels": ["agent:shipped"], "required": False}
