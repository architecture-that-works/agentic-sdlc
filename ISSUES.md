# ISSUES.md

Local improvement backlog. Add improvements as Agile User Story blocks below the ISSUES sentinel.

Run `task sync` to push pending blocks to GitHub Issues and the project board.
Run `task sync -- -DryRun` to preview without making changes.

---

## Block Format

Every block must follow this structure exactly so `task sync` can parse it:

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
  - *(no label)* — the **default, and almost always right**: labels are set by the pipeline, not when writing issues
  - `human:approval` — only to force a merge hold on a change that does not touch governance files (those are held automatically)
  - `human:decision` — set by refine, never by hand: the issue waits on questions listed in it
  - `agent:backlog` `agent:implementing` `agent:reviewing` `agent:shipped` `agent:failed` `agent:paused` — orchestrator state machine; set by the orchestrator, never by humans or agents writing issues
- `ESTIMATE:` — Fibonacci story point integer (see scale below). Synced to the **Estimate** field on the GitHub Project board. **Do not use the project board's Size field** (XS/S/M/L/XL) — it is not populated by any script and conflicts with Estimate as the single sizing signal.
- `PRIORITY:` — one of `P0 | P1 | P2 | P3 | P4` (see definitions below). Synced to the **Priority** field on the GitHub Project board.

After `task sync`, each processed block is removed from this file and lives as a GitHub Issue on the project board.

---

## Estimate

Estimates use the Fibonacci series: **1 · 2 · 3 · 5 · 8 · 13 · 21**. Points measure complexity, risk, and effort relative to the 1-point anchor — not calendar hours.

**Anchor — what is a 1?**

A 1-point issue is a single-file additive edit where correctness is verifiable by one command without running the test suite.

- *Update `Status: Proposed → Accepted` in one ADR file. Verified by `grep 'Status: Accepted' docs/adr/ADR-001-your-decision.md`.*
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
| 21 | Spans every bounded context; compounding unknowns. **Decompose before implementation.** | A PRD tackled as a single issue rather than decomposed child issues |

**Rules of thumb:**
- If unsure between two values, pick the higher.
- Estimates include the full cost: implementation, tests, review, and any documentation AC requires.
- If a dependency is unresolved, do not estimate — flag for refinement first.
- `ESTIMATE: 13` or above is an epic: the plan stage decomposes it into child issues rather than implementing it directly.

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

```
ISSUE: Burn down the whole ISSUE block on sync, fences included
PRIORITY: P4
ESTIMATE: 2
**Goal**: The file the owner writes issues into stays clean after every sync, with no debris to tidy by hand.
**Description**: `task sync` removes a synced block's *content* but leaves its fenced code block behind. Syncing five issues on 2026-11-07 left five empty ` ``` ` / ` ``` ` pairs under the `<!-- ISSUES -->` sentinel, which the owner then had to delete by hand.

Reproduction: add any `ISSUE: … END_ISSUE` block inside a fenced code block below the sentinel (the format the Block Format section mandates), run `task sync`, and inspect the tail of `ISSUES.md`.

Cause: `$IssueRegex` in `.github/tasks/sync.ps1` matches `ISSUE:\s*(.*?)\r?\n(.*?)\r?\nEND_ISSUE` — the fence lines sit outside the match, so the burn-down loop that replaces each processed block never removes them. The subsequent blank-line collapse then packs the orphaned fences together, which is why they appear as adjacent empty pairs rather than as obvious gaps.

This is cosmetic — sync is idempotent and an empty fence parses as no block — but `ISSUES.md` is the intake surface for every new issue, and debris accumulating on it one sync at a time is the opposite of a clean intake path.
**Requirements**:
1. Make the burn-down remove the fenced wrapper along with the block, without consuming a fence that belongs to neighbouring prose — the Block Format section above the sentinel contains a literal example block that must survive untouched.
2. Prefer matching the fence as part of the block at parse time over post-hoc cleanup of leftover fences, so there is one definition of "where a block starts and ends" rather than two.
3. Keep the existing behaviour intact: blocks above the sentinel are never parsed, the idempotent title reuse still applies, and `-DryRun` still changes nothing.
4. Add a test in `tests/orchestrator/test_sync_issues.py` that syncs a fenced block and asserts the tail of the file contains no empty fence pair, and that the Block Format example above the sentinel is unchanged.
**Acceptance Criteria**:
- After a sync of one or more fenced blocks, `ISSUES.md` contains no empty ` ``` ` pair and no trailing blank-line run.
- The literal example block in the Block Format section is byte-identical before and after a sync.
- `-DryRun` leaves the file untouched.
- `uv run pytest` passes, and the new test fails against the current burn-down logic.
END_ISSUE
```
