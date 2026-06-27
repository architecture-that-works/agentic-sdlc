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
"""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum

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
