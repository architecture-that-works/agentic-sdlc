# Skills Reference

How to find, read, and invoke skills in this repository.

## What a Skill Is

A skill is a packaged constraint document that tells an agent *how* to carry out one specific phase of work. Skills live under `.agents/skills/<name>/`. Reading a skill before implementing prevents re-deriving patterns that have already been agreed.

**Always invoke the relevant skill before implementing manually.** The skills index in `AGENTS.md` lists every skill and its trigger condition.

## Skill Directory Structure

Each skill directory follows this layout:

```
.agents/skills/<name>/
├── SKILL.md        # Always present — overview, scope, when to use, core pattern
├── REFERENCE.md    # Present for complex skills — mechanism detail and decision tables
├── EXAMPLES.md     # Present for complex skills — worked patterns and anti-patterns
└── scripts/        # Present for skills with idempotent automation (PowerShell)
```

Load `SKILL.md` first. If the task is non-trivial, also load `REFERENCE.md` and `EXAMPLES.md` — they contain detail that `SKILL.md` compresses out.

Skills with `REFERENCE.md` + `EXAMPLES.md`: `refine`, `architecture`, `plan`, `write-skills`.
Skills with `SKILL.md` only: `tdd`, `harness`, `review`, `ship`, `version-control`, domain skills.

## Workflow Skill Lifecycle

Skills are meant to be run in sequence. Starting a phase without the prior phase's outputs risks drift.

```
refine → architecture → plan → tdd → harness → review → ship
```

| Skill | Trigger | Primary output |
|-------|---------|----------------|
| `refine` | New feature — before any code | `CONTEXT.md` updates, Agent Brief |
| `architecture` | Dependency or blast-radius analysis | Architecture Impact section in issue body |
| `plan` | Agent Brief → implementation decomposition | Implementation Plan in issue body |
| `tdd` | Writing or changing code against acceptance criteria | Passing `uv run pytest`, minimal implementation |
| `harness` | Environment provisioning, context health, large test log offload | Managed session scaffold |
| `review` | Code review and auto-fix loop | Review verdict; PR ready for merge |
| `ship` | Pre-merge security checks, squash merge, knowledge base update | Merged PR, updated `CONTEXT.md` |

**Do not skip phases.** A `tdd` session without a prior `plan` has no PRD to trace tests to. A `review` without a prior `tdd` has no green suite to check.

## Meta Skills (cross-cutting, load on demand)

| Skill | When to load |
|-------|-------------|
| `version-control` | Any phase that touches git — branching, commits, PRs |
| `write-skills` | Creating or updating a skill in `.agents/skills/` |

Meta skills are phase-agnostic. Load `version-control` whenever a branch, commit, or PR is part of the task, regardless of which workflow phase you are in.

## Domain Skills (extend the tdd REFACTOR phase)

Domain skills add language-specific and architecture-specific implementation patterns to the REFACTOR step of the TDD loop.

| Skill | Domain |
|-------|--------|
| `application-engineering` | REST APIs, Claude single-call integration, OTel, SSE, auth |
| `data-engineering` | Medallion pipeline, SQLAlchemy, Polars, DuckLake |
| `agentic-engineering` | Plan-Act-Observe loops, multi-turn tool use, agent state, multi-agent coordination |

**Load exactly one domain skill per session.** `application-engineering` is the default for `project_type: application`. If an endpoint invokes an agent loop, load both: `application-engineering` for the endpoint, `agentic-engineering` for the loop internals.

## How to Read REFERENCE.md and EXAMPLES.md

`REFERENCE.md` contains decision tables and mechanism detail — the "why" behind the patterns. Read it before a phase starts to understand the invariants you are operating under.

`EXAMPLES.md` contains worked patterns — concrete before-and-after code or prompt snippets. Read it when you are mid-phase and unsure which of several options to pick. Examples are vetted; prefer them over re-deriving a pattern from first principles.

Both files are scoped to their skill — they never repeat content from `SKILL.md`, `AGENTS.md`, or `CONTEXT.md`. If the same constraint appears in both, the `AGENTS.md` or `CONTEXT.md` version is authoritative.

## Invocation Protocol

1. Identify the current phase from the issue body's `AGENT-STATE` JSON block.
2. Open the matching skill's `SKILL.md` in `.agents/skills/<name>/`.
3. If the skill has `REFERENCE.md`, load it now — before reading any source file.
4. If the skill has `EXAMPLES.md`, keep it open as a lookup during implementation.
5. Load any applicable domain skill for the REFACTOR step.
6. Follow `AGENTS.md` §Session Initialisation → Context Protocol before opening source files.

Never substitute reading the skill for reading the codebase. Skills constrain *how* to work; the codebase tells you *what* exists.

## Creating or Updating a Skill

Use the `write-skills` skill. Read `.agents/skills/write-skills/SKILL.md` before authoring any skill file. The `write-skills` skill enforces the directory spec (frontmatter format, `name` + `description` fields, token limit ≤500 lines per file) and the naming conventions.

Skill changes that are added to `AGENTS.md`'s index table are standing-instruction changes — they require a `refine` session authorization before merging.
