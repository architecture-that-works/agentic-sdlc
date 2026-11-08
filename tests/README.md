# Testing Guide

Conventions for writing and running the pytest suite in this folder. Referenced from
`AGENTS.md` § Conditional Context as "testing conventions, fixtures, coverage floor."

## Running the Suite

```bash
# Quick pass — same command CI uses:
uv run pytest

# With coverage (required before committing):
uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80

# Stop on first failure:
uv run pytest -x

# Run a single file:
uv run pytest tests/test_main.py
```

Coverage floor is 80% (`--cov-fail-under=80`). The CI gate fails below this threshold.

## File-Mirroring Rule (Test Parity)

`tests/` mirrors the structure of `src/` and `tools/` exactly. Every source module must have a corresponding test file.

```
src/main.py               → tests/test_main.py
src/config.py             → tests/test_config.py   (if config logic exists)
src/utils/m_log.py        → tests/utils/test_m_log.py
src/utils/m_error_formatter.py → tests/utils/test_m_error_formatter.py
src/tools/commit.py       → tests/tools/test_commit.py
src/tools/setup.py        → tests/tools/test_setup.py
```

**Rule 3 of AGENTS.md** enforces this: a PR that adds a new `src/**/*.py` or `tools/*.py` without a matching test file will be rejected.

## conftest.py — Shared Fixtures

`tests/conftest.py` defines fixtures available to every test in the suite. Add project-wide fixtures here; keep module-local fixtures in the test file itself.

**`reset_logging` (autouse=True)**
Clears logging state between every test — prevents handler accumulation when tests run in the same process. This fixture runs unconditionally; never disable it.

**`mock_settings` (on demand)**
Overrides pydantic-settings values via `monkeypatch` to prevent tests from reading `.env` from disk:

```python
def test_something(mock_settings):
    # settings.log_profile == "TEST"
    # settings.google_api_key == "test-key"
    ...
```

Use `mock_settings` in any test that exercises code paths gated on `Settings` fields. Do not load real `.env` values in tests — that breaks CI on clean runners.

## Fixture Patterns

**`monkeypatch` for env vars and module state**
`monkeypatch` is the standard way to swap config values, environment variables, and module-level singletons for a single test:

```python
def test_with_custom_env(monkeypatch):
    monkeypatch.setenv("LOG_PROFILE", "DEBUG")
    monkeypatch.setattr("src.config.settings.log_profile", "DEBUG")
    ...
```

Prefer `monkeypatch` over `unittest.mock.patch` for settings overrides — the attribute is restored automatically after the test.

**Mocking at system boundaries only**
Per the `implement` skill: mock only at system boundaries — external APIs, databases, `datetime.now`, and filesystem I/O. Never mock internal collaborators. Tests that mock collaborators pass without proving behaviour.

```python
# ✅ Mock at the HTTP boundary
def test_handler_returns_200(monkeypatch):
    # patch the external call, test through the real handler
    ...


# ❌ Mock an internal collaborator
def test_handler(monkeypatch):
    monkeypatch.setattr("src.main.SomeInternalHelper", FakeHelper)
    ...
```

**`tmp_path` for filesystem tests**
Use pytest's built-in `tmp_path` fixture for tests that write or read files. Never write to the repository root or a hardcoded `/tmp` path — it races when tests run in parallel.

## Test Naming and Structure

- Test files: `test_<module>.py`
- Test functions: `test_<behaviour>` — describe what the test asserts, not what it calls
- Group related tests in a class only when shared setup (e.g. a `setup_method`) justifies it; otherwise use plain functions

```python
# ✅ Describes behaviour
def test_order_total_includes_tax(): ...


# ❌ Describes a call
def test_order_total(): ...
```

## Parametrize for Data-Driven Tests

Use `@pytest.mark.parametrize` when the same assertion applies across multiple inputs:

```python
@pytest.mark.parametrize(
    "profile,level",
    [
        ("DEBUG", logging.DEBUG),
        ("INFO", logging.INFO),
        ("TEST", logging.WARNING),
    ],
)
def test_log_level_from_profile(profile, level, monkeypatch):
    monkeypatch.setattr("src.config.settings.log_profile", profile)
    ...
```

Avoid copy-pasting similar test functions — parametrize instead.

## What Tests Live Where

| Path | What goes here |
|------|----------------|
| `tests/test_main.py` | HTTP handler and entry point behaviour |
| `tests/utils/test_m_*.py` | Generic utility module tests |
| `tests/tools/test_*.py` | Developer tool tests (`commit`, `setup`) |
| `tests/orchestrator/` | Orchestrator module tests — mirrors `.github/orchestrator/` |
| `tests/checks/` | Validator tests — mirrors `.github/checks/` |
| tests/test_copier_template.py | Template generation and structure tests — template-only; copier excludes it from generated projects |
| `tests/conftest.py` | Project-wide fixtures only |

## Testing the orchestrator module

`Orchestrator.psd1` exports an explicit list, so private functions are genuinely
unreachable from a test. Dot-sourcing the `.psm1` populates *nothing* in the caller's
scope — not even `Invoke-Orchestration`, which is defined in that file — and
dot-sourcing a single stage file resolves its functions but not the module-scoped
`$Kanban*` variables they read.

Run inside module scope instead:

```powershell
Import-Module .\.github\orchestrator\Orchestrator.psd1 -Force
& (Get-Module Orchestrator) { Invoke-SomePrivateFunction -IssueNumber 1 }
```

`tests/orchestrator/test_plan.py` is the worked example, and it is roughly five times
faster this way.

**Never widen `FunctionsToExport` to make a test pass.** That is how an explicit API
list decays back to `'*'`; `check-module-api.ps1` fails the build if an export goes
uncalled or a private function is called from outside.

## Evals

An **eval** is a pytest test marked `eval` that scores one model-facing component (a
prompt, a skill, an LLM call) against a golden dataset with [DeepEval](https://deepeval.com)
metrics, judged by Claude. It answers a question unit tests cannot: *is the output still
good?* The review stage judges a *change* against its issue; an eval judges a *component*
against fixed inputs — neither repeats the other.

```bash
uv run pytest -m eval                            # every eval (calls Claude)
uv run pytest -m eval tests/evals/test_commit_eval.py
uv run pytest                                    # default run: evals deselected, no model calls
```

The judge is `ClaudeJudge` (`tests/evals/claude_judge.py`): Claude CLI first — it works with
the same `CLAUDE_CODE_OAUTH_TOKEN` the pipeline uses — then the Anthropic SDK when
`ANTHROPIC_API_KEY` is set. DeepEval's telemetry is forced off and its own pytest plugin is
disabled: evals are plain pytest, with no Confident AI login.

**Writing an eval**

1. **Pick the component** and the behaviour to protect. One eval file per component:
   `tests/evals/test_<component>_eval.py` with `pytestmark = pytest.mark.eval`.
2. **Write goldens** — 3–5 representative inputs in `tests/evals/goldens/<component>.jsonl`,
   one DeepEval golden per line (`input`, and optionally `expected_output`, `context`,
   `expected_tools`, `additional_metadata`). Load them with `eval_goldens.load_goldens`.
3. **Choose metrics** — `GEval` with `evaluation_steps` that restate the component's own
   rules (say what is *intended* too, or the judge marks the design down);
   `AnswerRelevancyMetric` / `FaithfulnessMetric` for grounded answers;
   `ToolCorrectnessMetric` for agents (deterministic from the tool trace). Pass
   `model=judge` to every LLM-judged metric. For every step that could penalise
   formatting or borderline-but-valid choices, add an explicit guard: "Do not deduct for
   leading or trailing whitespace — treat the output as if it were stripped" and "Do not
   deduct for a borderline-but-valid choice; only a clear violation should deduct." The
   judge's stated reasoning and the threshold it enforces must agree — if the judge's own
   words call a deduction "minor" but the threshold fails the case, tighten the rubric
   wording or lower the threshold.
4. **Score with the `evaluate` fixture** — `evaluate(LLMTestCase(...), [metrics])` measures,
   records and asserts; a failure lists each metric's score, threshold and reason.
5. **Set thresholds from real runs** — start at DeepEval's 0.5, run a few times, then raise
   to just below the observed scores. If the judge consistently scores compliant outputs
   at ~0.60, set the threshold at 0.6, not 0.7 — a threshold set above the judge's
   empirical scoring floor for valid outputs is a flake, not a gate.
6. **Prove the gate has teeth** — add a canary that degrades the prompt and asserts the
   metric fails (`test_a_degraded_prompt_fails_the_eval`).
7. **Gate it in CI** — add the component's path to `MODEL_FACING` in the `eval-scope` job of
   `.github/workflows/checks.yml`.

**Results** — every metric score becomes one OpenTelemetry GenAI `gen_ai.evaluation.result`
record, following a local-first, OTLP-opt-in egress pattern: by default they land in
`<Settings.log_dir>/evals/*.jsonl`; with `OTEL_EXPORTER_OTLP_ENDPOINT` set they are exported
over OTLP instead (one span per eval case, one event per metric), which MLflow ≥ 3.6 or any
OTel backend ingests. CI also uploads a JUnit report
(`eval-results` artifact).

**In CI** — the `eval` job runs only on PRs that change a model-facing path; skipped, it
reports success, so it can be a required check (`task protect`). The pipeline's ship stage
never merges a PR with a red check.

## The local gate

Six commands, all clean, before any push:

```powershell
uv run pytest ; uv run ruff check . ; uv run ruff format . ; uv run pyright
pwsh .github/checks/check-script-paths.ps1
pwsh .github/checks/check-doc-paths.ps1
pwsh .github/checks/check-module-api.ps1
```

Self-review is not a gate. It approved two changes CI then rejected (#154, #192): a
reviewer reads the diff, it never executes it.
