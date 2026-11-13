---
name: ADR-012-orchestrator-graphql-budget
description: Decision to cut the orchestrator's GraphQL footprint (default-branch + label ops moved off GraphQL, rate-limit pre-flight) and DEFER provisioning a dedicated CI identity — records why a GitHub App is infeasible for the user-owned Projects v2 board and the trigger to revisit
applies_to: all
---

# ADR-012: Orchestrator GraphQL Budget — Cut Consumption, Defer Dedicated CI Token

## Status

Accepted

## Context and Problem Statement

The AFK orchestrator (`orchestrator.yml` + `.github/scripts/kanban/*`) authenticates with `GH_TOKEN`, a personal classic PAT (see SECURITY.md). Nearly every `gh issue/pr/project/repo` call it makes hits GitHub's **GraphQL** API, which is rate-limited to **5000 points/hour per user** and throttles *independently* from the REST API (also 5000/hr, but near-idle in this workflow).

Because the cloud orchestrator and the developer's local `gh` session authenticate as the **same user** (`ysuurme`), they share one GraphQL budget and compete for it. On **2026-06-27** a 5-issue backlog drain plus interactive use drove GraphQL to `0/5000` and blocked `task runner` mid-drain. Two independent levers can address this:

1. **Reduce** how much GraphQL the orchestrator consumes per drain.
2. **Isolate** the orchestrator onto its own budget via a dedicated identity.

Background: memory `project_graphql_budget`.

A complication shapes lever 2: **kanban Project #5 is user-owned** (`KANBAN_PROJECT_OWNER=ysuurme`, account type *User*). As documented in SECURITY.md, **neither GitHub Apps nor fine-grained PATs can mutate user-owned Projects v2** — a classic PAT is the only credential that works. This rules out the "GitHub App installation token" that would otherwise be the textbook isolation answer, unless the project is first migrated to an organization. A *second* classic PAT under the same `ysuurme` account does **not** help either: the 5000/hr limit is per-user, not per-token.

## Considered Options

* **Option A — Dedicated bot GitHub account + its own classic PAT.** A separate user account (added as repo + Project #5 collaborator) carries its own 5000/hr GraphQL budget and, being a classic PAT, can mutate the user-owned project. Fully isolates CI from interactive use.
* **Option B — Migrate Project #5 to a GitHub organization, then use a GitHub App installation token.** Cleanest long-term isolation (installation-scoped budget), but requires transferring/re-creating the project, re-resolving `KANBAN_PROJECT_ID` / field IDs, and re-running `task setup`.
* **Option C — Cut GraphQL consumption and DEFER a dedicated identity.** Keep the single classic PAT; shrink the orchestrator's GraphQL footprint and add a pre-flight budget check; accept the shared budget until throttling actually recurs.

## Decision Outcome

Chosen option: **Option C.**

Rationale: the consumption cuts (below) remove the bulk of the orchestrator's GraphQL calls at zero operational cost, while both isolation options carry real, ongoing cost — Option A means standing up and securing a second GitHub identity; Option B means an org migration that reconfigures the whole kanban setup. Deferring keeps the system simple and revisits isolation only if the cheaper fix proves insufficient. The cut-consumption work is **not** deferred and ships with this decision.

### What shipped (consumption cuts)

| Lever | Before (GraphQL) | After |
|-------|------------------|-------|
| Default-branch resolution | `gh repo view --json defaultBranchRef` at ~6 call sites | Cached `$KanbanDefaultBranch` in `_common.ps1`: `GITHUB_DEFAULT_BRANCH` env → local `origin/HEAD` symref → `git ls-remote` (git protocol, not API) → `gh repo view` only as a guarded last resort |
| Issue-label writes | `gh issue edit --add-label/--remove-label` | `gh api` `POST`/`DELETE repos/{repo}/issues/{n}/labels` (REST) |
| Current agent:* label read | `gh issue view --json labels` | `gh api repos/{repo}/issues/{n}/labels` (REST) |
| Workflow default branch | `gh repo view` in the merge job's bash | `GITHUB_DEFAULT_BRANCH` job env, set from `github.event.repository.default_branch` |
| Projects v2 board moves | GraphQL (irreducible — no REST API) | **Unchanged** — per-process item cache + "skip if already in lane" guard retained |

A pre-flight in `runner.ps1` (shipped earlier, commit `2ddd18a`) reads the free `rate_limit` endpoint and fails with a precise reset time when GraphQL is exhausted, rather than mis-reporting an empty queue. A regression test (`tests/scripts/test_kanban_graphql_budget.py`) asserts no `gh repo view` returns to a stage-script hot path (or the `orchestrator.yml` inline bash) and that label ops stay on REST.

### Measured per-issue cost (2026-06-28)

Measured via `gh api rate_limit` GraphQL `remaining` deltas. GraphQL is a rolling **5000 points/hour** budget (separate from REST's own near-idle 5000/hr):

| Call | Cost | ~Times/issue |
|------|-----:|-------------:|
| `gh project item-list ... --limit 200` (board fetch) | **102** | 1 |
| `gh pr checks` (CI poll, every 10 s up to 15 min) | 2 | ~21 |
| `gh issue view/edit` body, `gh issue comment`, lane-move `item-edit`, `gh pr` create/view/list/merge | 1–2 | ~37 |
| `gh api .../labels` (REST, post-cut) | **0** | — |

Total **≈ 150–220 points/issue** (happy path) → **≈ 20–26 issues/hour** on a fresh budget, less when shared with interactive `gh`. The cuts above removed ~15 points/issue; the **dominant costs are the board fetch (~102) and CI polling (~42)**, which this ADR deliberately leaves in place — see below.

### Deferred levers (future reference)

If the orchestrator ever throttles again, these are the high-value reductions, in priority order. Both are **deferred**: ~25 issues/hour is ample for current AFK drains, and each touches a safety-critical path where a regression is worse than the budget it saves.

| Lever | Saves/issue | Effort & risk |
|-------|------------:|---------------|
| **Board fetch → targeted query.** Replace `gh project item-list --limit 200` (~102 pts) with the issue's `projectItems` connection (`repository.issue(number).projectItems`, ~2 pts). The "fetch all + cache" model backfires in the one-process-per-issue AFK drain — it spends ~100 points to locate a single item. | **~100** | Larger. Rewrites `Get-AllProjectItems` / `Get-ProjectStatus` / `Get-ProjectItemId` / `Get-ProjectFieldValues` and the per-process caching model. **Lane-correctness critical** — a wrong item id moves the wrong card. |
| **CI polling → REST.** Replace `gh pr checks` (2 pts × ~21 polls) with `gh api repos/{repo}/commits/{sha}/check-runs` + `.../status` (REST, 0 GraphQL). | **~42** | Medium. Two poll loops to convert (`merge.ps1` and the `orchestrator.yml` merge job) plus bucket-mapping (pass/fail/pending/skip) from `status`/`conclusion`. **CI-gating is safety-critical** — a mapping bug could squash-merge a red PR. |

Doing both would cut per-issue cost from ~190 → ~45 points (≈ 4×, ~100+ issues/hour). Sequence the board-fetch lever first (larger saving) and gate each behind the existing regression test plus a real before/after `rate_limit` comparison.

### Confirmation

* `tests/scripts/test_kanban_graphql_budget.py` passes; full `uv run pytest` green (155 tests).
* `git grep 'gh repo view' .github/scripts/kanban` returns only the two guarded last-resort fallbacks in `_common.ps1`.
* Compare `gh api rate_limit` GraphQL `remaining` before/after a backlog drain — consumption is materially lower; all `agent:*` transitions still apply.
* **Contingency only (not planned work):** a dedicated CI identity is judged unnecessary given the cuts, and no backlog item tracks it. Only if a full backlog drain plus normal interactive `gh` use again drives GraphQL toward `0/5000` (as on 2026-06-27) should isolation be reconsidered, starting from **Option A** (dedicated bot account + classic PAT) — Option B's GitHub App cannot mutate the user-owned Projects v2 board.

## Pros and Cons of the Options

### Option A — Dedicated bot account + classic PAT

| | |
|---|---|
| **Good** | Full budget isolation — CI gets its own 5000/hr, never competes with interactive use |
| **Good** | Classic PAT works with the existing user-owned Project #5 — no migration |
| **Bad** | A second GitHub identity to create, secure, and rotate; must be added to the branch-protection bypass list (the #92 post-merge CONTEXT.md push) |
| **Bad** | For a private repo a bot collaborator can consume a paid seat |

### Option B — Org migration + GitHub App

| | |
|---|---|
| **Good** | Cleanest, most durable isolation; installation-scoped budget; fine-grained permissions |
| **Good** | Unblocks GitHub App / fine-grained PAT support for Projects v2 generally |
| **Bad** | Requires migrating the project to an org and reconfiguring `KANBAN_PROJECT_*` vars + `task setup` |
| **Bad** | Largest blast radius for a budget problem the consumption cuts may already solve |

### Option C — Cut consumption, defer identity (chosen)

| | |
|---|---|
| **Good** | Removes most orchestrator GraphQL calls at zero operational cost |
| **Good** | No new identity, no migration, no extra secret to manage |
| **Good** | Pre-flight surfaces exhaustion clearly instead of failing as a silent no-op |
| **Bad** | Budget is still *shared* — a large enough drain alongside heavy interactive use could still throttle, deferring (not eliminating) the isolation work |
