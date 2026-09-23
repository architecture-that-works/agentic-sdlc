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
- Decomposed child issues, unlabelled — refine labels them
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

- **Tracer bullet first** — always Issue #1
- Each issue is independently mergeable
- **No labels at creation.** Every issue is refined on open, and the pipeline sets
  the labels: refine sets `agent:backlog` or `human:decision` (open questions), and
  ship sets `human:approval` when the PR touches governance files.

```bash
gh issue create --title "feat: <title>" --body "<body>"
```

## Quick Reference

| Step | Action | Tool |
|---|---|---|
| Deduplicate | Search open issues + `.out-of-scope.md` | `gh issue list` |
| PRD | Publish into the parent issue body (between `<!-- AGENT-PRD:BEGIN -->` markers) | `gh issue edit` |
| Decompose | One issue per vertical slice | `gh issue create` |

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

## Planner note — when a child needs a human

The orchestrator reads two signals from the issue carrier — blast radius (`## Architecture
Impact`) and `open_questions[]`. When the blast radius is wide or questions are open, the child
gets a *Planner note* in its body asking refine to confirm the decisions with the owner. It is a
note, not a label: refine decides whether a question is genuinely open.

## Common Mistakes

**Skipping deduplication.**
A concept rejected in `.out-of-scope.md` will be re-proposed without this check. Always search before writing.

**Horizontal slices in decomposition.**
"Implement the data layer" is a horizontal slice — it delivers nothing observable end-to-end. Every issue must cut through all layers from schema to consumer.

**File paths in PRD.**
The PRD must reference interfaces and contracts only. File paths rot. An agent reading a stale path will implement in the wrong location.

**Missing testing decisions.**
If the PRD has no testing decisions, the `implement` RED phase has no acceptance criteria. Every PRD must state what a good test looks like for this module.
