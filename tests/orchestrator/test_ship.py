"""Tests for the ship stage's human-approval hold (.github/orchestrator/stages/Ship.ps1).

human:approval is a state the pipeline sets, like human:decision: ship decides it
from the PR's actual diff once CI is green. A PR touching a governance file is held
for the owner to merge; any other PR merges. The owner can still force a hold by
adding the label. When the owner merges or closes a held PR, Complete-HeldPR ships
the issue or re-opens it for a comment. gh and git are in-memory fakes at module
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


def test_governance_files_are_matched_against_the_diff() -> None:
    out = _run(
        r"""
function script:gh { $global:LASTEXITCODE = 0
    'src/utils/m_version.py'; 'tests/utils/test_m_version.py'; '.github/workflows/stale.yml'; 'docs/adr/ADR-003-observability.md'; 'SECURITY.md' }
[pscustomobject]@{ files = @(Get-GovernanceFiles -PRNumber 9) } | ConvertTo-Json -Compress
"""
    )
    assert out["files"] == [
        ".github/workflows/stale.yml",
        "docs/adr/ADR-003-observability.md",
        "SECURITY.md",
    ]


# Invoke-Ship up to the merge: branch checkout, rebase and a green CI poll are faked.
_SHIP = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:Labels = @()
function script:Get-IssueLabel { param($IssueNumber) $script:Labels }
function script:Test-HoldAnnounced { param($IssueNumber) $false }
$script:State = $null
function script:Get-IssueState { param($IssueNumber) $script:State }
function script:Invoke-RebaseOnMaster { param($IssueNumber, $Branch) }
function script:Invoke-ContextUpdate { param($IssueNumber) }
function script:Set-IssueLabel { param($Number, $Add, $Remove) $script:Log.Add("label:+$Add") }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:" + ($Body -split "`n")[0]) }
function script:git { $global:LASTEXITCODE = 0; if ($args[0] -eq 'rev-parse') { 'feature/1-x' } }
function script:gh { $global:LASTEXITCODE = 0
    switch ($args[1]) {
        'view'   { 'feature/1-x' }
        'checks' { '[{"name":"test","bucket":"pass"}]' }
        'diff'   { $script:Diff }
        'merge'  { $script:Log.Add('merged') }
    } }
"""


def test_governance_change_is_held_after_green_ci(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/x.py', '.github/workflows/stale.yml')
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is False
    assert "merged" not in out["log"]
    # One pipeline label (#225): the hold replaces agent:reviewing.
    assert "state:human:approval" in out["log"]
    assert "state:agent:reviewing" not in out["log"]
    assert not any(e.startswith("label:") for e in out["log"])
    assert "comment:🤖⏸ Held for human approval" in out["log"]


def test_ordinary_change_merges(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/utils/m_version.py', 'tests/utils/test_m_version.py')
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is True
    assert "merged" in out["log"]
    assert "state:human:approval" not in out["log"]


def test_owner_label_still_forces_a_hold(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/x.py')
$script:Labels = @('human:approval')
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is False and "merged" not in out["log"]


def test_owner_hold_kept_in_the_carrier_still_forces_a_hold(tmp_path: Path) -> None:
    """The owner's label was replaced by a later state (#225); the carrier keeps it."""
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/x.py')
$script:State = [pscustomobject]@{ approval_required = $true }
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is False and "merged" not in out["log"]
    assert "state:human:approval" in out["log"]


def test_announced_hold_is_not_repeated(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('SECURITY.md')
$script:Labels = @('human:approval')
function script:Test-HoldAnnounced { param($IssueNumber) $true }
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out == {"r": False, "log": []}


# The owner merges or closes a held PR (afk.yml, pull_request closed).
_HELD = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:Labels = @('human:approval')
function script:Get-IssueLabel { param($IssueNumber) $script:Log.Add("read:$IssueNumber"); $script:Labels }
function script:Set-IssueLabel { param($Number, $Add, $Remove) $script:Log.Add("label:-$Remove") }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Set-AgentFailedState { param($IssueNumber, $FailedAt, $Reason) $script:Log.Add("failed:$FailedAt") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:" + ($Body -split "`n")[0]) }
function script:Invoke-ContextUpdate { param($IssueNumber) $script:Log.Add("context:$IssueNumber") }
function script:git { $global:LASTEXITCODE = 0 }
"""


def _held(call: str, tmp_path: Path) -> list[str]:
    out = _run(
        _HELD
        + call
        + "\n[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress",
        tmp_path,
    )
    return out["log"]


def test_owner_merge_of_a_held_pr_ships_the_issue(tmp_path: Path) -> None:
    log = _held(
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $true", tmp_path
    )
    assert log == [
        "read:212",
        "state:agent:shipped",
        "comment:🤖✅ Merged",
        "context:212",
    ]


def test_owner_close_of_a_held_pr_waits_for_their_comment(tmp_path: Path) -> None:
    log = _held(
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $false", tmp_path
    )
    assert "failed:review" in log
    assert "comment:🤖⏸ PR #9 closed without merging" in log
    assert "state:agent:shipped" not in log


def test_pr_that_was_never_held_is_left_alone(tmp_path: Path) -> None:
    unheld = _held(
        "$script:Labels = @('agent:shipped')\n"
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $true",
        tmp_path,
    )
    assert unheld == ["read:212"]
    foreign = _held(
        "Complete-HeldPR -PRNumber 9 -Branch 'dependabot/x' -Merged $true", tmp_path
    )
    assert foreign == []
