---
name: agentic-engineering
description: Use when building autonomous AI agents with the Claude API — Plan-Act-Observe loops, tool use, multi-agent coordination, context window management, agent state persistence, or testing agent behaviour
---

# Agentic Engineering

## Overview

Covers the design and implementation of autonomous AI agents. An agent is distinguished from an AI-backed API by its loop structure: it calls Claude multiple times across iterations, selects tools, observes results, and continues until a goal is achieved or the iteration cap is reached. All patterns are **provider-agnostic** — tool definitions, loop logic, and output validation are decoupled from the LLM provider. Core loop: **Plan → Act → Observe**.

**Primary artifact:** Functioning autonomous agent — tool use, structured outputs, multi-agent coordination — built provider-agnostically on the Anthropic SDK (primary) with the Google AI SDK as the secondary slot.

**Boundary with `application-engineering`:** If Claude makes **one call per API request**, that is an AI-backed API — load `application-engineering`. If Claude makes **multiple tool calls in a loop** before returning a final result, that is an agent — load this skill. A FastAPI endpoint that invokes an agent lives in `application-engineering`; the agent loop itself lives here.

See [REFERENCE.md](REFERENCE.md) for full code schemas (Plan-Act-Observe loop, tool definition template, structured output correction, sliding window, multi-agent coordination, Checkpointer, OTel spans per iteration). See [EXAMPLES.md](EXAMPLES.md) for a runnable end-to-end agent session with tool registration, loop execution, streaming, and observability.

## Scope

**Owns:** Plan-Act-Observe loop design and state management, tool definition standard (Pydantic → JSON Schema), structured output enforcement with correction on parse failure, provider-agnostic action executor, multi-agent coordination (Orchestrator + Handoff patterns), context window management within agent loops (sliding window, prompt caching), agent state persistence (Checkpointer pattern), agent testing patterns, OTel span emission per loop iteration.

**Does not own:** Single-turn Claude API calls and AI-backed REST endpoints (→ `application-engineering`), agent deployment infrastructure and environment provisioning (`.github/workflows/`, `.devcontainer/`), data pipeline patterns used by agents (→ `data-engineering`), domain model design (→ `refine`).

**Interfaces with:** `application-engineering` — agents are exposed to clients via thin API endpoints; single-call AI patterns and streaming SSE to client live there. `implement` — agent behaviour verified via RED-GREEN-REFACTOR; domain-specific testing patterns extend REFACTOR here.

## When to Use

- **Trigger:** Building an agent that calls Claude with tools across multiple iterations
- **Trigger:** Implementing structured output enforcement with correction on parse failure
- **Trigger:** Designing a Plan-Act-Observe loop or multi-turn autonomous flow
- **Trigger:** Coordinating multiple agents (Orchestrator + Handoff)
- **Trigger:** Managing context window limits within an agent loop
- **Trigger:** Writing tests for agent behaviour (not API contracts)
- **Trigger:** Persisting agent state for HITL approvals or crash recovery

**Do NOT use for:**
- Single-turn Claude calls within an API request (→ `application-engineering`)
- Agent deployment and infrastructure (`.github/workflows/`)
- Data pipelines that agents consume (→ `data-engineering`)

## Required Inputs

- Goal specification and tool definitions (from `refine` or Lean PRD)
- Pydantic models for structured final response
- Acceptance criteria for agent behaviour (from `plan` testing decisions)

## Primary Outputs

- Plan-Act-Observe loop implementation with `MAX_ITERATIONS` cap
- Tool registry with `execute_tool` that never raises
- Structured output enforcement with correction-on-failure
- `AgentCheckpoint` persistence after every iteration
- Agent behaviour tests (mock at the LLM boundary, not at tool execution)

## tdd REFACTOR Phase Patterns

Shared coding principles apply first — see `.agents/skills/implement/REFERENCE.md` § Coding Principles. Then extend with these agentic-engineering patterns:

- **`execute_tool` never raises:** If any tool implementation can raise an exception, wrap it. The agent loop must always receive a string result — errors are observations, not crashes.
- **Provider-agnostic executor isolation:** The `execute_tool` function must not import from `anthropic` or any other provider SDK. If it does, extract the provider coupling to the loop level.
- **Checkpointer completeness:** State is persisted after every iteration. If the Checkpointer only saves on success, add saves for `"running"` and `"awaiting_approval"` states.
- **Sliding window correctness:** The message history trim must preserve the system message and at least one user/assistant pair. If the trim removes the system prompt, fix the filter logic.
- **Termination coverage:** The test suite must cover all three termination paths — (1) successful parse, (2) `max_iterations` exceeded, (3) non-recoverable tool error. Missing coverage = missing termination guarantee.
- **OTel span per iteration:** Each loop iteration must emit a span. If spans are missing after GREEN, add them in REFACTOR — agent latency is invisible without per-iteration traces.

No `scripts/` directory — this skill is a constraint document with no deterministic operation to script.

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
| Building agent loop inside a router | Untestable, blocks the request thread | Agent loop runs in a service or background task; thin endpoint triggers it |
