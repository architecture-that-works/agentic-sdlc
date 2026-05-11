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
| Orchestrator Workflow | Label-driven agentic pipeline: `agent:backlog` triggers implement → review → merge | Not the same as a human code review |
| ISSUES.md | Local backlog of Agile User Story blocks, synced to GitHub Issues via `task sync` | Separate from GitHub Issues themselves |
| Kanban lane | GitHub Project board column mapped to an `agent:*` label | Managed automatically by `kanban-lanes.yml` |
| Signal comment | Issue comment starting with `🤖`; posted by the pipeline for agent decisions/outcomes (review results, failures, CI). Always retrieved by agents via `startswith("🤖")` filter to reconstruct issue history | Not to be confused with pipeline log noise |
| Noise comment | Issue comment starting with `·`; pipeline log entry (state transitions, phase starts). Never retrieved by agents | All other issue comments are noise |

## Bounded Contexts

| Context | Owns | Does Not Own |
|---------|------|--------------|
| `src/` | Application logic, config, utilities | Developer tooling |
| `src/tools/` | Developer CLI utilities (`commit-msg`) | Application business logic |
| `.agents/skills/` | AI workflow constraints and patterns | Runtime code |
| `.github/scripts/kanban/` | Orchestrator Workflow pipeline orchestration | Application features |

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

## Out of Scope

Concepts explicitly deferred or rejected. Prevents re-proposal in planning sessions.

| Concept | Reason deferred | Date |
|---------|-----------------|------|
| Multi-variant template (separate per-type scaffolds) | Single template with project_type prompt; specialised directory stubs deferred | 2026-05-10 |
| Gemini as primary AI provider | Claude-first; Gemini reserved as future secondary slot | 2026-05-09 |
