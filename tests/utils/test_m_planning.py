"""Property-based tests for src/utils/m_planning.py.

Invariant-based coverage that complements the example-based tests in
tests/test_kanban_state.py. Uses Hypothesis to assert properties that must
hold for *any* valid PlanningState, not just hand-chosen examples.
"""

from __future__ import annotations

from hypothesis import given, settings
from hypothesis import strategies as st

from src.utils.m_planning import (
    Lane,
    PlanningState,
    Question,
    Readiness,
    ReadinessFlag,
)

# ── Composite strategies ──────────────────────────────────────────────────────

_text_or_none = st.one_of(st.none(), st.text(min_size=1, max_size=80))

_readiness_flag = st.builds(
    ReadinessFlag,
    done=st.booleans(),
    populated_by=_text_or_none,
    timestamp=st.none(),
)

_readiness = st.builds(
    Readiness,
    refined=_readiness_flag,
    architected=_readiness_flag,
    planned=_readiness_flag,
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
    readiness=_readiness,
    open_questions=st.lists(_question, max_size=5),
    decided_questions=st.lists(_question, max_size=5),
    transitions=st.just([]),
)


# ── Invariant tests ───────────────────────────────────────────────────────────


@given(_planning_state)
def test_is_ready_for_backlog_iff_all_flags_done_and_no_open_questions(
    state: PlanningState,
) -> None:
    """is_ready_for_backlog() is True iff every readiness flag is done AND
    open_questions is empty — for any combination of flag values and questions."""
    expected = (
        state.readiness.refined.done
        and state.readiness.architected.done
        and state.readiness.planned.done
        and len(state.open_questions) == 0
    )
    assert state.is_ready_for_backlog() == expected


@given(_planning_state)
@settings(max_examples=50)
def test_planning_state_round_trips_through_model_dump(state: PlanningState) -> None:
    """PlanningState serialises and deserialises without data loss.

    Exercises the pydantic contract over the full space of valid states rather
    than a single hand-crafted fixture.
    """
    restored = PlanningState.model_validate(state.model_dump())
    assert restored == state
