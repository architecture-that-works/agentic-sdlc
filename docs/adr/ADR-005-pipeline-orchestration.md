# ADR-005: Pipeline Orchestration — Dagster Adoption

## Status
Proposed

## Context and Problem Statement
The default Medallion pipeline runs via a simple script entrypoint (`uv run main.py`). As the number of pipelines grows, the need for declarative asset management, built-in lineage, partitioning, and scheduling becomes apparent. Dagster is the primary candidate.

## Considered Options
- Dagster (Software-Defined Assets)
- Airflow
- dbt (SQL-centric teams)

## Decision Outcome
Adopt Dagster when: multiple Medallion pipelines are in production, partitioned backfills are needed, or observability into asset staleness is a primary concern.

## Dagster Software-Defined Assets

Dagster shifts orchestration from *task execution* to *asset production*. Each Medallion tier becomes a declared asset; Dagster handles execution, scheduling, and lineage.

```python
from dagster import asset, AssetIn
import polars as pl

@asset
def bronze_sick_leave(context) -> pl.DataFrame:
    return load_raw_files(RAW_PATH)

@asset(ins={"bronze": AssetIn("bronze_sick_leave")})
def silver_sick_leave(bronze: pl.DataFrame) -> pl.DataFrame:
    return transform_to_silver(bronze)

@asset(ins={"silver": AssetIn("silver_sick_leave")})
def gold_sick_leave(silver: pl.DataFrame) -> pl.DataFrame:
    return build_gold(silver)
```

Key properties:
- **Environment agnosticism** — same definitions in dev and production
- **Built-in lineage** — asset dependency graph IS the lineage graph; no separate OpenLineage emission needed when Dagster is the orchestrator
- **Partitioning and backfills** — time-partitioned assets and historical backfills are first-class
- **dbt integration** — dbt models can be declared as Dagster assets

## Pros and Cons

### Dagster
- Good, because: declarative assets, built-in partitioning/backfills, lineage out of the box
- Good, because: Python-native, same language as the stack
- Bad, because: significant complexity overhead for simple pipelines
- Bad, because: adoption requires restructuring pipeline code into asset definitions

### Airflow
- Good, because: broad ecosystem, multi-system orchestration
- Bad, because: task-centric (not asset-centric), no built-in lineage, heavier infrastructure

### dbt
- Good, because: SQL-centric teams find it natural
- Bad, because: SQL-only limits expressiveness for complex Python transformations
