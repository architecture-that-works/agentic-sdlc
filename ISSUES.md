# ISSUES.md

Local improvement backlog. Add improvements as Agile User Story blocks below the ISSUES sentinel.

Run `task sync` to push pending blocks to GitHub Issues and the project board.
Run `task sync -- -DryRun` to preview without making changes.

---

## Block Format

Every block must follow this structure exactly so `task sync` can parse it:

```
ISSUE: [Action-oriented Issue Title]
**Goal**: A singular non-technical explanation of the business outcome.
**Description**: Context answering *why* this matters, linking previous boundaries to the new feature.
**Requirements**:
1. Sequenced, modular actionable steps explicit enough for an independent developer (or AI) to implement.
**Acceptance Criteria**:
- Strict qualitative boundaries defining when the work is officially "finished".
END_ISSUE
```

Header fields — all optional, must appear before the body, in any order:

- `LABELS:` — comma-separated subset of the allowed label set. Agents must not create new labels. Allowed values:
  - *(no label)* — unattended is the **default**: the pipeline runs refine through ship without stopping
  - `human:approval` — implemented and self-reviewed unattended, then held for a human to merge the PR
  - `human:decision` — a question for a human; never enters the pipeline at all
  - `agent:backlog` `agent:implementing` `agent:reviewing` `agent:shipped` `agent:failed` — orchestrator state machine; set by the orchestrator, never by humans or agents writing issues
- `ESTIMATE:` — Fibonacci story point integer (see scale below). Synced to the **Estimate** field on the GitHub Project board. **Do not use the project board's Size field** (XS/S/M/L/XL) — it is not populated by any script and conflicts with Estimate as the single sizing signal.
- `PRIORITY:` — one of `P0 | P1 | P2 | P3 | P4` (see definitions below). Synced to the **Priority** field on the GitHub Project board.

After `task sync`, each processed block is removed from this file and lives as a GitHub Issue on the project board.

---

## Estimate

Estimates use the Fibonacci series: **1 · 2 · 3 · 5 · 8 · 13 · 21**. Points measure complexity, risk, and effort relative to the 1-point anchor — not calendar hours.

**Anchor — what is a 1?**

A 1-point issue is a single-file additive edit where correctness is verifiable by one command without running the test suite.

- *Update `Status: Proposed → Accepted` in one ADR file. Verified by `grep 'Status: Accepted' docs/adr/ADR-001.md`.*
- *Add a single `.gitignore` pattern as a standalone issue. Verified by `git check-ignore -v <pattern>`.*

A true 1 is rare as a standalone issue — in practice issues bundle and land at 2 minimum because AC always includes `uv run pytest`.

**Scale:**

| Points | Definition | Typical examples |
|--------|-----------|-----------------|
| 1 | Single-file additive edit; correctness verified by one command, no test run | Update one ADR status; add a single `.gitignore` pattern |
| 2 | Mechanical multi-file change; verifiable by CLI commands; no design decisions | Add a CI workflow file; add devcontainer config; update dependency pins |
| 3 | New document or single function with a clear spec; no architectural decision required | Add a `SECURITY.md`; write a multi-stage `Dockerfile`; add a coverage gate to CI |
| 5 | New cross-cutting behaviour touching multiple modules; tests required; path is clear | Add a new config field propagated through config, tests, and docs; port a script to a new runtime |
| 8 | Significant feature spanning multiple subsystems or requiring an explicit design decision | Multi-cloud deployment workflow with WIF; template restructure affecting generation output |
| 13 | Major system creation or replacement; end-to-end behaviour must be verified | Replace a polling-based pipeline with an event-driven one; introduce a new orchestration layer |
| 21 | Spans every bounded context; compounding unknowns. **Decompose before implementation.** | A PRD tackled as a single issue rather than decomposed child issues |

**Rules of thumb:**
- If unsure between two values, pick the higher.
- Estimates include the full cost: implementation, tests, review, and any documentation AC requires.
- If a dependency is unresolved, do not estimate — flag for refinement first.
- `ESTIMATE: 13` or above requires `LABELS: human:approval`. The agent implements and self-reviews, then holds for a human to merge.

---

## Priority

Priority expresses urgency and impact. Independent of size — a 1-point issue can be P2 if it blocks correct behaviour.

| Label | Name | Definition |
|-------|------|------------|
| P4 | Nice to have | Non-breaking improvement: clean-up, refactor, DX, or non-functional enhancement. No user-facing impact if deferred. |
| P3 | Normal — new work | New functionality. Application works without it, but planned and expected. |
| P2 | Priority — broken | Application not working correctly. Pick up in current or next sprint. Requires documented broken behaviour and reproduction path. |
| P1 | Application down | Completely unavailable or critically degraded. Immediate implementation. Extremely rare. |
| P0 | Multi-repo outage | Multiple repositories impacted. Incident-level response. |

Default new issues to **P3** (new work) or **P4** (improvement). Escalation to P2 or above requires the issue description to document the broken behaviour and a reproduction path or observable symptom.

---

<!-- ISSUES -->

ISSUE: Close the loop on agent PRs left sitting at agent:reviewing
LABELS: human:approval
ESTIMATE: 3
PRIORITY: P3
**Goal**: An agent-authored PR cannot quietly rot at `agent:reviewing` until `main` has moved far enough to make it unmergeable.
**Description**: The pipeline drives an issue to `agent:reviewing` and then stops — nothing tracks how long a PR waits for the human approval that lane implies. PR #175 (issue #154) sat from 2026-07-29 to 2026-09-20, seven weeks, during which `main` advanced past it and the branch acquired a `pyproject.toml` conflict that required hand resolution before CI could even run. The cost compounds: a stale branch also rebases onto a `main` whose CI gates have since changed, so the eventual rerun fails for reasons unrelated to the original work. There is no dashboard, notification, or scheduled sweep surfacing "these agent PRs are waiting on you". Note this is about *surfacing* staleness, not auto-merging — the human approval gate is deliberate and must stay.
**Requirements**:
1. Add a scheduled workflow (daily is sufficient) that lists open PRs whose linked issue carries `agent:reviewing`, with the age of each in days.
2. Escalate past a threshold (suggest 3 days): post or update a single comment on the PR noting how long it has waited, without spamming a new comment per run.
3. Surface the same list in a form the developer actually sees — a job summary on the scheduled run at minimum; consider a `task` target mirroring `task afk`'s queue display for local use.
4. Optionally flag PRs whose branch has fallen behind `main` by more than N commits, since that is the specific condition that turns a wait into a conflict.
5. Do not auto-close, auto-merge, or relabel anything — this issue only makes the backlog of waiting reviews visible.
**Acceptance Criteria**:
- A scheduled workflow exists and runs green on `main`.
- Given an open PR linked to an `agent:reviewing` issue older than the threshold, the workflow reports it by number, title, and age.
- Re-running the workflow updates rather than duplicates any comment it posts.
- No PR state, label, or merge status is modified by the workflow.
- `uv run pytest` passes and `ruff check .` / `ruff format --check .` are clean.
END_ISSUE

ISSUE: Decide whether the Planner/Generator/Evaluator split and agent event log are template features
LABELS: human:decision
ESTIMATE: 5
PRIORITY: P4
**Goal**: The harness content describing a Planner/Generator/Evaluator agent split, an `emitEvent` durable event log, and tool-call offloading rules either becomes implemented template machinery or is dropped — it stops living in a document as unimplemented aspiration.
**Description**: ADR-015 retired the `harness` skill and moved its content to `docs/HARNESS.md`. Reviewed against the repository, the PGE split, the event log and the offloading rules are implemented nowhere in `.github/orchestrator/` — no function emits an event, and nothing splits generation from evaluation. Documentation carries settled knowledge; in-flight intent belongs on an issue. The context-management thresholds and the Dev Container pointer stayed in `docs/HARNESS.md` because both describe something real. This issue decides the fate of the rest rather than leaving a document that describes machinery the repository does not have.
**Requirements**:
1. Decide per component — PGE split, `emitEvent` log, tool-call offloading rules — build, defer, or drop.
2. For each "build", raise a child issue with acceptance criteria written against `.github/orchestrator/`.
3. For each "drop", add an entry to `.out-of-scope.md` with the date and this issue as the source, so plan-phase deduplication finds it.
4. Do not re-expand `docs/HARNESS.md` to hold the deferred design; the issue is the carrier for in-flight intent (ADR-011).
**Acceptance Criteria**:
- Given the decision is recorded, no component remains undecided.
- Given a component is dropped, `.out-of-scope.md` carries it with a date and source link.
- Given a component is built, a child issue exists with acceptance criteria naming the orchestrator files it touches.
- `docs/HARNESS.md` is unchanged in length by this issue — it describes only what exists.
END_ISSUE
