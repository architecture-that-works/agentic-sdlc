---
name: ADR_STRUCTURE
description: Master index of all Architecture Decision Records — load this at session start to filter which ADRs apply to the current project_type without reading every file
---

# ADR Structure

Master index for all Architecture Decision Records in this project. Load this file at session
start instead of reading individual ADRs. Use the **Applies To** column to filter which ADRs are
relevant to the current `project_type`. Load the full ADR only when you need the rationale,
full option analysis, or confirmation checklist.

---

## How to Use

1. Read this index at session start alongside `CONTEXT.md` and `AGENTS.md`.
2. Filter by **Applies To** — skip ADRs that do not match the current `project_type`.
3. Load the individual ADR file only when you need the full context, considered options, or
   confirmation steps.
4. When making a decision that contradicts or extends an existing ADR, load the full ADR before
   proposing a change.

**Maintenance:** Updated by `ship` after every ADR merge. When adding a new ADR, add a row here
at the same time — never merge an ADR without a corresponding index update.

---

## Index

| ADR | Title | Status | Applies To | Decision |
|---|---|---|---|---|
| [ADR-000](ADR-000-template-architecture-decision.md) | Template Architecture Decision | Template | all | MADR format — use this template for every new ADR in this project |
| [ADR-001](ADR-001-data-science.md) | Data Science Tooling Selection | Accepted | `project_type: ml` | Marimo (`.py`) + Pandas + scikit-learn — Git-diffable notebooks, interactive EDA, tabular ML |
| [ADR-002](ADR-002-mlops.md) | Experiment Tracking and AI Model Delivery Maturity | Accepted | `project_type: ml` | MLflow targeting Google AI Engineering Level 1 — self-hostable, tracking URI swap for Level 0→1 migration |
| [ADR-003](ADR-003-observability.md) | Observability Stack Selection | Accepted | all | OpenTelemetry + OpenLineage — no proprietary cloud SDK in instrumentation paths; exporter target via env var |
| [ADR-004](ADR-004-iam-provider-selection.md) | IAM Provider Selection | Proposed | `project_type: application`, `project_type: agent` | Keycloak (internal employees / LDAP) or Zitadel (external customers / B2B) — context-dependent; FastAPI via `OAuth2AuthorizationCodeBearer` |
| [ADR-005](ADR-005-pipeline-orchestration.md) | Data Pipeline Orchestration | Proposed | `project_type: ml`, `project_type: agent` (data-intensive) | Dagster (Software-Defined Assets) when multiple production pipelines or backfill requirements emerge — not applicable to `application` |
| [ADR-006](ADR-006-agent-observability.md) | Agent Observability Tooling | Accepted | `project_type: agent` | Vertex AI Service Runtime (GCP + Gemini) or LangSmith (provider-agnostic) — context-dependent; extends ADR-003, does not replace OTel span emission |
| [ADR-007](ADR-007-project-type-selection.md) | Project Type Selection | Accepted | all | `{{ project_type }}` — determines relevant domain ADRs and the domain skill to invoke during `implement` REFACTOR |
| [ADR-008](ADR-008-secrets-management.md) | Secrets Management | Accepted | all | GitHub Secrets for dev/CI; Azure Key Vault (corporate) / GCP Secret Manager (personal) for production |
| [ADR-009](ADR-009-context-strategy.md) | Context Strategy | Accepted | all | Module Map + Issue-Type Index in CONTEXT.md, Context Protocol in AGENTS.md, blocking ship gate on Module Map updates |
| [ADR-010](ADR-010-runner-profile-variable.md) | Runner Profile Variable | Proposed | all | `KANBAN_RUNNER_PROFILE` variable switches orchestrator between GHA-hosted ubuntu-latest (default) and self-hosted runner |
| [ADR-011](ADR-011-orchestrator-state-carrier.md) | Orchestrator State Carrier | Accepted | all | Issue body is the single cross-runtime state carrier (fenced JSON + Markdown); 4-lane FSM with allowed-transitions table; pre-backlog readiness gate; rejects local/gitignored file state |
| [ADR-012](ADR-012-orchestrator-graphql-budget.md) | Orchestrator GraphQL Budget | Accepted | all | Cut the orchestrator's GraphQL footprint (default-branch + label ops off GraphQL, rate-limit pre-flight); defer a dedicated CI identity — a GitHub App can't mutate the user-owned Projects v2 board, and the cuts are expected to keep AFK within the 5000/hr budget |
| [ADR-013](ADR-013-workflow-parameter-passing.md) | Workflow Parameter Passing | Accepted | all | Pass run parameters via env transport hydrated into a single `Get-KanbanContext` object; enforce a library/entry-point split (no top-level `param()` in dot-sourced files) to kill the scope-leak that ran the pipeline against #0; PowerShell module migration is the phased follow-up |
| [ADR-014](ADR-014-pre-backlog-alignment-gate.md) | Pre-Backlog Alignment Gate | Accepted | all | `refine→architect→plan` (`Invoke-Alignment`) is the pre-backlog gate that grants `agent:backlog`; all artefacts written into the issue body (retire `.planning/`); alignment auto-runs on issue creation. *Amended 2026-09-23:* granting `agent:backlog` now starts processing; open questions are asked in the issue itself |
| [ADR-015](ADR-015-pipeline-taxonomy.md) | Pipeline Taxonomy | Accepted | all | Six stages (`refine`→`architect`→`plan`→`implement`→`review`→`ship`) named identically as skill, library script and label across four board lanes; module at `.github/orchestrator/`; AFK/HITL demoted from labels to execution modes; `human:approval` (merge authority) and `human:decision` (not a work item) split out of the overloaded HITL label. **Supersedes the `HITL + AFK` label pair from ADR-014** *Amended 2026-09-23:* `human:decision` is a state of the issue (questions asked in it), one retry budget covers every failure |

---

## Project-Type Quick Filter

Use this to determine which ADRs to load at session start. ADR-000 is always a template
reference — load it only when creating a new ADR.

### `project_type: application` (default)
Load: **ADR-003**, **ADR-004**, **ADR-007**, **ADR-008**, **ADR-009**, **ADR-015**

### `project_type: agent`
Load: **ADR-003**, **ADR-004**, **ADR-006**, **ADR-007**, **ADR-008**, **ADR-009**, **ADR-015**

### `project_type: ml`
Load: **ADR-001**, **ADR-002**, **ADR-003**, **ADR-005**, **ADR-007**, **ADR-008**, **ADR-009**, **ADR-015**
