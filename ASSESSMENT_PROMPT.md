# SDLC Maturity Assessment Prompt

Reusable re-assessment prompt for `my_template_repo`. Load into a Claude Code session with
full repository access. The rubric is tier-gated and binary — two independent assessors
reading the same codebase must reach the same score.

---

## Persona

You are an **uncompromising Principal AI Engineer**. Your job is to evaluate this template
repository against a fixed binary checklist. Score what *exists and works today*. Do not
award partial credit for roadmap items, comments, or documentation of intent. A criterion is
met only when the mechanism is implemented and observable in the codebase or CI configuration.

**What this template is:** A Copier-based Python project scaffold that generates production-
ready AI application projects AND maintains code quality autonomously through a label-driven
agentic pipeline. The score covers both dimensions equally: (1) how autonomous the pipeline
is, and (2) how AI-Engineering-ready the generated project scaffold is.

**Assessment default:** Evaluate against `project_type: application` — the default Copier
prompt choice. This is the primary target for an AI Architect building general-purpose AI
applications, REST APIs, and agent-backed services. Domain-specific criteria for `agent`
or `ml` project types are called out explicitly where they differ; apply only when those
types are the assessed default.

---

## Step 1 — Inventory First

Use Glob to discover what currently exists. Do not assume any file is present or absent —
the repo structure evolves as issues are implemented.

```
copier.yml                          template generation config
Taskfile.yml                        task runner surface
CONTEXT.md                          agent knowledge base template
AGENTS.md                           agent standing instructions template
.gitignore                          secret and cache patterns
pyproject.toml                      project metadata and dependencies
SECURITY.md                         (if present)
CODEOWNERS                          (if present)
Dockerfile*                         (if present)
.devcontainer/**                    (if present)
template/**                         (if present — signals template isolation complete)
.agents/**                          skill system files
docs/adr/**                         Architecture Decision Records
.github/workflows/**                all CI/CD and automation workflows
.github/scripts/**                  Orchestrator Workflow pipeline scripts
.github/dependabot.yml              (if present)
```

Then run:
```
gh issue list --state open --limit 50 --json number,title,labels
```
to establish what is planned but not yet implemented. Do not award credit for open issues.

---

## Step 2 — Read by Dimension

Read files discovered in Step 1 that are relevant to each dimension. Absence is evidence —
do not skip a dimension because its expected file does not exist.

### Dimension 1 — Pipeline Autonomy
Read all `.github/workflows/*.yml`. For each, note: trigger type (push/PR/label/schedule/
manual?), runner location (cloud vs local instruction), human gate points.
Read `.github/scripts/kanban/run.ps1` and `implement.ps1` for local polling loops or
hardcoded local paths.

### Dimension 2 — Containerisation & Reproducibility
Check for `Dockerfile*`, `.devcontainer/**`, `docker-compose*`. If found, read them.
Check CI workflows for UV dependency cache steps. Check `pyproject.toml` for lock-file
pinning. Check `copier.yml` for what the generated project receives.

### Dimension 3 — Template Fidelity
Read `copier.yml` — check for `_subdirectory` key and `_exclude` list. Check whether
`CONTEXT.md`, `AGENTS.md`, and skill files live at root or inside `template/`. Check
`CONTEXT.md`/`AGENTS.md` for Jinja2 tokens (`{{ }}`) vs sentinel tokens (`__UPPER__`).

### Dimension 4 — Security & Governance
Check `.gitignore` for secret file patterns. Check all workflow files for SHA-pinned action
refs. Check for `SECURITY.md`, `CODEOWNERS`. Check deployment workflows for credential
mechanism: Workload Identity Federation (`id-token: write` + WIF action) vs stored secrets.
Read `implement.ps1` for staging allowlist and denylist.

### Dimension 5 — AI Knowledge Base & Skill System
Read `CONTEXT.md` and `AGENTS.md` — are they populated templates or empty shells? Glob
`docs/adr/*.md` and check `Status:` fields. Read `.agents/SKILL_STRUCTURE.md` — is the skill
system MECE? Glob `.agents/skills/` — do the actual skill files exist in the repo, or only
in user-level Claude settings?

### Dimension 6 — CI Quality Gates
Read CI workflow files. Verify each gate is a blocking job (not a warning-only step):
lint, format check, typecheck, test with coverage floor, security audit.

### Dimension 7 — Delivery Pipeline
Check for container build workflow (GHCR push) and deployment workflow (cloud target).
Note credential mechanism from Dimension 4.

### Dimension 8 — Evaluation & Quality Verification
Check whether any workflow or script runs an automated quality gate beyond unit tests —
LLM-as-judge, smoke tests against a deployed environment, or AI output evaluation harness.

---

## Scoring Rubric — Real AI Engineering Maturity (0 to 10)

### Scoring Formula

The rubric is **tier-gated**. You must satisfy every criterion in tier N before claiming
any points in tier N+1. Within the blocking tier:

```
score = tier_base + (criteria_met / total_criteria) × 2
```

| Tier | Base | Criteria | Points per criterion |
|---|---|---|---|
| [0–2] AI Student / Hobbyist | 0 | 5 | 0.40 |
| [3–4] Junior AI Engineer | 2 | 8 | 0.25 |
| [5–6] Mid-Level AI Engineer | 4 | 11 | 0.18 |
| [7–8] Senior AI Engineer | 6 | 12 | 0.17 |
| [9–10] Principal AI Engineer | 8 | 6 | 0.33 |

Round to nearest **0.25**. Always report as `X.XX / 10` alongside `N/M criteria met at [stage]`.

---

### [0–2] AI Student / Hobbyist — Baseline existence

*Both dimensions:* Git, Python environment, config discipline, and a working template generator.

**Infrastructure** (3 criteria)
- [ ] Git repository with consistent, meaningful commit history
- [ ] Python package management uses UV with a committed lock file — not bare pip or `requirements.txt`
- [ ] All config loaded from environment (`.env` + pydantic-settings); no hardcoded credentials or endpoints in committed code

**Generated scaffold** (2 criteria)
- [ ] Copier `copier.yml` defines at minimum `project_name` and `description` prompts
- [ ] A generated project passes `uv sync` and runs on a cold clone without any manual steps

---

### [3–4] Junior AI Engineer — Disciplined baseline

*Both dimensions:* Automated quality gates on every change; reproducible project generation with meaningful choices.

**CI gates** (5 criteria — each must be a blocking job, not a warning)
- [ ] CI pipeline triggers automatically on every push and pull request (not manual-only)
- [ ] Lint gate: `ruff check` + `ruff format --check` — PR blocked on violation
- [ ] Typecheck gate: `pyright` — PR blocked on type errors
- [ ] Test gate: `pytest` with explicit minimum coverage (`--cov-fail-under=N`) — PR blocked below floor
- [ ] Security audit: `pip-audit` — PR blocked on known CVE in dependencies

**Supply chain** (2 criteria)
- [ ] All third-party GitHub Actions reference full commit SHA pins (not tag, branch, or `latest`)
- [ ] Automated dependency update tool configured (Dependabot or Renovate) for Actions and Python packages

**Generated scaffold** (1 criterion)
- [ ] Copier template includes a `project_type` prompt with ≥2 meaningful choices; `pyproject.toml` is customised with the project name at generation time (not left as template placeholder)

---

### [5–6] Mid-Level AI Engineer — Structured agentic SDLC

*Both dimensions:* Human-supervised agentic pipeline; generated projects carry an AI Engineering knowledge base and skill system.

**Pipeline automation** (4 criteria)
- [ ] MECE skill system exists covering every SDLC phase (refine → architecture → plan → tdd → harness → review → ship) with a single router document that prevents overlap
- [ ] Human-triggered agentic pipeline: agent implements a GitHub Issue, opens a PR, and human decides when to merge — no manual coding step required
- [ ] Label-driven kanban automation: project board columns update automatically on label events; no manual card movement
- [ ] AI provider (Claude Code or equivalent) integrated for at-mention triggers in issues and PRs

**Developer experience** (2 criteria)
- [ ] Idempotent local-to-GitHub issue pipeline: local backlog entries sync to GitHub Issues without creating duplicates on re-run
- [ ] Allowlist-based git staging with a sensitive-file denylist (blocks `.env`, `*.key`, `*.pem`, `*secret*`) enforced in the pipeline, not just documented

**Generated scaffold** (5 criteria)
- [ ] Generated projects include `CONTEXT.md` with structured sections: domain glossary, bounded contexts, architectural constraints, and out-of-scope declarations
- [ ] Generated projects include `AGENTS.md` with: session initialisation order, skill index, and standing rules that agents must follow
- [ ] Generated projects ship with an ADR framework: ADR-000 (format template) plus ≥3 Accepted or Proposed ADRs covering technology choices relevant to `project_type: application` (observability stack, IAM provider, project-type selection); `agent` and `ml` types count their additional domain ADRs toward this threshold
- [ ] Skill files (at minimum SKILL_STRUCTURE.md and the `version-control` skill) travel into generated projects via Copier — agents can load them without installing anything separately
- [ ] Context window health zones (Smart / Transition / Dumb) are documented in the skill system; agents are explicitly instructed to check zone before starting complex tasks

---

### [7–8] Senior AI Engineer — Autonomous pipeline

*Both dimensions:* Cloud-native, event-driven pipeline with no local machine dependency; generated projects containerised and AI-observability-ready from day one.

**Cloud-native orchestration** (3 criteria)
- [ ] A label event triggers the full implement → review → merge cycle inside GitHub Actions — no local machine needs to be running; human gates exist only at HITL checkpoints
- [ ] Multi-stage Dockerfile (UV-based; no pip) exists in the template and travels to generated projects
- [ ] Devcontainer with full AI Engineering toolchain (AI provider CLI + task runner + UV) exists in the template and travels to generated projects

**CI/CD hardening** (3 criteria)
- [ ] UV dependency cache is configured in CI — cold-start build reproduces without downloading all packages fresh
- [ ] Container image is published to a registry (e.g. GHCR) automatically on merge to the main branch
- [ ] Deployment uses Workload Identity Federation (WIF) — no stored service-principal secrets, API keys, or long-lived tokens in repository secrets

**Governance** (3 criteria)
- [ ] `CODEOWNERS` file maps governance files (AGENTS.md, CONTEXT.md, `docs/adr/`, `.github/workflows/`) to required reviewers — including agent-generated PRs
- [ ] `SECURITY.md` documents the secrets handling architecture, rotation policy, and responsible disclosure process
- [ ] `.gitignore` covers all secret file patterns: `.env*`, `*.key`, `*.pem`, `*secret*`, `*credential*`, and OS/editor cache files

**Generated scaffold** (3 criteria)
- [ ] Template source files are isolated in a `template/` subdirectory with `.jinja2` suffix; stable documents (CONTEXT.md, AGENTS.md) use sentinel tokens instead of Jinja2 to avoid double-render risk
- [ ] Skill files (full set) travel into generated projects via Copier and are not in the `_exclude` list
- [ ] Generated projects include observability hooks appropriate to the assessed project_type: `application` projects instrument services with OTel traces and structured logs with `trace_id` correlation (ADR-003); `agent` projects additionally emit one span per agent action (ADR-006) — no proprietary cloud SDK in instrumentation paths for either type

---

### [9–10] Principal AI Engineer — Zero-touch excellence

*Both dimensions:* Fully autonomous SDLC from issue creation to deployment; generated projects ship with AI output evaluation infrastructure.

**Autonomy** (3 criteria)
- [ ] AFK-labelled issues require zero human action from `agent:start` to merged PR — the pipeline runs end-to-end in GitHub Actions
- [ ] `CONTEXT.md` is auto-updated post-merge by the orchestrator without a human edit step — new architectural lessons are persisted back to the knowledge base automatically
- [ ] Pipeline reproduces from a cold GitHub Actions runner with no prior state — no secrets cached on runner, no local dependencies

**Evaluation & quality** (3 criteria)
- [ ] An automated evaluation gate runs before merge: an LLM-as-judge or property-based test verifies that agent-generated code meets the acceptance criteria, not just that unit tests pass
- [ ] Generated projects ship with an AI output evaluation harness — not just unit tests, but a framework for verifying the quality of AI-generated or AI-consumed content
- [ ] A durable event log captures every agent decision with a resume-on-crash capability — failed pipeline runs can be diagnosed and restarted from the point of failure

---

## Required Output Format

### 1. Executive Brutal Summary
Three sentences. (1) What this template is. (2) The single biggest bottleneck preventing
the next tier — name the specific mechanism that is missing. (3) What reaching the next
tier would concretely change about how an AI Architect uses this template day-to-day.

### 2. Critical Weaknesses & Vulnerabilities
Bullet points — exactly what is missing, manual, or poorly architected. For each:
- State the specific criterion that is not met
- Reference the file or mechanism where the gap is visible
- If an open GitHub Issue exists that addresses this, note it and state whether the
  planned implementation is architecturally sound

### 3. Strengths & Foundation
What this template genuinely does right. Name specific files, mechanisms, and design
decisions. No generic praise — if you cannot name the file, do not claim the strength.

### 4. The Verdict (Score & Role Mapping)

```
X.XX / 10 — Role Name
N/M criteria met at stage [X–Y] — full tier above is not yet unlocked
```

One strict paragraph: walk every dimension from Step 2, state whether the criteria in that
dimension were met or not, and justify the score mathematically against the formula.
Deduct for manual bottlenecks even when "planned to be fixed."

### 5. The Path to the Next Tier
3–5 highly technical, actionable steps to unlock the next tier. Per step:
- Specific change required (mechanism, not file path — those are volatile)
- Whether an open GitHub Issue already addresses this
- Which criterion it unlocks

---

## After Assessment

1. **Update `README.md`** — change the SDLC Maturity section to reflect the new score, role,
   criteria counts per stage, and today's date. Follow the existing table format.
2. **Commit:** `docs: update SDLC maturity assessment to X.XX/10`
