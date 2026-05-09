---
name: application-development
description: Use when designing or building APIs, implementing REST endpoints, defining request/response contracts, setting up authentication, handling background tasks, or structuring service-to-service communication
---

# Application Development

## Overview

Covers the design and implementation of production APIs and services. Enforces clean request/response contracts, consistent auth patterns, and service boundaries that respect the domain model defined in `refine`. **FastAPI** is the standard framework — Pydantic-native, auto-generates OpenAPI, and async-first. TypeScript is used at system edges only — SDK clients, OpenAPI-generated types, and Zod schemas where type-safe contracts are required by consumers outside the Python codebase.

**Primary artifact:** Production API or service (Python primary; TypeScript at system edges)

## Scope

**Owns:** REST API design and implementation, input validation and serialisation at request boundaries (Pydantic), authentication and authorisation patterns, background task design, service-to-service communication patterns, contract testing for API consumers. TypeScript at system edges — SDK clients, OpenAPI-generated types, Zod schemas.

**Does not own:** Domain modelling and bounded contexts (→ `refine`), infrastructure and deployment (→ `harness`), agent-specific API patterns (→ `agentic-development`), data pipeline design (→ `data-engineering`).

**Interfaces with:** `refine` — application layer implements ports defined during alignment; no business logic in routers. `tdd` — contract tests drive the RED phase for API behaviour. `agentic-development` — agents may call application APIs; agent-specific patterns live there.

## When to Use

- **Trigger:** Designing or implementing a REST API endpoint
- **Trigger:** Defining request/response models and validation
- **Trigger:** Setting up authentication or authorisation
- **Trigger:** Implementing background tasks or async processing
- **Trigger:** Structuring communication between services
- **Trigger:** Building a prediction API wrapper around a deployed model

**Do NOT use for:**
- Domain modelling or bounded context design (→ `refine`)
- Infrastructure or deployment configuration (→ `harness`)
- Agent-specific API patterns (→ `agentic-development`)

## Core Pattern

### FastAPI — Pydantic-Native, OpenAPI by Default

```python
from fastapi import FastAPI, Depends
from pydantic import BaseModel

app = FastAPI(title="Prediction API", version="1.0.0")

class PredictionRequest(BaseModel):
    quarter: str
    branch_id: int
    features: dict[str, float]

class PredictionResponse(BaseModel):
    prediction: float
    model_version: str
    confidence: float | None = None

@app.post("/v1/predict", response_model=PredictionResponse)
async def predict(
    request: PredictionRequest,
    service: PredictionService = Depends(get_prediction_service),
) -> PredictionResponse:
    return await service.predict(request)
```

OpenAPI docs auto-generated at `/docs` (Swagger UI) and `/redoc`.

### Router → Service → Port (Hexagonal)

Business logic never lives in the router.

```
routers/        # FastAPI routes — input validation + response shaping only
services/       # Business logic — calls ports, orchestrates domain logic
ports/          # Abstract interfaces (abc.ABC or typing.Protocol)
adapters/       # Concrete implementations injected via Depends()
```

```python
# ✅ Thin router
@router.post("/predict", response_model=PredictionResponse)
async def predict(request: PredictionRequest, service: PredictionService = Depends(get_service)):
    return await service.predict(request)

# ❌ Business logic in router
@router.post("/predict")
async def predict(request: PredictionRequest):
    model = load_model("model.pkl")
    features = engineer_features(request)
    return model.predict(features)
```

## Quick Reference

### API Style Selection

| Style | When | Framework |
|---|---|---|
| **REST** | Transactional operations (CRUD, prediction endpoints, webhooks) | FastAPI |
| **GraphQL** | Query-heavy clients needing flexible access to nested or related data across multiple clients | Strawberry + FastAPI |

**GraphQL with Strawberry** — preferred when clients need flexible querying. Schema generated from Python types; integrates directly with FastAPI at `/graphql`.

### Framework Decisions

| Concern | Choice | Reason |
|---|---|---|
| REST framework | FastAPI | Pydantic-native, auto OpenAPI, async-first |
| GraphQL framework | Strawberry + FastAPI | Type-annotated, Pydantic-compatible |
| Validation | Pydantic `BaseModel` | Same library as data-engineering — no new dependency |
| Auth | OAuth2 + JWT or API key | Choose based on client type (user vs service) |
| Testing | Contract tests (consumer-driven) | Primary test type — drives RED phase in `tdd` |
| Deployment | Dev Container | Follows `harness` environment standards |

### API Versioning

Always version from day one:
```python
router = APIRouter(prefix="/v1", tags=["prediction"])
```

### Auth Patterns

| Use case | Pattern |
|---|---|
| User-facing API | OAuth2 with JWT (`fastapi.security.OAuth2PasswordBearer`) |
| Service-to-service | API key header (`X-API-Key`) validated via dependency |
| Internal only | Managed Identity (Azure) / Service Account (GCP) — no key in code |

For self-hosted IAM selection (Keycloak vs Zitadel) → See `docs/adr/ADR-004-iam-provider-selection.md`

Never put secrets in code or environment variables — fetch from secrets manager at runtime via managed identity (→ `harness`).

### Background Tasks

```python
from fastapi import BackgroundTasks

@app.post("/predict")
async def predict(request: PredictionRequest, background_tasks: BackgroundTasks):
    result = await service.predict(request)
    background_tasks.add_task(log_prediction, result)
    return result
```

## Implementation

### Project Structure

```
src/
  api/
    routers/          # Route handlers — thin, no business logic
    services/         # Business logic layer
    ports/            # Abstract interfaces
    adapters/         # Concrete implementations
    models/           # Pydantic request/response models
  main.py             # FastAPI app initialisation
```

### Dependency Injection

```python
from functools import lru_cache
from fastapi import Depends

@lru_cache
def get_prediction_service() -> PredictionService:
    return PredictionService(model_adapter=ModelAdapter())

@router.post("/predict")
async def predict(
    request: PredictionRequest,
    service: PredictionService = Depends(get_prediction_service),
) -> PredictionResponse:
    return await service.predict(request)
```

### Contract Testing

```python
def test_predict_response_contract(client: TestClient) -> None:
    response = client.post("/v1/predict", json={
        "quarter": "2024Q1",
        "branch_id": 1,
        "features": {"avg_sick_days": 3.5},
    })
    assert response.status_code == 200
    body = response.json()
    assert "prediction" in body
    assert "model_version" in body
    assert isinstance(body["prediction"], float)
```

### Running with uv

```bash
uv run uvicorn src.main:app --reload   # Dev server
uv run pytest tests/                   # Run contract and integration tests
```

## Common Mistakes

**Business logic in the router.**
Routers validate input and return responses. Domain logic belongs in services. A router with more than ~10 lines of non-routing code is a code smell.

**No versioning from day one.**
Always prefix with `/v1/`. Retrofitting versioning onto an unversioned API breaks existing clients.

**Using `dict` instead of Pydantic models.**
Untyped `dict` responses lose validation, auto-documentation, and type safety. Every request and response must be a typed Pydantic model.

**Secrets in environment variables.**
Environment variables are visible in process lists and container inspection. Fetch secrets from a secrets manager at runtime via managed identity (→ `harness`).

**Missing contract tests for service-to-service APIs.**
Internal APIs break silently without contract tests. A producer change that violates the consumer contract won't be caught by unit tests.

**No response model on endpoints.**
Always set `response_model=` on every endpoint. Without it, FastAPI cannot generate correct OpenAPI docs and will serialise internal fields that should be hidden.
