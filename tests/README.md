# Testing Guide

Conventions for writing and running the tests in this folder: the pytest suite, and the
orchestrator's journeys in Pester. Referenced from `AGENTS.md` § Conditional Context as
"testing conventions, fixtures, coverage floor."

## Running the Suite

One command runs every test — pytest, then Pester — and is the command CI's `test` job,
the implement stage's verification and ship's local CI all run:

```bash
pwsh -NoProfile -File .github/tasks/test.ps1
```

It runs `uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80`, then one
Pester run over `tests/journeys/` with the line coverage Pester measures for
`.github/orchestrator/` (reported, not gated), and ends with one line per runner: passed or
failed, how long it took, and Pester's coverage. It exits non-zero when either runner failed.
It needs Pester 5; without it, it stops and prints the line that installs it:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

pytest alone:

```bash
# Quick pass:
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
| `tests/journeys/` | The orchestrator's journeys, in Pester — one file per path an issue takes |
| `tests/fakes/` | The fakes the journeys run on: GitHub, the engine, a git repository |
| `tests/checks/` | Validator tests — mirrors `.github/checks/` |
| tests/test_copier_template.py | Template generation and structure tests — template-only; copier excludes it from generated projects |
| `tests/conftest.py` | Project-wide fixtures only |

## Testing the orchestrator: journeys

The orchestrator is tested the way an issue travels through it. A **journey** is a Pester 5
file in `tests/journeys/`, named after the path it follows (`Refine.Tests.ps1`: refine →
architect → plan; `Build.Tests.ps1`: implement → review → ship). It enters only through the
conductor, `Invoke-Orchestration -IssueNumber <n> -From refine|implement|comment`, and asserts
only what the owner sees: the issue's label, the kind of comments posted (a 🤖 signal and its
heading, or a · noise line), the pull request's state, and what was pushed to the remote.
Nothing in a journey reaches into a private function.

The orchestrator has three outside seams, and each has one fake in `tests/fakes/`:

| Fake | Stands in for | What a test does with it |
|------|---------------|--------------------------|
| `tests/fakes/GitHub.ps1` | the `gh` command | Seeds issues and comments, reads labels, comments and pull requests back. It holds issues, labels, comments, pull requests and check runs in memory, records what changed, and records every label change as a transition. A `gh` call it does not know fails the test and names the call. |
| `tests/fakes/Engine.ps1` | `Invoke-EngineTask`, the one function that starts a model | Scripts what each Task returns, in order: an outcome, a reply, a checked answer, refused edits, and for an implement task the files it edits. A Task with nothing scripted fails the test and names it. |
| `tests/fakes/Repo.ps1` | the repository | Gives the journey a temporary git repository with a bare remote; git runs for real, so the test asks the remote what was pushed. |

No journey writes its own stand-in for `gh`: every one uses the fake GitHub. The fakes replace
`gh` and `Invoke-EngineTask` inside the module's scope with Pester mocks, so the
orchestrator's own code runs unchanged and the `Engine` setting is not touched.
`tests/journeys/Journey.ps1` loads the module once per run (only when it is not loaded yet)
and starts each journey with a fresh set of fakes:

```powershell
BeforeAll   { . (Join-Path $PSScriptRoot 'Journey.ps1') }
BeforeEach  { $script:repo = Start-Journey -Name 'Build: held for the owner' }
AfterEach   { Stop-Journey $script:repo }
It 'holds a change to a governance file for the owner' {
    Add-FakeIssue -Number 12 -Title 'Name the journeys' -Body (New-PlannedIssueBody -Number 12) -Labels 'agent:backlog'
    Add-EngineResult -Task ImplementSmall -Edits @{ 'CONTEXT.md' = '...' } -Reply '- Left undone: none'
    Add-EngineResult -Task CommitMessage -Reply 'docs(#12): name the journeys'
    Add-EngineResult -Task Review -Answer @{ verdict = 'approved'; report = 'ok' }
    Invoke-Orchestration -IssueNumber 12 -From implement
    Get-FakePipelineLabel 12 | Should -Be 'human:approval'
    Assert-JourneyClean
}
```

`tests/journeys/StateMachine.Tests.ps1` runs last in the same Pester run. It reads every label
transition the journeys caused, fails — naming it — on one that `$PipelineStates` in
`lib/Config.ps1` does not allow, and lists the designed transitions (the `AllowedFrom` entries)
that no journey has exercised yet. Never widen `AllowedFrom` to make it pass.

Pester alone, without pytest or coverage:

```powershell
Invoke-Pester tests/journeys                               # every file, in file-name order
Invoke-Pester tests/journeys/Build.Tests.ps1 -Output Detailed
```

Run alone, a journey file passes on its own. Only `.github/tasks/test.ps1` is sure to run the
state-machine report after every journey: it lists the journeys first and the report last.
`Invoke-Pester tests/journeys` runs the files in file-name order, so a journey whose name sorts
after `StateMachine` runs after the report, and the report misses its transitions. `$env:JOURNEY_LOG = 1` shows the orchestrator's own
log lines while a journey runs. The Python tests the journeys replace stay readable in git at
commit `2d9477e` and remain the specification of what the later journeys must cover.

**Never widen `FunctionsToExport` to make a test pass.** That is how an explicit API
list decays back to `'*'`; `check-orchestrator-api.ps1` fails the build if an export goes
uncalled or a private function is called from outside.

## Evals

An **eval** is a pytest test marked `eval` that runs one stage's instructions on a stored
case, on the model that stage uses, and checks the outcome in code. There is no second
model, no rubric and no pass mark: the check reads what the orchestrator or the owner
reads, so a red eval means the stage's instructions produced an outcome the pipeline would
mishandle. The review stage judges a *change* against its issue; an eval checks a *stage*
against fixed cases. Neither repeats the other.

**The four evals** — one file each in `tests/evals/`, with their stored cases in
`goldens/<target>.jsonl`:

| Eval | Runs | Checks in code |
|------|------|----------------|
| `test_review_eval.py` | the review skill on an issue plus a change, three times per case | The verdict, read the way `stages/Review.ps1` reads it (the checked `verdict` field of the result's `structured_output`, under `.agents/skills/review/answer.schema.json`), is right in all three runs: approve `clean`, reject `planted-bug` |
| `test_refine_eval.py` | the grill probe (`refine/scripts/grill.ps1 -Trace`) on an under-specified issue | Every tool the case expects was called; every open question has a recommendation and two alternatives; the agent brief names no source file (no `.py` or `.ps1` name, no `:<line>` reference) |
| `test_implement_eval.py` | the implement skill on a finished mini-task | The closing note has a line starting `Left undone:` and one starting `Issues discovered:` |
| `test_commit_eval.py` | `src/tools/commit.py` on a staged diff | The first line is `<type>(<scope>): <description>` or `<type>: <description>` with a listed type, at most 72 characters, no trailing period; no markdown fence, no Co-Authored-By or Signed-off-by trailer |

The skill under test runs on its stage's model, read from the orchestrator by
`stage_models()` in `tests/evals/stage_models.py`: one `pwsh` call that imports the
module and asks `Get-TaskModel` for the tasks `Review` and `ImplementLarge` on the engine
the `Engine` setting names. The refine eval's grill probe imports the module too, so it
runs on the `Refine` task's model and the `MaxTurns_Refine` budget, as the stage does.
Never write a model ID in `tests/evals/`. Without `pwsh`, an eval fails rather
than skips: a skipped gate reports green.

**Review cases come in twins.** A case with a defect is added together with a clean twin
that differs only in the defect — the same issue, tests and change, one line apart
(`test_the_review_cases_are_twins` holds the rule). Approving one and rejecting the other
can only be explained by that line. A new pair comes from a change a reviewer really got
wrong, not from an invented one.

**Adding an eval**

1. **Store a case** — one JSON object per line in `tests/evals/goldens/<target>.jsonl`,
   with an `id` and only the fields the check reads. Load it with
   `eval_goldens.load_goldens`.
2. **Write the check** — a small function in the eval's file that takes the stage's output
   and returns what is wrong with it (or whether it is right). Give it one test that needs
   no model, over one stored output that passes and one that fails. That test carries no
   mark, so it runs in the default suite.
3. **Write the eval test** — mark it `@pytest.mark.eval`, run the stage on each stored
   case on `stage_models()[<stage>]`, and assert the check.
4. **Gate it in CI** — give the target a `PATHS_<TARGET>` regex in the `eval-scope` job of
   `.github/workflows/checks.yml` naming exactly the files the eval reads: the stage's
   entry file or prompt source, its eval test and its stored cases, plus a run step in the
   `eval` job. `PATHS_SHARED` (`eval_goldens.py`, `stage_models.py` and
   `.github/orchestrator/lib/Config.ps1`) fires every target.

**Running them**

```bash
uv run pytest -m eval                            # every eval (calls Claude)
uv run pytest -m eval tests/evals/test_review_eval.py
uv run pytest                                    # default run: evals deselected, checks' own tests run
```

The Claude CLI must be installed and signed in (in CI, with `CLAUDE_CODE_OAUTH_TOKEN`).

**In CI** — the `eval` job runs only on a PR that changes a file an eval reads, and then
only the evals whose files changed; skipped, it reports success, so it can be a required
check (`pwsh -NoProfile -File .github/tasks/protect.ps1`). The pipeline's ship stage never merges a PR with a red check.

## The local gate

Six commands, all clean, before any push:

```powershell
pwsh -NoProfile -File .github/tasks/test.ps1 ; uv run ruff check . ; uv run ruff format . ; uv run pyright
pwsh .github/checks/check-references.ps1
pwsh .github/checks/check-orchestrator-api.ps1
```

Self-review is not a gate. It approved two changes CI then rejected (#154, #192): a
reviewer reads the diff, it never executes it.
