"""Get-UnwritablePaths — the one "outside the write allowlist" predicate
(.github/orchestrator/stages/Refine.ps1).

It answers the same question at two moments: the plan stage calls it on the
planned paths to warn early, and the ship stage calls it on the PR's real diff
(Get-ProposedFiles) to decide whether the PR is a proposal the owner approves.
One definition, because two would drift — the shape of #252, #266 and #275.

History worth keeping: this started as a *gate* (#223). A plan touching any path
outside the allowlist was parked at human:decision with an injected question,
because commit-time staging would otherwise abort three times and burn the retry
budget. That question turned out to be unanswerable — Invoke-Plan regenerates it
from the plan on every run, so answering it re-ran plan, which re-created it, and
#273 looped three times. Since #285 the paths are committed as proposals and the
PR is held instead, so this predicate classifies rather than blocks.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
REPO_ROOT = Path(__file__).parent.parent.parent
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )


def _import_prelude() -> str:
    """Module-scope invocation (`& (Get-Module Orchestrator) { ... }`) — the same
    pattern test_plan.py uses: Get-UnwritablePaths is private (ADR-015's explicit
    FunctionsToExport), so it's reachable only inside the module's own session
    state, not via Import-Module alone."""
    return (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
    )


def _unwritable(paths: list[str]) -> list[str]:
    array = ", ".join(f"'{p}'" for p in paths)
    script = (
        _import_prelude()
        + f"Get-UnwritablePaths -Paths @({array}) | ConvertTo-Json -Compress\n"
        + "}\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    out = result.stdout.strip()
    if not out:
        return []
    import json

    parsed = json.loads(out)
    return parsed if isinstance(parsed, list) else [parsed]


def test_fully_writable_plan_returns_empty() -> None:
    assert (
        _unwritable(["src/main.py", "tests/test_main.py", "docs/adr/ADR-000-x.md"])
        == []
    )


def test_partly_writable_plan_names_only_the_blocked_paths() -> None:
    result = _unwritable(
        [
            "src/main.py",
            ".github/workflows/checks.yml",
            ".github/tasks/reconcile.ps1",
        ]
    )
    assert result == [
        ".github/workflows/checks.yml",
        ".github/tasks/reconcile.ps1",
    ]


def test_fully_non_writable_plan_names_every_path() -> None:
    result = _unwritable(
        [
            ".github/orchestrator/stages/Plan.ps1",
            ".github/orchestrator/stages/Refine.ps1",
        ]
    )
    assert result == [
        ".github/orchestrator/stages/Plan.ps1",
        ".github/orchestrator/stages/Refine.ps1",
    ]


def test_empty_plan_is_writable() -> None:
    assert _unwritable([]) == []


def test_an_empty_allowlist_makes_every_path_unwritable() -> None:
    """Fail-safe. Losing the allowlist must mean "everything needs approval", never
    "anything merges unreviewed"."""
    script = (
        _import_prelude()
        + "$OrchestratorConfig.WritablePaths = @()\n"
        + "Get-UnwritablePaths -Paths @('src/a.py', 'tests/b.py') | ConvertTo-Json -Compress\n"
        + "}\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    import json

    assert json.loads(result.stdout.strip()) == ["src/a.py", "tests/b.py"]


def test_the_plan_stage_no_longer_asks_an_unanswerable_question() -> None:
    """The #273 loop: the injected question was regenerated from the plan on every
    run, so answering it re-ran architect and plan, which re-created it. No reply
    could ever clear it — not even its own recommended answer, which was "go
    implement it by hand".

    Invoke-Plan must now record the paths and leave open_questions untouched, and
    must strip a legacy question so issues the old gate parked unblock on their
    next run rather than needing the carrier edited by hand.
    """
    script = (
        _import_prelude()
        + r"""
function script:Write-Log { param($Message, $Color) }
function script:Get-IssueEstimate { param($IssueNumber) 3 }
function script:Set-IssueBodySection { param($IssueNumber, $BeginMarker, $EndMarker, $Markdown) $true }
function script:Set-PlanningReadiness { param($IssueNumber, $Stage, $StageLabel, $PopulatedBy) }
function script:Format-OwnerComments { param($IssueNumber) '' }
function script:Add-Comment { param($Number, $Body) $script:Comments.Add(($Body -split "`n")[0]) }
function script:Set-PlanningState { param($IssueNumber, $State) $script:Saved = $State }
function script:Get-IssueState { param($IssueNumber) $script:State }
function script:claude { $global:LASTEXITCODE = 0
    '{"plan_markdown":"1. do it","paths_to_modify":["src/a.py",".github/workflows/x.yml"]}' }
function script:gh { $global:LASTEXITCODE = 0; '{"title":"t","body":"b"}' }

$script:Comments = [System.Collections.Generic.List[string]]::new()
# A legacy question from the old gate, plus a real one that must survive.
$script:State = [pscustomobject]@{ open_questions = @(
    [pscustomobject]@{ text = 'This plan touches paths outside the agent-writable allowlist and cannot be auto-implemented: x.' },
    [pscustomobject]@{ text = 'Which database should this use?' }
) }

Invoke-Plan -Number 7

[pscustomobject]@{
    questions = @($script:Saved.open_questions | ForEach-Object { $_.text })
    proposed  = @($script:Saved.proposed_paths)
    announced = [bool](@($script:Comments) -match 'Proposal')
} | ConvertTo-Json -Compress
"""
        + "}\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    import json

    lines = [ln for ln in result.stdout.splitlines() if ln.startswith("{")]
    assert lines, result.stdout + result.stderr
    out = json.loads(lines[-1])

    # The legacy question is gone; the owner's real question is untouched.
    assert out["questions"] == ["Which database should this use?"]
    # The out-of-allowlist path is recorded as a proposal, and announced on the issue.
    assert out["proposed"] == [".github/workflows/x.yml"]
    assert out["announced"] is True


def test_an_unreadable_carrier_does_not_crash_the_plan_stage() -> None:
    """Get-IssueState returns $null when the AGENT-STATE block cannot be parsed.
    The proposal note is a convenience — ship re-derives the hold from the PR diff
    — so losing it must cost a warning, not the stage."""
    script = (
        _import_prelude()
        + r"""
function script:Write-Log { param($Message, $Color) }
function script:Get-IssueEstimate { param($IssueNumber) 3 }
function script:Set-IssueBodySection { param($IssueNumber, $BeginMarker, $EndMarker, $Markdown) $true }
function script:Set-PlanningReadiness { param($IssueNumber, $Stage, $StageLabel, $PopulatedBy) }
function script:Format-OwnerComments { param($IssueNumber) '' }
function script:Add-Comment { param($Number, $Body) }
function script:Set-PlanningState { param($IssueNumber, $State) throw 'must not be called with a null state' }
function script:Get-IssueState { param($IssueNumber) $null }
function script:claude { $global:LASTEXITCODE = 0
    '{"plan_markdown":"1. do it","paths_to_modify":[".github/workflows/x.yml"]}' }
function script:gh { $global:LASTEXITCODE = 0; '{"title":"t","body":"b"}' }

Invoke-Plan -Number 7
[pscustomobject]@{ survived = $true } | ConvertTo-Json -Compress
"""
        + "}\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert '"survived":true' in result.stdout.replace(" ", "")
