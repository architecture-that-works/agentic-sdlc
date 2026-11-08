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

ISSUE: Split implement into a Validation Contract step that must go RED before any code
ESTIMATE: 8
PRIORITY: P3
**Goal**: Correctness is defined before implementation: the acceptance criteria become failing tests first, written independently of the code, and the orchestrator proves they fail before it lets the agent implement.
**Description**: The implement skill prescribes Red-Green-Refactor, but the stage runs one Claude session that writes tests and code together, so nothing enforces that tests came first or ever failed. A Validation Contract makes the spec executable: one test per acceptance criterion, written from the issue body alone, confirmed RED by the orchestrator (non-zero pytest exit on the new tests), then a second session implements until GREEN. This is prompt chaining with a programmatic gate between the steps — one of Anthropic's canonical patterns — and the spec-driven heart of BMAD without its ceremony. Keep tests lean: the contract is one test per criterion plus what the implement skill's lean rules require for a new branch — not coverage for its own sake — and the suite's wall-clock must not grow beyond the new tests' own runtime. Depends on #294 (merge it first).
**Requirements**:
1. `Invoke-Develop` becomes two chained sessions: Contract (tests only, from the acceptance criteria; the orchestrator fails a run that wrote outside `tests/`) and Develop (implement until GREEN; tests may be refined, never deleted).
2. Between them the orchestrator runs the new tests and requires a non-zero exit; a contract that passes before implementation is posted as 🤖⚠️ Contract Vacuous and the run fails fast.
3. The implementation comment gains one line, `Contract: N tests RED → GREEN` (folded into the implementation record if that merged first).
4. Plan prompt rule: every acceptance criterion is a testable statement — an observable input and result — so a contract can be derived from it; refine flags criteria that are not.
5. `implement` skill: the RED phase states that in the pipeline RED is the contract step. No other skill text changes.
**Acceptance Criteria**:
- A pipeline run shows two sessions in the issue comments; the suite run between them exits non-zero on exactly the new tests.
- A contract that passes before implementation fails the run with the vacuous-contract signal.
- Suite wall-clock on `main` grows by no more than the new tests' own runtime; every new test traces to a criterion.
- `uv run pytest` passes.
END_ISSUE

ISSUE: Decide and implement failure kinds for self-healing retries
ESTIMATE: 8
PRIORITY: P3
**Goal**: A failed run heals itself when the failure is mechanical, retries with the right diagnosis when it is not, and the owner can see which kinds of failure recur — all from the issue carrier, with no new log.
**Description**: Research conclusion to confirm: the agent's logs already exist as the issue's signal comments and `attempts[]` (ADR-011); a second log medium was rejected (`emitEvent`, `.out-of-scope.md`). What the carrier lacks is the *kind* of each failure. Today `attempts[]` records the stage, so retry re-runs the stage with the diagnosis skill regardless of cause, and the hourly reconcile only knows "stuck". With a kind, recovery becomes routing — deterministic, no agent: a lint or format failure in CI → `ruff format`, commit, push, no engine call; a push rejected under lease → rebase and push; a usage limit → pause (exists); tests failing or review rejected → implement with diagnosis (exists); the same kind three times → `agent:failed` with the kind named. The orchestrator stays a workflow, not an agent, because the next step is predictable from the kind. Decisions for the owner (refine will ask): the kind vocabulary; whether a `task health` digest (histogram of kinds over recent issues via REST search) is wanted now or only once a recurrence is observed; whether `Format-ErrorBlock` carries the kind as its first line. Depends on the implementation record issue.
**Requirements**:
1. Every 🤖❌ / 🤖⚠️ signal and every `attempts[]` entry carries `kind: <one of the agreed vocabulary>`; `Format-ErrorBlock` is the single place that sets it.
2. `retry` and `reconcile` route on the kind; mechanical kinds (format, lease) heal without an engine call and are recorded as an attempt.
3. A kind that repeats three times lands on `agent:failed` with the kind in the comment.
4. Only if the owner decides so: `task health` prints the kind histogram for the last N shipped or failed issues.
**Acceptance Criteria**:
- `tests/orchestrator/test_reconcile.py` and a retry test cover one mechanical kind healed without an engine call and one non-mechanical kind routed to implement.
- A forced format failure in CI on a feature branch heals at the next hourly reconcile without an engine call.
- `uv run pytest` passes; no new carrier, file or label.
END_ISSUE

ISSUE: Record where Anthropic's five agentic patterns live in the pipeline (ADR-016)
ESTIMATE: 3
PRIORITY: P4
**Goal**: Anyone extending the pipeline sees which canonical pattern each stage uses, which patterns are deliberately not used, and what would justify changing that — so no agent is added for the sake of being an agent.
**Description**: The pipeline already is the patterns: prompt chaining (refine → architect → plan → implement → review → ship with programmatic gates between stages), routing (`Get-PhaseModel` picks the model by estimate; `project_type` picks the domain skill), orchestrator–workers (`Invoke-Orchestration` conducts; plan decomposes an epic into children), evaluator–optimizer (the review ↔ implement loop bounded by `MaxRetries`). Parallelization is used only in CI (`checks.yml` jobs) and deliberately not at implement (one concurrency group: one PAT budget, one usage budget, one branch at a time) nor at review (voting costs tokens for little gain at this scale). "Orchestrator as agent" gets the same answer: the orchestrator is a workflow because every next step is predictable; the agents are the stage sessions (grill, implement, review). Write this down once as a template-mechanism ADR with a revisit trigger per row (for example: a failure kind deterministic routing cannot handle; independent children waiting on the implement queue), and link it from `template/adr/README.md`. Name the spec-driven elements too: the issue body is the story file; acceptance criteria are the executable spec (Validation Contract); the implementation record is the Dev Agent Record.
**Requirements**:
1. `template/adr/ADR-016-agentic-patterns.md` in MADR form: one row per pattern — where it lives, status (used / deliberately not), revisit trigger. Under two pages.
2. A row in `template/adr/README.md`.
3. No `CONTEXT.md` change unless another document needs a new glossary term.
**Acceptance Criteria**:
- The ADR names all five patterns and the orchestrator-as-agent decision, each with a revisit trigger.
- `pwsh .github/checks/check-doc-paths.ps1` passes.
END_ISSUE

ISSUE: Refine reads the issue's own branch and PR before asking the owner
ESTIMATE: 3
PRIORITY: P4
**Goal**: When work for an issue already exists on its feature branch, refine decides from that branch instead of asking the owner questions the branch answers.
**Description**: Observed on #294 while pairing: the issue was implemented on `feature/294-lean-implement-review` and PR #295 opened minutes after the issue, yet refine raised three questions — the four parts of a finding, the `shortcut:` contract, the four follow-up issues — every one answered by the diff. Rule 1 (codebase first) reads the default branch only; in pairing mode, which the flow always runs through, the branch is the codebase. Each avoidable `human:decision` round costs the owner a context switch and delays review by a day. Smallest change: the grill's task prompt tells the subagent that when `feature/<N>-*` exists on origin (or an open PR references the issue) it reads that diff first and records what the diff answers in `decided_questions[]` with the PR as evidence. Nothing else changes.
**Requirements**:
1. `Get-GrillUserPrompt` receives the PR number and branch when one exists and adds one line to the task: "A PR exists for this issue: #M on branch B — run `gh pr diff M` first; a question the diff answers is decided, evidence: the PR".
2. No new question type, label or state; the `GrillResult` schema is unchanged.
**Acceptance Criteria**:
- `tests/orchestrator/test_grill.py`: with a PR present the rendered prompt names it; without one the prompt is byte-identical to today's.
- Re-running refine on an issue whose PR answers every question yields `open_questions=0`.
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
