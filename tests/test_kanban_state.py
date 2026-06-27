"""Tests for the issue-carried orchestrator state schema.

Two complementary surfaces are exercised:

1. ``src/utils/m_planning.py`` — the pydantic contract for the on-issue JSON
   block. Asserts that the model round-trips to/from JSON without data loss.
2. ``.github/scripts/kanban/_common.ps1`` § Test-StateTransition — the 4-lane
   FSM guard. Asserts every allowed transition succeeds and every disallowed
   pair raises an error.

The PowerShell surface is verified via an inline snippet that mirrors the
allowed-transitions table from ``_common.ps1`` exactly, so the test never
needs the live gh/Kanban environment that dot-sourcing ``_common.ps1`` would
demand.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from datetime import UTC, datetime

import pytest

from src.utils.m_planning import (
    Lane,
    PlanningState,
    Question,
    Readiness,
    ReadinessFlag,
    Transition,
)

# ── PowerShell test harness ───────────────────────────────────────────────────

PWSH = shutil.which("pwsh") or "pwsh"

pytestmark_ps = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

# Mirrors the allowed-transitions table from .github/scripts/kanban/_common.ps1.
# Keep this snippet in lock-step with the production table — both are the
# 4-lane FSM contract and any divergence is a bug.
_FSM_SNIPPET = """\
$KanbanAllowedTransitions = @{
    'backlog'      = @('implementing')
    'implementing' = @('review', 'backlog')
    'review'       = @('merged', 'implementing', 'backlog')
    'merged'       = @()
}

function Test-StateTransition {
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    if (-not $KanbanAllowedTransitions.ContainsKey($From)) {
        throw "Unknown source lane '$From'."
    }
    if ($KanbanAllowedTransitions[$From] -notcontains $To) {
        throw "Illegal transition '$From' -> '$To'."
    }
    return $true
}
"""


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
    )


ALLOWED_TRANSITIONS: list[tuple[str, str]] = [
    ("backlog", "implementing"),
    ("implementing", "review"),
    ("review", "merged"),
    ("review", "implementing"),
    ("implementing", "backlog"),
    ("review", "backlog"),
]

LANES: list[str] = ["backlog", "implementing", "review", "merged"]

DISALLOWED_TRANSITIONS: list[tuple[str, str]] = [
    (a, b) for a in LANES for b in LANES if (a, b) not in ALLOWED_TRANSITIONS
]


# ── FSM allowed-transition coverage ──────────────────────────────────────────


@pytestmark_ps
@pytest.mark.parametrize(("src", "dst"), ALLOWED_TRANSITIONS)
def test_allowed_transition_succeeds(src: str, dst: str) -> None:
    """Every allowed 4-lane transition must clear Test-StateTransition."""
    result = _ps(
        _FSM_SNIPPET
        + f"if (Test-StateTransition -From '{src}' -To '{dst}') {{ exit 0 }} else {{ exit 1 }}"
    )
    assert result.returncode == 0, (
        f"Allowed transition '{src}' -> '{dst}' was rejected by Test-StateTransition.\n"
        f"stderr: {result.stderr}"
    )


@pytestmark_ps
@pytest.mark.parametrize(("src", "dst"), DISALLOWED_TRANSITIONS)
def test_disallowed_transition_rejected(src: str, dst: str) -> None:
    """Every pair NOT in the allowed-table must raise an error."""
    result = _ps(
        _FSM_SNIPPET
        + f"try {{ Test-StateTransition -From '{src}' -To '{dst}' | Out-Null; exit 0 }} catch {{ exit 1 }}"
    )
    assert result.returncode == 1, (
        f"Disallowed transition '{src}' -> '{dst}' was NOT rejected.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


@pytestmark_ps
def test_refining_architecting_planning_are_not_lanes() -> None:
    """The 4-lane FSM excludes refine/architect/plan — they are pre-backlog
    readiness gates, not lanes. Test-StateTransition must reject them."""
    for ghost_lane in ("refining", "architecting", "planning"):
        result = _ps(
            _FSM_SNIPPET
            + f"try {{ Test-StateTransition -From '{ghost_lane}' -To 'backlog' | Out-Null; exit 0 }} catch {{ exit 1 }}"
        )
        assert result.returncode == 1, (
            f"'{ghost_lane}' must NOT be a recognised source lane — refine/architect/plan are pre-backlog gates."
        )


# ── pydantic round-trip ──────────────────────────────────────────────────────


def test_planning_state_round_trips_through_json() -> None:
    """Full state object → JSON → object must preserve every field."""
    now = datetime.now(UTC)
    state = PlanningState(
        issue_number=78,
        lane=Lane.IMPLEMENTING,
        readiness=Readiness(
            refined=ReadinessFlag(
                done=True, populated_by="refine (phase-1 stub)", timestamp=now
            ),
            architected=ReadinessFlag(
                done=True, populated_by="architect (phase-1 stub)", timestamp=now
            ),
            planned=ReadinessFlag(
                done=True, populated_by="plan (phase-1 stub)", timestamp=now
            ),
        ),
        open_questions=[],
        decided_questions=[
            Question(
                text="Use issue body as the cross-runtime carrier?",
                raised_by="refine",
                decided_by="architect",
                decision="yes",
                timestamp=now,
            )
        ],
        transitions=[
            Transition.model_validate(
                {
                    "from": None,
                    "to": "backlog",
                    "runtime": "laptop",
                    "timestamp": now,
                }
            ),
            Transition.model_validate(
                {
                    "from": "backlog",
                    "to": "implementing",
                    "runtime": "github-actions",
                    "timestamp": now,
                }
            ),
        ],
    )

    dumped = state.model_dump_json(by_alias=True)
    restored = PlanningState.model_validate(json.loads(dumped))
    assert restored.model_dump(by_alias=True) == state.model_dump(by_alias=True)


def test_lane_enum_only_has_four_values() -> None:
    """Lane enum is the 4-lane FSM. No refining/architecting/planning."""
    assert {lane.value for lane in Lane} == {
        "backlog",
        "implementing",
        "review",
        "merged",
    }


def test_readiness_gate_blocks_on_missing_flag() -> None:
    """All three readiness flags + zero open questions are required."""
    state = PlanningState(issue_number=1)
    assert state.is_ready_for_backlog() is False

    state.readiness.refined.done = True
    state.readiness.architected.done = True
    state.readiness.planned.done = True
    assert state.is_ready_for_backlog() is True


def test_readiness_gate_blocks_on_open_questions() -> None:
    """An open question blocks backlog entry even with full readiness."""
    state = PlanningState(
        issue_number=2,
        readiness=Readiness(
            refined=ReadinessFlag(done=True),
            architected=ReadinessFlag(done=True),
            planned=ReadinessFlag(done=True),
        ),
        open_questions=[Question(text="Unresolved alignment question")],
    )
    assert state.is_ready_for_backlog() is False


def test_transition_alias_round_trip() -> None:
    """The 'from' field uses an alias because 'from' is a Python keyword.
    JSON in/out must use the 'from'/'to' keys, not 'from_lane'/'to_lane'."""
    payload = {
        "from": "backlog",
        "to": "implementing",
        "runtime": "laptop",
        "timestamp": "2026-01-01T00:00:00Z",
    }
    t = Transition.model_validate(payload)
    assert t.from_lane == Lane.BACKLOG
    assert t.to_lane == Lane.IMPLEMENTING

    out = t.model_dump(by_alias=True, mode="json")
    assert out["from"] == "backlog"
    assert out["to"] == "implementing"
    assert "from_lane" not in out
