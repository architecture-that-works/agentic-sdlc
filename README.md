# python-uv-template

Copier-based Python project scaffold. Generates a production-ready structure with structured logging, typed config, AI-assisted commit messages, test coverage mirroring `src/`, and GitHub Actions CI — ready to `uv sync` and go.

---

## Table of Contents

- [Quickstart](#quickstart)
- [Repository Structure](#repository-structure)
- [Conventions](#conventions)
- [AI Workflow](#ai-workflow)

---

## Quickstart

Get a new project running in under 2 minutes.

**1. Install copier** — once, globally:
```bash
uv tool install copier
```

**2. Generate a new project**
```bash
uvx copier copy gh:your-username/my_template_repo path/to/new-project
```

Copier will prompt for:
- `project_name` — hyphenated name (e.g. `my-new-project`)
- `description` — one-line project description

**3. Replace the logging stub**
```bash
# Drop your m_log.py into src/utils/ — interface: f_log(), setup_logging(), f_log_execution()
```

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
