<!-- Values populated by task setup — run after copier copy -->
# CONTEXT.md — __PROJECT_NAME__

__PROJECT_DESCRIPTION__

---

## Glossary

| Term | Definition | Disambiguation |
|------|------------|----------------|
| Stage | One of the six units of work an issue passes through: `refine`, `architect`, `plan`, `implement`, `review`, `ship`. Each has one skill and one library script of the same name; four carry a label. | A stage does work; a lane holds it |
| Lane | A column on the GitHub Project board. There are four: Backlog, Implementing, Review, Shipped. | Six stages, four lanes — the first three never rest |
| Orchestrator | The PowerShell module at `.github/orchestrator/`. `Orchestrator.psm1` loads the library and is the single conductor of all six stages (`Invoke-Orchestration -From refine|implement`); `Orchestrator.psd1` declares the public surface. Owns every lane transition. Run context from `Get-OrchestratorContext`. | Not a human code review; not the board, which is one view of the state it manages |
| Method | How a stage is carried out. TDD is the method of `implement`. A stage may change method without changing its name. | — |
| Engine | An LLM provider adapter in `.github/orchestrator/engines/` — one file per provider. Each engine supplies its model for every Tier (its `Engines` row in `lib/Config.ps1`). One setting, `Engine`, chooses the engine that runs; an engine is enabled only once it fits the whole flow. | — |
| Check | A validator in `.github/checks/`, run by `checks.yml`. Named `check-<thing>.ps1`. | — |
| Task | A named model call — `Refine`, `Plan`, `ImplementLarge`, `ImplementSmall`, `Review`, `CommitMessage`, `EngineCheck`. `TaskTiers` in `lib/Config.ps1` gives each task its Tier, and `Get-TaskModel` answers which model it runs on, stopping the run when a value is missing. | Not a Command |
| Tier | A class of work, the same for every engine: `routine` (mechanical, one-shot text in a fixed format), `standard` (bounded work against a clear specification), `complex` (judgement on open or wide work — questions, design, trade-offs, a verdict). | Named for the work, never for a model |
| Command | A runnable in `.github/tasks/`, run with `pwsh -NoProfile -File .github/tasks/<name>.ps1`. Only `setup` also has a `Taskfile.yml` target. | Not a Task |
| Library | A PowerShell file dot-sourced by the module loader. PascalCase. Declares no top-level `param()` — dot-sourcing executes that block in the caller's scope (ADR-013). | Opposite of a Runnable |
| Runnable | A PowerShell file invoked directly. lowercase. Owns its `param()`. | Opposite of a Library |
| Carrier | The GitHub issue body. Holds the `AGENT-STATE` block (`open_questions[]`, `decided_questions[]`, `attempts[]`, `failed_at`) and the Agent Brief, Decisions, Architecture Impact, Implementation Plan and Attempts sections. | The only cross-runtime state medium (ADR-011). The owner talks to the pipeline in comments; the pipeline answers in the carrier |
| AFK | Execution mode: unattended, on GitHub Actions (`afk.yml`), driven by issue events — opened, `agent:backlog` added, owner comment. The default. The `afk.ps1` Command only backfills refine. | A mode, never a label |
| HITL | Execution mode: interactive, on the local machine. Entry point the `hitl.ps1` Command. Has no workflow. | A mode, never a label |
| `agent:` | Label prefix — the agent holds the ball. `agent:refining` marks the alignment gate (refine → architect → plan) as active. With the two `human:` holds these are the pipeline labels: an issue carries exactly one at a time, set only by `Set-AgentState` (ADR-015, 2026-10-02). | An owner's `human:approval` replaced by a later state is kept as `approval_required` in the carrier |
| `human:` | Label prefix — a human holds the ball; nothing advances until they act. `human:decision` = the issue waits on answers to the questions listed in it (set by refine); `human:approval` = a green PR waits for the owner's merge (set by ship when the diff touches `GovernancePaths` or any path outside `WritablePaths`, or by the owner); a comment on `human:approval` is a change request that starts a revision cycle on the existing PR. Labels are the pipeline's output — issues are written without them. | `human:approval`, not `human:review` — "review" already names the agent's own stage |
| Proposal | A committed change to a path outside `WritablePaths`. The agent writes it like any other change; ship holds the PR at `human:approval` with the files and their diffstat named, and merging is the approval (#285). | Not a question — refine never asks whether to make one |
| `KANBAN_*` variables | Deliberately retained — the one exception to the single-vocabulary rule. `KANBAN_RUNNER_PROFILE`, for one, is a live GitHub repository variable; renaming them means touching repository Settings and every generated project's setup for no functional gain. Do not "fix" them. | The module is `Orchestrator`; only the variable prefix is legacy |
| Eval | A pytest test marked `eval` that runs one stage's instructions on a stored case, on the model that stage uses, and checks the outcome in code — no judge model, no rubric, no pass mark. Four exist: review, refine, implement, commit. Opt-in: `uv run pytest -m eval`; gated in CI by the `eval` job when a file an eval reads changes (`tests/README.md` § Evals) | Not the review stage: review judges a *change* against its issue; an eval checks a *stage* against fixed cases |
| ISSUES.md | Local backlog of Agile User Story blocks, synced to GitHub Issues by the `sync.ps1` Command | Separate from GitHub Issues themselves |
| Signal comment | Issue comment starting with the robot emoji AND written by a trusted author (one whose `author_association` is in `TrustedAuthors`); posted by the orchestrator for agent decisions and outcomes (review results, failures, CI). Retrieved by agents by both criteria — prefix and trusted author — to reconstruct issue history | Not orchestrator log noise |
| Noise comment | Issue comment starting with a middle dot; orchestrator log entry (state transitions, stage starts). Never retrieved by agents | — |
| Owner comment | Any other comment by someone with write access — answers, context, guidance. Triggers the pipeline and is passed to every agent prompt | The pipeline posts with the owner's PAT, so the 🤖/· prefix is the only thing telling its comments apart; `Add-Comment` enforces it |

## Bounded Contexts

| Context | Owns | Does Not Own |
|---------|------|--------------|
| `src/` | Application logic, config, utilities | Developer tooling |
| `src/utils/` | Generic transferable modules (`m_*.py`) | Project-specific logic |
| `src/tools/` | Developer CLI utilities (`commit-msg`) | Application business logic |
| `.agents/skills/` | AI workflow constraints and patterns | Runtime code |
| `.github/orchestrator/` | The orchestrator module: all six stages and every lane transition | Application features; the commands that drive it (`.github/tasks/`); the validators (`.github/checks/`) |
| `docs/adr/` | This project's own Architecture Decision Records (MADR); ADR-000 is the blank form; this project's ADRs start at ADR-001 | Live documentation |

## Module Map

Navigation index for agents — how to use it is the Context Protocol in `AGENTS.md`. A new top-level `src/<domain>/` adds a row in the same PR (ADR-009).

| Module | Path | Bounded Context | Entry points |
|---|---|---|---|
| main | `src/main.py` | `src/` | `HelloHandler` (HTTPServer entry point) |
| config | `src/config.py` | `src/` | `Settings` (pydantic-settings) |
| utils | `src/utils/` | `src/utils/` | `m_*.py` modules — generic only |
| tools | `src/tools/` | `src/tools/` | per-tool `main()` (executed directly) |
| tests | `tests/` | mirrors `src/` and `tools/` | `pytest` discovery |
| orchestrator (library) | `.github/orchestrator/` | `.github/orchestrator/` | `Orchestrator.psd1` (explicit `FunctionsToExport`) / `Orchestrator.psm1` (loader + `Invoke-Orchestration`, the single conductor); `stages/` one file per stage — `Refine`, `Architect`, `Plan`, `Implement`, `Review`, `Ship`; `engines/` — `Claude.ps1`, `Gemini.ps1`; `lib/` — `Config.ps1` (incl. `$PipelineStates`, the one label table, and the model table — `Engine`, `Engines`, `TaskTiers`, read by `Get-TaskModel`), `GitHub.ps1`, `Util.ps1`, `Reconcile.ps1` (re-entry + the hourly warden), `Grill.ps1` |
| orchestrator (commands) | `.github/tasks/` | `.github/tasks/` | One runnable per Command: `refine.ps1` (Backlog gate), `hitl.ps1` (local), `afk.ps1` (cloud drain), `retry.ps1` (re-enters one issue), `reconcile.ps1` (re-enters every state nothing is working on), `setup.ps1`, `sync.ps1`, `protect.ps1`. Each owns its `param()` and `Import-Module`s the orchestrator. |
| checks | `.github/checks/` | `.github/checks/` | `check-module-map.ps1`, `check-references.ps1`, `check-orchestrator-api.ps1`, `check-token-scope.ps1` — the `checks` job of `checks.yml` runs every `check-*.ps1` in the folder, so a new check is a new file |
| skills | `.agents/skills/` | `.agents/skills/` | one directory per skill, each with `SKILL.md`; `review/answer.schema.json` defines the review's checked answer (`verdict`, `report`), passed to the engine by `stages/Review.ps1` and the review eval |
| ADRs (this project) | `docs/adr/` | `docs/adr/` | ADR-000 is the blank form; this project's ADRs start at ADR-001 |
| CI | `.github/workflows/` | (cross-cutting) | `checks.yml` (lint/typecheck/test/audit/checks), `afk.yml` (the pipeline, driven by issue events; hourly reconcile of states nothing is working on, incl. usage-limit resume; `stage` dispatch for overrides), `build.yml`, `deploy.yml` |
| contributor docs | `.github/ISSUE_TEMPLATE/`, `CONTRIBUTING.md` | (cross-cutting) | `issue.md` (the one place an issue's headings are written, no labels — read by `Get-IssueTemplate` / `Get-IssueHeadings` in `lib/Util.ps1` for refine's check, the epic child-issue body and `sync.ps1`'s block check), `config.yml` (blank issues off), `CONTRIBUTING.md` (how a change becomes a merged PR); `tests/test_issue_template.py` asserts ISSUES.md does not repeat the headings |
| `<domain>` | `src/<domain>/` | declared on first feature | declared on first feature |

## Issue-Type → Files Index

For each kind of work, read these files before opening anything else. If an unexpected file matters, add it to the Module Map *before* finishing the task.

| Working on... | Read first (nothing else unless surprised) |
|---|---|
| orchestrator change | `.github/orchestrator/Orchestrator.psm1` (load order + conductor), `lib/Config.ps1`, the affected stage file (`stages/Implement.ps1` / `stages/Review.ps1` / `stages/Ship.ps1`) or `lib/GitHub.ps1`, or the command (`.github/tasks/hitl.ps1`); for implement, `tests/orchestrator/test_implement_refusal.py`; for bringing a branch up to date (`Update-Branch`), `tests/orchestrator/test_update_branch.py`; for draft pull requests and the shipped guard (`Set-PRReady`, `Assert-NotShipped`), `tests/orchestrator/test_draft_pr.py`; for the conflict check after a merge (`Start-ConflictRounds`, `Test-BranchConflict`), `tests/orchestrator/test_conflict_rounds.py` |
| model / tier change | `.github/orchestrator/lib/Config.ps1` (`Engine`, `Engines`, `TaskTiers`, `ImplementLargeFrom`, `Get-TaskModel`), `tests/orchestrator/test_task_model.py`, `tests/evals/stage_models.py` |
| label / lane / state-machine change | `.github/orchestrator/lib/Config.ps1` (`$PipelineStates` — the one table), `lib/GitHub.ps1` (`Set-AgentState`), `lib/Reconcile.ps1`, `tests/orchestrator/test_reconcile.py`, `tests/test_kanban_state.py` |
| recovery / stuck-issue change | `.github/orchestrator/lib/Reconcile.ps1`, `lib/Config.ps1` (`$PipelineStates`, `StuckAfterMinutes`, `MaxReconcile`), `.github/tasks/reconcile.ps1`, `.github/tasks/retry.ps1`, `.github/workflows/afk.yml`, `tests/orchestrator/test_reconcile.py` |
| refine-stage change | `.github/orchestrator/stages/Refine.ps1` (`Invoke-Refine`, `Format-DecisionQuestions`), `stages/Architect.ps1`, `stages/Plan.ps1`, `.github/workflows/afk.yml`, `.github/tasks/refine.ps1`, `tests/orchestrator/test_refine.py`, `tests/orchestrator/test_architect.py` |
| sync-issues change | `.github/tasks/sync.ps1`, `tests/orchestrator/test_sync_issues.py`; for the heading check, `.github/ISSUE_TEMPLATE/issue.md`, `lib/Util.ps1` (`Get-IssueHeadings`), `tests/orchestrator/test_issue_headings.py` |
| `src/utils/` change | `src/utils/m_*.py`, matching `tests/utils/test_*.py` |
| `src/tools/` change | `src/tools/*.py`, matching `tests/tools/test_*.py` |
| eval change | the target's `tests/evals/test_*_eval.py` + `goldens/*.jsonl`, `tests/evals/stage_models.py` (the stages' models, read through `Get-TaskModel` in `.github/orchestrator/lib/Config.ps1`), `tests/evals/eval_goldens.py`, `tests/README.md` § Evals, `.github/workflows/checks.yml` (`eval-scope` `PATHS_*`, `eval` job) |
| ADR addition (this project's application) | `docs/adr/ADR-000-template-architecture-decision.md` (the blank form) |
| CI workflow change | `.github/workflows/*.yml`, `Taskfile.yml`, `pyproject.toml` |
| skill change | `.agents/skills/<name>/SKILL.md`, `.agents/skills/<name>/REFERENCE.md`, `.agents/skills/<name>/EXAMPLES.md`, `AGENTS.md` skill index |
| new `src/<domain>/` | `CONTEXT.md` Module Map (extend first), `AGENTS.md` Rules, then proceed |
| dependency / config | `pyproject.toml`, `uv.lock`, `.devcontainer/`, `Dockerfile` |

## Architectural Constraints

Invariants that must not be violated in any implementation.

- **UV only** — `uv add`, `uv sync`, `uv run`. Never `pip install`.
- **No hardcoded secrets** — all config via `.env` + `src/config.py`.
- **Test parity** — every `src/**/*.py` has a matching test file in `tests/`.
- **Lint gate** — `ruff check` + `ruff format --check` must pass before any commit.
- **`src/utils/` is generic** — no project-specific logic in `m_*.py` modules.
- **Standard library first** — prefer stdlib over third-party packages.
- **Claude-first AI** — Claude is the default engine and the only one in the cloud. Each engine supplies its models to the Tiers, and the one setting `Engine` in `lib/Config.ps1` chooses the engine; it ships as `claude`. Gemini has an `Engines` row but is not yet compatible with the flow and must not be selected.
- **Dev Container is the environment spec** — `.devcontainer/` defines it; keep its base image on the `requires-python` version, `uv sync` in the post-create step, and the `github-cli` and `powershell` features. One container per task — never reuse one across issues.
- **PowerShell 7+** — all `.ps1` scripts target `#Requires -Version 7.0`. Never target PS 5.1.
- **pydantic-settings `extra="ignore"`** — Settings class must always ignore unknown env vars.
- **This repo is simultaneously a project and a Copier template of itself** — anything under `tests/`, `pyproject.toml`, or the skill tree usually has a second home under the template root (a `.jinja2` suffix, or an entry in `copier.yml` `_exclude`). Check for a parallel path before assuming one edit is enough; missing it has broken generated projects twice.
- **Skills travel with generated projects** (ADR-009) — every skill referenced in `AGENTS.md` MUST be physically present under `.agents/skills/` in every generated project. Skill files local to `~/.claude/skills/` alone do not satisfy this constraint.
- **KISS** — no premature abstractions or heavy frameworks where a simple standard-library implementation suffices (e.g. `src/main.py` uses `http.server`, not a web framework).
- **Dependency Inversion** — external I/O (HTTP, filesystem, subprocess) sits behind an interface declared in `src/`. `src/tools/` is exempt: thin CLI utilities may call I/O directly.
- **DRY (Rule of Three)** — extract to `src/utils/` only once code is duplicated three times. `architect` flags duplication that meets the threshold.
- **The state machine is rigid** — `$PipelineStates` lists only transitions on the designed path. An issue that reaches a state the table refuses left the path somewhere: close that entry point, never widen `AllowedFrom` to accept it.

## Out of Scope

Rejected and deferred concepts live in one ledger, [`.out-of-scope.md`](.out-of-scope.md) — search it
before proposing anything new.
