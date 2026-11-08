---
name: TEMPLATE_ADR_STRUCTURE
description: Index of architecture decisions about this template's own orchestrator and pipeline mechanism — load when touching .github/orchestrator, .agents/skills, or copier.yml
---

# Template ADR Index

Decisions about **building and evolving the template's own mechanism** — the orchestrator,
the pipeline, the Copier variables that drive scaffolding. Not application architecture;
see [`adr-staging/`](../../adr-staging/) for that instead.

This index ships with every generated project, because the mechanism it documents ships
too. `AGENTS.md`'s Context Protocol loads this file (not `docs/adr/ADR_STRUCTURE.md`) when
the task touches `.github/orchestrator/`, `.agents/skills/`, or `copier.yml`.

| ADR | Title | Status | Decision |
|---|---|---|---|
| [ADR-007](ADR-007-project-type-selection.md) | Project Type Selection | Accepted | `{{ project_type }}` — determines relevant domain ADRs and the domain skill to invoke during `implement` REFACTOR |
| [ADR-009](ADR-009-context-strategy.md) | Context Strategy | Accepted | Module Map + Issue-Type Index in `CONTEXT.md`, Context Protocol in `AGENTS.md`, blocking ship gate on Module Map updates |
| [ADR-010](ADR-010-runner-profile-variable.md) | Runner Profile Variable | Proposed | `KANBAN_RUNNER_PROFILE` variable switches orchestrator between GHA-hosted `ubuntu-latest` (default) and self-hosted runner |
| [ADR-011](ADR-011-orchestrator-state-carrier.md) | Orchestrator State Carrier | Accepted | Issue body is the single cross-runtime state carrier (fenced JSON + Markdown); 4-lane FSM with allowed-transitions table; pre-backlog readiness gate |
| [ADR-012](ADR-012-orchestrator-graphql-budget.md) | Orchestrator GraphQL Budget | Accepted | Cut the orchestrator's GraphQL footprint (default-branch + label ops off GraphQL, rate-limit pre-flight) |
| [ADR-013](ADR-013-workflow-parameter-passing.md) | Workflow Parameter Passing | Accepted | Pass run parameters via env transport hydrated into a single `Get-OrchestratorContext` object; library/entry-point split |
| [ADR-014](ADR-014-pre-backlog-alignment-gate.md) | Pre-Backlog Alignment Gate | Accepted | `refine→architect→plan` is the pre-backlog gate that grants `agent:backlog`; `Invoke-Orchestration` (`-From refine`); artefacts written into the issue body |
| [ADR-015](ADR-015-pipeline-taxonomy.md) | Pipeline Taxonomy | Accepted | Six stages (`refine`→`architect`→`plan`→`implement`→`review`→`ship`) named identically as skill, library script and label across four board lanes |

**Maintenance:** add a row here at the same time as merging a new template-mechanism ADR —
never merge one without a corresponding index update.
