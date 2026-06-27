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

## Roadmap — Parked (NOT synced — here for visibility)

Everything **below** the `<!-- ISSUES -->` sentinel is ready to `task sync`; this section sits
**above** it, so sync ignores it. Promote an item by rewriting it as a proper
`ISSUE: … END_ISSUE` block below the sentinel once it's ready. Source: *Agentic Harness Evolution*
assessment (2026-06-27). Detailed pointer: memory `project_harness_roadmap.md`.

**Synced Phase-1 (now live):** #119 LLM-optimized error wrapper · #120 pre-commit + sub-60s CI ·
#121 PageRank codebase-map.

### Gated Phase-1 (need a decision before they earn a synced block)
- **Dynamic Plan/Act state machine** (Cline Plan/Act) — replaces the sequential skill chain with a
  read-only Plan / destructive Act loop. **Conflicts** with the adopted refine/architect/plan
  readiness gate; decide first: fixed sequence vs. dynamic loop. Spawns an ADR-009 update. High / High.
- **OpenTelemetry lineage context** (extends ADR-003; Principal "EU AI Act lineage + telemetry") —
  spans are *observability/audit*; the issue stays the *state* carrier (ADR-011). Gated on open
  question 1. High.

### Phase 2 — validation & resilience (after Phase 1 lands)
- **Hypothesis property-based testing** (Principal "Hypothesis PBT").
- **Cross-family adversarial review** — already tracked as **#89** (re-align, do not duplicate).
- **LLM-judge harness for ADRs** (Principal "LLM-judge harness").
- **CI-failure diagnose-and-patch subagent** (Principal "CI-failure diagnose-and-patch agent").

### Phase 3 — Cloud Run north star (partly tracked as #88)
- **Durable-execution event model** — GitHub Webhooks → Pub/Sub; durable, idempotent transitions.
- **ACP headless integration** (Cline ACP) — monitor the orchestrator from Zed/Neovim/JetBrains.
- **Ephemeral sandbox execution** (OpenAI Sandbox Agents / Daytona / Docker / E2B).

### Open questions (resolve before promoting the gated items)
1. **Telemetry egress vs. repo isolation** — OTel spans to an external backend (LangSmith/Datadog),
   or local `.jsonl` to preserve "everything-as-files"? (Gates the OTel item.)
2. **Review gating authority** — if cross-family review (#89) rejects Claude's work, route to
   `agent:failed` + notify, or force an autonomous Claude refactor loop?
3. **Sandboxing liability (Phase 3)** — orchestrator runs Bash in its own container, or provisions
   isolated remote sandboxes for untrusted LLM-generated code?

---

<!-- ISSUES -->
