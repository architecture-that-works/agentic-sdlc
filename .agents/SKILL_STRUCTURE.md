# Skill Structure

Master reference for the MECE agentic SDLC skill system.
Check this before writing or updating any skill to verify scope placement and avoid overlap.

---

## Guiding Philosophy

Software engineering fundamentals matter more than ever. These skills are a best effort at
condensing those fundamentals into repeatable, agent-executable practices. The design rejects
"vibe coding" — low-fidelity prompting and unverified generation — in favour of disciplined,
adversarial, interface-first engineering rooted in the Pragmatic Programmer series, Wes McKinney's
performance hierarchy, and Matt Pocock's type-safe boundary philosophy.

Primary language: **Python**. TypeScript is a secondary boundary language used where type-safe
contracts are needed at system edges (API schemas, SDK clients); Python remains the implementation
language throughout.

---

## Context Window Awareness (Cross-Cutting Principle)

Context window fill is not neutral — reasoning quality degrades non-linearly as the window fills.
This is not a hard rule that prohibits large contexts; it is a calibration guide that every skill
must respect and surface to the agent at the right moment.

| Zone | Token Range | Reasoning Characteristic | Recommended Action |
|---|---|---|---|
| **Smart Zone** | < 100k | High precision; reliable instruction following. | Optimal for alignment, architecture, TDD. |
| **Transition Zone** | 100k – 250k | Emerging drift; subtle logic errors possible. | Compact before starting new complex tasks. |
| **Dumb Zone** | > 250k | Coherence degrades; conflict resolution unreliable. | Reset recommended. Exception: reference-only contexts (agent reads large codebases without deep reasoning). |

**Ownership of context hygiene:**
- `refine` owns the CONTEXT.md schema and initialisation.
- `harness` owns compact(), reset triggers, and tool-call offloading decisions.
- Every workflow skill must note when its phase is sensitive to context fill.

---

## Structure

```
Workflow     refine → architecture → plan → tdd → harness → review → ship
─────────────────────────────────────────────────────────────────────
Domain       application-engineering · data-engineering · agentic-engineering
─────────────────────────────────────────────────────────────────────
Meta         version-control · write-skills
```

Skills are **Mutually Exclusive** (every concern has exactly one owner) and **Collectively
Exhaustive** (every phase of the agentic SDLC is covered).

**Workflow skills** are sequential phases — load the relevant phase skill before starting work
in that phase. Each skill is a constraint document that prevents a specific class of agent failure.

**Domain skills** follow the `*-engineering` naming convention. They extend `tdd`'s REFACTOR
phase with implementation patterns specific to a problem space. The default domain is
`application-engineering` (matches `project_type: application`). Load exactly one domain skill
per implementation session — do not load domain skills for project types that do not apply.

**Meta skills** are project-type agnostic and cross-cutting. `version-control` defines branch,
commit, and PR conventions used by every workflow phase that touches git. `write-skills` defines
the standard for creating and validating new skills. Meta skills are loaded on demand, not
automatically at session start.

**Domain skill boundary — application-engineering vs agentic-engineering:**
- `application-engineering`: Claude makes **one** `messages.create` call per API request. The
  service calls Claude as a dependency and returns a structured or streamed result to the client.
- `agentic-engineering`: Claude makes **multiple** tool calls across iterations in a Plan-Act-Observe
  loop before returning a final result. State is managed across iterations.
- A FastAPI endpoint that *invokes* an agent belongs in `application-engineering`. The agent loop
  itself belongs in `agentic-engineering`.

---

## Meta

### `version-control`
**Primary artifact:** Linked branch → commit → PR tied to a GitHub Issue

**Owns:** Branch naming convention (`feature/{issue-number}-{dense-slug}`), commit message
format (`feat(#N): Title`), PR creation with issue auto-close (`Closes #N`), GitHub CLI (`gh`)
command patterns and error handling, agent-driven automation of the full branch → commit → PR
flow, worktree creation for isolated fix branches.

**Does not own:** CI/CD pipeline configuration (→ `harness`), code review standards (→
`review`), PR merge and governance (→ `ship`).

**Interfaces with:** All workflow skills — every phase that touches git or the GitHub API uses
the conventions defined here. The Director Workflow auto-generates branch names as
`feature/{number}-{word1}-{word2}-{word3}`; manual branches must follow the same pattern.

**Context sensitivity:** Low. Version-control operations are stateless and safe at any context
fill level.

---

## Workflow

### `refine`
**Primary artifact:** CONTEXT.md (domain glossary + architectural boundaries) and Agent Brief
(interface-first specification)

**Owns:**
- Adversarial Senior Architect persona and the "grill-me" protocol — relentless questioning
  down every decision-tree branch before any code is written.
- Shared language construction: building a project glossary that reduces ambiguous terms to
  concise, agreed tokens (e.g., "materialization cascade").
- CONTEXT.md schema — the source of truth ingested by every agent at session start: glossary,
  bounded contexts, architectural constraints, and out-of-scope declarations.
- AGENTS.md persistence rules — style preferences and standing instructions that sit at the top
  of every conversation.
- ADR (Architectural Decision Record) creation and referencing — prevents regressions during
  grilling sessions.
- Agent Brief synthesis — durable specification written in terms of interfaces and contracts,
  never volatile file paths or line numbers.
- Pragmatic Programmer integration during grilling: dig for requirements (PP-51), think like a
  user (PP-52), prioritise long-lived abstractions over implementation details (PP-53), surface
  broken windows (PP-4), propose options not excuses (PP-3).
- Context window initialisation: CONTEXT.md is loaded first in every new session; the agent
  must flag if current context fill would push into the Transition Zone before alignment begins.

**Does not own:** Architecture mapping or static analysis (→ `architecture`), PRD or issue
creation (→ `plan`), code implementation (→ `tdd`).

**Interfaces with:** `architecture` — the architectural map validates and refines the shared
language. `plan` — the Agent Brief is the direct input to Lean PRD synthesis. `harness` — 
CONTEXT.md and AGENTS.md are loaded by the harness at session initialisation.

**Context sensitivity:** High. Alignment requires the agent to be in the Smart Zone. If context
fill is already in the Transition Zone, compact before starting a new alignment session. Never
begin a grill-me session in the Dumb Zone.

---

### `architecture`
**Primary artifact:** Architecture map with fragility scores, coupling metrics, and blast-radius
report

**Owns:**
- Codeflow CLI integration: generating JSON exports of file and module dependency graphs.
- Dependency visualisation: identifying circular dependencies, layer boundary violations, and
  structural anti-patterns (God Objects, anemic domain models).
- Deep module identification: locating components that encapsulate significant complexity behind
  a simple, testable interface — the target state for all refactoring.
- Shallow module detection: flagging components where interface complexity approaches
  implementation complexity — a refactoring trigger.
- Metric interpretation: fragility score (probability of side-effects), coupling metric
  (inter-layer dependency degree), churn data (historical modification frequency), pattern
  grade (A–F design pattern adherence).
- Blast-radius computation: quantifying the surface area of a proposed change before any code
  is committed. Output as a "thermal receipt" in PR comments.
- GitHub CLI research loop: piping Codeflow JSON through `jq` to cross-reference topology
  findings with existing GitHub Issues and architectural discussions.
- Refactoring demand: blocking progress when pattern grade or fragility score violates layer
  boundaries established in `refine`.

**Does not own:** Domain model design decisions (→ `refine`), infrastructure dependency mapping
(→ domain skills), CI/CD topology (→ `harness`).

**Interfaces with:** `refine` — topology validates the architectural boundaries declared in
CONTEXT.md. `plan` — blast-radius findings inform scope decisions in the Lean PRD. `review` —
thermal receipts are surfaced in the PR review cycle.

**Context sensitivity:** Medium. Codeflow JSON exports can be large. Pipe outputs to the
filesystem; only load summary metrics into context. Safe to run in the Transition Zone if raw
outputs are offloaded.

---

### `plan`
**Primary artifact:** Lean PRD published as a GitHub Issue, decomposed into labelled grabbable
issues

**Owns:**
- Lean PRD synthesis (`to-prd`): consuming the Agent Brief and architecture map to produce a
  structured specification.
- PRD components: problem statement (user perspective), long list of user stories
  ("As a [role], I want [action], so that [value]"), implementation decisions (schema changes
  and API contracts — no file paths), testing decisions (what makes a good test for this
  module), out-of-scope boundaries.
- Tracer bullet framing: every PRD prioritises narrow, end-to-end vertical slices that cut
  through all system layers (schema → API → consumer) over horizontal slices that deliver one
  layer at a time.
- Deduplication: `gh search issues` check against existing issues and the `.out-of-scope/`
  knowledge base before finalising the PRD. Rejected "wontfix" concepts must not be re-proposed.
- Issue decomposition (`to-issues`): breaking the approved PRD into individual GitHub Issues,
  each labelled HITL (Human-in-the-Loop) or AFK (Away-from-Keyboard).
- `.out-of-scope/` knowledge base reads: ensuring prior architectural rejections are respected.

**Does not own:** Domain glossary or shared language (→ `refine`), static analysis or
dependency data (→ `architecture`), code implementation (→ `tdd`), issue merging or PR creation
(→ `version-control`, `ship`).

**Interfaces with:** `refine` — the Agent Brief is the primary input. `architecture` — blast-radius
findings gate scope decisions. `tdd` — testing decisions in the PRD define the acceptance
criteria for the TDD loop. `version-control` — issues created here are the targets for
feature branches.

**Context sensitivity:** Medium. PRD synthesis requires coherent reasoning; run in the Smart
Zone when possible. Deduplication queries are stateless and safe at any fill level.

---

### `tdd`
**Primary artifact:** Passing test suite with minimal, refactored implementation code

**Owns:**
- Red-Green-Refactor loop enforcement:
  - **RED:** Write one failing test that verifies a specific behaviour through a public
    interface. Mocking is restricted to system boundaries (external APIs, databases, time).
    Internal collaborators must never be mocked.
  - **GREEN:** Write only enough code to pass the current test. Anticipating future tests or
    writing horizontal slices is prohibited.
  - **REFACTOR:** Remove duplication, deepen shallow modules, apply SOLID principles. Complexity
    moves behind simple interfaces; the public surface shrinks or stays constant.
- Acceptance criteria traceability: every test maps to a user story or testing decision from
  the Lean PRD.
- TypeScript type-safe boundaries (when TypeScript is the target language at system edges):
  simple interfaces with compile-time guarantees; no deep generic wizardry that overwhelms the
  compiler or the agent.
- Test suite ergonomics: fast, isolated unit tests; external boundaries mocked; suite must
  remain a low-latency feedback loop for the agent.

**Does not own:** Test infrastructure provisioning (→ `harness`), PR creation (→
`version-control`), code review (→ `review`), performance infrastructure (→ domain skills).

**Interfaces with:** `plan` — acceptance criteria from the Lean PRD drive the RED phase.
`harness` — the TDD loop runs inside managed sessions; large test logs are offloaded by the
harness. Domain skills — extend the REFACTOR phase with domain-specific patterns (e.g.,
Medallion pipeline structure in `data-engineering`).

**Context sensitivity:** High during RED and GREEN phases (precise instruction following
required). REFACTOR is lower sensitivity. If context fill reaches Transition Zone mid-loop,
compact before the next RED phase begins.

---

### `harness`
**Primary artifact:** Configured managed agent session with Planner/Generator/Evaluator split
and durable event log

**Owns:**
- Managed Agents primitives: Agents (model + system prompt + skills), Environments (secure
  cloud containers with pre-installed toolchain), Sessions (stateful, persistent filesystem
  across multi-hour tasks), Events (real-time human steering and interruption stream).
- `provision()`: container initialisation using standard toolchain recipes. Environments are
  disposable ("cattle, not pets") — one per task.
- `emitEvent()`: durable event log enabling resume-on-crash and full task accountability.
- Planner/Generator/Evaluator split: the agent must never grade its own work. The Evaluator
  is a separate agent instance (often using Playwright or equivalent for live-page verification)
  that provides a detached critique triggering iterative refinement in the Generator.
- Tool-call offloading: large outputs (test logs, Codeflow JSON, build artefacts) are written
  to the filesystem. Only head and tail tokens enter the context window.
- `compact()`: context organisation for prompt cache hits; used to reduce latency and cost for
  long sessions.
- Context reset protocol: when context fill reaches the Dumb Zone and the task requires deep
  reasoning, the harness initiates a structured handoff — writing a handoff artefact to disk,
  resetting the session, and re-initialising from CONTEXT.md. Exception: reference-only
  contexts (agent reads large codebases without synthesising novel solutions) may safely exceed
  250k tokens.
- CONTEXT.md and AGENTS.md loading at session start.

**Does not own:** CONTEXT.md content or the grill-me protocol (→ `refine`), TDD loop logic (→
`tdd`), PR review (→ `review`), merge and governance (→ `ship`).

**Interfaces with:** `refine` — CONTEXT.md and AGENTS.md are the harness initialisation inputs.
`tdd` — the TDD loop runs inside harness sessions; log offloading keeps the loop fast.
`review` — the Evaluator agent in the harness feeds findings to the review cycle.

**Context sensitivity:** This skill manages context for all other skills. The harness itself
must always operate in the Smart Zone; it is the last line of defence before a Dumb Zone reset.

---

### `review`
**Primary artifact:** Multi-agent review report with auto-applied fixes and a verified clean
PR

**Owns:**
- Multi-agent parallel review: running Claude, and or Gemini reviewers in parallel;
  consolidating findings into a single actionable report.
- Auto-fix and refine loop: `review refine` feeds findings to a Generator agent in an
  isolated worktree. The loop (fix → re-review → fix) continues until all findings are
  resolved or the iteration limit is reached.
- Verification and compaction: `review compact` filters false positives by verifying findings
  against the current code state; related issues are consolidated before reporting.
- PR-level batch orchestration: `ci_pr_batches` tracks review status across the full PR, not
  just individual commits.
- Senior Architect standard enforcement: if a review finding maps to a principle established
  during `refine` (e.g., a module encapsulation leak, a tracer-bullet violation), the PR is
  blocked and an automated fix cycle is triggered.
- Review database accountability: every finding and fix attempt is persisted (jobs, reviews,
  responses tables) for full traceability of generated code.

**Does not own:** Code implementation (→ `tdd`), static topology analysis (→ `architecture`),
merge and security governance (→ `ship`).

**Interfaces with:** `tdd` — review validates that GREEN and REFACTOR phases produced
compliant code. `architecture` — thermal receipts from topology are surfaced in the review report.
`ship` — a clean review is the gate for the `ship` phase.

**Context sensitivity:** Low for individual commit reviews (stateless). High for the fix loop
— each fix iteration should start from a compact context to avoid compounding drift.

---

### `ship`
**Primary artifact:** Squash-merged PR with clean history, closed GitHub Issue, updated
knowledge base

**Owns:**
- `gh pr merge --squash`: final merge command; enforces a clean, linear commit history.
- Auto-close enforcement: PR body must contain `Closes #N`; the skill validates this before
  merge is attempted.
- Security governance:
  - Sandboxing verification: confirms agent-generated code ran inside the managed container
    with no access to host credentials.
  - Credential scoping audit: tokens used during development must never be reachable from the
    agent's execution sandbox.
  - Supply chain integrity: dependency manifest review for new third-party packages introduced
    in the PR; flag unpinned or unvetted additions.
  - CI/CD workflow permission review: check for over-permissioned tokens or misconfigured
    workflow triggers.
  - Prompt injection checklist: verify that any user-controlled input flowing through the
    system cannot alter agent instructions.
- Knowledge persistence (post-merge cleanup turn):
  - `.out-of-scope/` update: any improvement deferred during review is recorded so it cannot
    be re-proposed in a future `plan` session.
  - CONTEXT.md update: new architectural lessons, revised glossary terms, or boundary
    clarifications discovered during the task are committed back to the root CONTEXT.md.

**Does not own:** Code review findings (→ `review`), branch or commit operations (→
`version-control`), container and environment teardown (→ `harness`).

**Interfaces with:** `review` — a passing review is the prerequisite for ship. `version-control`
— merge uses the branch and PR conventions established there. `refine` — CONTEXT.md updates
feed back into the next session's initialisation.

**Context sensitivity:** Low. Merge operations and knowledge persistence writes are stateless
and safe at any context fill level.

---

## Domain

Domain skills extend `tdd`'s REFACTOR phase with implementation patterns specific to a
problem space. They do not own the TDD loop itself, version-control conventions, or the
workflow phases — those are inherited from the workflow skills.

---

### `application-engineering`
**Primary artifact:** Production AI-backed API or service — Claude as a replaceable port, OTel-instrumented, Pydantic-contracted.

**Owns:** REST API design and implementation, input validation and serialisation at request
boundaries (Pydantic), Claude API integration as a service dependency (single-turn completions,
structured outputs via tool_use, SSE streaming to client), AI port/adapter pattern,
OTel instrumentation at the request boundary, AI error handling (rate limits, timeouts,
exponential backoff), authentication and authorisation patterns, background task design,
service-to-service communication, contract testing for API consumers.

**Does not own:** Plan-Act-Observe loops and multi-turn autonomous agents (→ `agentic-engineering`),
agent state persistence and multi-step orchestration (→ `agentic-engineering`), infrastructure
and deployment (→ `harness`), data pipeline design (→ `data-engineering`), domain modelling
(→ `refine`).

**Interfaces with:** `refine`, `tdd`, `agentic-engineering`.

---

### `data-engineering`
**Primary artifact:** Validated, query-ready datasets produced by a layered pipeline

**Owns:** ELT pipeline design and implementation (Raw → Bronze → Silver → Gold Medallion
architecture), data validation and schema enforcement at layer boundaries, data quality gates,
feature pipeline implementation (computing features at scale), storage backend selection
(local/prototype vs. production scale), pipeline orchestration patterns, lineage event
emission from pipeline steps.

**Does not own:** Feature design — which features to compute (→ `refine` or domain knowledge),
model training pipelines (→ `agentic-engineering` if AI-driven, or out of current scope),
general telemetry instrumentation patterns (→ `harness` or cross-cutting).

**Interfaces with:** `refine`, `tdd`, `application-engineering`.

---

### `agentic-engineering`
**Primary artifact:** Functioning autonomous agent — Plan-Act-Observe loop, tool use, structured outputs, multi-agent coordination — provider-agnostic, Anthropic SDK primary.

**Owns:** Plan-Act-Observe loop design and state management, tool definition standard (Pydantic
→ JSON Schema), structured output enforcement with correction on parse failure, provider-agnostic
action executor, multi-agent coordination (Orchestrator + Handoff patterns), context window
management within agent loops (sliding window, prompt caching), agent state persistence
(Checkpointer pattern), agent testing patterns, OTel span emission per loop iteration.

**Does not own:** Single-turn Claude API calls and AI-backed REST endpoints (→ `application-engineering`),
agent deployment infrastructure and environment provisioning (→ `harness`), data pipeline
patterns used by agents (→ `data-engineering`).

**Interfaces with:** `application-engineering`, `harness`, `tdd`.

---

## Meta

### `write-skills`
**Primary artifact:** Valid, MECE-compliant SKILL.md

**Owns:** Skill creation standards and SKILL.md template, validation process (baseline → draft
→ verify), MECE enforcement and split/gap detection against this SKILL_STRUCTURE.md, routing
signal format for agent skill selection, ASO (Agent Search Optimisation) rules for skill
discoverability.

**Does not own:** Project-specific agent instructions (→ CONTEXT.md / AGENTS.md), individual
skill content.

**Interfaces with:** All skills — defines the contract every skill must follow.

---

## Explicit Boundary Rules

Shared concerns that appear across multiple skills. Ownership is fixed here to prevent duplication.

| Concern | Owner | Notes |
|---|---|---|
| CONTEXT.md schema and authoring | `refine` | Loaded by `harness` at session start; updated by `ship` post-merge |
| AGENTS.md persistence rules | `refine` | Loaded by `harness`; not modified during implementation |
| Domain glossary construction | `refine` | Shared language reduces token cost across all phases |
| ADR creation and referencing | `refine` | Referenced in `architecture` and `plan` to prevent regressions |
| Agent Brief (interface-first spec) | `refine` | Input to `plan`; never contains file paths |
| Architecture map and metrics | `architecture` | Fragility, coupling, churn, pattern grade |
| Blast-radius computation | `architecture` | Surfaced in PR comments; gates `plan` scope decisions |
| GitHub Issue research loop | `architecture` | Cross-references topology findings with existing issues via `gh` + `jq` |
| Lean PRD synthesis | `plan` | Consumes Agent Brief + architecture map |
| Tracer bullet framing | `plan` | End-to-end vertical slices; never horizontal |
| HITL / AFK labelling | `plan` | Applied to every issue during decomposition |
| `.out-of-scope/` reads | `plan` | Prevents re-proposing rejected concepts |
| `.out-of-scope/` writes | `ship` | Deferred improvements recorded post-merge |
| TDD loop (Red-Green-Refactor) | `tdd` | Domain skills extend REFACTOR; they do not own the loop |
| Mocking rules | `tdd` | System boundaries only; internal collaborators never mocked |
| Python performance hierarchy | `tdd` | Applied in REFACTOR when profiling reveals a bottleneck |
| TypeScript type-safe boundaries | `tdd` + `application-engineering` | TypeScript at system edges; Python for implementation |
| Container and environment setup | `harness` | Disposable per task; provisioned via standard recipes |
| Planner/Generator/Evaluator split | `harness` | Evaluator is always a separate agent instance |
| Tool-call offloading | `harness` | Large outputs to filesystem; head+tail in context |
| Context reset protocol | `harness` | Triggered when Dumb Zone is reached and deep reasoning is required |
| compact() usage | `harness` | For prompt cache hits and Transition Zone management |
| Multi-agent PR review | `review` | Claude + Codex + Gemini in parallel |
| Auto-fix and refine loop | `review` | Isolated worktree; iteration-limited |
| Senior Architect standard enforcement at PR | `review` | Maps findings to `refine` principles |
| Squash merge and auto-close | `ship` | `gh pr merge --squash`; `Closes #N` required |
| Security governance | `ship` | Sandboxing, credential scoping, supply chain, prompt injection |
| CONTEXT.md post-session update | `ship` | New lessons committed back after merge |
| Branch and commit conventions | `version-control` | Used by all workflow phases |
| PR creation with issue link | `version-control` | `Closes #N` format; validated by `ship` |
| REST API design | `application-engineering` | FastAPI primary; Pydantic validation at boundaries |
| TypeScript SDK clients and schemas | `application-engineering` | Zod / OpenAPI-generated types at consumer edges |
| Medallion pipeline architecture | `data-engineering` | Raw → Bronze → Silver → Gold |
| Data validation at layer boundaries | `data-engineering` | Schema enforcement per Medallion tier |
| Plan-Act-Observe loop | `agentic-engineering` | State management and tool execution |
| Anthropic SDK usage | `agentic-engineering` | Primary agent runtime; provider-agnostic executor pattern |
| Agent state persistence (Checkpointer) | `agentic-engineering` | Pattern owned here; infrastructure in `harness` |
| Skill MECE validation | `write-skills` | All new skills checked against this document before publishing |