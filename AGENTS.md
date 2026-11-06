# AGENTS.md — Standing Instructions for AI Agents

Python + UV application: entry point `src/main.py`, config `src/config.py` (pydantic-settings,
loads `.env`). What the project *is* — glossary, Module Map, constraints — lives in `CONTEXT.md`;
this file says how to *work* in it.

## Session Initialisation

Load in this order before any task:

1. `CONTEXT.md` — glossary, Module Map, Issue-Type Index, Architectural Constraints.
2. `AGENTS.md` — this file.
3. ADR index — pick the one that matches the task:
   - Touching `.github/orchestrator/`, `.agents/skills/`, or `copier.yml` (the template's own
     mechanism) → `template/adr/README.md`, then only the ADRs it lists as relevant.
   - Anything else (this project's own application code) → `docs/adr/ADR_STRUCTURE.md`, then
     only the ADRs its Quick Filter lists for the Project Type in `CONTEXT.md`, if any exist yet.
4. The task — issue body, PR diff, or prompt. If steps 1–4 would exceed ~100k tokens, keep it on
   disk and read it on demand.

**Context health.** Past ~150k tokens, finish the current stage, write large tool output (logs,
dumps) to disk with a short summary in its place, and compact. Past ~250k, stop: record the
stage, files changed, suite status and next action in the issue body (never a local file —
ADR-011), then start a fresh session from step 1 and re-run the suite before continuing.

## Context Protocol (ADR-009)

Mandatory before opening any source file (`.py`, `.ps1`, `.yml`):

1. From the Module Map and Issue-Type Index in `CONTEXT.md`, pick the 3–5 files the task needs
   and name them in your first message.
2. Read only those files.
3. If the work needs a file the Map does not list, read it and add it to the Map in the same PR.
4. Never grep the codebase to orient yourself. If the Map cannot answer the question, the Map is
   incomplete — fix it rather than work around it.

## Rules

1. **Architectural Constraints are invariants.** Everything under that heading in `CONTEXT.md`
   (UV only, no hardcoded secrets, test parity, lint gate, …) applies to every change.
2. **Never modify `AGENTS.md` or `CONTEXT.md` during implementation** — those changes go through
   a `refine` session. The Module Map and Issue-Type Index are the exception (Context Protocol
   step 3).
3. **A new top-level `src/<domain>/` needs a Module Map row in the same PR** — `ship` rejects it
   otherwise.
4. **Size and prioritise issues** with the scales in the `ISSUES.md` header.

## Safety & Boundaries

- Never modify files outside the project root, install global packages, or change global config.
- Never set `agent:*` labels or remove `human:*` labels — the orchestrator and humans own them.
  Only a human merges a `human:approval` issue (see `SECURITY.md` § Human Oversight).
- When in doubt, fail safely and surface the ambiguity.

## Skills

Invoke the matching skill before implementing manually. Each lives at
`.agents/skills/<name>/SKILL.md`; read `REFERENCE.md` and `EXAMPLES.md` beside it when present.

### Stages — in order

| Skill | When to invoke |
|-------|----------------|
| `refine` | Starting a new feature — align on glossary, boundaries and ADRs before any code |
| `architect` | Analysing dependencies, blast radius, or module structure |
| `plan` | Turning an Agent Brief into a Lean PRD and decomposed GitHub Issues |
| `implement` | Implementing via Red-Green-Refactor |
| `review` | Code review, auto-fix loop, PR validation |
| `ship` | Pre-merge security checks, squash merge, knowledge-base update |

### Cross-cutting — load on demand

| Skill | When to invoke |
|-------|----------------|
| `diagnosis` | Implementation or CI fails and the root cause is unclear — before attempting a fix |
| `version-control` | Branching (`feature/{number}-{slug}`), commits, PRs |
| `write-skills` | Creating or updating skills in `.agents/skills/` |

### Domain — extend `implement` REFACTOR; load exactly one

| Skill | When to invoke |
|-------|----------------|
| `application-engineering` | AI-backed REST APIs, single-call Claude integration, OTel, SSE, auth. Default for `project_type: application` |
| `data-engineering` | Medallion pipeline, SQLAlchemy, Polars, DuckLake |
| `agentic-engineering` | Plan-Act-Observe loops, multi-turn tool use, agent state, multi-agent coordination |

If an endpoint invokes an agent loop, load both `application-engineering` (the endpoint) and
`agentic-engineering` (the loop).

## Conditional Context

Load only when the task needs it:

- Testing conventions, fixtures, coverage floor — `tests/README.md`
- Skill invocation protocol and lifecycle — `.agents/skills/README.md`
