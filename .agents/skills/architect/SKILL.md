---
name: architect
description: Use when mapping dependencies, identifying structural anti-patterns, computing blast radius of a proposed change, validating topology against boundaries declared in CONTEXT.md, or auditing the whole repo for bugs, risk and bloat before any issue exists
---

# Architect

## Overview

Prevents structural drift and unplanned side-effects by making the dependency topology visible before changes are committed. Every proposed change gets a blast-radius computation; findings that violate `CONTEXT.md` boundaries block progress. Standalone, the same eye audits the whole repo and turns what it finds into backlog.

**Primary artifact:** Architecture map with dependency metrics and blast-radius report posted as a PR comment; for an audit, ranked findings written as ISSUES.md blocks.

## Scope

**Owns:** Dependency graph generation and visualisation, circular dependency and layer-violation detection, deep/shallow module identification, fragility and coupling metric interpretation, blast-radius computation, GitHub Issue cross-reference loop, refactoring demand enforcement, the standalone repo audit.

**Does not own:** Domain model design decisions (→ `refine`), judging a single change (→ `review`), infrastructure, deployment topology and CI/CD configuration (`.github/workflows/`).

**Interfaces with:** `refine` — topology validates the boundaries declared in `CONTEXT.md`. `plan` — blast-radius findings gate scope decisions in the Lean PRD. `review` — blast-radius report is posted as a PR comment for reviewer visibility; the repo audit reuses `review`'s finding categories and severities.

## When to Use

- Before committing any change that touches more than one module
- When a `refine` session declares a new boundary that needs structural validation
- When fragility or coupling signals suggest a refactoring is overdue
- When `review` surfaces a pattern-grade failure
- When asked to audit the repo, find bloat, or say what can be deleted — standalone, no issue yet

**Do NOT use for:** Domain modelling or glossary decisions (→ `refine`), writing implementation code (→ `implement`), reviewing one PR (→ `review`).

## Required Inputs

- Current codebase
- `CONTEXT.md` bounded contexts (defines the layer boundaries to validate against)
- PR diff or list of proposed changed modules

## Primary Outputs

- Dependency graph (written to filesystem — never loaded into context in full)
- Blast-radius report (posted as a PR comment via `gh pr comment`)
- List of blocked / at-risk / safe modules
- Refactoring recommendation (proceed | refactor first | block)
- Repo audit: at most 20 ranked findings; each one but the small suggestions written as an ISSUES.md block

## Core Pattern

### Dependency Analysis

Use whatever static analysis tool is available for the language (e.g. `pyreverse`, `pydeps`, `dependency-cruiser`, `madge`). Output to filesystem — never load raw graph data into the context window.

**What to look for:**
- Circular dependencies — flag immediately, block merge
- Layer boundary violations — flag per boundaries in `CONTEXT.md`
- God Objects — single module with high fan-in from multiple layers
- Anemic domain models — logic scattered across thin wrappers

**Module depth classification:**
- **Deep module:** Large implementation, small interface. Target state.
- **Shallow module:** Interface complexity ≈ implementation complexity. Refactoring trigger.

### Blast-Radius Computation

Run before any code is committed to a PR. Steps:

1. Identify all modules directly changed
2. Trace all callers and dependents (one level up)
3. Check each against layer boundaries in `CONTEXT.md`
4. Classify each affected module: **safe** (within boundary) or **at-risk** (crosses boundary)
5. Post the report as a PR comment using `gh pr comment`

**Blast-radius report format:**
```
## Blast-Radius Report

**Changed:** module-a, module-b
**At-risk:** module-c (crosses domain boundary defined in CONTEXT.md §Bounded Contexts)
**Safe:** module-d, module-e

**Recommendation:** [proceed | refactor first | block]
```

### GitHub Issue Research Loop

After generating the topology report, cross-reference findings with open GitHub Issues:
```bash
gh issue list --label architecture --json number,title,body | jq '.[] | ...'
```
Flag any open issue that overlaps with the current blast-radius. Prevents duplicate work.

### Repo Audit (standalone)

Audit like the senior developer who just inherited the repo and will be paged when it breaks. Changes nothing; its output is backlog.

1. **Map first.** Read the README, the build and deploy config, the dependency list, the entry points (the Module Map in `CONTEXT.md`) and the tests. Find the expected load — one person running a script, or many users and processes at once — and say which you assumed. Trace the main flows end to end (input, storage, output) and read those paths fully: user input, auth, data writes, anything shared between processes. Big repo: go deep where a mistake costs the most, not file by file, and say what you did not read.
2. **Look for** the `review` finding categories, in order: bug, risk, scale, missing test, speed, lean (REFERENCE § Finding categories in `review`). Before calling code unused, grep the whole tree — tests, fixtures, config and string references included.
3. **Check** each finding the way `review` does: a concrete case or no finding; the smallest fix, preferably one that deletes.
4. **Dedupe** against open issues (the research loop above) and `.out-of-scope.md`.
5. **Report**, at most 20 findings, most important first, no severity tags: `What this repo does:` and the load assumed; the numbered three-part findings (defect / case / fix); `Verdict:` healthy, or the numbers to fix first; `Lean: -<N> lines, -<M> dependencies possible.`; `Not checked:`.
6. **Write each finding as an ISSUES.md block** — except the small suggestions (INFO in `review`'s table), which stay in the report — one per finding, sized with the ISSUES.md scale; template in [REFERENCE.md](REFERENCE.md). `.github/tasks/sync.ps1` opens them; `refine` takes it from there.

## Quick Reference

| Signal | Action |
|---|---|
| Circular dependency | Block — do not proceed |
| Layer boundary violation | Block — flag in blast-radius report |
| Shallow module detected | Trigger REFACTOR phase in `implement` |
| Pattern grade F | Block — raise with `refine` before `plan` |
| Blast-radius crosses boundary | Post report, await explicit approval |
| Audit finding (not a small suggestion) | One ISSUES.md block each; `.github/tasks/sync.ps1` |

**Context sensitivity:** Medium. Graph outputs go to filesystem; only summary metrics enter context. Safe to run in Transition Zone if raw outputs are offloaded.

## Common Mistakes

**Loading raw graph output into context.**
Dependency graphs can be thousands of lines. Write to disk, read only the summary. Loading the full graph pushes the session into Transition Zone.

**Skipping blast-radius for "small" changes.**
Blast radius is non-negotiable regardless of change size. A one-line change in a high-fan-in module can have a wide blast radius.

**Blocking without a recommendation.**
Every block must include a concrete recommendation: refactor X before proceeding, or raise with `refine` to revise the boundary.

**Auditing file by file.**
A complete walk of a big repo produces two hundred nits and misses the race. Go where a mistake costs the most — input, auth, writes, shared state — and say what you did not read.

**Opening audit issues with labels.**
Labels are the pipeline's output. Write the block without one; `refine` sets `agent:backlog` or `human:decision`.
