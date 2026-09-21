---
name: plan
description: Use when synthesising a Lean PRD from an Agent Brief, decomposing requirements into GitHub Issues, or checking scope against existing issues and out-of-scope decisions
---

# Plan

## Overview

Prevents unbounded scope and re-proposed rejected ideas by turning the Agent Brief into a structured Lean PRD, then breaking it into labelled GitHub Issues before any code is written.

**Primary artifact:** Lean PRD published as a GitHub Issue, decomposed into grabbable child issues.

## Scope

**Owns:** Lean PRD synthesis, tracer bullet framing, user story format, issue decomposition and `human:*` labelling, deduplication against open issues and `.out-of-scope.md`, testing decisions per PRD.

**Does not own:** Domain glossary or shared language (→ `refine`), static analysis or blast-radius data (→ `architect`), code implementation (→ `implement`), PR creation or branch naming (→ `version-control`).

**Interfaces with:** `refine` — Agent Brief is the primary input. `architect` — blast-radius findings gate scope decisions. `implement` — testing decisions in the PRD define acceptance criteria for the RED phase. `version-control` — issues created here are the targets for feature branches.

## When to Use

- Agent Brief has been signed off by `refine`
- Architecture map and blast-radius report are available from `architect`
- Ready to break work into trackable, executable issues

**Do NOT use for:** Glossary or boundary decisions (→ `refine`), topology or dependency analysis (→ `architect`), writing any code (→ `implement`).

## Required Inputs

- Signed-off Agent Brief (from `refine`)
- Blast-radius report (from `architect`)
- Access to `gh` CLI for deduplication and issue creation
- `.out-of-scope.md` knowledge base (flat file — one `## ` heading per rejected concept)

## Primary Outputs

- Lean PRD published as a GitHub Issue
- Decomposed child issues, each labelled `human:approval`, `human:decision`, or nothing
- `.out-of-scope.md` entries for explicitly deferred concepts

## Core Pattern

### Step 1 — Deduplicate

Before writing a single word of PRD:
```bash
gh issue list --search "<key terms>" --json number,title,state
```
Also check `.out-of-scope.md` for rejected concepts. If the idea was rejected before, it does not get re-proposed — reference the original rejection instead.

### Step 2 — Lean PRD

Write the PRD as a GitHub Issue with this structure:

```markdown
## Problem Statement
One paragraph from the user's perspective. No implementation detail.

## User Stories
- As a [role], I want [action], so that [value].
(Minimum 3; cover the happy path and the two most likely failure modes)

## Tracer Bullet
The single narrowest vertical slice that proves the pipe works:
schema change → API endpoint → consumer response.
This is Issue #1 in decomposition.

## Implementation Decisions
Schema changes and API contracts only. No file paths.

## Testing Decisions
What makes a good test for this module. Drives the RED phase in `implement`.

## Out of Scope
Anything explicitly deferred. Feeds `.out-of-scope.md` after merge.
```

### Step 3 — Issue Decomposition

Break the PRD into individual GitHub Issues. Rules:

- **Tracer bullet first** — always Issue #1, and it carries no `human:` label
- Each issue is independently mergeable
- Unattended is the **default**. A `human:` label is the opt-out, and it marks the exact point where the agent stops.

**No `human:` label** — runs refine through ship unattended.
**`human:approval`** — implements and self-reviews unattended, then holds for a human to merge.
**`human:decision`** — a question for a human; never enters the pipeline.

```bash
# Unattended (the default) — no label needed.
gh issue create --title "feat: <title>" --body "<body>"

# Needs a human to merge it.
gh issue create --title "feat: <title>" --body "<body>" --label "human:approval"
```

## Quick Reference

| Step | Action | Tool |
|---|---|---|
| Deduplicate | Search open issues + `.out-of-scope.md` | `gh issue list` |
| PRD | Publish into the parent issue body (between `<!-- AGENT-PRD:BEGIN -->` markers) | `gh issue edit` |
| Decompose | One issue per vertical slice | `gh issue create` |
| Label | `human:*` only where the agent must stop | `--label` flag |

**Context sensitivity:** Medium. PRD synthesis requires coherent reasoning — run in Smart Zone when possible. Deduplication queries are stateless and safe at any fill level.

## Unattended Invocation

The orchestrator runs the plan stage non-interactively via `Invoke-Plan` in `.github/orchestrator/stages/Plan.ps1`. Plan is the **third readiness stage** (refine → architect → plan) — it is not a board lane and there is no `agent:planning` label. Per ADR-011 the GitHub issue is the cross-runtime state carrier:

- Architecture / blast-radius is read from the issue (the `## Blast-Radius Report` comment published by the architect stage), never from a local file.
- The Lean PRD is written into the parent issue body between `<!-- AGENT-PRD:BEGIN -->` / `<!-- AGENT-PRD:END -->` markers.

Standalone invocation:

```pwsh
# Runs dedupe → PRD synthesis → child emission for one parent epic issue.
# Returns the number of children created, or $null if the dedupe gate aborted.
Import-Module .github/orchestrator/Orchestrator.psd1
Invoke-Plan -IssueNumber 42
```

The conductor (`Invoke-Orchestration -From refine`) calls the same function directly. On success the function marks `readiness.planned` in the issue-carried AGENT-STATE block; on a dedupe hit it posts a `🤖❌ Plan Aborted — duplicate` signal comment and returns `$null` without flipping readiness.

## Labelling Heuristic — when to withhold autonomy

Unattended is the default. The orchestrator decides whether to attach a `human:` label from two signals, both read from the issue carrier:

| Blast radius (from `## Blast-Radius Report` comment) | open_questions[] (from AGENT-STATE) | Default child label |
|------|------|------|
| Narrow — `At-risk: none` or `Recommendation: proceed` | empty | *(none)* — fully unattended |
| Narrow | non-empty | `human:decision` on the question; parent stays unattended |
| Wide — at-risk modules listed | any | `human:approval` |

Either side may opt **up** to `human:approval` (e.g. UX, credentials, a business decision). Neither ever removes a `human:` label a human or the heuristic applied — correctness for recursive issue creation outweighs throughput, since a wrong heuristic pollutes the backlog.

## Common Mistakes

**Skipping deduplication.**
A concept rejected in `.out-of-scope.md` will be re-proposed without this check. Always search before writing.

**Horizontal slices in decomposition.**
"Implement the data layer" is a horizontal slice — it delivers nothing observable end-to-end. Every issue must cut through all layers from schema to consumer.

**File paths in PRD.**
The PRD must reference interfaces and contracts only. File paths rot. An agent reading a stale path will implement in the wrong location.

**Missing testing decisions.**
If the PRD has no testing decisions, the `implement` RED phase has no acceptance criteria. Every PRD must state what a good test looks like for this module.
