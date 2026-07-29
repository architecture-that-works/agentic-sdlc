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
