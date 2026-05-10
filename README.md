# python-uv-template

Copier-based Python project scaffold. Generates a production-ready structure with structured logging, typed config, AI-assisted commit messages, test coverage mirroring `src/`, and GitHub Actions CI — ready to `uv sync` and go.

## SDLC Maturity

**Current: 5.75 / 10 — Mid-Level AI Engineer** · Assessed: 2026-05-10

> Re-assess: load [`ASSESSMENT_PROMPT.md`](ASSESSMENT_PROMPT.md) into a Claude Code session, then update this table.

| Stage | Role | Criteria | Status |
|---|---|---|---|
| **0–2** | AI Student / Hobbyist | 5 / 5 | ✅ Git, UV lock, env-based config, Copier generator works cold |
| **3–4** | Junior AI Engineer | 8 / 8 | ✅ Blocking CI gates (lint · typecheck · test · pip-audit), SHA-pinned actions, Dependabot, `project_type` prompt |
| **5–6** | Mid-Level AI Engineer ◄ | 10 / 11 | 🔄 Skill files not embedded in generated projects — `AGENTS.md` references skills that don't travel via Copier |
| **7–8** | Senior AI Engineer | 0 / 12 | 🔲 Cloud-native orchestration · Dockerfile + devcontainer · WIF credentials · CODEOWNERS · SECURITY.md · template isolation |
| **9–10** | Principal AI Engineer | 0 / 6 | 🔲 Automated eval gates · self-improving CONTEXT.md · cold-start reproducibility · AI output evaluation harness |

**Score formula:** tier-gated binary checklist. All criteria in tier N must be met before tier N+1 points are awarded. Within the blocking tier: `base + (met/total × 2)`. Full criteria in [`ASSESSMENT_PROMPT.md`](ASSESSMENT_PROMPT.md).

---

## Table of Contents

- [SDLC Maturity](#sdlc-maturity)
- [Quickstart](#quickstart)
- [Repository Structure](#repository-structure)
- [Conventions](#conventions)
- [AI Workflow](#ai-workflow)

---

## Quickstart

Get a new project running in under 5 minutes.

**1. Install prerequisites** — once, globally:
```bash
uv tool install copier                        # project generator
winget install --id Microsoft.PowerShell      # PowerShell 7 (Windows)
winget install --id Task.Task                 # Taskfile runner
```

**2. Generate a new project**
```bash
uvx copier copy gh:your-username/my_template_repo path/to/new-project
```

Copier will prompt for:
- `project_name` — hyphenated name (e.g. `my-new-project`)
- `description` — one-line project description
- `project_type` — target project type: `application` (default), `agent`, or `ml`

**3. Replace the logging stub**
```bash
# Drop your m_log.py into src/utils/ — interface: f_log(), setup_logging(), f_log_execution()
```

**4. Wire up the Director Workflow** — once per project:

a. Create a GitHub Project (Projects v2, Kanban board) with a **Status** field containing at least: `Backlog`, `Implementing`, `Review`, `Merged`.

b. Set the two required values in `.env`:
```
KANBAN_PROJECT_NUMBER=<your project number>
KANBAN_PROJECT_OWNER=<your GitHub username or org>
```

c. Run setup — auto-discovers field IDs and sets GitHub Actions variables:
```bash
task setup
```

d. Add GitHub repository secrets:

| Secret | How to obtain |
|--------|--------------|
| `GH_TOKEN` | Classic PAT with `repo` + `project` scopes — fine-grained PATs do not support Projects v2 |
| `CLAUDE_CODE_OAUTH_TOKEN` | From [claude.ai/settings](https://claude.ai/settings) → API keys |

---

## Repository Structure

```
my_template_repo/
├── copier.yml                    Prompt definitions and generation config
├── LICENSE
├── README.md                     This file
├── main.py                       Entry point (templated)
├── pyproject.toml                Project metadata and dependencies
├── src/
│   ├── config.py                 Centralised config (pydantic-settings, loads .env)
│   └── utils/                    Generic transferable modules (m_*.py)
├── tests/                        Pytest suite, mirrors src/ hierarchy
├── .agents/skills/               Skill system — AI workflow for every generated project
├── .github/workflows/            CI: lint + typecheck + test
├── docs/adr/                     Architecture Decision Records (MADR format)
├── CONTEXT.md                    Domain glossary template (filled at generation time)
└── AGENTS.md                     Agent standing instructions (filled at generation time)
```

---

## Conventions

- **Utility modules**: `m_*.py` naming in `src/utils/` — generic, no project-specific logic
- **Domain folders**: add `src/<domain>/` as the project grows — never pollute `src/utils/`
- **Test parity**: every `src/**/*.py` gets a matching `tests/**/test_*.py`
- **UV only**: `uv add`, `uv sync`, `uv run` — never `pip install`
- **Native Secret Management**: uses local vault named 'LocalStore' for secret management

---

## AI Workflow

Every generated project ships with a structured AI engineering workflow. It is not optional scaffolding — it is the primary mechanism for keeping agents aligned, context-efficient, and audit-ready across the full development lifecycle.

### How it works

The workflow is a sequential skill chain: **refine → architecture → plan → tdd → harness → review → ship**. Each skill is a constraint document that prevents a specific class of agent failure. Skills live in `.agents/skills/`.

| Phase | Skill | What it prevents |
|-------|-------|-----------------|
| Align | `refine` | Premature implementation without shared language or agreed boundaries |
| Map | `architecture` | Blind changes with unknown blast-radius |
| Specify | `plan` | Coding without acceptance criteria or re-proposing rejected ideas |
| Build | `tdd` | Untested code and shallow module design |
| Run | `harness` | Context degradation, unverified output, environment drift |
| Verify | `review` | Uncaught regressions and principle violations before merge |
| Merge | `ship` | Security gaps, supply chain risk, lost architectural decisions |

**Persistent across all phases:** `version-control` — branch naming, commit format, PR conventions.

**Domain extensions** (extend the `tdd` REFACTOR phase with implementation patterns):
- `application-development` — REST APIs, FastAPI, Pydantic, auth
- `data-engineering` — Medallion pipeline, SQLAlchemy, Polars, DuckLake
- `agentic-development` — Plan-Act-Observe loops, tool use, multi-agent coordination

### Key files in every generated project

| File | Purpose |
|------|---------|
| `CONTEXT.md` | Domain glossary, bounded contexts, architectural constraints — read first every session |
| `AGENTS.md` | Standing instructions and skill index — loaded after `CONTEXT.md` |
| `docs/adr/` | Architecture Decision Records (MADR format) — one per significant technology choice |

### Starting a new feature

```
1. Open CONTEXT.md — read the glossary and constraints
2. Invoke refine skill — align on requirements and boundaries
3. Invoke architecture skill — understand blast-radius before touching code
4. Invoke plan skill — decompose into labelled GitHub Issues
5. Invoke tdd skill — Red-Green-Refactor loop
6. Invoke review skill — auto-fix and validate before merge
7. Invoke ship skill — security checks, squash merge, update CONTEXT.md
```

ADRs for tool selection decisions are in `docs/adr/`. See `ADR-000` for the template format.
