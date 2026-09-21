# HARNESS.md — Development Environment and Context Health

The workspace an agent operates in: where code runs, and how a session stays inside the
context window it can actually reason in. Not a stage — no issue ever sits in a "Harness"
lane (ADR-015).

Load this when provisioning an environment, or when a session is long enough that context
fill is becoming the constraint.

## Environment

The Dev Container **is** the environment spec — `.devcontainer/devcontainer.json` and
`.devcontainer/docker-compose.devcontainer.yml`. Read those rather than reproducing them
here; a copy in a document is a copy that drifts.

What matters about it, and what a change must preserve:

| Invariant | Why |
|---|---|
| Base image matches `requires-python` in `pyproject.toml` | A version skew between container and lockfile surfaces as an unreproducible test failure |
| `uv sync --frozen` as `postCreateCommand` | Installs exact lockfile versions. Never `pip install` — UV only |
| `github-cli` and `powershell` features present | `.github/tasks/` and `.github/orchestrator/` are PowerShell; the orchestrator shells out to `gh` |
| One container per task | Containers are cattle. A container reused across two issues carries the first one's state into the second |

Verify a workspace before starting:

```powershell
pwsh .github/checks/verify-settings.ps1
```

It checks the toolchain, `pyproject.toml`, and that `.devcontainer/devcontainer.json` and
`.claude/settings.json` are valid JSON. `.claude/` is absent from generated projects by
design (copier `_exclude`), and the check passes without it.

## Context health

An agent degrades well before it runs out of window. These thresholds are the trigger
points, not aspirations — act on the zone you are in rather than on how the session feels.

| Token fill | Zone | Action |
|---|---|---|
| < 100k | Smart | Proceed |
| 100k–150k | Approaching transition | Finish the current stage; compact before starting the next |
| 150k–250k | Transition | Compact now. Do not start a new stage |
| > 250k | Dumb | Reset. Write the handoff and start a fresh session |

### Compacting

1. Find the large tool outputs in context — test logs, file dumps, command output.
2. Write each one over 500 lines to disk; replace it in context with a three-line summary
   and the path.
3. Compact.
4. Confirm fill is back under 100k before continuing.

Offloading is the part that actually recovers room. A 2,000-line pytest log summarised as
"41 passed, 2 failed — `tests/utils/test_m_http.py::test_retry`, log at `<path>`" costs
three lines instead of two thousand, and the path keeps the detail one command away.

### Resetting

Past 250k, compacting is not enough — start a fresh session. The handoff goes **in the
issue body**, not in a local file: the issue is the single cross-runtime state carrier
(ADR-011), and a local handoff file is invisible to the next runner.

Record in the `AGENT-STATE` block and the issue body:

- which stage is in progress, and the step within it
- files modified so far, and whether the suite is currently green
- the single next action
- any question that arose and is still open — as `open_questions[]`, so the refine stage
  can pick it up rather than the next session rediscovering it

Then start the new session on `CONTEXT.md` → `AGENTS.md` → the issue, and re-run the suite
before continuing. Confirming green is cheaper than debugging a regression inherited from a
session you can no longer see.

## Keeping a long session honest

The failure this protects against is an agent grading its own work. Two habits do most of
the work, and neither needs machinery:

- **State the acceptance condition before writing the code**, in a form that can be checked
  by running something. "Looks right" is not an acceptance condition; it is a deferred
  decision.
- **Check the output against that condition, not against the intent.** New public surface
  that no test covers is a GREEN-phase violation even when the suite passes — see
  `.agents/skills/implement/SKILL.md`.

A dedicated Planner/Generator/Evaluator split and a durable event log were specified for
this template but are implemented nowhere in `.github/orchestrator/`. They are tracked as
an open decision rather than described here as though they exist.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Continuing past 250k because the task is "nearly done" | The last 10% is where the expensive errors land |
| Writing the handoff to a local file | Invisible to the next runner; ADR-011 makes the issue body the carrier |
| Reusing one container across two issues | State leaks between tasks and the failure looks like flakiness |
| Keeping raw test logs in context | The cheapest tokens to recover, and almost always the largest block |
