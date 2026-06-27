<!-- Values populated by task setup — run after copier copy -->
# CONTEXT.md — __PROJECT_NAME__

__PROJECT_DESCRIPTION__

| Key | Value |
|-----|-------|
| Project Type | __PROJECT_TYPE__ |

---

## Glossary

| Term | Definition | Disambiguation |
|------|------------|----------------|
| Orchestrator | Label-driven agentic workflow: `agent:backlog` triggers implement → review → merge. Configured in `.github/scripts/kanban/config.ps1`. | Not the same as a human code review |
| Orchestration | The full implement → review loop → merge sequence run by the orchestrator for a single issue | One orchestration run = one issue end-to-end |
| ISSUES.md | Local backlog of Agile User Story blocks, synced to GitHub Issues via `task sync` | Separate from GitHub Issues themselves |
| Kanban lane | GitHub Project board column mapped to an `agent:*` label | Managed automatically by `kanban-lanes.yml` |
| Signal comment | Issue comment starting with `🤖`; posted by the orchestrator for agent decisions/outcomes (review results, failures, CI). Always retrieved by agents via `startswith("🤖")` filter to reconstruct issue history | Not to be confused with orchestrator log noise |
| Noise comment | Issue comment starting with `·`; orchestrator log entry (state transitions, phase starts). Never retrieved by agents | All other issue comments are noise |

## Bounded Contexts

| Context | Owns | Does Not Own |
|---------|------|--------------|
| `src/` | Application logic, config, utilities | Developer tooling |
| `src/utils/` | Generic transferable modules (`m_*.py`) | Project-specific logic |
| `src/tools/` | Developer CLI utilities (`commit-msg`) | Application business logic |
| `.agents/skills/` | AI workflow constraints and patterns | Runtime code |
| `.github/scripts/kanban/` | Orchestrator: issue orchestration (implement → review → merge) | Application features |
| `docs/adr/` | Architecture Decision Records (MADR) | Live documentation |

## Module Map

Navigation index for agents. Read CONTEXT.md, identify the target bounded context, then open only the files in that row. Rows added when a new top-level `src/<domain>/` directory is introduced (enforced by `ship` per ADR-009).

| Module | Path | Bounded Context | Entry points |
|---|---|---|---|
| main | `src/main.py` | `src/` | `HelloHandler` (HTTPServer entry point) |
| config | `src/config.py` | `src/` | `Settings` (pydantic-settings) |
| utils | `src/utils/` | `src/utils/` | `m_*.py` modules — generic only |
| tools | `src/tools/` | `src/tools/` | per-tool `main()` (executed directly) |
| tests | `tests/` | mirrors `src/` and `tools/` | `pytest` discovery |
| orchestrator | `.github/scripts/kanban/` | `.github/scripts/kanban/` | `start.ps1` (HITL local), `runner.ps1` (GHA queue drain), `retry.ps1` (recovery) — task entry points; `run.ps1` (full pipeline), `config.ps1` (configuration) |
| scripts | `.github/scripts/` | `.github/scripts/` | `sync-issues.ps1` (ISSUES.md → GitHub Issues + Project board), `setup.ps1`, `check-module-map.ps1` |
| skills | `.agents/skills/` | `.agents/skills/` | one directory per skill, each with `SKILL.md` |
| ADRs | `docs/adr/` | `docs/adr/` | `ADR_STRUCTURE.md` (master index) |
| CI | `.github/workflows/` | (cross-cutting) | `ci.yml`, `build.yml` |
| `<domain>` | `src/<domain>/` | declared on first feature | declared on first feature |

## Issue-Type → Files Index

For each kind of work, read these files before opening anything else. If an unexpected file matters, add it to the Module Map *before* finishing the task.

| Working on... | Read first (nothing else unless surprised) |
|---|---|
| orchestrator change | `.github/scripts/kanban/config.ps1`, `_common.ps1`, the affected stage script (`implement.ps1` / `review.ps1` / `merge.ps1` / `start.ps1`) |
| sync-issues change | `.github/scripts/sync-issues.ps1`, `tests/scripts/test_sync_issues.py` |
| `src/utils/` change | `src/utils/m_*.py`, matching `tests/utils/test_*.py` |
| `src/tools/` change | `src/tools/*.py`, matching `tests/tools/test_*.py` |
| ADR addition | `docs/adr/ADR_STRUCTURE.md`, `ADR-000` template |
| CI workflow change | `.github/workflows/*.yml`, `Taskfile.yml`, `pyproject.toml` |
| skill change | `.agents/skills/<name>/SKILL.md`, `.agents/skills/<name>/REFERENCE.md`, `.agents/skills/<name>/EXAMPLES.md`, `AGENTS.md` skill index |
| new `src/<domain>/` | `CONTEXT.md` Module Map (extend first), `AGENTS.md` Rules, then proceed |
| dependency / config | `pyproject.toml`, `uv.lock`, `.devcontainer/`, `Dockerfile` |
| template / Copier change | `copier.yml`, `pyproject.toml.jinja2`, `tests/test_copier_template.py` |

## Architectural Constraints

Invariants that must not be violated in any implementation.

- **UV only** — `uv add`, `uv sync`, `uv run`. Never `pip install`.
- **No hardcoded secrets** — all config via `.env` + `src/config.py`.
- **Test parity** — every `src/**/*.py` has a matching test file in `tests/`.
- **Lint gate** — `ruff check` + `ruff format --check` must pass before any commit.
- **`src/utils/` is generic** — no project-specific logic in `m_*.py` modules.
- **Standard library first** — prefer stdlib over third-party packages.
- **Claude-first AI** — Claude CLI (primary) → Claude SDK (fallback). Gemini slot reserved; do not add as primary.
- **PowerShell 7+** — all `.ps1` scripts target `#Requires -Version 7.0`. Never target PS 5.1.
- **pydantic-settings `extra="ignore"`** — Settings class must always ignore unknown env vars.
- **Module Map is the source of truth** (ADR-009) — every new top-level `src/<domain>/` directory MUST add a row to the Module Map in the same PR. Enforced by the `ship` skill.
- **Skills travel with generated projects** (ADR-009) — every skill referenced in `AGENTS.md` MUST be physically present under `.agents/skills/` in every generated project. Skill files local to `~/.claude/skills/` alone do not satisfy this constraint.
- **Context Protocol is mandatory** (ADR-009) — agents MUST follow `AGENTS.md` §Session Initialisation → Context Protocol before reading any source file.

## Out of Scope

Top-5 summary of explicitly deferred or rejected concepts. Full ledger with date and source ADR cross-links: [`.out-of-scope.md`](.out-of-scope.md). Plan-phase deduplication MUST search `.out-of-scope.md`, not this table.

| Concept | Reason deferred | Date |
|---------|-----------------|------|
| Embedded web framework (FastAPI/Flask) in the hello-world starter | Standard Library First constraint; stdlib http.server is sufficient | 2026-05-12 |
| Separate `CLAUDE.md` for behavioural rules | Rejected in ADR-009; `AGENTS.md` is the single standing-instructions file (cross-tool convention) | 2026-05-11 |
| Generic Module Map per project_type (separate maps for application / agent / ml) | Rejected in ADR-009; single Map at template-time lists only invariant rows; project_type-specific rows added as first feature lands | 2026-05-11 |
| Codespace as HITL validation surface | HITL surface is the developer's laptop indefinitely; persistent Cloud Run Orchestrator Service is the Phase-3 cloud-runtime north star, not Codespaces | 2026-05-12 |
| LangGraph (or any agent-framework library) as orchestrator runtime | Drag too high for a template — forks should not need to learn LangGraph. Steal patterns (declarative graph, checkpoint, interrupt) without the dependency | 2026-05-12 |
