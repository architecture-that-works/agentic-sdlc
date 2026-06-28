---
name: ADR-013-workflow-parameter-passing
description: Decision to pass run parameters between orchestrator scripts via an environment transport hydrated into a single Get-KanbanContext object, and package the orchestrator as a PowerShell module (Import-Module) so module-private $Kanban* state can never leak into a caller's scope — the dot-source leak that ran the pipeline against #0
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

Chosen: **Both B and C, shipped together in this PR.**

Option A is rejected as a patch. B (env transport + `Get-KanbanContext`) fixes the parameter-passing determinism; C (the module) makes the leak class *impossible by construction* rather than merely policed. They reinforce each other, so they land together: `Get-KanbanContext` is the module's exported interface.

### The contract

1. **Transport = environment.** Callers set `KANBAN_ISSUE` / `KANBAN_MAX_RETRIES` (alongside the existing `KANBAN_*` config). Env survives every boundary — `Import-Module`, dot-sourcing, nested `pwsh`, subprocesses; a script-scope variable does not.
2. **Interface = `Get-KanbanContext`.** `kanban/Config.ps1` hydrates the run's key parameters once into a single immutable object (`IssueNumber`, `MaxRetries`, `Repo`, `DefaultBranch`, `ProjectNumber`, `Runtime`) via a `Get-EnvInt` helper that retrieves directly and falls back cleanly (with a logged warning) on a missing/invalid value. Every consumer reads `(Get-KanbanContext).X` — never a bare `$Issue`, never ad-hoc `$env:` reads. New per-run keys are added in this one place.
3. **Module = encapsulation.** The orchestrator is a PowerShell module: `kanban/Kanban.psd1` + `Kanban.psm1` load the library files (`Config`, `Util`, `GitHub`, `../Claude`, the phase files `Architecture`/`Implement`/`Review`/`Merge`, and `Orchestrator`) and `Export-ModuleMember -Function *` — **functions only, never variables**. Because consumers `Import-Module`, the private `$Kanban*` state and any internal `param()` defaults stay in module scope and can never reach the caller. The dot-source `grill.ps1` `param()` leak is structurally impossible.
4. **Thin task scripts.** `tasks/` holds the Taskfile/workflow commands (`start`, `runner`, `retry`, `setup`, `sync-issues`); each `Import-Module`s the library and calls exported functions. There is **no `run.ps1`** — `orchestrator.yml` and `start.ps1` call `Invoke-Orchestration` directly (it fails loud if `IssueNumber <= 0`, so the pipeline can never run against #0). `grill.ps1` is split into `_grill.ps1` (dot-sourced library, no `param()`) + `grill.ps1` (CLI wrapper).

Directory layout: `kanban/` = the library/module; `tasks/` = thin commands; `ci/` = CI checks; `Claude.ps1` (provider-generic) sits at `.github/scripts/`.

This complements ADR-011's three deterministic layers:

| Scope | Carrier |
|-------|---------|
| Static config | `KANBAN_*` env → `$Kanban*` consts in `kanban/Config.ps1` (module-private) |
| **Per-run parameters** | **`KANBAN_ISSUE`/`KANBAN_MAX_RETRIES` env → `Get-KanbanContext`** (this ADR) |
| Cross-runtime state | issue-body JSON (ADR-011) |

### Enforcement

`tests/scripts/test_kanban_script_contract.py` statically asserts no dot-sourced file (including those loaded by `Kanban.psm1`) declares a top-level `param()`, that the `grill.ps1` CLI is never dot-sourced, and that task entry points are never dot-sourced — a cheap guard belt-and-suspenders with the module's structural encapsulation.

### Confirmation

* Reproduced: with `KANBAN_ISSUE=42`, `Import-Module Kanban` then dot-sourcing the full library chain leaves `(Get-KanbanContext).IssueNumber == 42` and a bare `$Issue` empty (no leak); all expected functions are exported and `$KanbanRepo` is **not** visible in the caller's scope.
* `tests/scripts/test_kanban_script_contract.py` + `test_grill_harness.py` pass; full `uv run pytest` green.
* A `task runner` drain resolves a real issue number (never #0) and moves it out of `agent:backlog`.

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
