# Agentic Engineering — Examples

Runnable end-to-end walkthrough for the `agentic-engineering` skill. See [SKILL.md](SKILL.md) for the overview, scope, and REFACTOR patterns. See [REFERENCE.md](REFERENCE.md) for full code schemas and decision tables.

> **Note:** Paths in this file are illustrative for the described feature. They are excluded from the doc-path check by design.

---

## End-to-End: Autonomous Agent with Tool Use

### Full Agent Loop (Claude API)

```python
import anthropic
from pydantic import BaseModel

client = anthropic.Anthropic()
MAX_ITERATIONS = 10


def run_agent(
    goal: str, tools: list[dict], response_model: type[BaseModel], system: str = ""
) -> BaseModel:
    messages = [{"role": "user", "content": goal}]

    for iteration in range(MAX_ITERATIONS):
        response = client.messages.create(
            model="claude-opus-4-5",
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
                    tool_results.append(
                        {
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "content": result,
                        }
                    )
            messages.append({"role": "user", "content": tool_results})

    raise AgentMaxIterationsError(
        f"Agent did not complete within {MAX_ITERATIONS} iterations"
    )
```

### Streaming with SSE (Internal — Accumulate Before Executing)

```python
# Accumulate partial tool call JSON before executing — never execute on a fragment
with client.messages.stream(
    model="claude-opus-4-5", tools=tools, messages=messages
) as stream:
    accumulated: dict[str, str] = {}

    for event in stream:
        if (
            event.type == "content_block_start"
            and event.content_block.type == "tool_use"
        ):
            accumulated[event.content_block.id] = ""
        elif event.type == "content_block_delta" and hasattr(
            event.delta, "partial_json"
        ):
            accumulated[str(event.index)] = (
                accumulated.get(str(event.index), "") + event.delta.partial_json
            )

    final = stream.get_final_message()
```

For streaming agent text output **to a client** (SSE to browser/CLI) → `application-engineering`.

### Agent Observability

Emit OpenTelemetry spans — one span per loop iteration. For general OTel setup or agent-specific visualisation tooling, consult your architecture-decision store, or write one from `docs/adr/ADR-000-template-architecture-decision.md` if none exists yet.

```python
from opentelemetry import trace

tracer = trace.get_tracer("agent.loop")

for iteration in range(MAX_ITERATIONS):
    with tracer.start_as_current_span("agent.iteration") as span:
        span.set_attribute("agent.iteration", iteration)
        span.set_attribute("agent.stop_reason", response.stop_reason)
        span.set_attribute(
            "agent.tool_calls",
            len([b for b in response.content if b.type == "tool_use"]),
        )
```
