# AGENTS.md — Project Context for AI Agents

## Project Identity

**{{ project_name }}** — {{ description }}

| Key | Value |
|-----|-------|
| Stack | Python + UV |
| Project Type | {{ project_type }} |
| Entry point | `main.py` |
| Config | `src/config.py` (pydantic-settings, loads `.env`) |

## Session Initialisation

Load in this order at the start of every session:

1. `CONTEXT.md` — domain glossary, bounded contexts, and architectural constraints
2. `AGENTS.md` — this file; standing instructions and skill index
3. `docs/adr/ADR_STRUCTURE.md` — master ADR index; filter by `applies_to` for the current `project_type` and load only the relevant ADR files
4. Task-specific context — issue description, PR diff, or user prompt

Never begin a task without reading `CONTEXT.md` first. An agent that skips this will hallucinate boundaries that were already agreed.

After reading `ADR_STRUCTURE.md`, load only the ADRs that match the current `project_type`. For `project_type: application` (the default): ADR-003, ADR-004, ADR-007, ADR-008. Do not load ADRs scoped to other project types — they pollute context with irrelevant constraints.

If loading steps 1–3 + step 4 would push context fill past 100k tokens, offload step 4 to the filesystem and load on demand.

## Skills

Invoke the relevant skill before implementing manually. Skills are located in `.agents/skills/`.

**Workflow** (sequential — refine → architecture → plan → tdd → harness → review → ship):

| Skill | When to invoke |
|-------|----------------|
| `refine` | Starting a new feature — alignment on glossary, boundaries, and ADRs before any code |
| `architecture` | Analysing dependencies, blast-radius, or module structure |
| `plan` | Translating an Agent Brief into a Lean PRD and decomposed GitHub Issues |
| `tdd` | Implementing features via Red-Green-Refactor |
| `harness` | Provisioning environments, managing context health, Planner/Generator/Evaluator split |
| `review` | Code review, auto-fix loop, PR validation |
| `ship` | Pre-merge security checks, squash merge, knowledge base update |

**Meta** (project-type agnostic, cross-cutting — load on demand):

| Skill | When to invoke |
|-------|----------------|
| `version-control` | Branching (`feature/{number}-{slug}`), commits, PRs — any phase that touches git |
| `write-skills` | Creating or updating skills in `.agents/skills/` |

**Domain** (extend `tdd` REFACTOR with implementation patterns — named `*-engineering`):

| Skill | When to invoke |
|-------|----------------|
| `application-engineering` | AI-backed REST APIs, Claude single-call integration, OTel instrumentation, SSE streaming, auth patterns |
| `data-engineering` | Medallion pipeline, SQLAlchemy, Polars, DuckLake |
| `agentic-engineering` | Plan-Act-Observe loops, multi-turn tool use, agent state, multi-agent coordination |

Load exactly one domain skill per session. `application-engineering` is the default for `project_type: application`. If an endpoint invokes an agent loop, load both: `application-engineering` for the endpoint, `agentic-engineering` for the loop internals.

Domain-specific information for this **{{ project_type }}** project is captured in ADRs matching this type — see `docs/adr/ADR-007-project-type-selection.md` and any domain ADRs with `Status: Accepted`.

## Repository Layout

| Path | Purpose |
|------|---------|
| `main.py` | Entry point |
| `src/config.py` | Centralised config (pydantic-settings, loads `.env`) |
| `src/utils/` | Generic transferable modules (`m_*.py`) |
| `src/<domain>/` | Domain-specific logic — add folders here as the project grows |
| `src/tools/` | Developer utilities — executed directly, never imported by application code |
| `tests/` | Pytest suite, mirrors `src/` and `tools/` hierarchy |
| `.agents/skills/` | Skill system — invoke skills before implementing manually |
| `docs/adr/` | Architecture Decision Records (MADR format) |
| `CONTEXT.md` | Domain glossary, bounded contexts, architectural constraints |
| `.github/workflows/` | CI: lint + typecheck + test |

## Rules

1. **UV only.** `uv add`, `uv sync`, `uv run` — never `pip install`.
2. **No hardcoded secrets.** All config via `.env` + `src/config.py`.
3. **Test parity.** Every `src/**/*.py` and `tools/*.py` has a matching test file.
4. **Lint must pass.** `ruff check` + `ruff format --check` before commit.
5. **Standard library first.** Prefer stdlib over third-party packages.
6. **`src/utils/` stays generic.** No project-specific logic in `m_*.py` files.
7. **Never modify `AGENTS.md` during implementation.** Changes go through a `refine` session.

## Safety & Boundaries

- Never modify files outside the project root.
- Never install global packages or modify global configs.
- When in doubt, fail safely and surface the ambiguity.
