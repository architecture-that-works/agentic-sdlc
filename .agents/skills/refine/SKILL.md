---
name: refine
description: Use when starting a new feature or task and alignment on requirements, interfaces, and architectural boundaries is needed before any code is written
---

# Refine

## Overview

Prevents premature implementation by forcing full alignment on domain language, architectural boundaries, and interface contracts before a single line of code is written. The agent plays an adversarial Senior Architect — relentless, codebase-first, and always opinionated.

**Primary artifact:** `CONTEXT.md` (glossary + boundaries) and Agent Brief (interface-first specification)

## Scope

**Owns:** Grill-me protocol, shared language construction, `CONTEXT.md` schema, `AGENTS.md` persistence rules, ADR creation (MADR format), Agent Brief synthesis, context window initialisation.

**Does not own:** Architecture mapping and static analysis (→ `architect`), PRD and issue creation (→ `plan`), code implementation (→ `implement`).

**Interfaces with:** `architect` — topology validates boundaries declared in `CONTEXT.md`. `plan` — Agent Brief is the direct input to Lean PRD synthesis.

## When to Use

- Starting any new feature, service, or significant refactor
- Shared language is ambiguous or missing
- Architectural boundaries haven't been agreed before coding begins

**Do NOT use for:** Architecture mapping or dependency analysis (→ `architect`), decomposing requirements into issues (→ `plan`).

## Required Inputs

- Existing codebase (read before asking any questions)
- Raw user request or problem statement
- Current `CONTEXT.md` (if it exists)

## Primary Outputs

- `CONTEXT.md` with glossary, bounded contexts, and architectural constraints
- `.out-of-scope.md` entries for rejected concepts
- `AGENTS.md` persistence rules (one-time setup; updated only in `refine` sessions)
- ADRs (one per architectural decision made during grilling)
- Agent Brief (interface-first specification; input to `plan`)

## Core Pattern

### The Grill-Me Protocol

Run relentlessly. Walk every branch of the decision tree. Resolve dependencies between decisions one by one before moving on.

**Rule 1 — Codebase first.** If a question can be answered by reading the codebase, read it. Never ask the human what the code already says.

**Rule 2 — Always recommend.** Every question must include the agent's recommended answer. Asking without a recommendation is not grilling — it is delegating.

**Rule 3 — No branch left open.** A decision is resolved only when every alternative has been examined and rejected or accepted. Partial resolution is not resolution.

**Rule 4 — Interface before implementation.** The Agent Brief is written in terms of contracts and schemas. It must never reference file paths or line numbers — those are volatile.

**Rule 5 — Smallest complete scope.** The Agent Brief specifies the smallest version that does the core job. Every feature, option or flexibility the issue did not ask for is named in Out of Scope in one line — it is not built, and `plan` does not re-propose it. A vague issue gets the smallest version, not the most complete one.

**Pragmatic Programmer checks during grilling:**
- Dig for real requirements, not stated desires (PP-51)
- Think like a user, not a builder (PP-52)
- Prefer long-lived abstractions over implementation details (PP-53)
- Surface broken windows — name them, don't work around them (PP-4)
- Propose options, not excuses (PP-3)

### CONTEXT.md Schema

```markdown
## Glossary
| Term | Definition | Disambiguation |

## Bounded Contexts
| Context | Owns | Does Not Own |

## Architectural Constraints
Invariants that must not be violated in any implementation.

## Out of Scope
Concepts explicitly deferred or rejected (prevents re-proposal in `plan`).
```

### AGENTS.md Persistence Rules

`AGENTS.md` holds standing instructions that apply to every session (Claude and Gemini). It is loaded at the top of every conversation before any task begins. Contents: style preferences, response format rules, context initialisation order, provider-specific quirks. Never modify `AGENTS.md` during implementation — changes go through a `refine` session.

### ADR Format (MADR)

Every architectural decision made during grilling becomes a MADR:

```markdown
# ADR-NNN: Title

## Status
[Proposed | Accepted | Deprecated | Superseded by ADR-NNN]

## Context and Problem Statement
...

## Considered Options
- Option A
- Option B

## Decision Outcome
Chosen: Option A — because [justification].

### Positive Consequences
### Negative Consequences

## Pros and Cons of the Options
### Option A
- Good, because ...
- Bad, because ...
```

Store ADRs in `docs/adr/`. Reference by number in `CONTEXT.md` Architectural Constraints.

## Quick Reference

| Artefact | Owner | When written |
|---|---|---|
| `CONTEXT.md` | `refine` | Start of session; updated by `ship` post-merge |
| `AGENTS.md` | `refine` | One-time setup; updated only in `refine` sessions |
| ADR (MADR) | `refine` | One per architectural decision made during grilling |
| Agent Brief | `refine` | End of grilling; input to `plan` |

**Context sensitivity:** High. Begin only in Smart Zone (< 100k tokens). If already in Transition Zone, compact before starting. Never begin a grill-me session in the Dumb Zone (> 250k tokens).

## AFK Invocation Pattern (self-grill subagent)

The interactive grill-me protocol has an AFK analog: a subagent spawned by the
kanban orchestrator's `Invoke-Refine` phase. The subagent enforces Rules 1-5
above without a human in the loop and emits a structured `GrillResult`
(`src/utils/m_planning.py::GrillResult`) bundling the Agent Brief, open and
decided questions, and proposed glossary diffs.

**Carrier (post-ADR-011).** The output is written into the GitHub issue body —
the single cross-runtime carrier (ADR-014 retired `.planning/`).

- Agent Brief → Markdown section bounded by `<!-- AGENT-BRIEF:BEGIN/END -->`
  markers. Frontmatter records `populated_by: self-grill-subagent`.
- Open/decided questions → the `open_questions[]` / `decided_questions[]` arrays
  inside the AGENT-STATE JSON block. Open questions block backlog entry per the
  readiness gate (`Test-Readiness`).
- Every open question is multiple choice: `decision` holds the recommendation
  (option A) and `alternatives` two genuine alternatives (B, C). The orchestrator
  asks them in the issue itself — a `## Decisions` body section plus a comment,
  label `human:decision` — and the owner answers in a plain comment (`ok`, `1B`,
  `2: own words`). The answer check records each decision or asks a follow-up.

**Readiness lanes.** `refine`, `architect`, and `plan` are NOT kanban lanes —
they are pre-backlog readiness flags in the same JSON state block. The four
board lanes (Backlog, Implementing, Review, Shipped) are the only lanes the
project board surfaces.

**Standalone harness probe.** The subagent is invocable directly for one-shot
test runs from a developer machine:

```powershell
# Grill a live GitHub issue and print the JSON to stdout:
pwsh .agents/skills/refine/scripts/grill.ps1 -Issue 42

# Probe an under-specified body without touching GitHub:
pwsh .agents/skills/refine/scripts/grill.ps1 `
    -Title 'Add SSE endpoint' `
    -Body  'we want streaming completions'

# Render the assembled prompt only — no Claude call:
pwsh .agents/skills/refine/scripts/grill.ps1 -Issue 42 -DryRun
```

The output is validated against `GrillResult` (pydantic) before the orchestrator
writes anything to the issue. Validation failure raises and aborts the refine
phase — partial alignment never makes it to the issue body.

## Common Mistakes

**Asking before reading the codebase.**
If the answer is in the code, find it. Asking the human wastes alignment time and breaks trust in the agent's competence.

**Questions without recommendations.**
An agent that only asks is not a Senior Architect — it is a junior taking notes. Every question needs a stated position.

**Agent Brief contains file paths.**
File paths are volatile. The brief must reference interfaces, schemas, and contracts only. A brief with file paths will rot before it reaches `plan`.

**Starting a grill session mid-Transition Zone.**
Alignment requires precise reasoning. A session started at 150k tokens will drift before it reaches agreement. Compact first.

**A brief that builds the most complete version.**
A vague issue invites a full-featured brief, and every downstream stage inflates with it. Specify the core job; everything else is one line in Out of Scope.
