---
name: ADR-014-pre-backlog-alignment-gate
description: Decision to make refine→architect→plan a pre-backlog alignment gate that grants agent:backlog, with all alignment artefacts written into the issue body (retiring the .planning/ directory), and to make processing (implement→review→merge) human-triggered rather than automatic on the agent:backlog label
applies_to: all
---

# ADR-014: Pre-Backlog Alignment Gate

## Status

Accepted

## Context and Problem Statement

The 4-lane FSM (ADR-011) defines a pre-backlog **readiness gate**: an issue may only enter `agent:backlog` once it is `refined + architected + planned` with zero open questions. The gate was wired into `Set-AgentState`, but the flow around it was inconsistent:

1. **The gate was unreachable.** `Invoke-Architect` and `Invoke-Plan` were orphaned stubs with no callers, so `readiness.architected`/`readiness.planned` were never set — `Test-Readiness` could never clear. Meanwhile `sync-issues.ps1` applied `agent:backlog` directly from `ISSUES.md` `LABELS:` headers via `gh issue create --label`, **bypassing the gate entirely**. Issues landed "ready" without ever being aligned.
2. **Alignment ran in the wrong lane.** `Invoke-Implement` called `Invoke-Refine` then `Invoke-Architecture` *inside* the Implementing lane. Refinement, architecture, and planning happened during processing, not before the backlog — the opposite of what the gate is for.
3. **Artefacts lived outside the carrier.** `Architecture.ps1` wrote `.planning/<issue>/BLAST_RADIUS.md` + `state.json` to a gitignored local directory, contradicting ADR-011 (the issue body is the *single* cross-runtime carrier). Local files do not survive the hosted-runner → laptop boundary.
4. **The label auto-started work.** `orchestrator.yml` triggered the implement job on the `agent:backlog` labeled event, so anything that set the label immediately kicked off implementation — there was no separation between "ready" and "go".

We want one coherent flow: issues land un-aligned, a gate makes them ready, and the human decides when to process.

## Considered Options

* **Option A — Patch the gate in place.** Wire the orphaned stubs, keep `.planning/`, keep the `agent:backlog`-triggers-implement behaviour. Minimal change, but leaves the artefacts off-carrier and conflates "ready" with "go".
* **Option B — A first-class alignment gate.** Make `refine → architect → plan` an explicit pre-backlog conductor (`Invoke-Alignment`) that grants `agent:backlog` only when `Test-Readiness` clears; write every artefact into the issue body (retire `.planning/`); separate alignment (automatic on issue creation) from processing (human-triggered).

## Decision Outcome

Chosen: **Option B.**

### The flow

```
ISSUES.md ──task sync──▶ issue created (un-aligned, no agent:* label)
                              │
                   align.yml (on issue opened)  ── or ──  task align
                              │
              Invoke-Alignment  (Backlog gate, Refine.ps1)
                 1. Invoke-Refine        body, estimate, priority, Agent Brief,
                                         open questions → HITL children
                 2. Invoke-Architecture  blast-radius → "## Architecture Impact"
                 3. Invoke-Plan          impl. plan   → "## Implementation Plan"
                              │
                   Test-Readiness clears? ──no──▶ agent:backlog withheld;
                              │                    resolve HITL, re-run align
                             yes
                              ▼
                      agent:backlog  (ready, queued — NOT started)
                              │
              task runner (cloud drain)  ── or ──  task start (local HITL)
                              ▼
          Orchestrator.ps1: Implement (Develop → PR) → Review → Merge
```

### The contract

1. **Alignment is the toll-gate.** `Invoke-Alignment` (in `Refine.ps1`, the Backlog-lane owner) runs `Invoke-Refine → Invoke-Architecture → Invoke-Plan`, then calls `Set-AgentState 'agent:backlog'` — which re-checks `Test-Readiness` — only when refined + architected + planned and zero open questions. Open questions surface as HITL child issues; the label is withheld until they are resolved and alignment is re-run. The conductor is idempotent: already-aligned and HITL issues are skipped.
2. **Artefacts live in the issue body (extends ADR-011).** The Architect step writes `## Architecture Impact` and the Plan step writes `## Implementation Plan`, each as a marker-bounded section (`Set-IssueBodySection`) alongside the existing `AGENT-STATE` JSON and `Agent Brief`. **There is no `.planning/` directory** — `Set-PipelineState`, `BLAST_RADIUS.md`, `state.json`, and the raw pydeps file are removed. The blast-radius AST analysis is retained; only its sink changed.
3. **Alignment is automatic; processing is human-triggered.** `align.yml` runs `Invoke-Alignment` on the `issues: opened` event (skipping `HITL` children and already-`agent:backlog` issues). Granting `agent:backlog` no longer triggers anything — `orchestrator.yml`'s implement job runs **only** on `workflow_dispatch` (`task runner`) or locally (`task start`). The label means "ready", not "go".
4. **Sync never sets pipeline state.** `sync-issues.ps1` strips any `agent:*` label from `ISSUES.md` `LABELS:` headers; issues always land un-aligned and must pass the gate.
5. **The Implementing lane is Develop → PR only.** Alignment is done before the backlog, so `Invoke-Implement` no longer calls refine/architecture. A thin readiness re-check warns (does not re-align) if an issue somehow reaches Implementing un-aligned.

### Trigger surface

| Command / event | Effect |
|---|---|
| `task sync` | `ISSUES.md` → issues (un-aligned) |
| `align.yml` on issue opened | auto-align one issue → `agent:backlog` if ready |
| `task align ISSUE=N` / `task align` | align one / all un-aligned issues (local, backfill) |
| `task runner` | dispatch cloud drain of the `agent:backlog` queue |
| `task start [ISSUE=N]` | process one aligned issue locally (HITL) |

### Confirmation

* `Import-Module Kanban` exports `Invoke-Alignment`; the orphaned `Invoke-Architect` and `Set-PipelineState` are gone.
* `tests/scripts/test_kanban_script_contract.py` asserts: `Invoke-Alignment` exists and runs refine+architect+plan; the orphaned stub is removed; `Implement.ps1` runs neither refine nor architecture; no `.planning/` reference remains in any library script; `Architecture.ps1` writes via `Set-IssueBodySection` and sets `readiness.architected`.
* `tests/scripts/test_architecture.py` covers the file-count gate, the trivial-impact Markdown, the marker-bounded body-section upsert, and `$safeStr` truncation.
* Full `uv run pytest` green; module import smoke clean.

## Amendments

**2026-09-23** — at the owner's request, *ready* is now also *go*. Granting `agent:backlog`
starts implement → review → ship (`afk.yml` triggers on the label), so the owner never has to
trigger processing. What stays: the gate itself — `agent:backlog` is granted only when the issue
is refined, architected and planned with zero open questions — and everything in the issue body.
What changes around it: open questions are asked in the issue (label `human:decision`, a
`## Decisions` section, multiple-choice options) instead of in child issues, and the owner's
comment triggers the re-check. Stopping an issue is now done by closing it.

## Pros and Cons of the Options

### Option A — Patch the gate in place
| | |
|---|---|
| **Good** | Smallest change |
| **Bad** | Artefacts stay off-carrier (`.planning/` lost across runners); "ready" still auto-starts work; alignment still runs in the wrong lane |

### Option B — First-class alignment gate (chosen)
| | |
|---|---|
| **Good** | One coherent flow; the gate is reachable and enforced; every artefact survives on the issue carrier (ADR-011); "ready" and "go" are cleanly separated; per-lane scripts map 1:1 to lanes |
| **Good** | Enforced by contract tests — the bypass and off-carrier classes cannot silently return |
| **Bad** | Auto-alignment spends Claude + GraphQL on every new issue (accepted: `task align` is the controlled batch alternative; the ADR-012 cuts keep it within budget) |
