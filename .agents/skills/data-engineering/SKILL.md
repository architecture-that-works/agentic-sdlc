---
name: data-engineering
description: Use when designing or implementing data pipelines, structuring Medallion architecture tiers, defining data quality gates, schema validation with Pydantic, writing SQLAlchemy or Polars transformations, configuring DuckLake storage, or building feature pipelines for ML consumption
---

# Data Engineering

## Overview

ELT pipelines following a Mini-Medallion architecture (Raw → Bronze → Silver → Gold). Two storage backends: **SQLite + SQLAlchemy** for local/prototype; **DuckLake (PostgreSQL catalog + Parquet + DuckDB)** for production scale. **Polars** is the default transformation library. Primary output: Gold tables or Parquet datasets that are ML-ready, null-free, and correctly shaped.

**Primary artifact:** Validated, query-ready datasets produced by a layered Medallion pipeline.

See [REFERENCE.md](REFERENCE.md) for full Medallion tier definitions, Polars and Pydantic Sandwich code schemas, storage backend decision tables, SQLAlchemy API selection, and lineage emission patterns. See [EXAMPLES.md](EXAMPLES.md) for a runnable end-to-end pipeline walkthrough (Raw → Gold) with DuckLake setup, upsert, Gold layer rules, and integration-test commands.

## Scope

**Owns:** ELT pipeline design and implementation, Medallion tier definitions and boundaries, SQLAlchemy Core (Bronze bulk inserts) and ORM (Silver/Gold transformations), Polars for pipeline data transformations, DuckLake storage backend configuration, storage backend selection (SQLite vs DuckLake), Pydantic boundary validation (the Sandwich), upsert logic, data quality gates, schema contracts, feature pipeline implementation (computing features at scale — not designing them), lineage event emission from pipeline steps (OpenLineage).

**Does not own:** Feature design — which features to compute and why (→ `refine`), model training pipelines (→ `agentic-engineering`), general telemetry instrumentation (consult your architecture-decision store, or write one from `docs/adr/ADR-000-template-architecture-decision.md` if none exists yet).

**Interfaces with:** `refine` — feature requirements and domain boundaries are specified there; data-engineering implements the Gold pipeline against those specs. `implement` — integration tests for each pipeline stage drive the RED phase. `application-engineering` — Gold tables / Parquet datasets are the contract for downstream APIs.

## When to Use

- **Trigger:** Designing or building any layer of the Medallion pipeline
- **Trigger:** Writing SQLAlchemy models, Core inserts, or ORM transformations
- **Trigger:** Writing Polars transformation logic for pipeline stages
- **Trigger:** Configuring or querying a DuckLake storage backend
- **Trigger:** Deciding storage backend — SQLite vs DuckLake
- **Trigger:** Adding or modifying data quality gates or schema validation
- **Trigger:** Implementing a feature pipeline from a `refine` specification

**Do NOT use for:**
- Deciding which features to engineer (→ `refine`)
- Model training pipelines (→ `agentic-engineering`)

## Required Inputs

- Feature specification from `refine` (which features to compute and why)
- Source data schema (raw input format)
- Storage backend decision (SQLite vs DuckLake)
- Acceptance criteria from Lean PRD testing decisions (from `plan`)

## Primary Outputs

- Medallion pipeline (Raw → Bronze → Silver → Gold)
- SQLAlchemy models and Polars transformation functions
- Data quality gate checks (row count, type contract, Zero-Null policy)
- Integration tests covering each pipeline stage output

## tdd REFACTOR Phase Patterns

Shared coding principles apply first — see `.agents/skills/implement/REFERENCE.md` § Coding Principles. Then extend with these data-engineering patterns:

- **Medallion boundary enforcement:** Each tier function must read only from the tier below and write only to its own tier. If Bronze logic appears in Silver, extract it back to Bronze.
- **Polars over Pandas:** If Pandas appears in pipeline code after GREEN, replace with Polars equivalents. Exception: boundary conversion for downstream libraries that strictly require `pd.DataFrame`.
- **Pydantic Sandwich tightening:** All data entering a SQLAlchemy session or Polars write must pass through a Pydantic model. If raw dict access appears after GREEN, extract a validator.
- **Zero-Null gate completeness:** The Gold layer must enforce null-free output. If `test_gold_no_nulls` passes but the interpolation logic is fragile, refactor the interpolation to be explicit and idempotent.
- **Upsert idempotency:** Bronze upsert logic must be safe to run multiple times on the same source file. If the test suite doesn't cover duplicate ingestion, add a test and fix the logic if it fails.
- **Lineage event coverage:** Every pipeline stage boundary should emit an OpenLineage event. If missing after GREEN, add it in REFACTOR.

No `scripts/` directory — this skill is a constraint document with no deterministic operation to script.

## Common Mistakes

**Using Pandas for pipeline transformations.** Pandas is not used in data-engineering pipelines. Polars is the default. The only exception is a boundary conversion when a downstream library strictly requires `pd.DataFrame`.

**Using SQLAlchemy ORM at Bronze for bulk inserts.** ORM overhead is unnecessary at the loading stage. Use SQLAlchemy Core for Bronze.

**Validating data inside SQLAlchemy models.** `@validates` fires at flush time. Use the Pydantic Sandwich: validate at the boundary, store with SQLAlchemy.

**Pivoting target (Fact) tables in Gold.** Target datasets must preserve the composite key. Pivoting creates Cartesian explosions.

**Writing intermediate files to disk.** Zero-Artifact policy is absolute. State lives in the database or registered Parquet files. No temporary CSVs or JSONs between tiers.

**Running `python` directly instead of `uv run`.** Always use `uv run` — correct environment and interpreter are guaranteed.

**Reprocessing all Raw files on every pipeline run.** Upsert logic exists to prevent this. Processing only new files is a core efficiency constraint.
