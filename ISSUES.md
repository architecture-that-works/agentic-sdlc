# ISSUES.md

Local improvement backlog. Add improvements as Agile User Story blocks below the ISSUES sentinel.

Run `task sync` to push pending blocks to GitHub Issues and the project board.
Run `task sync -- -DryRun` to preview without making changes.

---

## Block Format

Every block must follow this structure exactly so `sync-issues.ps1` can parse it:

```
ISSUE: [Action-oriented Issue Title]
**Goal**: A singular non-technical explanation of the business outcome.
**Description**: Context answering *why* this matters, linking previous boundaries to the new feature.
**Requirements**:
1. Sequenced, modular actionable steps explicit enough for an independent developer (or AI) to implement.
**Acceptance Criteria**:
- Strict qualitative boundaries defining when the work is officially "finished".
END_ISSUE
```

Header fields — all optional, must appear before the body, in any order:

- `LABELS:` — comma-separated subset of the allowed label set. Agents must not create new labels. Allowed values:
  - `AFK` — issue can be processed autonomously by the orchestrator without human intervention
  - `HITL` — issue requires human decision or approval at some point; orchestrator will not pick it up automatically
  - `agent:backlog` `agent:implementing` `agent:review` `agent:merged` `agent:failed` — orchestrator state machine; set by the orchestrator, not by humans or agents writing issues
- `ESTIMATE:` — Fibonacci story point integer (see scale below). Synced to the **Estimate** field on the GitHub Project board. **Do not use the project board's Size field** (XS/S/M/L/XL) — it is not populated by any script and conflicts with Estimate as the single sizing signal.
- `PRIORITY:` — one of `P0 | P1 | P2 | P3 | P4` (see definitions below). Synced to the **Priority** field on the GitHub Project board.

After `task sync`, each processed block is removed from this file and lives as a GitHub Issue on the project board.

---

## Estimate

Estimates use the Fibonacci series: **1 · 2 · 3 · 5 · 8 · 13 · 21**. Points measure complexity, risk, and effort relative to the 1-point anchor — not calendar hours.

**Anchor — what is a 1?**

A 1-point issue is a single-file additive edit where correctness is verifiable by one command without running the test suite.

- *Update `Status: Proposed → Accepted` in one ADR file. Verified by `grep 'Status: Accepted' docs/adr/ADR-001.md`.*
- *Add a single `.gitignore` pattern as a standalone issue. Verified by `git check-ignore -v <pattern>`.*

A true 1 is rare as a standalone issue — in practice issues bundle and land at 2 minimum because AC always includes `uv run pytest`.

**Scale:**

| Points | Definition | Typical examples |
|--------|-----------|-----------------|
| 1 | Single-file additive edit; correctness verified by one command, no test run | Update one ADR status; add a single `.gitignore` pattern |
| 2 | Mechanical multi-file change; verifiable by CLI commands; no design decisions | Add a CI workflow file; add devcontainer config; update dependency pins |
| 3 | New document or single function with a clear spec; no architectural decision required | Add a `SECURITY.md`; write a multi-stage `Dockerfile`; add a coverage gate to CI |
| 5 | New cross-cutting behaviour touching multiple modules; tests required; path is clear | Add a new config field propagated through config, tests, and docs; port a script to a new runtime |
| 8 | Significant feature spanning multiple subsystems or requiring an explicit design decision | Multi-cloud deployment workflow with WIF; template restructure affecting generation output |
| 13 | Major system creation or replacement; end-to-end behaviour must be verified | Replace a polling-based pipeline with an event-driven one; introduce a new orchestration layer |
| 21 | Full architectural phase spanning every bounded context; compounding unknowns. **Decompose before implementation.** | A PRD tackled as a single issue rather than decomposed child issues |

**Rules of thumb:**
- If unsure between two values, pick the higher.
- Estimates include the full cost: implementation, tests, review, and any documentation AC requires.
- If a dependency is unresolved, do not estimate — flag for refinement first.
- `ESTIMATE: 13` or above requires `LABELS: HITL`. The agent does not proceed AFK.

---

## Priority

Priority expresses urgency and impact. Independent of size — a 1-point issue can be P2 if it blocks correct behaviour.

| Label | Name | Definition |
|-------|------|------------|
| P4 | Nice to have | Non-breaking improvement: clean-up, refactor, DX, or non-functional enhancement. No user-facing impact if deferred. |
| P3 | Normal — new work | New functionality. Application works without it, but planned and expected. |
| P2 | Priority — broken | Application not working correctly. Pick up in current or next sprint. Requires documented broken behaviour and reproduction path. |
| P1 | Application down | Completely unavailable or critically degraded. Immediate implementation. Extremely rare. |
| P0 | Multi-repo outage | Multiple repositories impacted. Incident-level response. |

Default new issues to **P3** (new work) or **P4** (improvement). Escalation to P2 or above requires the issue description to document the broken behaviour and a reproduction path or observable symptom.

---

<!-- ISSUES -->

ISSUE: fix(kanban): harden orchestrator project-board access (cache PROJECT_ID, sync workflows, setup scope check)
LABELS: AFK
PRIORITY: P2
ESTIMATE: 5
**Goal**: Eliminate the recurring orchestrator failures around project-board access so every pipeline run resolves the project owner, project ID, estimate, and priority fields without per-call gh probes.
**Description**: A previous round of fixes (commit landing alongside this issue) added the missing `KANBAN_*` env vars to `orchestrator.yml` and removed the silent probe in `Get-ResolvedOwner`. Three structural weaknesses remain. (1) `Get-ProjectId` still queries `gh project list --owner` on every orchestrator run instead of using a setup-time resolved value, so any owner/scope flake fails the whole pipeline. (2) `kanban-lanes.yml` independently re-queries `gh project list --owner` to find the project node ID for every label-driven lane move — same brittleness, separate workflow. (3) `task setup` never verifies that the PAT in `secrets.GH_TOKEN` actually has the `project` scope, so scope mismatches surface only at runtime with noisy logs. The fix is to resolve `KANBAN_PROJECT_ID` once at setup, persist it in `.env` and as a GHA variable, plumb it through both workflows, and add a setup-time scope assertion.
**Requirements**:
1. Update `.github/scripts/setup.ps1` to resolve the project node ID via `gh project list --owner $ProjectOwner --format json` filtered by project number, and store the result in `.env` as `KANBAN_PROJECT_ID` AND via `gh variable set KANBAN_PROJECT_ID`.
2. Update `.github/scripts/kanban/_common.ps1` `Get-ProjectId` to return `$env:KANBAN_PROJECT_ID` directly when set, falling back to the existing query only when absent.
3. Add `KANBAN_PROJECT_ID: ${{ vars.KANBAN_PROJECT_ID }}` to the orchestrator job env block in `.github/workflows/orchestrator.yml`.
4. Update `.github/workflows/kanban-lanes.yml` to consume `${{ vars.KANBAN_PROJECT_ID }}` directly for the lane move (drop the in-step `gh project list` query at lines 50-51).
5. Add a setup-time scope check in `setup.ps1`: probe `gh auth status --show-token` (or run a known project-scope command) and warn loudly if `project` scope is missing. Document in setup output that the PAT used for `GH_TOKEN` repo secret must also carry `project` scope — local `gh auth` having it does not guarantee the secret does.
6. Update `README.md` Quickstart section to note that the `GH_TOKEN` repo secret PAT must carry both `repo` AND `project` scopes (current wording is correct but easy to miss).
**Acceptance Criteria**:
- A fresh `task setup` populates `KANBAN_PROJECT_ID` in `.env` AND as a GHA variable.
- The orchestrator log shows no `gh project list --owner` calls during a pipeline run (only `gh project item-list` and `gh project item-edit`, which use the cached project ID).
- A label-event-driven lane move via `kanban-lanes.yml` succeeds without any `gh project list` call in the workflow log.
- `task setup` warns the user when the active gh auth context lacks `project` scope.
- All existing kanban tests pass; orchestrator end-to-end run on issue #23 (or any agent:backlog issue) completes the implement phase with correct SP (matching the project Estimate field) and the lane visibly transitions Backlog → Implementing → Review → Merged.
END_ISSUE
