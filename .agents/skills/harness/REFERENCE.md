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
