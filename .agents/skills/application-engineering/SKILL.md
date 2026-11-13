---
name: application-engineering
description: Use when designing or building AI-backed APIs and services — REST endpoints, request/response contracts, Claude API integration (single-call patterns), streaming AI responses to clients, OTel instrumentation, authentication, or service-to-service communication
---

# Application Engineering

## Overview

Covers the design and implementation of production AI application services. The primary use case is a FastAPI service that calls the Claude API — one Claude call per API request, returning structured or streamed results. **FastAPI** is the standard framework; **Anthropic Python SDK** is the primary AI provider; **Pydantic** validates every boundary. OTel instrumentation is mandatory from day one (ADR-003).

**Primary artifact:** Production AI-backed API or service — Claude as a replaceable port, OTel-instrumented, Pydantic-contracted.

**Boundary with `agentic-engineering`:** This skill owns **single-call** Claude patterns — one `messages.create` per API request. If the service drives a Plan-Act-Observe loop with multiple tool calls across iterations, that loop belongs in `agentic-engineering`. A FastAPI endpoint that *invokes* an agent lives here; the agent itself lives there.

See [REFERENCE.md](REFERENCE.md) for full code schemas (port/adapter, OTel instrumentation, SSE streaming, exponential backoff), API style and auth selection tables, and versioning patterns. See [EXAMPLES.md](EXAMPLES.md) for the project structure tree, contract testing setup, and runnable commands.

## Scope

**Owns:** REST API design and implementation, input validation and serialisation at request boundaries (Pydantic), Claude API integration as a service dependency (single-turn completions, structured outputs via tool_use, SSE streaming to client), AI port/adapter pattern (provider-agnostic abstraction), OTel instrumentation at the request boundary, AI error handling (rate limits, timeouts, exponential backoff), authentication and authorisation patterns, background task design, service-to-service communication, contract testing for API consumers.

**Does not own:** Plan-Act-Observe loops and multi-turn autonomous agents (→ `agentic-engineering`), agent state persistence and multi-step orchestration (→ `agentic-engineering`), infrastructure and environment provisioning (`.github/workflows/`, `.devcontainer/`), data pipeline design (→ `data-engineering`), domain model design (→ `refine`).

**Interfaces with:** `refine` — application layer implements ports defined during alignment; no business logic in routers. `implement` — contract tests drive the RED phase for API behaviour. `agentic-engineering` — an API endpoint may *invoke* an agent; agent internals live there.

## When to Use

- **Trigger:** Designing or implementing a REST API endpoint that calls Claude
- **Trigger:** Defining request/response models and validation
- **Trigger:** Instrumenting a service with OTel traces and structured logs
- **Trigger:** Setting up authentication or authorisation
- **Trigger:** Implementing streaming AI responses to a client via SSE
- **Trigger:** Adding exponential backoff for Claude API rate limits

**Do NOT use for:**
- Plan-Act-Observe agent loops (→ `agentic-engineering`)
- Multi-step orchestration with tool calls across iterations (→ `agentic-engineering`)
- Infrastructure or deployment configuration (`.github/workflows/`, `SECURITY.md` § Deployment Credentials)

## Required Inputs

- Domain model and port interfaces (from `refine`)
- Acceptance criteria from Lean PRD testing decisions (from `plan`)
- ADR-003 (OTel instrumentation standard) and ADR-004 (IAM provider) from `docs/adr/`

## Primary Outputs

- FastAPI router with Pydantic-validated request/response models
- `AICompletionPort` abstraction with `ClaudeAdapter` implementation
- OTel-instrumented service layer (one span per Claude call)
- Contract tests using `FakeAIPort` (Claude never called in tests)

## tdd REFACTOR Phase Patterns

Shared coding principles apply first — see `.agents/skills/implement/REFERENCE.md` § Coding Principles. Then extend with these application-engineering patterns:

- **Router → Service → Port:** Business logic must not live in the router. Move any logic from routers into the service layer. Claude must be accessed only through an abstract `AICompletionPort`.
- **Deep service modules:** The service's public interface should be minimal — one method per use case. Move validation, retry, and OTel span creation behind this interface.
- **Port/adapter split:** If the `ClaudeAdapter` is too thick (contains business logic), extract it. Adapters translate; services orchestrate.
- **Contract test completeness:** Every public endpoint must have a contract test using `FakeAIPort`. If a test calls the real Claude, extract it into an integration test suite gated by an env var.
- **OTel span per Claude call:** Each `AICompletionPort.complete` or `complete_structured` call must be wrapped in a tracer span. If it isn't after GREEN, add it in REFACTOR.

No `scripts/` directory — this skill is a constraint document with no deterministic operation to script.

## Common Mistakes

**Claude call directly in the router.** Untestable, unswappable, no OTel span. Every Claude call goes through an `AICompletionPort` adapter.

**Using a Plan-Act-Observe loop inside an API service.** If the service needs to call Claude multiple times with tools in a loop, that is an agent — load `agentic-engineering` and expose the agent via a thin endpoint here.

**No `response_model=` on endpoints.** FastAPI cannot generate correct OpenAPI docs and may serialise internal fields. Every endpoint must declare `response_model=`.

**Secrets in environment variables.** Environment variables are visible in process lists and container inspection. Fetch secrets from a secrets manager at runtime via managed identity (`SECURITY.md`, ADR-008).

**Catching `RateLimitError` without backoff.** Immediate retry on rate limit triggers another rate limit. Always use exponential backoff.

**No OTel span on AI calls.** AI calls are the most expensive and latency-sensitive operation in the service. If they are not instrumented, debugging production latency is guesswork.

**Missing `Closes #N` in commits.** Version control convention from `version-control` — the PR auto-close link is required. `ship` validates this before merge.

**No versioning from day one.** Always prefix routes with `/v1/`. Retrofitting versioning onto an unversioned API breaks existing clients.
