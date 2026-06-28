---
name: ADR-013-workflow-parameter-passing
description: Decision to pass run parameters between kanban scripts via an environment transport hydrated into a single Get-KanbanContext object, enforce a library/entry-point split (no top-level param in dot-sourced files), and migrate to a PowerShell module in a follow-up
applies_to: all
---

# ADR-013: Workflow Parameter Passing — Run Context Object + Env Transport

## Status

Accepted

## Context and Problem Statement

The kanban orchestrator is a tree of PowerShell scripts. Entry points (`run.ps1`, `start.ps1`) dot-source a chain of libraries (`_common.ps1`, `implement.ps1`, `review.ps1`, `merge.ps1`, `architecture.ps1`, and the refine self-grill helper) so functions are shared in one scope.

**Dot-sourcing runs a file's top-level statements — including its `param()` block — in the caller's scope.** Any dot-sourced file with a `param()` therefore injects its parameter *names* (at their defaults) into the shared scope, silently overwriting caller variables of the same name.

This bit us concretely: `run.ps1 -Issue 86` bound `$Issue = 86`, then `. implement.ps1` → `. grill.ps1` ran `grill.ps1`'s `param([int]$Issue = 0)` **in run.ps1's scope**, resetting `$Issue` to `0`. The whole pipeline then ran against issue **#0** (label adds 404'd, no progress), and only the drain loop guard stopped an infinite re-dispatch. The fix at the workflow→`run.ps1` boundary (a previous PR) could not see this — the corruption happened *after* binding, inside the dot-source chain. The bug was introduced when a new dot-sourced file (`grill.ps1`, self-grill subagent) added a colliding `param()`.

Run parameters passed through **script-scope variables** are thus non-deterministic: adding any new dot-sourced file can clobber them. As this template evolves and more files reference these key parameters, we need a passing mechanism that is stable by construction.

## Considered Options

* **Option A — Defensive capture.** In `run.ps1`, copy `$Issue` into a uniquely-named variable before the dot-sources and use that. Fixes the symptom locally; leaves the leak hazard for every other variable and every future dot-sourcer. A patch, not a foundation.
* **Option B — Env transport + run context object + enforced library/entry split.** Pass run parameters as environment variables (the only transport stable across `&`-calls, dot-sourcing, nested `pwsh`, and subprocesses), hydrate them once into a single `Get-KanbanContext` object that everything reads, and forbid top-level `param()` in any dot-sourced file (enforced by test).
* **Option C — Convert the scripts to a PowerShell module now.** `Import-Module` exposes only exported functions; module-private variables and internal `param()` defaults never reach the caller's scope, so the leak class is impossible by construction. The proper long-term structure, but a large, test-touching refactor.

## Decision Outcome

Chosen: **Option B now, Option C as the immediate follow-up (phased).**

Option A is rejected as a patch. Option C is the correct end-state, but converting all entry scripts and tests while the AFK pipeline was broken was too much risk in one step — so we ship B to fix the bug deterministically and establish the contract, **designing B's interface (`Get-KanbanContext`) to be exactly what the module will export**, so Phase 2 reuses it unchanged.

### The contract (Phase 1 — this ADR)

1. **Transport = environment.** Entry points set `KANBAN_ISSUE` / `KANBAN_MAX_RETRIES` (alongside the existing `KANBAN_*` config). Env survives every boundary; a script-scope variable does not.
2. **Interface = `Get-KanbanContext`.** `_common.ps1` hydrates the run's key parameters once into a single immutable object (`IssueNumber`, `MaxRetries`, `Repo`, `DefaultBranch`, `Runtime`) via a `Get-EnvInt` helper that retrieves directly and falls back cleanly (with a logged warning) on a missing/invalid value. Every script reads `(Get-KanbanContext).X` — never a bare `$Issue`, never ad-hoc `$env:` reads. New per-run keys are added in this one place.
3. **Library / entry-point split.** Dot-sourced **libraries** (`_*.ps1` and the stage files) carry functions only — **no top-level `param()`**. **Entry points** (`run.ps1`, `start.ps1`, `retry.ps1`, `runner.ps1`) own a `param()`/read the context and are invoked with `&`, never dot-sourced. `grill.ps1` was split into `_grill.ps1` (dot-sourced library, no `param()`) + `grill.ps1` (thin CLI wrapper) to conform.
4. **`run.ps1` takes no parameters** — it reads `Get-KanbanContext` and fails loud if `IssueNumber <= 0`, so the pipeline can never silently run against #0.

This complements ADR-011's three deterministic layers:

| Scope | Carrier |
|-------|---------|
| Static config | `KANBAN_*` env → `$Kanban*` consts in `_common.ps1` |
| **Per-run parameters** | **`KANBAN_ISSUE`/`KANBAN_MAX_RETRIES` env → `Get-KanbanContext`** (this ADR) |
| Cross-runtime state | issue-body JSON (ADR-011) |

### Enforcement

`tests/scripts/test_kanban_script_contract.py` statically asserts no dot-sourced file declares a top-level `param()`, that `grill.ps1` is never dot-sourced, and that entry points are never dot-sourced. The scope-leak class cannot silently return.

### Phase 2 — module migration (follow-up PR + ADR update)

Convert the dot-sourced files into a `Kanban` module (`.psm1` + `.psd1`): `Import-Module` in entry scripts, `Get-KanbanContext` and the stage functions exported, stage files loaded internally so their scope never reaches the importer. `PowerShellVersion = '7.0'` in the manifest replaces scattered `#Requires`. Tests migrate to `Import-Module`/Pester. The `Get-KanbanContext` interface from Phase 1 is the module's export — no rework.

### Confirmation

* Reproduced: with `KANBAN_ISSUE=86`, dot-sourcing the full `run.ps1` chain leaves `(Get-KanbanContext).IssueNumber == 86` and a bare `$Issue` empty (no leak).
* `tests/scripts/test_kanban_script_contract.py` + `test_grill_harness.py` pass; full `uv run pytest` green.
* A `task runner` drain resolves a real issue number (never #0) and moves it out of `agent:backlog`.
* Revisit at Phase 2: once the module ships, the no-top-level-`param()` test becomes redundant with module encapsulation but is kept as a cheap guard.

## Pros and Cons of the Options

### Option A — Defensive capture
| | |
|---|---|
| **Good** | Smallest possible change |
| **Bad** | Patches one variable; the leak hazard remains for all others and all future dot-sourcers |

### Option B — Env transport + context object (chosen, Phase 1)
| | |
|---|---|
| **Good** | Deterministic across every boundary; one place to add run keys; fixes the bug at the root; forward-compatible with the module |
| **Good** | Enforced by test — the bug class cannot silently return |
| **Bad** | Convention still has to be followed for new files (mitigated by the contract test); not yet true encapsulation |

### Option C — PowerShell module (chosen, Phase 2)
| | |
|---|---|
| **Good** | Leak class impossible by construction; explicit public API; versioned manifest; Pester-testable |
| **Bad** | Large, test-touching refactor — too risky to land in the same step as the bug fix |
