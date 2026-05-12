# python-uv-template

Copier-based Python project scaffold. Generates a production-ready structure with structured logging, typed config, AI-assisted commit messages, test coverage mirroring `src/`, and GitHub Actions CI — ready to `uv sync` and go.

## SDLC Maturity

**Current: 1.25 / 10 — AI Student / Hobbyist** · Assessed: 2026-05-12

> Re-assess: load [`ASSESSMENT_PROMPT.md`](ASSESSMENT_PROMPT.md) into a Claude Code session, then update this table.

| Stage | Role | Criteria | Status |
|---|---|---|---|
| **0–2** | AI Student / Hobbyist ◄ | 5 / 8 | 🔲 Pinned Python honored by Dockerfile + devcontainer · `.gitignore` covers full secret-pattern set · README states Python version |
| **3–4** | Junior AI Engineer | 5 / 7 | 🔲 Secret-scanning CI gate · Dependabot covers `pip`/`uv` (currently `github-actions` only) |
| **5–6** | Medior AI Engineer | 9 / 12 | 🔲 `CONTEXT.md` codifies SOLID/DRY/KISS/TDD · skill dirs gain `REFERENCE.md`/`EXAMPLES.md`/`scripts/` · diagnosis skill |
| **7–8** | Senior AI Engineer | 3 / 10 | 🔲 Deploy workflow on live surface · `CODEOWNERS` covers SECURITY.md/CODEOWNERS/adr/workflows · `SECURITY.md` disclosure + permission model · pre-commit harness · codebase-map generator · LLM-optimized error wrapper |
| **9–10** | Principal AI Engineer | 1 / 13 | 🔲 Cross-family adversarial review · Hypothesis PBT · LLM-judge harness · EU AI Act lineage + telemetry · CI-failure diagnose-and-patch agent |

**Score formula:** tier-gated binary checklist. All criteria in tier N must be met before tier N+1 points are awarded. Within the blocking tier: `base + (met/total × 2)`. Full criteria in [`ASSESSMENT_PROMPT.md`](ASSESSMENT_PROMPT.md).

---

## Table of Contents

- [SDLC Maturity](#sdlc-maturity)
- [Quickstart](#quickstart)
- [Validate the harness end-to-end](#validate-the-harness-end-to-end)
- [Repository Structure](#repository-structure)
- [Conventions](#conventions)
- [AI Workflow](#ai-workflow)

---

## Quickstart

Get a new project running in under 5 minutes.

**1. Install prerequisites** — once, globally:

**Python 3.13** — required interpreter. Install it if not present: `uv python install 3.13`

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

**4. Wire up the Orchestrator Workflow** — once per project:

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
| `GH_TOKEN` | Classic PAT with `project`, `read:org`, `repo`, `user`, `workflow` scopes — fine-grained PATs do not support Projects v2 |
| `CLAUDE_CODE_OAUTH_TOKEN` | From [claude.ai/settings](https://claude.ai/settings) → API keys |

> **Important — `GH_TOKEN` scope requirement:** The `GH_TOKEN` repo secret **must** be a **classic PAT** with all five of the following scopes: `project`, `read:org`, `repo`, `user`, `workflow`. Fine-grained PATs do not support GitHub Projects v2. Missing scopes cause silent failures at runtime — `project` breaks kanban board mutations, `workflow` blocks any PR that touches `.github/workflows/*.yml`, `read:org` is required for org-owned projects, `user` for identity calls (`gh api user`), and `repo` for issue/PR/commit operations. `task setup` will warn if your local `gh auth` context lacks the `project` scope, but that does not verify the secret — check the PAT settings page directly.

---

## Validate the harness end-to-end

After generating a new project, confirm the hello-world server starts and responds correctly before writing your first feature.

**1. Build the image**
```bash
docker build -t <name>:dev .
```

**2. Start the container**
```bash
docker run --rm -p 8000:8000 <name>:dev
```

**3. Open the root route in a browser**

Navigate to `http://localhost:8000` — you should see an HTML page with the project name and version.

**4. Check the health endpoint**
```bash
curl http://localhost:8000/healthz
```

Expected response: `ok`

The hello-world handler in `src/main.py` is intentionally minimal — it is the starting point for your first feature, not production code. Replace `HelloHandler` with your own request logic and delete or extend the `/healthz` route to match your application's health semantics.

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
- **Python 3.13**: required interpreter — install via `uv python install 3.13` (see [Quickstart §1](#quickstart))
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

---

### Orchestrator Workflow

The Orchestrator Workflow is the autonomous execution layer. Once an issue is queued, the orchestrator runs end-to-end: branch → implement → review → merge.

#### State machine

Every issue carries exactly one `agent:` label at any time. The label name matches the project board lane name.

```
agent:backlog ──► agent:implementing ──► agent:review ──► agent:merged
     ▲                   │                    │
     │                   │  (rejected)         │  (max retries exceeded)
     │                   ▼                    ▼
     └──────── agent:implementing ◄──── agent:failed ──► Backlog
```

| Label | Lane | Meaning |
|---|---|---|
| `agent:backlog` | Backlog | Queued — orchestrator will pick up on next poll |
| `agent:implementing` | Implementing | Branch created, Claude Code actively implementing |
| `agent:review` | Review | PR open, agent self-review running or passed |
| `agent:merged` | Merged | PR squash-merged, issue closed |
| `agent:failed` | Backlog | Unrecoverable error or max retries exceeded — human required |

#### Transitions

| Event | From → To |
|---|---|
| `task sync` or label applied manually | issue created → `agent:backlog` |
| Orchestrator picks up (GHA or `task start`) | `agent:backlog` → `agent:implementing` |
| PR opened, review phase begins | `agent:implementing` → `agent:review` (lane moves immediately) |
| Review passes | stays `agent:review` until orchestrator merges |
| Review rejected | `agent:review` → `agent:implementing` (orchestrator retries implement) |
| Max retries exceeded (default: 2) | → `agent:failed` + Backlog lane |
| Orchestrator merges | `agent:review` → `agent:merged` |
| `task retry ISSUE=N` | any state → `agent:backlog` (recovery) |

#### Task commands

```bash
task setup                  # one-time bootstrap — discover Project field IDs into .env + GHA vars
task sync                   # parse ISSUES.md and push pending blocks to GitHub Issues
task start                  # HITL — interactive Backlog picker; runs full orchestration here
task start ISSUE=13         # HITL orchestration for issue #13, skipping the picker
task retry ISSUE=13         # reset a stuck or failed issue back to agent:backlog
task runner                 # start the self-hosted GHA runner in this terminal
task runner OFFLINE=1       # gracefully stop the GHA runner (drains current job first)
```

GHA-triggered orchestration runs (label events on `agent:backlog`) process issues
**lowest issue number first**. HITL runs use the interactive picker.

#### Issue body template

Issues used with the Orchestrator Workflow should follow the structure defined in `ISSUES.md`. The orchestrator's refine phase will apply the template automatically if the body is missing required fields. It also assigns `estimate:N` (Fibonacci SP) and `priority:X` labels if absent — issues entering implementation are always fully specified.

---
