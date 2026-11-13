---
name: ADR-011-orchestrator-state-carrier
description: Orchestrator state lives in the GitHub issue itself (single cross-runtime carrier); 4-lane FSM with explicit allowed-transitions table and a pre-backlog readiness gate; local files rejected for cross-runtime continuity
---

# ADR-011: Orchestrator State Carrier

## Status
Accepted

## Context and Problem Statement

The kanban orchestrator must resume work from any runtime — a developer's
laptop, a GitHub Actions runner, or the Phase-3 Cloud Run Orchestrator Service
(see ADR-010 and the Phase-3 cloud-runtime north star in CONTEXT.md "Out of
Scope"). Today state lives in two places that do not survive a runtime
handover:

1. `**.planning/<issue>/state.json**` — a working cache on whichever filesystem
   ran the previous orchestration pass. A GHA runner starts with an empty
   workspace and cannot see the developer's `.planning/` directory. A Cloud Run
   container starts with an empty disk on every invocation.
2. **Issue comments parsed by regex** — orthogonal to the comment taxonomy
   (`🤖` signal vs. `·` noise) and brittle: free-form text changes drift the
   parser, and reading state requires scanning every comment.

Before Phase 2 (alignment logic) and Phase 3 (cloud runtime) extend the system,
the state schema must be frozen as runtime-agnostic. The contract must let any
runtime read and write the state with no shared filesystem and no out-of-band
storage.

A parallel concern: the workflow earlier carried a planned 8-label expansion
(`agent:refining`, `agent:architecting`, `agent:planning`) to surface the
pre-backlog stages as kanban lanes. That bloats the label set, leaks
implementation phases into the human-facing board, and conflates "readiness to
be picked up" with "currently in flight." The four canonical lanes
(`backlog → implementing → review → merged`, with `agent:failed` as in-backlog
recovery) already model the kanban surface; readiness belongs *inside* an
issue's state, not as a separate lane.

## Considered Options

* **Option A — Local `.planning/<issue>/state.json`** (status quo)
* **Option B — A separate external store** (Redis, Firestore, an S3 bucket)
* **Option C — The GitHub issue body as the single durable carrier**
  (machine-state fenced JSON region + human-readable Markdown sections)

## Decision Outcome

Chosen option: **Option C — the issue body is the single cross-runtime
carrier**, because it is the only store that every runtime can already reach,
authenticated, with the same `gh` calls. Cloud Run starts with nothing on disk
but always has API access to the issue. A GHA runner sees the same data the
laptop saw. There is no schema-migration work in Phase 3 because there is no
local state to migrate.

The state is held inside the issue body as a fenced JSON block bounded by two
HTML comment markers:

```
<!-- AGENT-STATE:BEGIN -->
```json
{ ... PlanningState ... }
```
<!-- AGENT-STATE:END -->
```

`Get-PlanningState` extracts the block via deterministic regex over the markers
(never over freeform comments) and parses it as JSON. `Set-PlanningState`
replaces only the bounded region — every Markdown section outside the markers
is preserved verbatim. The canonical schema is the pydantic model
`src/utils/m_planning.py::PlanningState`.

### 4-lane allowed-transitions table

`Test-StateTransition` rejects every pair not in this table:

| From → To       | Meaning |
|-----------------|---------|
| `backlog → implementing`        | orchestrator picked up a ready issue |
| `implementing → review`         | implementation complete, PR opened |
| `review → merged`               | approved + merged |
| `review → implementing`         | reject/retry — feedback addressed |
| `implementing → backlog`        | failure → `agent:failed` (in-backlog recovery) |
| `review → backlog`              | failure → `agent:failed` (in-backlog recovery) |

`refining`, `architecting`, `planning` are **not lanes**. They are
pre-backlog readiness flags (`PlanningState.readiness.refined |
architected | planned`) carried inside the same JSON block.

### Readiness gate

`Test-Readiness` returns `true` only when all three readiness flags are
`done = true` and `open_questions` is empty. `Set-AgentState` calls
`Test-Readiness` before permitting entry to `agent:backlog`. Issues that
fail the gate stay where they are and surface a warning — the orchestrator
never picks up an unrefined issue.

### Confirmation

* Schema lives at `src/utils/m_planning.py`; round-trip covered by
  `tests/test_kanban_state.py`.
* FSM allowed-transitions table lives in `.github/scripts/kanban/_common.ps1`
  (`$KanbanAllowedTransitions`); `tests/test_kanban_state.py` covers every
  allowed pair and every disallowed pair.
* Label set provisioning lives in `.github/scripts/setup.ps1` and is exactly
  `AFK`, `HITL`, `agent:backlog`, `agent:implementing`, `agent:review`,
  `agent:merged`, `agent:failed`. No `agent:refining|architecting|planning`.
* `.planning/` remains in `.gitignore` (and is inherited by every Copier-
  generated project) so the working cache is never committed.
* Revisit when Phase 3 introduces the persistent Cloud Run runtime — confirm
  that the runtime can still resume any issue from issue + repo + PR alone.

## Pros and Cons of the Options

### Option A — Local `.planning/<issue>/state.json`

| | |
|---|---|
| **Good** | Simple, no API calls per write. |
| **Good** | Easy to inspect with cat/ls. |
| **Bad** | Invisible to any other runtime — cannot survive laptop → GHA → Cloud Run handover. |
| **Bad** | Phase-3 service would need a state-migration tool from a directory that may not exist on the source machine. |

### Option B — External store (Redis, Firestore, S3, ...)

| | |
|---|---|
| **Good** | Universally reachable by any runtime. |
| **Good** | Independent of GitHub API rate limits. |
| **Bad** | Introduces new infra (auth, secrets, region, cost) before Phase 3 needs it. |
| **Bad** | Splits truth — state in one place, the issue it relates to in another, eventually they drift. |
| **Bad** | A fork of this template now needs an external dependency on day 1. |

### Option C — Issue body fenced JSON + Markdown sections

| | |
|---|---|
| **Good** | Single durable carrier reachable by every runtime via `gh`. |
| **Good** | No new infrastructure; works on day 1 for forks. |
| **Good** | State is co-located with the work it describes; humans and agents read the same artefact. |
| **Good** | Phase-3 Cloud Run service has no local-state migration to do. |
| **Bad** | Writes cost a `gh issue edit` API call. |
| **Bad** | A `gh issue edit` race between two runtimes can clobber state (mitigated by single-active-runtime semantics enforced by the orchestrator lock + GHA concurrency group). |
