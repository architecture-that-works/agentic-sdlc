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

```
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
```

```
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
```

```
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
```

```
ISSUE: Show agent:refining while refine, architect and plan run
ESTIMATE: 3
PRIORITY: P3
**Goal**: At a glance on the board, an issue being refined shows an agent is working on it instead of looking stale.
**Description**: Sync this block only after #297 merges — both change `$PipelineStates`, `afk.yml` and the `CONTEXT.md` glossary. Owner, 2026-11-13: "when a new issue is put on the backlog and the refine starts there is no label on the issue hence at a glance it looks stale, since the agent is refining add label agent:refining for refine/architect/plan so it is clear that an agent is working on the issue." Today refine, architect and plan run on an issue with no pipeline label until refine grants `agent:backlog` or asks via `human:decision` — the pipeline taxonomy deliberately gave only three of the six stages a label (ADR-015). This amends that: the alignment gate gets one label too. `$PipelineStates` is the one table, so the state itself is one row.
**Requirements**:
1. Add `'agent:refining' = @{ LaneName = 'Backlog'; Holder = 'agent'; Recovery = 'restart' }` to `$PipelineStates` in `.github/orchestrator/lib/Config.ps1`.
2. The conductor sets `agent:refining` through `Set-AgentState` when refine starts (issue opened, owner comment, backfill, retry into refine) and replaces it with `agent:backlog` or `human:decision` when plan or refine ends, as today; a failure ends at `agent:failed` as today.
3. `.github/workflows/afk.yml`: an owner comment on an issue at `agent:refining` still starts refine — it queues behind the running one in the per-issue concurrency group, so no answer is lost. Update the trigger table in the header comment.
4. Recovery: a stalled `agent:refining` is re-entered from refine by the hourly warden (`Recovery = 'restart'`); check `Restart-Issue` in `lib/Reconcile.ps1` resolves an un-planned carrier to refine.
5. `.github/tasks/setup.ps1`: add the label row (description: "Refine, architect and plan are running"). `CONTEXT.md`: the Stage glossary row says four stages carry a label; the `agent:` row lists it.
**Acceptance Criteria**:
- `tests/test_kanban_state.py` / `tests/orchestrator/test_setup_labels.py`: the row exists with Backlog lane, agent holder, restart recovery, and setup creates the label.
- `tests/workflows/test_afk.py`: an owner comment on an `agent:refining` issue starts refine; a 🤖/· comment does not.
- `tests/orchestrator/test_reconcile.py`: a stalled `agent:refining` issue is restarted at refine.
- Live: a newly opened issue shows `agent:refining` within a minute and ends at `agent:backlog` or `human:decision`.
- `uv run pytest`, `ruff check`, `ruff format --check` and all checks pass.
- Owner follow-up after merge: run `task setup` once so the label exists on this repo.
END_ISSUE
```

```
ISSUE: Name the orchestrator's files after the stages and skills they serve
ESTIMATE: 5
PRIORITY: P3
**Goal**: Each stage has one obvious place for its logic, its instructions and its tests, all carrying the stage's name — one location to change a stage.
**Description**: Sync this block only after the "Show agent:refining while refine, architect and plan run" issue merges — all three issues in that chain change `.github/orchestrator/`. Owner on #294 (2026-11-13), verbatim: "Why is there a .github/orchestrator/lib/Grill.ps1, I want the orchestrator to follow the exact naming conventions as the agreed stages and naming of skills so it is extremely clear what is configured where and how stages relate to each other. Goal is to have 1 clear location for updates/adjustments. Do not mix naming, clearly reference ps1 and skills and .md files, what logic should live where." Today refine's questioning lives under a second name in three places: `.github/orchestrator/lib/Grill.ps1`, `.agents/skills/refine/scripts/grill.ps1` and `tests/orchestrator/test_grill.py`, next to `stages/Refine.ps1` and `tests/orchestrator/test_refine.py`. Each skill also carries a `scripts/` folder (`blast-radius.ps1`, `run-tests.ps1`, `decompose.ps1`, `pre-review.ps1`, `preflight.ps1`, …) whose relation to the stage files is not written down. The six stages, their skills and their library files share one name by decision (pipeline taxonomy, ADR-015); this closes the gaps. The resulting rule is recorded in the TADR for the orchestrator module when the TADR set is written.
**Requirements**:
1. Inventory every file in `.github/orchestrator/`, `.github/tasks/` and `.agents/skills/*/scripts/` with the stage it serves (or "cross-stage"), and post it as the plan.
2. Write down where logic lives: stage logic in `.github/orchestrator/stages/<Stage>.ps1`; the agent's instructions in `.agents/skills/<stage>/SKILL.md` (with `REFERENCE.md` / `EXAMPLES.md`); `lib/` holds only cross-stage code; the stage's tests in `tests/orchestrator/test_<stage>.py`. Decide what a skill's `scripts/` folder is for, or remove the folders whose logic duplicates a stage file.
3. Apply it: fold `lib/Grill.ps1` into `stages/Refine.ps1` (or give it the stage's name) and `test_grill.py` into `test_refine.py`; rename or fold every other file the inventory shows serving one stage under another name. "Grill" leaves the vocabulary unless `CONTEXT.md` defines it.
4. Update `Orchestrator.psm1` load order, `Orchestrator.psd1` exports, `.github/checks/check-module-api.ps1` expectations, and the `CONTEXT.md` Module Map and Glossary.
**Acceptance Criteria**:
- Every file under `.github/orchestrator/` and `.agents/skills/*/scripts/` is named after a stage, an engine, or a cross-stage term in the `CONTEXT.md` Glossary.
- The `CONTEXT.md` Module Map shows, for each stage, its stage file, its skill and its test file on one row.
- `uv run pytest`, `ruff check`, `ruff format --check` and all checks (including `check-module-api.ps1` and `check-doc-functions.ps1`) pass.
END_ISSUE
```

```
ISSUE: Rewrite the template's eight ADRs as TADRs at today's paths
ESTIMATE: 5
PRIORITY: P3
**Goal**: Every decision about the template's mechanism reads as true today and carries a number no project ADR can collide with.
**Description**: Sync this block only after #298 merges — it needs `.template/adr/` to exist. After it, `.template/adr/` holds eight ADRs numbered 007 and 009–015: gaps left by the domain ADRs, numbers that collide with a project's own ADR-001 onwards, and content describing retired layouts (`kanban/`, `.github/scripts/`, `Kanban.psd1`, the `tdd` phase; ADR-007's `{{ project_type }}` was never rendered because only `.jinja2` files are). Decision settled with the owner (2026-11-13): template decisions are `TADR-NNN` in `.template/adr/`, numbered from 001 in the order foundation → environment → application → security → AI → context → pipeline; a project's own ADRs are `ADR-NNN` in `docs/adr/` from 001. TADRs are never copied into projects; citations in shipped code stay (renamed) as references to the template at the project's pinned version. Final numbering: TADR-001 template as a versioned foundation (new, next issue), 002 project types and domain skills (← ADR-007), 003 toolchain and environment (new), 004 application baseline (new), 005 secrets and trust boundaries (new), 006 AI engines (new), 007 context strategy (← ADR-009), 008 pipeline taxonomy (← ADR-015), 009 state carrier (← ADR-011), 010 pre-backlog alignment gate (← ADR-014), 011 orchestrator module and run context (← ADR-013), 012 GitHub API budget (← ADR-012), 013 runner profile, Proposed (← ADR-010), 014 quality signals (new). This issue does the eight with a predecessor; the next completes the set.
**Requirements**:
1. `git mv` each of the eight to `.template/adr/TADR-NNN-<slug>.md` per the mapping and rewrite it in MADR form as the current state: Status, Context and Problem Statement, Considered Options (rejected alternatives included), Decision Outcome, Confirmation. About two pages at most; drop implementation logs (ADR-015's) — history lives in git.
2. TADR-002 takes from the domain ADRs only what the shipped domain skills rely on (read them with `git show 2c714de:adr-staging/<file>`): `application-engineering` authenticates with an OAuth2 bearer and leaves the IAM provider to the project; `agentic-engineering` emits one OTel span per loop iteration and leaves the tracing tool to the project; `data-engineering`'s stack is the one the skill teaches (Polars, SQLAlchemy, DuckLake) — record that ADR-001's Pandas choice is not the template's.
3. Rename every citation repo-wide with a scripted whole-word mapping (`\bADR-007\b` → `TADR-002`, …, `\bADR-015\b` → `TADR-008`). Leave illustrative project ADR filenames untouched — `docs/adr/ADR-009-credential-rotation.md` and `ADR-008-secrets-management.md` in `tests/orchestrator/test_implement_denylist.py` and `.github/orchestrator/stages/Implement.ps1`, `docs/adr/ADR-010-sse-stdlib-workaround.md` in `.agents/skills/refine/EXAMPLES.md`: list every match followed by a `-slug` and review it by hand.
4. `.template/adr/README.md`: one index table — TADR, Title, Status, Decision, Formerly (old ADR number), so old numbers in closed issues and commits still resolve.
5. Point `.out-of-scope.md` "Source ADR" links at the TADR files.
**Acceptance Criteria**:
- `git grep -nE '\bADR-0(07|09|1[0-6])\b'` matches only the illustrative filenames listed in requirement 3.
- Each TADR cites only `TADR-NNN` numbers and repo paths that exist; none mentions `kanban/`, `.github/scripts/`, `Kanban.psd1` or a `tdd` phase.
- `uv run pytest`, `ruff check`, `ruff format --check` and all checks pass.
END_ISSUE
```

```
ISSUE: Complete the TADR set so it explains the whole template structure
ESTIMATE: 8
PRIORITY: P3
**Goal**: Anyone working on the template can trace every folder and file a project receives to the decision that put it there, without leaving `.template/adr/`.
**Description**: Sync this block only after the "Rewrite the template's eight ADRs as TADRs at today's paths" issue merges. After it, the TADRs cover project types, context and the pipeline only. Nothing records the Copier and versioning model, the toolchain, the application baseline, secrets, the AI engines or the quality signals; the reasoning for secrets (ADR-008) and telemetry (ADR-003) lived in domain ADRs that have left the repo (`git show 2c714de:adr-staging/<file>`). Decision settled with the owner (2026-11-13): the TADR set is self-sufficient — its reasoning is a closed circle inside `.template/adr/`. When working on the template you work on the TADRs; a project takes the template as a given and adds its own ADRs on top; feedback flows upstream and is fixed here.
**Requirements**:
1. TADR-001 template as a versioned foundation: Copier with this repo as a template of itself; `.template/` never copied; a root file with a `.jinja2` twin is dual-use — plain file is the template repo's own, twin is the project's day-one copy (`pyproject.toml`, `ISSUES.md`, `.out-of-scope.md`); a release is a git tag that projects record in `.copier-answers.yml` and follow with `copier update`; a table of template-owned and project-owned paths; two improvement loops — feedback from projects as issues on this repo, and the regular assessment (`.template/ASSESSMENT_PROMPT.md`, reports in `.template/assessments/`). Considered options include a multi-variant template, a `_subdirectory` layout (breaks running the pipeline on this repo) and auditing projects with the claude-code-setup plugin.
2. TADR-003 toolchain and environment: UV only, the Python version, the ruff gate, pytest with the 80% coverage floor and test parity, pre-commit, `Taskfile.yml` with one runnable per target, the Dev Container as the environment spec, `Dockerfile`, PowerShell 7. Considered: Codespace as the HITL surface.
3. TADR-004 application baseline: `src/` layout, `src/config.py` with pydantic-settings `extra="ignore"` and `.env`, generic `src/utils/m_*.py`, `src/tools/`, standard library first (`http.server`), KISS, dependency inversion, the rule of three. Considered: a web framework in the starter, TDD and SOLID as strict constraints.
4. TADR-005 secrets and trust boundaries: `.env` locally, Actions secrets in CI, a managed secret store in production (the template part of ADR-008); the `GH_TOKEN` classic PAT and `CLAUDE_CODE_OAUTH_TOKEN`; the sensitive-path denylist with its `docs/adr/` exemption; `GovernancePaths` and `WritablePaths`; proposals held at `human:approval`; `CODEOWNERS`.
5. TADR-006 AI engines: Claude first, CLI before SDK, Gemini optional and local only, `afk.yml` pins Claude, `KANBAN_ENGINE`. Considered: Gemini as primary, cross-family review.
6. TADR-014 quality signals: the `checks.yml` jobs, the validators in `.github/checks/`, evals (DeepEval metrics, Claude judge, goldens, the gated `eval` job), OpenTelemetry as vendor-neutral telemetry and the eval export (the template part of ADR-003). Considered: Plan Adherence as an eval.
7. `.template/adr/README.md` gains a coverage table: every git-tracked top-level path, each folder under `.github/` and each skill under `.agents/skills/` maps to exactly one TADR.
8. Every `.out-of-scope.md` entry points at the TADR whose Considered Options hold its reasoning; an entry is a heading and a one-line pointer.
9. `.template/tests/test_tadr_set.py` with three checks — coverage: every tracked path of the kinds in requirement 7 has exactly one row naming an existing TADR; closure: no `\bADR-\d` (unprefixed) in `.template/adr/`; current: every repo path cited in `.template/**/*.md` exists (assessment reports excluded — they are dated history).
**Acceptance Criteria**:
- `test_tadr_set.py` passes, and includes a case showing a new top-level folder without a coverage row fails it.
- From the coverage table alone, any folder in a generated project leads to the TADR that explains it.
- `uv run pytest`, `ruff check`, `ruff format --check` and all checks pass.
- Owner follow-up after merge (not the agent's): tag `v0.2.0`; generate a project at that tag, change a template-owned file here, and confirm `copier update` brings only that change.
END_ISSUE
```
