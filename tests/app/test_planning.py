"""The issue-carried state schema (``src/utils/m_planning.py``), by what it does.

``PlanningState`` is the AGENT-STATE block in the issue body (ADR-011); ``GrillResult``
is the self-grill answer refine validates before it writes anything back. The
properties hold for any valid state; the examples cover what the properties do not
reach: the JSON keys of a transition and the rules a grill answer must follow.
"""

from __future__ import annotations

import json

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from pydantic import ValidationError

from src.utils.m_planning import (
    GrillResult,
    Lane,
    PlanningState,
    Question,
    Readiness,
    ReadinessFlag,
    Transition,
)

_text_or_none = st.one_of(st.none(), st.text(min_size=1, max_size=80))

_readiness_flag = st.builds(
    ReadinessFlag,
    done=st.booleans(),
    populated_by=_text_or_none,
    timestamp=st.none(),
)

_question = st.builds(
    Question,
    text=st.text(min_size=1, max_size=200),
    raised_by=_text_or_none,
    decided_by=st.none(),
    decision=st.none(),
    timestamp=st.none(),
)

_planning_state = st.builds(
    PlanningState,
    issue_number=st.integers(min_value=1, max_value=999_999),
    lane=st.sampled_from(Lane),
    readiness=st.builds(
        Readiness,
        refined=_readiness_flag,
        architected=_readiness_flag,
        planned=_readiness_flag,
    ),
    open_questions=st.lists(_question, max_size=5),
    decided_questions=st.lists(_question, max_size=5),
    transitions=st.just([]),
)


@given(_planning_state)
def test_ready_for_backlog_only_when_every_flag_is_done_and_no_question_is_open(
    state: PlanningState,
) -> None:
    expected = (
        state.readiness.refined.done
        and state.readiness.architected.done
        and state.readiness.planned.done
        and len(state.open_questions) == 0
    )
    assert state.is_ready_for_backlog() == expected


@given(_planning_state)
@settings(max_examples=50)
def test_any_state_survives_a_trip_through_json(state: PlanningState) -> None:
    restored = PlanningState.model_validate(json.loads(state.model_dump_json()))
    assert restored == state


def test_a_transition_is_written_with_the_from_and_to_keys() -> None:
    # 'from' is a Python keyword, so the model reads and writes it through an alias.
    payload = {
        "from": "backlog",
        "to": "implementing",
        "runtime": "laptop",
        "timestamp": "2026-01-01T00:00:00Z",
    }
    transition = Transition.model_validate(payload)
    assert (transition.from_lane, transition.to_lane) == (
        Lane.BACKLOG,
        Lane.IMPLEMENTING,
    )

    out = transition.model_dump(by_alias=True, mode="json")
    assert (out["from"], out["to"]) == ("backlog", "implementing")
    assert "from_lane" not in out


def test_a_grill_answer_needs_only_a_brief() -> None:
    result = GrillResult.model_validate(
        {
            "agent_brief": {
                "feature_name": "self-grill-subagent",
                "problem_statement": "AFK refine needs an actual alignment phase.",
            }
        }
    )
    assert result.open_questions == []
    assert result.decided_questions == []
    assert result.glossary_diffs == []
    assert result.agent_brief.tracer_bullet is None


def test_a_full_grill_answer_survives_a_trip_through_json() -> None:
    result = GrillResult.model_validate(
        {
            "agent_brief": {
                "feature_name": "sse-endpoint",
                "problem_statement": "Browser needs streaming completions.",
                "interfaces": ["GET /stream?q=<prompt> -> text/event-stream"],
                "constraints": ["Standard Library First"],
                "out_of_scope": ["Multi-turn streaming"],
                "tracer_bullet": "GET /stream?q=hello -> 3 tokens -> [DONE]",
            },
            "open_questions": [
                {
                    "text": "Authentication model for /stream?",
                    "decision": "Bearer token.",
                    "alternatives": ["Session cookie", "None"],
                }
            ],
            "decided_questions": [{"text": "SSE?", "decision": "Yes."}],
            "glossary_diffs": [{"term": "SSE Endpoint", "definition": "GET stream."}],
        }
    )
    assert result.glossary_diffs[0].action == "add"

    restored = GrillResult.model_validate(json.loads(result.model_dump_json()))
    assert restored == result


@pytest.mark.parametrize(
    "payload",
    [
        pytest.param({"open_questions": []}, id="no brief"),
        pytest.param(
            {
                "agent_brief": {"feature_name": "x", "problem_statement": "y"},
                "glossary_diffs": [
                    {"term": "X", "definition": "Y", "action": "invent"}
                ],
            },
            id="unknown glossary action",
        ),
    ],
)
def test_refine_rejects_a_grill_answer_that_breaks_the_contract(payload) -> None:
    with pytest.raises(ValidationError):
        GrillResult.model_validate(payload)
