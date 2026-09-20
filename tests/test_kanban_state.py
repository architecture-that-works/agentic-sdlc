"""Tests for the issue-carried orchestrator state schema.

Two complementary surfaces are exercised:

1. ``src/utils/m_planning.py`` — the pydantic contract for the on-issue JSON
   block. Asserts that the model round-trips to/from JSON without data loss.
2. ``.github/orchestrator/_common.ps1`` § Test-StateTransition — the 4-lane
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
from pydantic import ValidationError

from src.utils.m_planning import (
    AgentBrief,
    GlossaryDiff,
    GrillResult,
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

# Mirrors the allowed-transitions table from .github/orchestrator/_common.ps1.
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
        check=False,
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


# ── Self-grill subagent contract (issue #85) ─────────────────────────────────


def test_grill_result_validates_minimal_payload() -> None:
    """Smallest valid GrillResult: brief + empty question/diff lists."""
    payload = {
        "agent_brief": {
            "feature_name": "self-grill-subagent",
            "problem_statement": "AFK refine needs an actual alignment phase.",
        },
        "open_questions": [],
        "decided_questions": [],
        "glossary_diffs": [],
    }
    result = GrillResult.model_validate(payload)
    assert result.agent_brief.feature_name == "self-grill-subagent"
    assert result.open_questions == []
    assert result.decided_questions == []
    assert result.glossary_diffs == []


def test_grill_result_round_trips_full_payload() -> None:
    """A populated GrillResult must round-trip JSON without losing any field."""
    payload = {
        "agent_brief": {
            "feature_name": "sse-endpoint",
            "problem_statement": "Browser needs streaming completions.",
            "interfaces": ["GET /stream?q=<prompt> -> text/event-stream"],
            "constraints": ["ADR-003: Standard Library First"],
            "out_of_scope": ["Multi-turn streaming"],
            "tracer_bullet": "GET /stream?q=hello -> 3 tokens -> [DONE]",
        },
        "open_questions": [
            {
                "text": "Authentication model for /stream?",
                "raised_by": "self-grill-subagent",
                "decision": "Recommend: bearer token — consistent with existing endpoints.",
            }
        ],
        "decided_questions": [
            {
                "text": "Use SSE rather than chunked encoding?",
                "raised_by": "self-grill-subagent",
                "decided_by": "self-grill-subagent",
                "decision": "SSE — evidence: ADR-010 already accepts SSE.",
            }
        ],
        "glossary_diffs": [
            {
                "term": "SSE Endpoint",
                "definition": "GET endpoint returning text/event-stream.",
                "disambiguation": "Not WebSocket — no bidirectional channel.",
                "action": "add",
            }
        ],
    }
    result = GrillResult.model_validate(payload)

    dumped = result.model_dump_json(by_alias=True)
    restored = GrillResult.model_validate(json.loads(dumped))
    assert restored.model_dump(by_alias=True) == result.model_dump(by_alias=True)


def test_grill_result_rejects_missing_agent_brief() -> None:
    """agent_brief is required — refine must abort if the subagent omits it."""
    with pytest.raises(ValidationError):
        GrillResult.model_validate({"open_questions": [], "decided_questions": []})


def test_agent_brief_holds_only_interface_terms() -> None:
    """The brief carries contracts, not file paths (Rule 4)."""
    brief = AgentBrief(
        feature_name="grill-me-afk",
        problem_statement="Phase-1 refine is a JSON formatter, not alignment.",
        interfaces=["GrillResult JSON -> AGENT-BRIEF + AGENT-STATE blocks"],
        constraints=["ADR-011: issue body is the carrier"],
    )
    assert brief.interfaces[0].startswith("GrillResult")
    assert brief.tracer_bullet is None  # optional


def test_glossary_diff_defaults_to_add_action() -> None:
    diff = GlossaryDiff(term="HITL child issue", definition="Decision needed.")
    assert diff.action == "add"


def test_glossary_diff_action_constrained() -> None:
    """The action enum is Literal['add','revise','remove']."""
    with pytest.raises(ValidationError):
        GlossaryDiff.model_validate(
            {"term": "X", "definition": "Y", "action": "invent"}
        )


# ── populated_by provenance — phase-1 stub vs. self-grill (issue #85) ────────


def test_self_grill_populated_by_string_round_trips() -> None:
    """The readiness flag must accept the 'self-grill-subagent' string set by
    Invoke-Refine, not just the phase-1 stub provenance."""
    now = datetime.now(UTC)
    state = PlanningState(
        issue_number=85,
        readiness=Readiness(
            refined=ReadinessFlag(
                done=True, populated_by="self-grill-subagent", timestamp=now
            ),
        ),
    )
    dumped = state.model_dump_json(by_alias=True)
    restored = PlanningState.model_validate(json.loads(dumped))
    assert restored.readiness.refined.populated_by == "self-grill-subagent"


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
