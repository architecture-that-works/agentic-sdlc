# Testing Guide

The map of what is tested where and how, then how to run each kind of test, then what a
generated project carries. Referenced from `AGENTS.md` § Conditional Context.

Tests follow behaviour: a journey per path an issue takes, a table per decision the
orchestrator makes, the application by what it does. A source file needs no test file of
its own; a test is named after the behaviour it holds.

## The map

One folder per kind of test. Each folder of the repository, and where it is tested:

| Folder of the repository | Tested in | How |
|---|---|---|
| `src/` (`main.py`, `config.py`), `src/utils/`, `src/tools/` | `tests/app/` | pytest, by what the code does: the HTTP server answers requests, the schema accepts and rejects states, the tools write commits and fill in a project. Counted by the 80% coverage gate for `src/` |
| `.github/orchestrator/` | `tests/journeys/` | Pester 5: a journey per path through `Invoke-Orchestration`, asserting what the owner sees (§ Testing the orchestrator) |
| `.github/orchestrator/` — its decisions | `tests/decisions/` | Pester 5: a table per decision, a row per input, asserting the outcome through the module (`OwnerComment.Tests.ps1`: what an owner comment leads to in each pipeline state) |
| `.github/orchestrator/lib/Config.ps1` — `$PipelineStates` | `tests/journeys/StateMachine.Tests.ps1` | Pester 5: runs last and checks every label transition the tables and journeys caused |
| the orchestrator's outside seams (`gh`, the engine, the repository) | `tests/fakes/` | the fakes the journeys and tables run on — not tests themselves |
| `.github/tasks/` | `tests/journeys/` (the stages the commands start); `tests/template/` (`test.ps1` in a generated project) | Pester; pytest |
| `.github/workflows/`, `Dockerfile`, `.dockerignore`, `.github/ISSUE_TEMPLATE/`, `.github/PULL_REQUEST_TEMPLATE.md`, `CONTRIBUTING.md` | `tests/repository/` | pytest, reading the files: a workflow job, a template heading, a Dockerfile stage |
| `.github/checks/` | `tests/checks/` | pytest, running each check on a temporary repository (until decision tables replace it) |
| `.agents/skills/` | `tests/evals/` | pytest `-m eval`: a stage's instructions on a stored case, on the stage's model (§ Evals) |
| `copier.yml`, the `.jinja2` twins, what travels | `tests/template/` | pytest: generates real projects and runs their tests and checks |
| `.devcontainer/` | `tests/template/` | pytest: the generated project's container definition |
| `docs/adr/`, `AGENTS.md`, `CONTEXT.md` and the other documents | `.github/checks/` (`check-references.ps1`, `check-module-map.ps1`) | the checks job, not a test |

`tests/conftest.py` holds the fixtures every pytest test shares (§ conftest.py).

## Running each kind

One command runs every test — pytest, then Pester — and is the command CI's `test` job,
the implement stage's verification and ship's local CI all run:

```bash
pwsh -NoProfile -File .github/tasks/test.ps1
```

It runs `uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80`, then one
Pester run over every decision table and every journey with the line coverage Pester
measures for `.github/orchestrator/` (reported, not gated), the state-machine report last.
It prints the Pester version it runs on, before the run and on Pester's summary line, so a
difference between a machine and the runner shows in the output. It ends with one line per
runner: passed or failed, how long it took, and Pester's coverage, and exits non-zero when
either runner failed. When there are Pester tests it needs Pester 5; without it, it stops
and prints the line that installs it:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

With no Pester test folder — a generated project — it runs pytest alone and says Pester was
not run.

**The application** (pytest):

```bash
uv run pytest tests/app                                              # quick pass
uv run pytest tests/app --cov=src --cov-report=term-missing --cov-fail-under=80
uv run pytest -x tests/app/test_main.py                              # one file, stop on first failure
```

The coverage floor is 80% (`--cov-fail-under=80`); the `test` job fails below it.

**The repository's files, the checks and the template** (pytest):

```bash
uv run pytest                              # every pytest test; evals deselected
uv run pytest tests/template               # generates projects; needs pwsh
```

**The orchestrator** (Pester) — see § Testing the orchestrator. **The evals** — see § Evals.

## What travels to a generated project

A project generated with Copier carries the tests of its own code only: `tests/app/`,
`tests/README.md` (this file), `tests/conftest.py` and the one test command, which runs
pytest alone there. Every other test folder tests the template — its orchestrator, its
workflows, its checks and its skills — and `copier.yml` `_exclude` keeps it home:
journeys, decisions, fakes, repository, template, evals and checks. The orchestrator, the
commands and the checks travel; their tests do not. The template smoke test generates a
project and asserts exactly this: it holds `tests/app/` and none of the other folders, its
test command passes, the orchestrator module loads and every check passes. A project
without evals keeps a green `eval` check: an eval target whose eval file is missing never
runs.

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

## Testing the orchestrator: journeys and decision tables

The orchestrator is tested the way an issue travels through it. A **journey** is a Pester 5
file in `tests/journeys/`, named after the path it follows (`Refine.Tests.ps1`: refine →
architect → plan; `Build.Tests.ps1`: implement → review → ship). It enters only through the
conductor, `Invoke-Orchestration -IssueNumber <n> -From refine|implement|comment`, and asserts
only what the owner sees: the issue's label, the kind of comments posted (a 🤖 signal and its
heading, or a · noise line), the pull request's state, and what was pushed to the remote.
Nothing in a journey reaches into a private function.

A **decision table** is a Pester 5 file in `tests/decisions/`, named after one decision the
orchestrator makes. Each row is one input — a pipeline state, say — and the outcome the owner
sees for it, entered through the same conductor (`OwnerComment.Tests.ps1`: what an owner's
comment leads to in each state). A table asserts what the decision produces, never the rows of
`$PipelineStates`: the label table is written once, in `lib/Config.ps1`, and a second copy is
removed, not guarded by a test. A table dot-sources `tests/journeys/Journey.ps1` and runs on
the same fakes.

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
transition the tables and journeys caused, fails — naming it — on one that `$PipelineStates` in
`lib/Config.ps1` does not allow, and lists the designed transitions (the `AllowedFrom` entries)
that no journey has exercised yet. Never widen `AllowedFrom` to make it pass.

Pester alone, without pytest or coverage:

```powershell
Invoke-Pester tests/journeys                               # every file, in file-name order
Invoke-Pester tests/journeys/Build.Tests.ps1 -Output Detailed
Invoke-Pester tests/decisions -Output Detailed             # every decision table
```

Run alone, a journey or table file passes on its own. Only `.github/tasks/test.ps1` is sure to
run the state-machine report after every table and journey: it lists them first, sorted by
name, and the report last.
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
only the evals whose files changed and whose eval file exists (a generated project has
none); skipped, it reports success, so it can be a required
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
