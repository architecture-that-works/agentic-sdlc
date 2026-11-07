# Agentic Engineering — Reference

Mechanism detail and full code schemas for the `agentic-engineering` skill. See [SKILL.md](SKILL.md) for the overview, scope, and REFACTOR patterns. See [EXAMPLES.md](EXAMPLES.md) for a runnable end-to-end agent session.

---

## Core Patterns

### The Plan-Act-Observe Loop

A recursive state machine. The agent receives a goal, generates a thought, selects a tool, executes it, and observes the result — repeating until the `final_response` schema is satisfied or `max_iterations` is reached.

```
[Goal]
  └─→ [Plan: Generate Thought]
        └─→ [Act: Select + Execute Tool]
              └─→ [Observe: Parse Result]
                    ├─→ loop (tool_use) ──────────────────────────────┐
                    │                                                  │
                    └─→ end_turn → [Structured Output: Pydantic]      │
                                         ├─→ parse ok  → DONE         │
                                         └─→ parse fail → Correction ─┘
```

**Termination conditions (in priority order):**
1. `final_response` parses into the target Pydantic model → success
2. `max_iterations` reached → raise typed `AgentMaxIterationsError` → hard stop
3. Tool returns non-recoverable terminal error → hard stop

**Always cap iterations — never remove this guard:**

```python
MAX_ITERATIONS = 10

for iteration in range(MAX_ITERATIONS):
    response = llm.generate(messages, tools=tools)
    # ... process response
else:
    raise AgentMaxIterationsError(
        f"Agent did not complete within {MAX_ITERATIONS} iterations"
    )
```

### Structured Output Enforcement

Every final agent response must parse into a Pydantic model. On failure, inject the validation error back into the loop as a Correction Observation — not a crash.

```python
from pydantic import BaseModel, ValidationError


def parse_or_correct(
    raw: str, model: type[BaseModel], messages: list[dict]
) -> BaseModel | None:
    try:
        return model.model_validate_json(raw)
    except ValidationError as e:
        messages.append(
            {
                "role": "user",
                "content": f"Your response failed validation:\n{e}\n\nCorrect your output and retry.",
            }
        )
        return None  # loop continues
```

### Provider-Agnostic Action Executor

The `execute_tool` function is the critical isolation layer. Tool execution must be completely decoupled from the LLM provider.

```python
from collections.abc import Callable

TOOL_REGISTRY: dict[str, Callable] = {
    "search_documents": search_documents,
    "transfer_to_agent": transfer_to_agent,
}


def execute_tool(tool_name: str, tool_input: dict) -> str:
    fn = TOOL_REGISTRY.get(tool_name)
    if fn is None:
        return f"Error: Tool '{tool_name}' does not exist. Available tools: {list(TOOL_REGISTRY.keys())}"
    try:
        return str(fn(**tool_input))
    except Exception as e:
        return f"Error: {e}"
```

**Rule:** `execute_tool` never raises. It always returns a string. This prevents the agent from halting on recoverable errors.

---

## Quick Reference

### Tool Definition Template (Pydantic → JSON Schema)

```python
from pydantic import BaseModel, Field


class SearchDocuments(BaseModel):
    """
    Searches the document store for relevant content.
    Use when the user asks for information that requires document retrieval.
    Returns: list of matching document excerpts as a JSON string.
    """

    query: str = Field(..., description="The search query")
    max_results: int = Field(
        5, ge=1, le=20, description="Maximum number of results to return"
    )
```

**Convert to provider format:**

```python
# Claude format
claude_tool = {
    "name": "search_documents",
    "description": SearchDocuments.__doc__,
    "input_schema": SearchDocuments.model_json_schema(),
}
```

**Tool description rules:** Write as technical documentation — what it does, when to use it, what each parameter means, what it returns. Vague descriptions → wrong tool selection.

### Context and State Management

| Scope | Mechanism |
|---|---|
| Short-term | Thread-local message histories trimmed via sliding window |
| Long-term | Vector search (RAG-based retrieval for cross-session knowledge) |
| Prompt cache | Cache system prompt + tool defs for iterative loops (Claude: `cache_control`) |

**Sliding window:**

```python
def trim_messages(messages: list[dict], max_tokens: int = 8_000) -> list[dict]:
    system = [m for m in messages if m["role"] == "system"]
    history = [m for m in messages if m["role"] != "system"]
    while estimate_tokens(history) > max_tokens and len(history) > 2:
        history = history[2:]
    return system + history
```

**Prompt caching (Claude) — cache long-lived static content only:**

```python
system = [
    {"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}
]
```

Do NOT cache per-turn messages or tool results.

### Multi-Agent Coordination

**Orchestrator Pattern:** A Lead Agent dispatches tasks to specialised sub-agents.

```python
class TransferToAgent(BaseModel):
    """
    Transfer control to a specialised sub-agent.
    Use when the current task requires expertise outside your own scope.
    Returns: the sub-agent's final response as a string.
    """

    agent_name: str = Field(..., description="Target agent identifier")
    task: str = Field(..., description="Clear, self-contained task description")
    context: dict = Field(
        default_factory=dict, description="Relevant state to pass forward"
    )
```

**Rule:** The `context` dict must be self-contained. The sub-agent has no access to the orchestrator's message history.

### State Persistence (Checkpointer)

Save state after every loop iteration. Enables HITL approvals and crash recovery.

```python
@dataclass
class AgentCheckpoint:
    run_id: str
    iteration: int
    messages: list[dict]
    tool_calls: list[dict]
    status: str  # "running" | "awaiting_approval" | "complete" | "failed"
```

| Backend | When |
|---|---|
| **Firestore (GCP)** | Production; HITL approval workflows |
| **SQLite** | Local development and testing |
