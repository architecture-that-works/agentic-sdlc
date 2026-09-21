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
| Stage | One of the six units of work an issue passes through: `refine`, `architect`, `plan`, `implement`, `review`, `ship`. Each has one skill and one library script of the same name; three carry a label. | A stage does work; a lane holds it |
| Lane | A column on the GitHub Project board. There are four: Backlog, Implementing, Review, Shipped. | Six stages, four lanes — the first three never rest |
| Orchestrator | The PowerShell module at `.github/orchestrator/`. `Orchestrator.psm1` loads the library and is the single conductor of all six stages (`Invoke-Orchestration -From refine|implement`); `Orchestrator.psd1` declares the public surface. Owns every lane transition. Run context from `Get-OrchestratorContext`. | Not a human code review; not the board, which is one view of the state it manages |
| Method | How a stage is carried out. TDD is the method of `implement`. A stage may change method without changing its name. | — |
| Engine | An LLM provider adapter in `.github/orchestrator/engines/` — one file per provider. Selected by `KANBAN_ENGINE`. | — |
| Check | A validator in `.github/checks/`, run by `checks.yml`. Named `check-<thing>.ps1`. | — |
| Task | A command in `Taskfile.yml`. Each target is backed by one runnable of the same name in `.github/tasks/`. | — |
| Library | A PowerShell file dot-sourced by the module loader. PascalCase. Declares no top-level `param()` — dot-sourcing executes that block in the caller's scope (ADR-013). | Opposite of a Runnable |
| Runnable | A PowerShell file invoked directly. lowercase. Owns its `param()`. | Opposite of a Library |
| Carrier | The GitHub issue body. Holds the `AGENT-STATE` block, `open_questions[]`, `decided_questions[]`, `failed_at`, and the Architecture Impact, Implementation Plan and Agent Brief sections. | The only cross-runtime state medium (ADR-011) |
| AFK | Execution mode: unattended, on GitHub Actions. Entry point `task runner`, workflow `afk.yml`. The default. | A mode, never a label |
| HITL | Execution mode: interactive, on the local machine. Entry point `task start`. Has no workflow. | A mode, never a label |
| `agent:` | Label prefix — the agent holds the ball. Exactly one `agent:` label at a time. | — |
| `human:` | Label prefix — a human holds the ball; nothing advances until they act. `human:approval` = merge authority; `human:decision` = a question, never a work item. | `human:approval`, not `human:review` — "review" already names the agent's own stage |
| `KANBAN_*` variables | Deliberately retained — the one exception to the single-vocabulary rule. `KANBAN_ENGINE` and `KANBAN_RUNNER_PROFILE` are live GitHub repository variables; renaming them means touching repository Settings and every generated project's setup for no functional gain. Do not "fix" them. | The module is `Orchestrator`; only the variable prefix is legacy |
| ISSUES.md | Local backlog of Agile User Story blocks, synced to GitHub Issues via `task sync` | Separate from GitHub Issues themselves |
| Signal comment | Issue comment starting with the robot emoji; posted by the orchestrator for agent decisions and outcomes (review results, failures, CI). Retrieved by agents by that prefix to reconstruct issue history | Not orchestrator log noise |
| Noise comment | Issue comment starting with a middle dot; orchestrator log entry (state transitions, stage starts). Never retrieved by agents | All other issue comments are noise |

## Bounded Contexts

| Context | Owns | Does Not Own |
|---------|------|--------------|
| `src/` | Application logic, config, utilities | Developer tooling |
| `src/utils/` | Generic transferable modules (`m_*.py`) | Project-specific logic |
| `src/tools/` | Developer CLI utilities (`commit-msg`) | Application business logic |
| `.agents/skills/` | AI workflow constraints and patterns | Runtime code |
| `.github/orchestrator/` | The orchestrator module: all six stages and every lane transition | Application features; the commands that drive it (`.github/tasks/`); the validators (`.github/checks/`) |
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
| orchestrator (library) | `.github/orchestrator/` | `.github/orchestrator/` | `Orchestrator.psd1` (explicit `FunctionsToExport`) / `Orchestrator.psm1` (loader + `Invoke-Orchestration`, the single conductor); `stages/` one file per stage — `Refine`, `Architect`, `Plan`, `Implement`, `Review`, `Ship`; `engines/` — `Claude.ps1`, `Gemini.ps1`; `lib/` — `Config.ps1`, `GitHub.ps1`, `Util.ps1`, `Grill.ps1` |
| orchestrator (commands) | `.github/tasks/` | `.github/tasks/` | One runnable per `Taskfile.yml` target: `align.ps1` (Backlog gate), `start.ps1` (HITL), `runner.ps1` (AFK drain), `retry.ps1` (resumes from `failed_at`), `setup.ps1`, `sync.ps1`, `protect.ps1`. Each owns its `param()` and `Import-Module`s the orchestrator |
| checks | `.github/checks/` | `.github/checks/` | `check-module-map.ps1`, `check-script-paths.ps1`, `check-doc-paths.ps1`, `check-module-api.ps1`, `verify-settings.ps1` — all run by `checks.yml` |
| skills | `.agents/skills/` | `.agents/skills/` | one directory per skill, each with `SKILL.md` |
| ADRs | `docs/adr/` | `docs/adr/` | `ADR_STRUCTURE.md` (master index) |
| CI | `.github/workflows/` | (cross-cutting) | `checks.yml` (lint/typecheck/test/audit/guards), `afk.yml` (whole pipeline unattended; `stage` input), `build.yml`, `deploy.yml`, `branch-protection.yml` |
| `<domain>` | `src/<domain>/` | declared on first feature | declared on first feature |

## Issue-Type → Files Index

For each kind of work, read these files before opening anything else. If an unexpected file matters, add it to the Module Map *before* finishing the task.

| Working on... | Read first (nothing else unless surprised) |
|---|---|
| orchestrator change | `.github/orchestrator/Orchestrator.psm1` (load order + conductor), `lib/Config.ps1`, the affected stage file (`stages/Implement.ps1` / `stages/Review.ps1` / `stages/Ship.ps1`) or `lib/GitHub.ps1`, or the task entry (`.github/tasks/start.ps1`) |
| refine-stage change | `.github/orchestrator/stages/Refine.ps1` (`Invoke-Refine`), `stages/Architect.ps1`, `stages/Plan.ps1`, `.github/workflows/afk.yml`, `.github/tasks/align.ps1`, `tests/orchestrator/test_architecture.py` |
| sync-issues change | `.github/tasks/sync.ps1`, `tests/orchestrator/test_sync_issues.py` |
| `src/utils/` change | `src/utils/m_*.py`, matching `tests/utils/test_*.py` |
| `src/tools/` change | `src/tools/*.py`, matching `tests/tools/test_*.py` |
| ADR addition | `docs/adr/ADR_STRUCTURE.md`, `ADR-000` template |
| CI workflow change | `.github/workflows/*.yml`, `Taskfile.yml`, `pyproject.toml` |
| skill change | `.agents/skills/<name>/SKILL.md`, `.agents/skills/<name>/REFERENCE.md`, `.agents/skills/<name>/EXAMPLES.md`, `AGENTS.md` skill index |
| new `src/<domain>/` | `CONTEXT.md` Module Map (extend first), `AGENTS.md` Rules, then proceed |
| dependency / config | `pyproject.toml`, `uv.lock`, `.devcontainer/`, `Dockerfile` |
| template / Copier change | `pyproject.toml.jinja2`, plus copier.yml and tests/test_copier_template.py — both template-only, copier excludes them from generated projects |

## Architectural Constraints

Invariants that must not be violated in any implementation.

- **UV only** — `uv add`, `uv sync`, `uv run`. Never `pip install`.
- **No hardcoded secrets** — all config via `.env` + `src/config.py`.
- **Test parity** — every `src/**/*.py` has a matching test file in `tests/`.
- **Lint gate** — `ruff check` + `ruff format --check` must pass before any commit.
- **`src/utils/` is generic** — no project-specific logic in `m_*.py` modules.
- **Standard library first** — prefer stdlib over third-party packages.
- **Dual-Engine AI** — Claude and Gemini are co-primary engines for the pipeline, orchestrated via `KANBAN_ENGINE` per run. Claude remains the template default.
- **PowerShell 7+** — all `.ps1` scripts target `#Requires -Version 7.0`. Never target PS 5.1.
- **pydantic-settings `extra="ignore"`** — Settings class must always ignore unknown env vars.
- **Module Map is the source of truth** (ADR-009) — every new top-level `src/<domain>/` directory MUST add a row to the Module Map in the same PR. Enforced by the `ship` skill.
- **Skills travel with generated projects** (ADR-009) — every skill referenced in `AGENTS.md` MUST be physically present under `.agents/skills/` in every generated project. Skill files local to `~/.claude/skills/` alone do not satisfy this constraint.
- **Context Protocol is mandatory** (ADR-009) — agents MUST follow `AGENTS.md` §Session Initialisation → Context Protocol before reading any source file.
- **KISS (Keep It Simple, Stupid)** — Avoid premature abstractions, heavy frameworks, or complex architectures when simpler standard-library implementations suffice. Example: `src/main.py` uses `http.server` instead of pulling in a web framework for a minimal healthcheck.
- **Dependency Inversion** — External I/O (HTTP, filesystem, subprocess) MUST be hidden behind an interface declared in `src/`. Exception: `src/tools/` is explicitly exempt to allow thin CLI utilities (e.g. `src/tools/commit.py` calls `subprocess.run` directly).
- **DRY (Rule of Three)** — Code must be duplicated three times before extraction to `src/utils/` is permitted to avoid premature abstraction. The `architect` stage should identify if functionality is duplicated and propose leveraging or generalizing an existing module if the threshold is met.

## Out of Scope

Top-5 summary of explicitly deferred or rejected concepts. Full ledger with date and source ADR cross-links: [`.out-of-scope.md`](.out-of-scope.md). Plan-phase deduplication MUST search `.out-of-scope.md`, not this table.

| Concept | Reason deferred | Date |
|---------|-----------------|------|
| Embedded web framework (FastAPI/Flask) in the hello-world starter | Standard Library First constraint; stdlib http.server is sufficient | 2026-05-12 |
| Separate `CLAUDE.md` for behavioural rules | Rejected in ADR-009; `AGENTS.md` is the single standing-instructions file (cross-tool convention) | 2026-05-11 |
| Generic Module Map per project_type (separate maps for application / agent / ml) | Rejected in ADR-009; single Map at template-time lists only invariant rows; project_type-specific rows added as first feature lands | 2026-05-11 |
| Codespace as HITL validation surface | HITL surface is the developer's laptop indefinitely; persistent Cloud Run Orchestrator Service is the Phase-3 cloud-runtime north star, not Codespaces | 2026-05-12 |
| LangGraph (or any agent-framework library) as orchestrator runtime | Drag too high for a template — forks should not need to learn LangGraph. Steal patterns (declarative graph, checkpoint, interrupt) without the dependency | 2026-05-12 |
