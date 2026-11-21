"""Tests for Get-PhaseModel — the estimate-driven model selector in lib/Config.ps1.

Acceptance criteria (issue #339):
  implement 0, 1, 2  → Sonnet tier  (claude-sonnet-5-5)
  implement 3, 5, 8  → Opus tier    (claude-opus-5-5)
  review (any SP)    → Opus tier
  refine, plan       → Opus tier
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


def _run_phase_model(cases: list[tuple[int, str]]) -> dict:
    """Call Get-PhaseModel for each (Estimate, Phase) pair; return {key: model} dict."""
    assignments = "\n".join(
        f"$r['{estimate}:{phase}'] = Get-PhaseModel -Estimate {estimate} -Phase '{phase}'"
        for estimate, phase in cases
    )
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        "$r = @{}\n"
        f"{assignments}\n"
        "$r | ConvertTo-Json -Compress\n"
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


def test_implement_low_sp_uses_sonnet() -> None:
    """Estimates 0, 1 and 2 (at or below OpusImplementThreshold=2) → Sonnet tier."""
    data = _run_phase_model([(0, "implement"), (1, "implement"), (2, "implement")])
    assert data["0:implement"] == "claude-sonnet-5-5"
    assert data["1:implement"] == "claude-sonnet-5-5"
    assert data["2:implement"] == "claude-sonnet-5-5"


def test_implement_high_sp_uses_opus() -> None:
    """Estimates 3, 5 and 8 (above OpusImplementThreshold=2) → Opus tier."""
    data = _run_phase_model([(3, "implement"), (5, "implement"), (8, "implement")])
    assert data["3:implement"] == "claude-opus-5-5"
    assert data["5:implement"] == "claude-opus-5-5"
    assert data["8:implement"] == "claude-opus-5-5"


def test_review_always_uses_opus() -> None:
    """Review always routes to Opus regardless of estimate."""
    data = _run_phase_model([(0, "review"), (3, "review"), (8, "review")])
    assert data["0:review"] == "claude-opus-5-5"
    assert data["3:review"] == "claude-opus-5-5"
    assert data["8:review"] == "claude-opus-5-5"


def test_refine_and_plan_use_opus() -> None:
    """Refine and plan phases route to the Opus tier."""
    data = _run_phase_model([(0, "refine"), (0, "plan")])
    assert data["0:refine"] == "claude-opus-5-5"
    assert data["0:plan"] == "claude-opus-5-5"
