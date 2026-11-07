# Data Engineering — Reference

Mechanism detail and full code schemas for the `data-engineering` skill. See [SKILL.md](SKILL.md) for the overview, scope, and REFACTOR patterns. See [EXAMPLES.md](EXAMPLES.md) for a runnable end-to-end pipeline walkthrough.

---

## Core Patterns

### Medallion Architecture (ELT)

Load first, transform in-place. Never write intermediate files to disk — all state lives in the database or object storage.

**Raw** — Source Zone
- Local files exactly as received — source of truth for reprocessing
- Excluded from version control (`.gitignore`)
- No transformation — read-only input layer

**Bronze** — Landing Zone
- Technology: **SQLAlchemy Core** (bulk inserts, speed-optimised)
- Structure: Star Schema — Fact tables + Dimension tables
- Upsert logic: process only new files in Raw; never reprocess the entire dataset

**Silver** — Clean Zone
- Technology: **SQLAlchemy ORM** (complex joins) or **Polars** (large-scale transformation)
- Flatten nested structures, cast types, standardise strings
- JOIN Fact + Dimension tables to replace codes with human-readable values

**Gold** — ML Zone
- Technology: **SQLAlchemy ORM** (SQLite backend) or **Polars → Parquet** (DuckLake backend)
- **Target datasets (Fact):** preserve composite key (e.g., `Quarter + Branch`) — **NEVER pivot**
- **Feature datasets (Dimension):** pivot/flatten to exactly 1 row per `Quarter` for clean `LEFT JOIN`
- Zero-Null policy: enforce via interpolation before the ML handoff gate

### Polars as Default Processing Library

```python
import polars as pl

# ✅ Polars pipeline transformation
df = pl.read_database("SELECT * FROM silver_sick_leave", connection)
df_gold = (
    df.filter(pl.col("value").is_not_null())
    .with_columns(pl.col("period").str.to_date())
    .group_by("quarter", "branch")
    .agg(pl.col("value").mean().alias("avg_value"))
)
df_gold.write_parquet("data/gold/sick_leave/2024Q1.parquet")

# ❌ Pandas in pipelines — single-threaded, eager, memory-heavy
import pandas as pd
```

Exception: Pandas is acceptable as a boundary conversion when a downstream library strictly requires `pd.DataFrame`. Convert at the boundary: `df.to_pandas()`.

### The Pydantic Sandwich

Validate at the boundary — before data touches a SQLAlchemy session or Polars write. Use **SQLModel** (unifies SQLAlchemy + Pydantic in one class) when validation and storage shapes are identical.

```python
from sqlmodel import SQLModel, Field, Session


class SickLeaveRecord(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    period: str = Field(pattern=r"^\d{4}Q[1-4]$")
    value: float


record = SickLeaveRecord.model_validate(raw_data)  # Raises ValidationError if invalid
with Session(engine) as session:
    session.add(record)
    session.commit()
```

Use separate `Pydantic(BaseModel)` + `SQLAlchemy(Base)` only when the validation and storage shapes genuinely diverge between tiers.

---

## Quick Reference

### Technology Tiers

#### Must-Have (Every Project)

| Task | Tool |
|---|---|
| Dependency management | `uv` |
| Pipeline transformation | `polars` |
| ORM / SQL abstraction | SQLAlchemy Core (Bronze) + ORM (Silver/Gold) |
| Boundary validation | Pydantic (Sandwich / SQLModel) |
| Data lake query engine | `duckdb` |
| Storage backend | SQLite (local/prototype) |
| Architecture | Medallion (Raw → Bronze → Silver → Gold) |

#### Optional (Mature / Production Setup)

| Tool | Adopt when |
|---|---|
| **DuckLake** | Production data lake with multi-consumer access (PostgreSQL catalog + Parquet) |
| **PySpark** | Data exceeds single-machine capacity; Databricks environment |
| **Dagster** | Mature orchestration with Software-Defined Assets, built-in lineage, scheduling |
| **OpenLineage + Marquez** | Data lineage tracking at scale across pipeline stages |
| **dbt** | Team is strongly SQL-heavy and Python transformations are not preferred |

### Storage Backend Selection

| Backend | When | Catalog | Storage | Query |
|---|---|---|---|---|
| SQLite + SQLAlchemy | Local dev, prototype, portable | Embedded `.db` | `.db` file | SQLAlchemy / DuckDB |
| DuckLake | Production scale, cloud, multi-consumer | PostgreSQL | Parquet on object storage | DuckDB |

### SQLAlchemy API Selection

| Tier | API | Reason |
|---|---|---|
| Bronze | Core | Bulk inserts, speed-critical |
| Silver | ORM or Polars | ORM for joins; Polars for large-scale transformation |
| Gold | ORM or Polars → Parquet | ORM for SQLite backend; Polars for DuckLake backend |

### Medallion Tier Responsibilities

| Tier | Transformation | Quality Gate |
|---|---|---|
| Raw | None | None — source of truth |
| Bronze | None — load only (Star Schema) | Upsert deduplication |
| Silver | Flatten, cast types, JOIN, standardise | Type contract compliance |
| Gold | Feature engineering, pivot rules, interpolation | Zero-Null policy, ML shape contract |

### Pipeline Entrypoint Pattern

```bash
uv run main.py                 # ML pipeline only — runs on existing Gold tables
uv run main.py --refresh-data  # Full pipeline — Raw → Gold → ML
```
