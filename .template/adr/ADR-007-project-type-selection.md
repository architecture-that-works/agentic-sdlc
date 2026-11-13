---
name: ADR-007-project-type-selection
description: Documents the project_type selected at generation time — determines which domain ADRs apply and which domain skill to invoke during the tdd REFACTOR phase
---

# ADR-007: Project Type Selection

## Status
Accepted

## Context and Problem Statement

At project generation time, a `project_type` was selected to signal the primary domain of this project. This ADR records that choice and its implications for which domain-specific ADRs are relevant and which domain skill to invoke during the `tdd` REFACTOR phase.

## Considered Options

* application — general-purpose REST APIs, workers, and CLI tools
* agent — Plan-Act-Observe loop projects with OTel span emission per iteration
* ml — Medallion pipeline and MLOps projects with experiment tracking

## Decision Outcome

Chosen: **{{ project_type }}**

This selection determines:
- Which domain-specific ADRs in `docs/adr/` are relevant (see mapping below)
- The domain skill to invoke during the `tdd` REFACTOR phase (see `AGENTS.md`)
- The expected directory structure as the project grows (see `CONTEXT.md`)

The base scaffold (config, logging, test harness, CI, Orchestrator Workflow) is identical for all project types. Specialised directory stubs are planned for a future iteration.

### Domain tool choices

Domain tool choices beyond the skill's stack are the project's own ADRs.

### Confirmation

* Confirm `CONTEXT.md` header shows `Project Type: {{ project_type }}`
* Confirm `AGENTS.md` identity table shows `Project Type: {{ project_type }}`
* Confirm the domain skill matching the `project_type` is invoked during the `tdd` REFACTOR phase

## Pros and Cons of the Options

### application

| | |
|---|---|
| **Good** | General-purpose — REST APIs, background workers, CLI tools |
| **Good** | Broadest applicability; minimal domain-specific overhead |
| **Bad** | No built-in agent loop or ML pipeline scaffolding |

### agent

| | |
|---|---|
| **Good** | Plan-Act-Observe loop patterns baked in from the start |
| **Good** | OTel span emission per loop iteration for observability |
| **Bad** | Heavier observability setup compared to a simple application |

### ml

| | |
|---|---|
| **Good** | Medallion pipeline structure and MLOps tooling aligned from day one |
| **Good** | Experiment tracking and model registry path built in |
| **Bad** | Highest infrastructure overhead of the three types |
