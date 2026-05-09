---
name: agentic-development
description: Use when building agents with the Claude API or Gemini API, implementing tool use, designing Plan-Act-Observe loops, coordinating multi-agent systems, managing context windows, or testing agent behaviour
---

# Agentic Development

## Overview

Covers the design and implementation of AI agents. All patterns are **provider-agnostic** — tool definitions, loop logic, and output validation are decoupled from the LLM provider to prevent vendor lock-in. Both Claude (Anthropic SDK) and Gemini (Google AI SDK) are supported. Core loop: **Plan → Act → Observe**.

**Primary artifact:** Functioning agent — tool use, structured outputs, multi-agent coordination — provider-agnostic, supporting Anthropic SDK and Google AI SDK.

## Scope

**Owns:** Plan-Act-Observe loop design and state management, tool definition standard (Pydantic → JSON Schema), structured output enforcement with correction on parse failure, provider-agnostic action executor, multi-agent coordination (Orchestrator + Handoff patterns), context window management within agent loops (sliding window, prompt caching), agent state persistence (Checkpointer pattern), agent testing patterns, agent-driven ML pipeline orchestration (training, evaluation, model promotion).

**Does not own:** General API development patterns (→ `application-development`), agent deployment infrastructure (→ `harness`), data pipeline patterns used by agents (→ `data-engineering`).

**Interfaces with:** `application-development` — agents often expose or consume APIs; general API patterns live there. `harness` — agent runtime deployment, environment provisioning, and Planner/Generator/Evaluator split. `tdd` — agent behaviour is verified via the RED-GREEN-REFACTOR loop; domain-specific testing patterns extend REFACTOR here.

## When to Use

- **Trigger:** Building an agent with Gemini, Claude, or any LLM API
- **Trigger:** Implementing tool use or structured outputs
- **Trigger:** Designing a Plan-Act-Observe loop or multi-turn conversation flow
- **Trigger:** Coordinating multiple agents (Orchestrator + Handoff)
- **Trigger:** Managing context window limits or prompt structure
- **Trigger:** Writing tests for agent behaviour
- **Trigger:** Implementing agent-driven ML training, evaluation, or model promotion

**Do NOT use for:**
- General API endpoint development (→ `application-development`)
- Agent deployment and infrastructure (→ `harness`)
- Data pipelines that agents consume (→ `data-engineering`)

## Core Pattern

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
    raise AgentMaxIterationsError(f"Agent did not complete within {MAX_ITERATIONS} iterations")
```

### Structured Output Enforcement

Every final agent response must parse into a Pydantic model. On failure, inject the validation error back into the loop as a Correction Observation — not a crash.

```python
from pydantic import BaseModel, ValidationError

def parse_or_correct(raw: str, model: type[BaseModel], messages: list[dict]) -> BaseModel | None:
    try:
        return model.model_validate_json(raw)
    except ValidationError as e:
        messages.append({
            "role": "user",
            "content": f"Your response failed validation:\n{e}\n\nCorrect your output and retry.",
        })
        return None  # loop continues
```

### Provider-Agnostic Action Executor

The `execute_tool` function is the critical isolation layer. Tool execution must be completely decoupled from the LLM provider.

```python
from collections.abc import Callable

TOOL_REGISTRY: dict[str, Callable] = {
    "get_metrics": get_metrics,
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

## Quick Reference

### Tool Definition Template (Pydantic → JSON Schema)

```python
from pydantic import BaseModel, Field

class GetMetrics(BaseModel):
    """
    Fetches metrics for a specific entity and period.
    Use this tool when the user requests entity-level metric data.
    Returns: float representing the metric value.
    """
    entity_id: str = Field(..., description="The entity identifier")
    quarter: str = Field(..., pattern=r"^\d{4}Q[1-4]$", description="Quarter in YYYYQ[1-4] format")
```

**Convert to provider format:**

```python
# Gemini / OpenAI-compatible
tool_schema = GetMetrics.model_json_schema()

# Claude format
claude_tool = {
    "name": "get_metrics",
    "description": GetMetrics.__doc__,
    "input_schema": GetMetrics.model_json_schema(),
}
```

**Tool description rules:** Write as technical documentation — what it does, when to use it, what each parameter means, what it returns. Vague descriptions → wrong tool selection.

### Context and State Management

| Scope | Mechanism |
|---|---|
| Short-term | Thread-local message histories trimmed via sliding window |
| Long-term | Vector search (RAG-based retrieval for cross-session knowledge) |
| Prompt cache | Cache system prompt + tool defs for iterative loops (Claude: `cache_control`; Gemini: context caching) |

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
system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}]
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
    context: dict = Field(default_factory=dict, description="Relevant state to pass forward")
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

## Implementation

### Full Agent Loop (Claude API)

```python
import anthropic
from pydantic import BaseModel

client = anthropic.Anthropic()
MAX_ITERATIONS = 10

def run_agent(goal: str, tools: list[dict], response_model: type[BaseModel], system: str = "") -> BaseModel:
    messages = [{"role": "user", "content": goal}]

    for iteration in range(MAX_ITERATIONS):
        response = client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=4_096,
            system=system,
            tools=tools,
            tool_choice={"type": "auto"},
            messages=messages,
        )
        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            text = next((b.text for b in response.content if hasattr(b, "text")), "")
            result = parse_or_correct(text, response_model, messages)
            if result:
                return result

        elif response.stop_reason == "tool_use":
            tool_results = []
            for block in response.content:
                if block.type == "tool_use":
                    result = execute_tool(block.name, block.input)
                    tool_results.append({"type": "tool_result", "tool_use_id": block.id, "content": result})
            messages.append({"role": "user", "content": tool_results})

    raise AgentMaxIterationsError(f"Agent did not complete within {MAX_ITERATIONS} iterations")
```

### Streaming with SSE

```python
# Accumulate partial tool call JSON before executing — never execute on a fragment
with client.messages.stream(model="claude-sonnet-4-6", tools=tools, messages=messages) as stream:
    accumulated: dict[str, str] = {}

    for event in stream:
        if event.type == "content_block_start" and event.content_block.type == "tool_use":
            accumulated[event.content_block.id] = ""
        elif event.type == "content_block_delta" and hasattr(event.delta, "partial_json"):
            accumulated[str(event.index)] = accumulated.get(str(event.index), "") + event.delta.partial_json

    final = stream.get_final_message()
```

**Rule:** Always accumulate `partial_json` deltas before execution. Executing on partial JSON raises a parse error that silently corrupts the loop.

### Agent Observability

Emit OpenTelemetry spans — one span per loop iteration. General OTel setup → `harness`.

```python
from opentelemetry import trace

tracer = trace.get_tracer("agent.loop")

for iteration in range(MAX_ITERATIONS):
    with tracer.start_as_current_span("agent.iteration") as span:
        span.set_attribute("agent.iteration", iteration)
        span.set_attribute("agent.stop_reason", response.stop_reason)
```

For agent-specific visualisation tool selection (Vertex AI Service Runtime vs LangSmith) → `docs/adr/ADR-006-agent-observability.md`.

## Common Mistakes

| Mistake | Consequence | Correction |
|---|---|---|
| Vague tool descriptions | Wrong tool selection or missing required params | Write as technical docs: what, when, params, returns |
| No `max_iterations` cap | Infinite loop → runaway cost | Always set `MAX_ITERATIONS = 10`; raise `AgentMaxIterationsError` |
| Executing partial streaming JSON | JSON parse error mid-loop | Accumulate all `partial_json` deltas before executing |
| Raising on tool execution error | Agent halts; no recovery | `execute_tool` never raises — return `"Error: <message>"` |
| Crashing on hallucinated tool name | Agent halts | Check `TOOL_REGISTRY`; return available tool names as feedback |
| Provider-coupled tool logic | Vendor lock-in | Keep `execute_tool` provider-agnostic; registry is the only coupling point |
| No state persistence | Crash = lost work; HITL impossible | Checkpoint after every iteration |
| Passing full history to sub-agent | Irrelevant context; performance degrades | Pass only a `context: dict` with the specific state the sub-agent needs |
