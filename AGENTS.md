# AGENTS.md — Project Context for AI Agents

## Project Identity

Python + UV application.

| Key | Value |
|-----|-------|
| Stack | Python + UV |
| Entry point | `src/main.py` |
| Config | `src/config.py` (pydantic-settings, loads `.env`) |

## Session Initialisation

Load in this order at the start of every session:

1. `CONTEXT.md` — domain glossary, bounded contexts, Module Map, Issue-Type Index, and architectural constraints
2. `AGENTS.md` — this file; standing instructions and skill index
3. `docs/adr/ADR_STRUCTURE.md` — master ADR index; filter by `applies_to` for the current `project_type` and load only the relevant ADR files
4. Task-specific context — issue description, PR diff, or user prompt

Never begin a task without reading `CONTEXT.md` first. An agent that skips this will hallucinate boundaries that were already agreed.

After reading `ADR_STRUCTURE.md`, load only the ADRs that match the current `project_type`. For `project_type: application` (the default): ADR-003, ADR-004, ADR-007, ADR-008, ADR-009. Do not load ADRs scoped to other project types — they pollute context with irrelevant constraints.

If loading steps 1–3 + step 4 would push context fill past 100k tokens, offload step 4 to the filesystem and load on demand.

### Context Protocol

Mandatory before opening any source file. See ADR-009.

1. Read `CONTEXT.md` fully. Do not open any `.py` / `.ps1` / `.yml` file yet.
2. From the Module Map and Issue-Type Index, identify the 3–5 files relevant to this task. Write them down explicitly — name them in your first user-facing message before reading them.
3. Read only those files. If you feel the urge to read more, ask: *does CONTEXT.md tell me this file is in scope for this issue type?* If no — stop. Work with what you have.
4. If implementation reveals a dependency not on the Map:
   - Read that file.
   - Add it to the Module Map (or extend an existing row's entry points) in the same PR.
5. Never `Grep` `**/*.py` to orient yourself. If the Map does not answer your question, the Map is incomplete — update it; do not work around it.

Violation of this protocol degrades every future agent session. Keep the Map accurate.

## Conditional Context

Load these docs only when the task requires them — do not load preemptively.

- For testing conventions, fixture patterns, and pytest usage: read `docs/TESTING.md`.
- For the skill system reference, invocation protocol, and lifecycle: read `docs/SKILLS.md`.

## Skills

Invoke the relevant skill before implementing manually. Skills are located in `.agents/skills/`.

**Workflow** (sequential — refine → architect → plan → implement → review → ship):

| Skill | When to invoke | References |
|-------|----------------|------------|
| `refine` | Starting a new feature — alignment on glossary, boundaries, and ADRs before any code | [REFERENCE.md](.agents/skills/refine/REFERENCE.md) · [EXAMPLES.md](.agents/skills/refine/EXAMPLES.md) |
| `architect` | Analysing dependencies, blast-radius, or module structure | [REFERENCE.md](.agents/skills/architect/REFERENCE.md) · [EXAMPLES.md](.agents/skills/architect/EXAMPLES.md) |
| `plan` | Translating an Agent Brief into a Lean PRD and decomposed GitHub Issues | [REFERENCE.md](.agents/skills/plan/REFERENCE.md) · [EXAMPLES.md](.agents/skills/plan/EXAMPLES.md) |
| `diagnosis` | Implementation or CI fails and the root cause is unclear — before attempting a fix | — |
| `implement` | Implementing features via Red-Green-Refactor | [REFERENCE.md](.agents/skills/implement/REFERENCE.md) · [EXAMPLES.md](.agents/skills/implement/EXAMPLES.md) |
| `review` | Code review, auto-fix loop, PR validation | [REFERENCE.md](.agents/skills/review/REFERENCE.md) · [EXAMPLES.md](.agents/skills/review/EXAMPLES.md) |
| `ship` | Pre-merge security checks, squash merge, knowledge base update | [REFERENCE.md](.agents/skills/ship/REFERENCE.md) · [EXAMPLES.md](.agents/skills/ship/EXAMPLES.md) |

**Meta** (project-type agnostic, cross-cutting — load on demand):

| Skill | When to invoke | References |
|-------|----------------|------------|
| `version-control` | Branching (`feature/{number}-{slug}`), commits, PRs — any phase that touches git | — |
| `write-skills` | Creating or updating skills in `.agents/skills/` | [REFERENCE.md](.agents/skills/write-skills/REFERENCE.md) · [EXAMPLES.md](.agents/skills/write-skills/EXAMPLES.md) |

**Domain** (extend `implement` REFACTOR with implementation patterns — named `*-engineering`):

| Skill | When to invoke |
|-------|----------------|
| `application-engineering` | AI-backed REST APIs, Claude single-call integration, OTel instrumentation, SSE streaming, auth patterns |
| `data-engineering` | Medallion pipeline, SQLAlchemy, Polars, DuckLake |
| `agentic-engineering` | Plan-Act-Observe loops, multi-turn tool use, agent state, multi-agent coordination |

Load exactly one domain skill per session. `application-engineering` is the default for `project_type: application`. If an endpoint invokes an agent loop, load both: `application-engineering` for the endpoint, `agentic-engineering` for the loop internals.

Domain-specific information for this project is captured in ADRs matching the project type — see `docs/adr/ADR-007-project-type-selection.md` and any domain ADRs with `Status: Accepted`.

## Repository Layout

| Path | Purpose |
|------|---------|
| `src/main.py` | Entry point |
| `src/config.py` | Centralised config (pydantic-settings, loads `.env`) |
| `src/utils/` | Generic transferable modules (`m_*.py`) |
| `src/<domain>/` | Domain-specific logic — add folders here as the project grows |
| `src/tools/` | Developer utilities — executed directly, never imported by application code |
| `tests/` | Pytest suite, mirrors `src/` and `tools/` hierarchy |
| `.agents/skills/` | Skill system — invoke skills before implementing manually |
| `docs/adr/` | Architecture Decision Records (MADR format) |
| `docs/TESTING.md` | Pytest conventions, fixture patterns, file-mirroring rule, coverage floor |
| `docs/SKILLS.md` | Skill invocation protocol, workflow lifecycle, domain vs. meta skill selection |
| `CONTEXT.md` | Leading repo-structure doc — domain glossary, bounded contexts, Module Map (agent navigation index), architectural constraints |
| `.github/workflows/` | CI (`ci.yml`: lint + typecheck + test); the alignment gate (`align.yml`: refine→architect→plan on issue creation); the orchestrator drain (`orchestrator.yml`: implement→review→merge) |
| `.github/scripts/kanban/` | Orchestrator **library**: the `Kanban` PowerShell module (`Kanban.psd1`/`.psm1`, `Import-Module`). One script per lane — `Refine.ps1` (Backlog gate + `Invoke-Alignment`), `Architect.ps1`/`Implement.ps1`/`Review.ps1`/`Merge.ps1`, conducted by `Orchestrator.ps1`. No top-level `param()` in module files (ADR-013) |
| `.github/scripts/tasks/` | Thin Taskfile/workflow commands that `Import-Module` the library: `align`, `start`, `runner`, `retry`, `setup`, `sync-issues` |
| `.github/scripts/ci/` | CI gate scripts (`check-module-map.ps1`); generic `Claude.ps1` helper sits at `.github/scripts/` |
| _(issue body)_ | Per-issue pipeline artifacts live IN the issue body (ADR-011/ADR-014): `AGENT-STATE` JSON, `Agent Brief`, `Architect Impact`, `Implementation Plan` |

## Rules

1. **UV only.** `uv add`, `uv sync`, `uv run` — never `pip install`.
2. **No hardcoded secrets.** All config via `.env` + `src/config.py`.
3. **Test parity.** Every `src/**/*.py` and `tools/*.py` has a matching test file.
4. **Lint must pass.** `ruff check` + `ruff format --check` before commit.
5. **Standard library first.** Prefer stdlib over third-party packages.
6. **`src/utils/` stays generic.** No project-specific logic in `m_*.py` files.
7. **Never modify `AGENTS.md` or `CONTEXT.md` during implementation.** Changes to standing instructions or bounded contexts go through a `refine` session. The Module Map and Issue-Type Index inside `CONTEXT.md` are the exception — they may be updated mid-implementation when a new file or domain is discovered (per ADR-009).
8. **Sizing and priority rules** — Fibonacci estimate anchor, scale, and priority definitions — are defined in the `ISSUES.md` header.
9. **Map first, code second** (ADR-009). Follow the Context Protocol above before reading any source file. Name the target files explicitly before opening them.
10. **New `src/<domain>/` requires a Module Map row.** A PR that adds a new top-level `src/<domain>/` directory without adding a matching row to `CONTEXT.md` will be rejected by the `ship` skill.

## Safety & Boundaries

- Never modify files outside the project root.
- Never install global packages or modify global configs.
- When in doubt, fail safely and surface the ambiguity.
