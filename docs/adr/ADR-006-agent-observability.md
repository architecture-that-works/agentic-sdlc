# ADR-006: Agent Observability Tooling

## Status
Proposed

## Context and Problem Statement
Agent loops emit OpenTelemetry spans (one per iteration) as the primary observability layer. Beyond raw OTel, a dedicated agent visualisation tool enables full loop replay and failure analysis. Two candidates: Vertex AI Service Runtime (GCP-native) and LangSmith.

## Considered Options
- Vertex AI Service Runtime
- LangSmith

## Decision Outcome
Context-dependent — see decision drivers below.

## Pros and Cons

### Vertex AI Service Runtime
- Good, because: GCP-native — zero additional infrastructure if already on GCP
- Good, because: integrated with Gemini API for full end-to-end agent tracing
- Bad, because: GCP lock-in — not portable to other providers
- Bad, because: limited to Vertex AI-deployed agents

### LangSmith
- Good, because: provider-agnostic — works with Claude, Gemini, OpenAI
- Good, because: full loop replay, prompt versioning, evaluation datasets
- Good, because: integrates with the LangChain ecosystem
- Bad, because: additional SaaS dependency
- Bad, because: LangChain coupling if using LangSmith's native integrations

## Decision Drivers

**Choose Vertex AI Service Runtime when:** agents are deployed on GCP and Gemini is the primary provider.
**Choose LangSmith when:** provider-agnostic observability is needed, or the codebase uses LangChain patterns.

Both are compatible with the OTel span emission pattern in `agentic-development`. General OTel setup → `harness`.
