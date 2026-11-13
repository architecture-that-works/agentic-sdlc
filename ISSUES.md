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
  - *(no label)* — the **default, and almost always right**: labels are set by the pipeline, not when writing issues
  - `human:approval` — only to force a merge hold on a change that does not touch governance files (those are held automatically)
  - `human:decision` — set by refine, never by hand: the issue waits on questions listed in it
  - `agent:backlog` `agent:implementing` `agent:reviewing` `agent:shipped` `agent:failed` `agent:paused` — orchestrator state machine; set by the orchestrator, never by humans or agents writing issues
- `ESTIMATE:` — Fibonacci story point integer (see scale below). Synced to the **Estimate** field on the GitHub Project board. **Do not use the project board's Size field** (XS/S/M/L/XL) — it is not populated by any script and conflicts with Estimate as the single sizing signal.
- `PRIORITY:` — one of `P0 | P1 | P2 | P3 | P4` (see definitions below). Synced to the **Priority** field on the GitHub Project board.

After `task sync`, each processed block is removed from this file and lives as a GitHub Issue on the project board.

---

## Estimate

Estimates use the Fibonacci series: **1 · 2 · 3 · 5 · 8 · 13 · 21**. Points measure complexity, risk, and effort relative to the 1-point anchor — not calendar hours.

**Anchor — what is a 1?**

A 1-point issue is a single-file additive edit where correctness is verifiable by one command without running the test suite.

- *Update `Status: Proposed → Accepted` in one ADR file. Verified by `grep 'Status: Accepted' docs/adr/ADR-001-your-decision.md`.*
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
- `ESTIMATE: 13` or above is an epic: the plan stage decomposes it into child issues rather than implementing it directly.

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

ISSUE: Post a dense implementation record for every implement run
ESTIMATE: 5
PRIORITY: P4
**Goal**: The owner and the reviewer see in one issue comment what an implement run did, what it left undone, which commands ran with which exit code, what it discovered, and whether it followed the procedure.
**Description**: The 🤖 Implementation comment holds the agent's last bullets and a file list; the orchestrator's own commands (pytest, ruff format, git) and their exit codes live only in the runner log, and nobody records whether the agent read AGENTS.md, CONTEXT.md and a skill, or ran the suite before stopping. The stream the orchestrator already parses (tool_use blocks for Read/Write/Edit/Bash) is enough to derive a procedure line without a second medium — the issue stays the only carrier (ADR-011; an `emitEvent` log is in `.out-of-scope.md`). This record is the base the self-healing issue builds on: a failure kind is only useful once the run is legible. Spec-driven analogue: BMAD's Dev Agent Record, kept inside our story file — the issue. Depends on #294 (merge it first): it introduces the `Left undone:` / `Issues discovered:` bullets this record extends.
**Requirements**:
1. Extend the 🤖 Implementation comment with five dense lines after the file list: `Implemented:` (the agent's bullets), `Left undone:` and `Issues discovered:` (the agent's closing bullets, per the implement skill), `Commands:` (every command the orchestrator itself ran in the stage — pytest, ruff, git — as `name → exit code`), `Procedure:` (derived from the stream: AGENTS.md read, CONTEXT.md read, a skill read, pytest run — each ✓ or ✗).
2. Record the same five fields in the run's `attempts[]` entry of AGENT-STATE (decision Q3-d on #294), so a retry reads them without parsing comments.
3. One comment per run; no new file, label or second log.
**Acceptance Criteria**:
- A pipeline run on a trivial issue posts one 🤖 Implementation comment with all five lines populated; `Procedure:` shows ✗ when the agent never ran pytest.
- `tests/orchestrator/` covers the procedure derivation from a recorded stream fixture — one test per field, no more.
- `uv run pytest` passes; existing comment consumers (review signal history, retry) still find the comment.
END_ISSUE

ISSUE: Evals for the review and implement skills
ESTIMATE: 5
PRIORITY: P4
**Goal**: A change to the review or implement skill is judged against fixed goldens before it ships, the way the refine grill and the commit message already are.
**Description**: Decision Q3 (a, b) on #294. The two skills now carry a method — three-part findings with a concrete case and a verdict line naming what blocks; a `Left undone:` / `Issues discovered:` closing note — and nothing measures whether a model following them produces that shape. Evals judge a component against goldens (`CONTEXT.md` glossary); add one per skill under `tests/evals/`, opt-in like the others, judged by Claude through the existing `evaluate` fixture. Few goldens, no new framework.
**Requirements**:
1. `tests/evals/test_review_eval.py` with `goldens/review.jsonl`: one clean diff (expected APPROVED, no findings) and one with a planted bug (expected REJECTED naming it; three parts; a concrete case; no severity tag).
2. `tests/evals/test_implement_eval.py` with `goldens/implement.jsonl`: a task whose expected output ends with `Left undone:` and `Issues discovered:` lines.
3. Gated by the existing `eval` CI job when `.agents/skills/review/` or `.agents/skills/implement/` change.
**Acceptance Criteria**:
- `uv run pytest -m eval` passes on `main`; the planted-bug golden fails when the review skill's § Report section is removed.
- Suite wall-clock outside `-m eval` is unchanged.
END_ISSUE

ISSUE: CI check that every shortcut: comment names its follow-up
ESTIMATE: 2
PRIORITY: P4
**Goal**: A `shortcut:` comment without a follow-up cannot reach `main`.
**Description**: Decision Q3 (c) on #294. The contract is `# shortcut: <reason> — to be fixed in <follow-up-slug>` (implement REFERENCE § Shortcut Comments) and review lists such lines under `Not checked:`. The one thing a reviewer cannot be trusted to catch every time is a shortcut with no follow-up named — a linter can. Add `check-shortcuts.ps1` to `.github/checks/`, run by `checks.yml`, over `src/` and `.github/` (skipping itself).
**Requirements**:
1. `.github/checks/check-shortcuts.ps1`: non-zero exit and the offending lines when a `shortcut:` comment lacks `to be fixed in <slug>`.
2. A `checks.yml` step and `tests/checks/test_check_shortcuts.py` with one passing and one failing fixture.
**Acceptance Criteria**:
- A commit with `# shortcut: linear scan` and no follow-up fails CI; the same line with ` — to be fixed in orders-index` passes.
- `uv run pytest` passes.
END_ISSUE
