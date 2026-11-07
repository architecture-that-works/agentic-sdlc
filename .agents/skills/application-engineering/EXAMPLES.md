# Application Engineering — Examples

Runnable end-to-end walkthrough for the `application-engineering` skill. See [SKILL.md](SKILL.md) for the overview, scope, and REFACTOR patterns. See [REFERENCE.md](REFERENCE.md) for full code schemas and decision tables.

> **Note:** Paths in this file (e.g. `src/api/routers/`) are illustrative for the described feature. They are excluded from the doc-path check by design.

---

## End-to-End: AI-Backed Analysis API

### Project Structure

```
src/
  api/
    routers/          # FastAPI route handlers — thin, no business logic
    services/         # Business logic layer — orchestrates ports
    ports/            # Abstract interfaces: AICompletionPort, etc.
    adapters/         # Concrete implementations: ClaudeAdapter, etc.
    models/           # Pydantic request/response models
  main.py             # FastAPI app initialisation and lifespan
```

### Contract Testing

```python
# tests/api/test_analyse_contract.py
from unittest.mock import AsyncMock
from fastapi.testclient import TestClient
from ports.ai_port import AICompletionPort


class FakeAIPort(AICompletionPort):
    async def complete(self, prompt: str, system: str = "") -> str:
        return "Mocked response"

    async def complete_structured(self, prompt: str, schema):
        return schema(summary="stub", sentiment="neutral", key_points=[])


def test_analyse_response_contract(client: TestClient) -> None:
    response = client.post("/v1/analyse", json={"text": "Hello world"})
    assert response.status_code == 200
    body = response.json()
    assert "summary" in body
    assert "sentiment" in body
    assert "key_points" in body
```

Test the contract, not the AI output. The `FakeAIPort` is the controlled collaborator — Claude itself is never called in unit tests.

### Running with UV

```bash
uv run uvicorn src.main:app --reload   # Dev server
uv run pytest tests/                   # Run contract and integration tests
```
