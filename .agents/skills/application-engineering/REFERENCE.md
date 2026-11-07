# Application Engineering — Reference

Mechanism detail and full code schemas for the `application-engineering` skill. See [SKILL.md](SKILL.md) for the overview, scope, and REFACTOR patterns. See [EXAMPLES.md](EXAMPLES.md) for the project structure tree, contract testing setup, and runnable commands.

---

## Core Patterns

### FastAPI — Pydantic-Native, OpenAPI by Default

```python
from fastapi import FastAPI, Depends
from pydantic import BaseModel

app = FastAPI(title="AI Application API", version="1.0.0")


class AnalyseRequest(BaseModel):
    text: str
    language: str = "en"


class AnalyseResponse(BaseModel):
    summary: str
    sentiment: str
    key_points: list[str]


@app.post("/v1/analyse", response_model=AnalyseResponse)
async def analyse(
    request: AnalyseRequest,
    service: AnalysisService = Depends(get_analysis_service),
) -> AnalyseResponse:
    return await service.analyse(request)
```

OpenAPI docs auto-generated at `/docs` (Swagger UI) and `/redoc`. Always set `response_model=` — without it FastAPI cannot generate correct OpenAPI docs and may leak internal fields.

### Router → Service → Port (Hexagonal)

Business logic never lives in the router. Claude is accessed only through an abstract port.

```
routers/        # FastAPI routes — input validation + response shaping only
services/       # Business logic — calls ports, orchestrates domain logic
ports/          # Abstract interfaces (AICompletionPort, etc.)
adapters/       # Concrete implementations injected via Depends()
```

```python
# ✅ Thin router, Claude behind a port
@router.post("/analyse", response_model=AnalyseResponse)
async def analyse(
    request: AnalyseRequest, service: AnalysisService = Depends(get_service)
):
    return await service.analyse(request)


# ❌ Claude call directly in router — no abstraction, untestable
@router.post("/analyse")
async def analyse(request: AnalyseRequest):
    client = AsyncAnthropic()
    response = await client.messages.create(...)
    return parse(response)
```

### Claude API Integration — Single-Call Pattern

```python
# ports/ai_port.py
from abc import ABC, abstractmethod
from pydantic import BaseModel


class AICompletionPort(ABC):
    @abstractmethod
    async def complete(self, prompt: str, system: str = "") -> str: ...

    @abstractmethod
    async def complete_structured(
        self, prompt: str, schema: type[BaseModel]
    ) -> BaseModel: ...


# adapters/claude_adapter.py
from anthropic import AsyncAnthropic
from ports.ai_port import AICompletionPort


class ClaudeAdapter(AICompletionPort):
    def __init__(self, model: str = "claude-opus-4-5"):
        self._client = AsyncAnthropic()
        self._model = model

    async def complete(self, prompt: str, system: str = "") -> str:
        response = await self._client.messages.create(
            model=self._model,
            max_tokens=1024,
            system=system,
            messages=[{"role": "user", "content": prompt}],
        )
        return response.content[0].text

    async def complete_structured(
        self, prompt: str, schema: type[BaseModel]
    ) -> BaseModel:
        response = await self._client.messages.create(
            model=self._model,
            max_tokens=1024,
            tools=[
                {
                    "name": "return_result",
                    "description": f"Return the structured result as {schema.__name__}",
                    "input_schema": schema.model_json_schema(),
                }
            ],
            tool_choice={"type": "tool", "name": "return_result"},
            messages=[{"role": "user", "content": prompt}],
        )
        tool_block = next(b for b in response.content if b.type == "tool_use")
        return schema(**tool_block.input)
```

**Register via dependency injection:**

```python
from functools import lru_cache
from fastapi import Depends
from ports.ai_port import AICompletionPort
from adapters.claude_adapter import ClaudeAdapter


@lru_cache
def get_ai_port() -> AICompletionPort:
    return ClaudeAdapter()


def get_analysis_service(
    ai: AICompletionPort = Depends(get_ai_port),
) -> AnalysisService:
    return AnalysisService(ai_port=ai)
```

This makes Claude swappable without touching business logic. Tests inject a `FakeAIPort`.

### OTel Instrumentation at the Request Boundary

Instrument at the service layer, not the router. Emit one span per Claude call. Follow ADR-003 — no proprietary cloud SDK in instrumentation paths.

```python
from opentelemetry import trace
from opentelemetry.semconv.ai import (
    SpanAttributes,
)  # opentelemetry-semantic-conventions-ai

tracer = trace.get_tracer(__name__)


class AnalysisService:
    def __init__(self, ai_port: AICompletionPort) -> None:
        self._ai = ai_port

    async def analyse(self, request: AnalyseRequest) -> AnalyseResponse:
        with tracer.start_as_current_span("ai.analyse") as span:
            span.set_attribute(SpanAttributes.LLM_REQUEST_MODEL, "claude-opus-4-5")
            span.set_attribute(SpanAttributes.LLM_REQUEST_TYPE, "completion")
            result = await self._ai.complete_structured(
                prompt=f"Analyse the following text:\n\n{request.text}",
                schema=AnalyseResponse,
            )
            span.set_attribute(SpanAttributes.LLM_RESPONSE_FINISH_REASON, "tool_use")
            return result
```

### Streaming AI Responses via SSE

Stream Claude output directly to the client. Do not buffer the full response.

```python
import json
from fastapi.responses import StreamingResponse
from anthropic import AsyncAnthropic

client = AsyncAnthropic()


@router.post("/v1/generate")
async def generate(request: GenerateRequest) -> StreamingResponse:
    async def token_stream():
        async with client.messages.stream(
            model="claude-opus-4-5",
            max_tokens=2048,
            messages=[{"role": "user", "content": request.prompt}],
        ) as stream:
            async for text in stream.text_stream:
                yield f"data: {json.dumps({'token': text})}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(token_stream(), media_type="text/event-stream")
```

### AI Error Handling — Rate Limits and Timeouts

```python
import asyncio
from anthropic import RateLimitError, APITimeoutError, APIStatusError

MAX_RETRIES = 3


async def complete_with_retry(ai_port: AICompletionPort, prompt: str) -> str:
    for attempt in range(MAX_RETRIES):
        try:
            return await ai_port.complete(prompt)
        except RateLimitError:
            if attempt == MAX_RETRIES - 1:
                raise
            await asyncio.sleep(2**attempt)  # exponential backoff: 1s, 2s, 4s
        except APITimeoutError:
            if attempt == MAX_RETRIES - 1:
                raise
        except APIStatusError as e:
            if e.status_code >= 500 and attempt < MAX_RETRIES - 1:
                await asyncio.sleep(1)
            else:
                raise
    raise RuntimeError("Unreachable")
```

Never catch `anthropic.AuthenticationError` in retry logic — it is not transient.

---

## Quick Reference

### API Style Selection

| Style | When | Framework |
|---|---|---|
| **REST** | Transactional operations (CRUD, AI completion endpoints, webhooks) | FastAPI |
| **SSE** | Streaming AI responses to browser or CLI clients | FastAPI `StreamingResponse` |
| **GraphQL** | Query-heavy clients needing flexible access to nested data | Strawberry + FastAPI |

### Auth Patterns

| Use case | Pattern |
|---|---|
| User-facing API | OAuth2 with JWT (`fastapi.security.OAuth2PasswordBearer`) |
| Service-to-service | API key header (`X-API-Key`) validated via dependency |
| Managed identity | Azure Managed Identity / GCP Service Account — no key in code |

For self-hosted IAM selection, consult your architecture-decision store, or write one from `docs/adr/ADR-000-template-architecture-decision.md` if none exists yet.
Never put secrets in environment variables — fetch from secrets manager at runtime via managed identity (`SECURITY.md`, ADR-008).

### API Versioning

Always version from day one:
```python
router = APIRouter(prefix="/v1", tags=["analysis"])
```
