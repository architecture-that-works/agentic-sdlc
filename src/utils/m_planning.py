"""
Issue-carried planning-state schema.

Defines the pydantic contract for the orchestrator's per-issue state. The state
lives in the GitHub issue body inside a fenced JSON block, so any runtime
(developer laptop, GHA runner, future Cloud Run service) can resume work without
needing local files.

Fields
------
- ``issue_number``       — GitHub issue number this state belongs to.
- ``lane``               — current 4-lane FSM position.
- ``readiness``          — pre-backlog gate: refined / architected / planned flags,
                           each with provenance (``populated_by`` + timestamp).
- ``open_questions``     — unresolved alignment questions blocking backlog entry.
- ``decided_questions``  — resolved questions, kept for audit.
- ``transitions``        — append-only audit log of lane transitions.

The self-grill subagent (``.agents/skills/refine/scripts/grill.ps1``) emits a
``GrillResult`` — bundling the ``AgentBrief`` interface-first specification,
open/decided questions, and proposed glossary diffs. ``Invoke-Refine`` validates
the subagent's JSON against this contract before writing anything back to the
issue body.
"""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class Lane(StrEnum):
    """4-lane FSM. ``agent:failed`` is an in-Backlog recovery, not a lane."""

    BACKLOG = "backlog"
    IMPLEMENTING = "implementing"
    REVIEW = "review"
    MERGED = "merged"


class ReadinessFlag(BaseModel):
    """Single readiness checkpoint with provenance."""

    model_config = ConfigDict(extra="ignore")

    done: bool = False
    populated_by: str | None = None
    timestamp: datetime | None = None


class Readiness(BaseModel):
    """Pre-backlog readiness gate. All three flags must be ``done`` and
    ``open_questions`` must be empty before an issue earns ``agent:backlog``."""

    model_config = ConfigDict(extra="ignore")

    refined: ReadinessFlag = Field(default_factory=ReadinessFlag)
    architected: ReadinessFlag = Field(default_factory=ReadinessFlag)
    planned: ReadinessFlag = Field(default_factory=ReadinessFlag)


class Question(BaseModel):
    """Open or decided alignment question."""

    model_config = ConfigDict(extra="ignore")

    text: str
    raised_by: str | None = None
    decided_by: str | None = None
    decision: str | None = None
    timestamp: datetime | None = None
    # The human:decision issue that carries an open question. Closing it (with an
    # optional answer comment) is how a human decides; refine reads it back.
    child_issue: int | None = None


class Transition(BaseModel):
    """Single lane transition — append-only audit entry."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    from_lane: Lane | None = Field(default=None, alias="from")
    to_lane: Lane = Field(alias="to")
    runtime: str
    timestamp: datetime


class PlanningState(BaseModel):
    """Issue-carried orchestrator state. Single source of truth across runtimes."""

    model_config = ConfigDict(extra="ignore")

    issue_number: int
    lane: Lane = Lane.BACKLOG
    readiness: Readiness = Field(default_factory=Readiness)
    open_questions: list[Question] = Field(default_factory=list)
    decided_questions: list[Question] = Field(default_factory=list)
    transitions: list[Transition] = Field(default_factory=list)

    def is_ready_for_backlog(self) -> bool:
        """True only when every readiness flag is set and no open questions remain."""
        return (
            self.readiness.refined.done
            and self.readiness.architected.done
            and self.readiness.planned.done
            and len(self.open_questions) == 0
        )


class GlossaryDiff(BaseModel):
    """Proposed change to ``CONTEXT.md`` Glossary surfaced by the self-grill subagent."""

    model_config = ConfigDict(extra="ignore")

    term: str
    definition: str
    disambiguation: str | None = None
    action: Literal["add", "revise", "remove"] = "add"


class AgentBrief(BaseModel):
    """Interface-first specification — direct input to the ``plan`` skill.

    Per refine/SKILL.md Rule 4 (Interface before implementation), the brief must
    describe contracts and schemas only — never file paths or line numbers.
    """

    model_config = ConfigDict(extra="ignore")

    feature_name: str
    problem_statement: str
    interfaces: list[str] = Field(default_factory=list)
    constraints: list[str] = Field(default_factory=list)
    out_of_scope: list[str] = Field(default_factory=list)
    tracer_bullet: str | None = None


class GrillResult(BaseModel):
    """Structured output of the self-grill subagent. Validated before the
    orchestrator writes anything back to the GitHub issue body."""

    model_config = ConfigDict(extra="ignore")

    agent_brief: AgentBrief
    open_questions: list[Question] = Field(default_factory=list)
    decided_questions: list[Question] = Field(default_factory=list)
    glossary_diffs: list[GlossaryDiff] = Field(default_factory=list)
