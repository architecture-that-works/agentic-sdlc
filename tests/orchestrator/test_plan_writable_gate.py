"""Tests for the writable-path gate in Invoke-Plan (.github/orchestrator/stages/Refine.ps1).

An issue whose Implementation Plan only touches paths inside WritablePaths is
granted agent:backlog as before. A plan that touches ANY path outside it used to
reach agent:backlog anyway, get implemented, and abort at commit-time staging —
three times — before landing on agent:failed, burning the whole retry budget on
a predictable outcome (#223, reproduced by #211: a plan that only creates
.github/workflows/stale-prs.yml and .github/tasks/stale-prs.ps1).

Get-UnwritablePaths is the gate: it returns the subset of a plan's
paths_to_modify that WritablePaths does not cover, using the same -like glob
matching Invoke-CommitAndPR applies at commit time. An empty result means the
plan is fully writable; any entry means Invoke-Plan holds the issue at
human:decision instead of letting it reach agent:backlog.
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
            ".github/workflows/stale-prs.yml",
            ".github/tasks/stale-prs.ps1",
        ]
    )
    assert result == [
        ".github/workflows/stale-prs.yml",
        ".github/tasks/stale-prs.ps1",
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
