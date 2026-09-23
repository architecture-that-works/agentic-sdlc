"""Tests for the issue-carried orchestrator state schema.

``src/utils/m_planning.py`` is the pydantic contract for the AGENT-STATE JSON block
in the issue body (ADR-011) and for the self-grill result. The tests assert that the
models round-trip to and from JSON without data loss and enforce the readiness gate.
"""

from __future__ import annotations

import json
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
    diff = GlossaryDiff(
        term="human:decision child issue", definition="Decision needed."
    )
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
