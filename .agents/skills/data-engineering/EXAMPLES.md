# Data Engineering — Examples

Runnable end-to-end walkthrough for the `data-engineering` skill. See [SKILL.md](SKILL.md) for the overview, scope, and REFACTOR patterns. See [REFERENCE.md](REFERENCE.md) for full Medallion tier definitions, code schemas, and decision tables.

> **Note:** Paths in this file (e.g. `src/data_engineering/`, `data/0_Raw/`) are illustrative for the described pipeline. They are excluded from the doc-path check by design.

---

## End-to-End: Medallion Pipeline (Raw → Gold)

### Project Structure

```
src/
  data_engineering/     # Medallion pipeline (Raw, Bronze, Silver, Gold)
  utils/                # Shared SQLAlchemy session handlers, DB utilities
  config.py             # Pipeline configuration (metrics enabled, paths, backend)
data/
  0_Raw/                # Source files — excluded from Git
  *.db                  # SQLite databases — excluded from Git
  gold/                 # Parquet files (DuckLake backend) — excluded from Git
```

### DuckLake Setup and Usage

```python
import duckdb
import polars as pl

conn = duckdb.connect()
conn.execute("INSTALL ducklake; LOAD ducklake;")
conn.execute("""
    ATTACH 'ducklake:postgresql://user:pass@host/catalog_db'
    AS lake (DATA_PATH 's3://bucket/data/')
""")

df_gold.write_parquet("s3://bucket/data/gold/sick_leave/2024Q1.parquet")
result = conn.execute("SELECT * FROM lake.gold.sick_leave").pl()
```

### Upsert Pattern (Bronze / SQLite)

```python
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

stmt = sqlite_insert(BronzeTable).values(records)
stmt = stmt.on_conflict_do_nothing(index_elements=["source_file", "record_id"])
session.execute(stmt)
session.commit()
```

### Gold Layer Shape Rules

1. **Target tables:** rows indexed on composite key `(Quarter, Branch)` — one row per prediction unit
2. **Feature tables:** rows indexed on `(Quarter,)` — exactly one row per time period
3. **Structural join:** `LEFT JOIN feature ON target.quarter = feature.quarter`
4. **Zero-Null gate:** run interpolation before exposing Gold to downstream — no nulls may pass

### Data Lineage (OpenLineage)

Emit OpenLineage events from each Medallion tier for machine-readable lineage:

```python
from openlineage.client import OpenLineageClient, RunEvent, RunState

client = OpenLineageClient.from_environment()
client.emit(
    RunEvent(
        eventType=RunState.COMPLETE,
        job=Job(namespace="pipeline", name="silver_transformation"),
        inputs=[Dataset(namespace="sqlite", name="bronze_sick_leave")],
        outputs=[Dataset(namespace="sqlite", name="silver_sick_leave")],
    )
)
```

Compatible with OpenMetadata, Apache Atlas, and Marquez.

### Integration Testing for ETL Pipelines

Integration tests — not unit tests — are the primary test type. Test the output of each stage, not the transformation logic.

```python
def test_silver_row_count(session: Session) -> None:
    count = session.execute(select(func.count()).select_from(SilverSickLeave)).scalar()
    assert count > 0


def test_gold_no_nulls(session: Session) -> None:
    nulls = session.execute(
        select(func.count())
        .select_from(GoldSickLeave)
        .where(GoldSickLeave.avg_value.is_(None))
    ).scalar()
    assert nulls == 0, "Gold Zero-Null policy violated"
```

Standard checks per stage: row count, unique IDs, date range, Zero-Null (Gold only).
