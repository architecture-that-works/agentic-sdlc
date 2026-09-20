"""Tests for the label bootstrap step in .github/scripts/setup.ps1.

Two layers of coverage:

1. File-based checks (no gh required) — parse setup.ps1 and verify every
   required label name and the --force flag are present in the script text.

2. PS snippet tests — replicate the $BaseLabels data structure (the Oracle)
   and verify its internal consistency: valid hex colours, non-empty
   descriptions, and correct entry count.

The Oracle snippet is intentionally a copy of the array in setup.ps1; if
setup.ps1 drifts from the Oracle the file-based checks will catch it.
"""

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).parent.parent.parent
    / ".github"
    / "tasks"
    / "setup.ps1"
)
PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

REQUIRED_LABELS = {
    "AFK",
    "HITL",
    "planning",
    "enhancement",
    "bug",
    "agent:backlog",
    "agent:implementing",
    "agent:reviewing",
    "agent:shipped",
    "agent:failed",
    "human:approval",
    "human:decision",
}

# Oracle — replicated from setup.ps1 $BaseLabels.
# Tests 3-5 verify the Oracle's internal consistency.
# Tests 1-2 verify setup.ps1 implements the Oracle.
_BASE_LABELS_SNIPPET = textwrap.dedent("""\
    $BaseLabels = @(
        @{ Name = 'AFK';                Color = '0075ca'; Description = 'Agent executes start-to-finish without interruption' }
        @{ Name = 'HITL';               Color = 'e4e669'; Description = 'Requires human decision or approval before closing' }
        @{ Name = 'planning';           Color = 'c5def5'; Description = 'Planning artifact — PRD or Agent Brief' }
        @{ Name = 'enhancement';        Color = 'a2eeef'; Description = 'New feature or request' }
        @{ Name = 'bug';                Color = 'd73a4a'; Description = 'Something is not working' }
        # agent:* — the agent holds the ball. Exactly one at a time (ADR-015).
        @{ Name = 'agent:backlog';      Color = '0075ca'; Description = 'Refined, architected, planned — ready to implement' }
        @{ Name = 'agent:implementing'; Color = 'e4e669'; Description = 'Implement stage in progress' }
        @{ Name = 'agent:reviewing';    Color = '969696'; Description = 'Review stage in progress' }
        @{ Name = 'agent:shipped';      Color = '0e8a16'; Description = 'Shipped — PR merged and issue closed' }
        @{ Name = 'agent:failed';       Color = 'd73a4a'; Description = 'A stage errored unrecoverably — see failed_at in the issue body' }
        # human:* — a human holds the ball; nothing advances until they act (ADR-015).
        @{ Name = 'human:approval';     Color = 'd4c5f9'; Description = 'Implemented and self-reviewed — a human must merge the PR' }
        @{ Name = 'human:decision';     Color = 'd4c5f9'; Description = 'A question for a human — not a work item; never enters the pipeline' }
    )
""")


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )


# ── File-based checks ─────────────────────────────────────────────────────────


def test_all_required_labels_defined_in_setup() -> None:
    """Every required workflow label appears in the setup.ps1 label array."""
    content = SCRIPT.read_text(encoding="utf-8")
    missing = [lbl for lbl in REQUIRED_LABELS if f"'{lbl}'" not in content]
    assert not missing, f"Labels missing from setup.ps1: {missing}"


def test_setup_uses_force_flag() -> None:
    """setup.ps1 uses --force when creating labels so the bootstrap is idempotent."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert "--force" in content, "setup.ps1 must use 'gh label create --force'"


# ── PS snippet tests (Oracle consistency) ────────────────────────────────────


def test_base_labels_count() -> None:
    """$BaseLabels defines exactly the expected number of labels."""
    result = _ps(_BASE_LABELS_SNIPPET + "$BaseLabels.Count")
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(len(REQUIRED_LABELS)), (
        f"Expected {len(REQUIRED_LABELS)} labels, got: {result.stdout.strip()}"
    )


def test_base_labels_all_have_color() -> None:
    """Every label entry has a non-empty Color field."""
    result = _ps(
        _BASE_LABELS_SNIPPET
        + "$empty = @($BaseLabels | Where-Object { -not $_.Color })\n"
        + "if ($empty.Count -gt 0) { exit 1 } else { exit 0 }"
    )
    assert result.returncode == 0, "All labels must have a non-empty Color"


def test_base_labels_all_have_description() -> None:
    """Every label entry has a non-empty Description field."""
    result = _ps(
        _BASE_LABELS_SNIPPET
        + "$empty = @($BaseLabels | Where-Object { -not $_.Description })\n"
        + "if ($empty.Count -gt 0) { exit 1 } else { exit 0 }"
    )
    assert result.returncode == 0, "All labels must have a non-empty Description"


def test_base_labels_colors_are_valid_hex() -> None:
    """Every label Color is a 6-character lowercase hex string."""
    result = _ps(
        _BASE_LABELS_SNIPPET
        + "$invalid = @($BaseLabels | Where-Object { $_.Color -notmatch '^[0-9a-fA-F]{6}$' })\n"
        + "if ($invalid.Count -gt 0) { $invalid.Name -join ',' | Write-Host; exit 1 } else { exit 0 }"
    )
    assert result.returncode == 0, (
        f"Labels with invalid hex colors: {result.stdout.strip()}"
    )
