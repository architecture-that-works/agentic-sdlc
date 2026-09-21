---
name: harness
description: Use when provisioning a development environment, configuring a managed agent session, managing context window health, or setting up the Planner/Generator/Evaluator split for a multi-step task
---

# Harness

## Overview

Prevents context degradation and unverified agent output by managing the execution environment and agent session lifecycle. The harness is the last line of defence before a Dumb Zone reset — it must always operate in the Smart Zone.

**Primary artifact:** Configured managed agent session with Planner/Generator/Evaluator split, durable event log, and a provisioned Dev Container environment.

See [REFERENCE.md](REFERENCE.md) for the full Dev Container spec, PGE configuration,
context management zone table, and tool-call offloading rules. See [EXAMPLES.md](EXAMPLES.md)
for worked session walkthroughs (provisioning, context reset, Evaluator blocking a regression).

## Scope

**Owns:** Dev Container and GitHub Codespaces provisioning, Planner/Generator/Evaluator agent split, event log (`emitEvent`), tool-call offloading, `compact()` and context reset protocol, `CONTEXT.md` and `AGENTS.md` loading at session start.

**Does not own:** `CONTEXT.md` content or the grill-me protocol (→ `refine`), TDD loop logic (→ `tdd`), PR review findings (→ `review`), merge and governance (→ `ship`).

**Interfaces with:** `refine` — `CONTEXT.md` and `AGENTS.md` are the harness initialisation inputs. `tdd` — the TDD loop runs inside harness sessions; log offloading keeps the loop fast. `review` — the Evaluator agent feeds findings to the review cycle.

## When to Use

- Starting any multi-step implementation task
- Provisioning a new isolated environment for a task
- Context fill is approaching the Transition Zone and action is needed
- Setting up the Evaluator agent to review Generator output

**Do NOT use for:** Writing `CONTEXT.md` content (→ `refine`), running the TDD loop (→ `tdd`), reviewing PR code quality (→ `review`).

## Required Inputs

- `CONTEXT.md` and `AGENTS.md` (loaded in this order at session start)
- Task description or GitHub Issue
- Toolchain requirements for the Dev Container

## Primary Outputs

- Provisioned Dev Container environment (disposable — one per task)
- Configured Planner/Generator/Evaluator agent split
- Event log entries for every significant state transition
- Tool-call outputs offloaded to filesystem (head + tail in context only)

## Core Pattern

### Environment Provisioning (Dev Container / GitHub Codespaces)

Environments are disposable — one per task, never shared between tasks.

**Dev Container standard:**
- Define in `.devcontainer/devcontainer.json`
- Include: language runtime, package manager, `gh` CLI, test runner (pytest), linter
- Docker available locally via Rancher Desktop for offline development
- GitHub Codespaces for cloud-hosted sessions

```json
{
  "name": "task-environment",
  "image": "mcr.microsoft.com/devcontainers/python:3.12",
  "features": {
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "postCreateCommand": "pip install -e '.[dev]'"
}
```

### Session Initialisation

Load in this order at the start of every session:
1. `CONTEXT.md` — domain glossary, boundaries, constraints
2. `AGENTS.md` — standing instructions and style preferences
3. Task-specific context (issue body, relevant test files)

If loading steps 1 + 2 + step 3 would push context fill into Transition Zone (> 100k tokens), offload step 3 to filesystem and load on demand.

### Planner / Generator / Evaluator Split

The agent must never grade its own work.

| Role | Responsibility | Provider |
|---|---|---|
| **Planner** | Breaks the issue into ordered steps; owns the task graph | Claude |
| **Generator** | Executes one step at a time; writes code and tests | Claude |
| **Evaluator** | Reviews Generator output against acceptance criteria; triggers re-generation on failure | Claude (separate instance, separate system prompt) |

**Evaluator system prompt must include:**
- The acceptance criteria from the PRD
- The architectural constraints from `CONTEXT.md`
- Explicit instruction to critique, not collaborate

### Tool-Call Offloading

Large outputs must never enter the context window:
- Test logs → write to `logs/test-output.txt`, read head + tail only
- Dependency graphs → write to `docs/architecture/graph.json`, read summary only
- Build artefacts → filesystem only

### Context Management

| Zone | Action |
|---|---|
| < 100k tokens | Proceed normally |
| 100k–250k tokens | Run `compact()` before starting any new complex task |
| > 250k tokens | Initiate context reset: write handoff artefact, reset session, re-initialise from `CONTEXT.md` |

**Exception:** Reference-only contexts (agent reads large codebases without synthesising novel solutions) may safely exceed 250k tokens — no reset required.

**`compact()` usage:** Organises the context for prompt cache hits. Run at the start of long sessions and before switching between major phases (e.g. end of RED phase, start of REFACTOR).

## Common Mistakes

**Starting a session without loading CONTEXT.md first.**
Every session begins with `CONTEXT.md` and `AGENTS.md`. An agent that skips this will hallucinate boundaries that were already agreed.

**Evaluator using the same system prompt as the Generator.**
The Evaluator must have an independent system prompt focused on critique. A shared prompt produces agreement bias, not evaluation.

**Loading raw tool output into context.**
Test logs and dependency graphs belong on the filesystem. Loading them in full pushes the session into Transition Zone before meaningful work begins.

**Reusing environments across tasks.**
Environments are cattle, not pets. A shared environment carries state from previous tasks. Provision fresh for each task.


# Harness — Reference

Deep-dive reference for the `harness` skill. See [SKILL.md](SKILL.md) for the overview,
scope, and quick start. See [EXAMPLES.md](EXAMPLES.md) for worked session walkthroughs.

---

## Dev Container — Full Specification

### Standard devcontainer.json shape

```json
{
  "name": "task-environment",
  "image": "mcr.microsoft.com/devcontainers/python:3.12",
  "features": {
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "ghcr.io/devcontainers/features/powershell:1": {}
  },
  "postCreateCommand": "uv sync --frozen",
  "remoteEnv": {
    "UV_CACHE_DIR": "/tmp/uv-cache"
  },
  "customizations": {
    "vscode": {
      "extensions": ["ms-python.python", "charliermarsh.ruff"]
    }
  }
}
```

**Required features for this project:**
- Python 3.12 base image (matches `pyproject.toml` `requires-python`)
- `github-cli` feature (needed for `gh pr`, `gh issue`)
- `powershell` feature (needed for `.ps1` scripts in `.github/scripts/`)
- `uv sync --frozen` as `postCreateCommand` (installs exact lock-file versions)

**Never:**
- Use `pip install` in `postCreateCommand` — UV only (ADR rule 1)
- Share one Dev Container across two tasks — containers are cattle, not pets

### Offline development (Rancher Desktop)

```bash
# Build locally
docker build -t task-env .devcontainer/
docker run --rm -it -v $(pwd):/workspace task-env bash
```

---

## Planner / Generator / Evaluator — Full Configuration

### Planner responsibilities

The Planner owns the task graph. It reads the GitHub Issue and produces an ordered step
list before any code is written. The Planner never writes code.

**Planner output format:**

```
Step 1: [action] — [acceptance condition]
Step 2: [action] — [acceptance condition]
...
```

Each step must have a concrete, machine-verifiable acceptance condition. A step with
"looks right" as its acceptance condition is not a step — it is a deferred decision.

### Generator responsibilities

The Generator executes exactly one Planner step at a time. It writes code, runs tests,
and produces artefacts. It never self-evaluates — it only reports what the acceptance
condition says (pass or fail).

### Evaluator responsibilities

The Evaluator reviews one Generator output per turn. It must use an independent system
prompt focused on critique — never the same prompt as the Generator.

**Evaluator system prompt (canonical):**

```
You are the Evaluator in a Planner/Generator/Evaluator pipeline. Your job is to
critique the Generator's output — not to collaborate, refine, or help. You must:

1. Read the acceptance criterion for this step.
2. Read the Generator's output.
3. Decide: PASS or FAIL.
4. If FAIL: state the specific gap between the output and the criterion.
5. Do not suggest fixes — only identify the gap. The Generator re-runs after your report.

Acceptance criterion for this step:
<paste criterion here>
```

**Agreement bias trap:** If the Evaluator uses the same system prompt as the Generator,
it will agree with the Generator's rationalizations. The prompts must be independent.

---

## Context Management — Detailed Zone Table

| Token Range | Zone | Name | Agent Action |
|-------------|------|------|--------------|
| < 100k | Green | Smart Zone | Proceed normally |
| 100k–150k | Yellow | Approaching Transition | Complete current phase; compact before next |
| 150k–250k | Orange | Transition Zone | compact() immediately; do not start new phase |
| > 250k | Red | Dumb Zone | Context reset — write handoff artefact, start fresh |

### compact() protocol

1. Identify all tool call outputs in the current context.
2. For each large output (> 500 lines): write to filesystem, replace with a 3-line summary.
3. Call compact() — this organises cache hits.
4. Confirm context fill has dropped below 100k before continuing.

### Context reset protocol

When context fill exceeds 250k tokens:

1. Write the handoff artefact to disk:

   ```bash
   cat > .agents/handoff.md << 'EOF'
   # Session Handoff

   ## State at reset
   - Current step: <step N of M>
   - Files modified: <list>
   - Tests passing: <yes/no>
   - Next action: <what to do first in the new session>

   ## Open questions
   - <any unresolved decision>
   EOF
   ```

2. Start a new session with just `CONTEXT.md`, `AGENTS.md`, and the handoff artefact.
3. Re-read the GitHub Issue from the handoff — do not rely on memory.
4. Confirm all previously passing tests still pass before continuing.

---

## Tool-Call Offloading — Full Rules

| Output type | Size threshold | Offload location | What stays in context |
|-------------|---------------|------------------|-----------------------|
| Test output | > 50 lines | `logs/test-output.txt` | Exit code + first 5 failure lines |
| Dependency graph | any | `docs/arch/deps.json` | Summary: module count + circular count |
| Build artefacts | any | filesystem only | None |
| GitHub API responses | > 20 items | `logs/gh-output.json` | Summary: count + first 3 items |

**Rule:** Never load raw tool output into context when it exceeds the threshold. An agent
that violates this rule will push the session into the Transition Zone during orientation
and have no context budget left for implementation.

---

## Event Log — emitEvent Protocol

Log every significant state transition so the session can be reconstructed on reset:

```python
import json, datetime, pathlib


def emit_event(event_type: str, **data) -> None:
    log = pathlib.Path("logs/session.jsonl")
    log.parent.mkdir(exist_ok=True)
    entry = {"ts": datetime.datetime.utcnow().isoformat(), "type": event_type, **data}
    with log.open("a") as f:
        f.write(json.dumps(entry) + "\n")
```

**Required events:**

| Event | When | Required fields |
|-------|------|-----------------|
| `session_start` | First action in any session | `issue`, `context_fill` |
| `step_complete` | Each Planner step completes | `step`, `outcome` (PASS/FAIL), `context_fill` |
| `compact_triggered` | After calling compact() | `context_before`, `context_after` |
| `session_reset` | Before writing handoff and starting fresh | `handoff_path`, `context_fill` |


# Harness — Examples

Worked walkthroughs demonstrating the `harness` skill. See [SKILL.md](SKILL.md) for the
quick-start and [REFERENCE.md](REFERENCE.md) for the full Dev Container spec, PGE
configuration, and context management zone table.

---

## Example 1: Provisioning a Session for a Tracer Bullet Issue

**Context:** The `plan` skill has produced Issue #1 (tracer bullet: implement a streaming
endpoint). The agent must provision the harness before the `tdd` loop begins.

### Step 1 — Context fill check

```
Agent estimates context fill: ~22k tokens. Smart Zone — proceed.
```

### Step 2 — Session initialisation

Load in order:
1. `CONTEXT.md` — confirm bounded context and module map for the target feature.
2. `AGENTS.md` — confirm skill sequence for this issue type.
3. GitHub Issue #1 body — tracer bullet description and acceptance criteria.

```python
emit_event("session_start", issue=1, context_fill=22000)
```

### Step 3 — Provision Dev Container

```bash
# Verify .devcontainer/devcontainer.json exists
cat .devcontainer/devcontainer.json

# For local development: build and run
docker build -t task-env .devcontainer/
docker run --rm -it -v $(pwd):/workspace task-env bash

# Inside container: verify toolchain
python --version   # → Python 3.12.x
uv --version       # → uv 0.x.x
gh --version       # → gh 2.x.x
pwsh --version     # → PowerShell 7.x.x
uv run pytest --collect-only | tail -5   # → N tests collected
```

### Step 4 — Configure PGE split

**Planner** reads Issue #1 and produces the step list:

```
Step 1: Create tests/test_streaming.py with a failing test for GET /stream Content-Type
        → Acceptance: uv run pytest -x fails with ImportError or AssertionError

Step 2: Implement src/streaming/__init__.py with a minimal SSE handler returning
        Content-Type: text/event-stream
        → Acceptance: uv run pytest -x passes test_streaming_content_type

Step 3: REFACTOR — apply deep module checklist; no new public methods
        → Acceptance: uv run pytest passes; diff shows no new public methods added
```

**Generator** executes Step 1. **Evaluator** checks the acceptance condition independently.

### Step 5 — Monitor context fill between steps

After Step 1 completes:

```python
emit_event("step_complete", step=1, outcome="PASS", context_fill=35000)
# 35k — well within Smart Zone. Proceed to Step 2.
```

After Step 2 completes:

```python
emit_event("step_complete", step=2, outcome="PASS", context_fill=80000)
# 80k — approaching Transition Zone. Run compact() before Step 3.
```

---

## Example 2: Context Reset Mid-Session

**Context:** A session implementing Issue #5 (large feature) has reached 260k tokens.
The compact() trigger at 150k was missed. Now in the Dumb Zone.

### Step 1 — Detect the zone

```
Agent: context fill is 260k tokens — Dumb Zone. Context reset required.
```

### Step 2 — Write the handoff artefact

```bash
cat > .agents/handoff.md << 'EOF'
# Session Handoff — Issue #5

## State at reset
- Current step: 4 of 7
- Files modified: src/domain/service.py, tests/test_service.py
- Tests passing: yes (uv run pytest exits 0 as of last check)
- Next action: implement Step 5 — add error handling to DomainService.process()

## Steps completed
1. ✅ RED: test_service_processes_valid_input — PASSED
2. ✅ GREEN: DomainService.process() minimal implementation
3. ✅ REFACTOR: removed internal helper, consolidated into process()
4. ✅ RED: test_service_raises_on_invalid_input — PASSED

## Open questions
- Should InvalidInput be a ValueError subclass or a custom exception?
  Current choice: ValueError (stdlib first). Still open if reviewer disagrees.
EOF
```

```python
emit_event("session_reset", handoff_path=".agents/handoff.md", context_fill=260000)
```

### Step 3 — Start fresh session

New session loads:
1. `CONTEXT.md`
2. `AGENTS.md`
3. `.agents/handoff.md`

```bash
# Confirm tests still pass in the new session before continuing
uv run pytest -x
# → PASSED (Step 3 confirmed clean)
```

Continue from Step 5 with a context fill of ~15k.

---

## Example 3: Evaluator Blocking a GREEN Regression

**Context:** Step 2 (implement the handler). Generator writes `StreamHandler` with a new
public method `close()` that no test covers.

```python
class StreamHandler:
    def handle(self, path: str, query: dict, wfile) -> None:
        wfile.write(b"HTTP/1.1 200 OK\r\n")
        wfile.write(b"Content-Type: text/event-stream\r\n\r\n")
        wfile.flush()

    def close(self) -> None:  # ← no test for this
        pass
```

Acceptance criterion for Step 2: "Content-Type header is `text/event-stream`. Test passes."

```bash
uv run pytest -x
# → PASSED
```

Generator reports PASS. Evaluator review:

```
FAIL — A new public method StreamHandler.close() was added. The acceptance criterion
for this step does not include close(). New public behaviour without a failing test is a
GREEN phase violation (tdd/SKILL.md Rule: do not anticipate future tests).
Remove close() or add a RED test for it first.
```

Generator removes `close()`. Re-run:

```bash
uv run pytest -x
# → PASSED
```

Evaluator:

```
PASS — StreamHandler exposes only handle(). Content-Type is set correctly. No
unapproved public methods.
```

Step 2 complete.


