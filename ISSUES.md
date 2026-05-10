# ISSUES.md

Local improvement backlog. Add improvements as Agile User Story blocks below the ISSUES sentinel.

Run `task sync` to push pending blocks to GitHub Issues and the project board.
Run `task sync -- -DryRun` to preview without making changes.

---

## Block Format

Every block must follow this structure exactly so `sync-issues.ps1` can parse it:

```
ISSUE: [Action-oriented Issue Title]
LABELS: AFK
ESTIMATE: 5
PRIORITY: P3
**Goal**: A singular non-technical explanation of the business outcome.
**Description**: Context answering *why* this matters, linking previous boundaries to the new feature.
**Requirements**:
1. Sequenced, modular actionable steps explicit enough for an independent developer (or AI) to implement.
**Acceptance Criteria**:
- Strict qualitative boundaries defining when the work is officially "finished".
END_ISSUE
```

Header fields — all optional, must appear before the body, in any order:

- `LABELS:` — comma-separated label names. Known labels (`AFK`, `HITL`, `planning`, `enhancement`, `bug`) are auto-created with canonical colours if absent. Unknown labels are created with a grey fallback. The `repo:<repo-name>` label is always applied regardless.
- `ESTIMATE:` — Fibonacci story point integer (see scale below). Synced to the **Estimate** field on the GitHub Project board.
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

**Scale — benchmarked against actual issues in this repo:**

| Points | Definition | Repo examples |
|--------|-----------|---------------|
| 1 | Single-file additive edit; correctness verified by one command, no test run | Single ADR status update; single `.gitignore` pattern |
| 2 | Mechanical, multi-file; verifiable by CLI commands; no design thought | #3 (pin SHAs + Dependabot), #17 (.gitignore), #22 (devcontainer), #24 (UV cache + id-token audit), #25 (build.yml), #27 (accept ADRs + CODEOWNERS + remove _tasks) |
| 3 | New document or single function; clear spec; no design decision required | #1 (harden staging), #2 (CI coverage + audit), #18 (SECURITY.md + ADR-008), #21 (Dockerfile) |
| 5 | New cross-cutting behaviour; tests needed; path is clear | #5 (embed skills), #6 (project_type), #7 (post-merge CONTEXT.md), #20 (sentinel tokens), #28 (port CONTEXT.md step to orchestrator) |
| 8 | Significant complexity; multiple subsystems or a design decision requiring alignment | #19 (template restructure + HITL junction), #26 (multi-cloud deploy via WIF) |
| 13 | Major system creation or replacement; end-to-end testing required | #23 (native GitHub Actions orchestrator) |
| 21 | Full architectural phase spanning every bounded context; compounding unknowns. **Decompose before implementation.** | PRD #16 as a single issue — the full multi-phase template evolution without prior decomposition |

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
