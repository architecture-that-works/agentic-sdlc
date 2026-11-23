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
| `src/` (`main.py`, `config.py`), `src/utils/`, `src/tools/` | `tests/app/` | pytest, by what the code does: the HTTP server answers requests, the schema accepts and rejects states, the setup tool fills in a project. Counted by the 80% coverage gate for `src/` |
| `.github/orchestrator/` | `tests/journeys/` | Pester 5: a journey per path through `Invoke-Orchestration`, asserting what the owner sees (§ Testing the orchestrator) |
| `.github/orchestrator/` — its decisions | `tests/decisions/` | Pester 5: a table per decision, a row per input, asserting the outcome through the module (§ Testing the orchestrator) |
| `.github/orchestrator/lib/Config.ps1` — `$PipelineStates` | `tests/journeys/StateMachine.Tests.ps1` | Pester 5: runs last, checks every label transition the tables and journeys caused, and that each designed transition was caused |
| `.github/orchestrator/Orchestrator.psd1` — `FunctionsToExport` | `tests/journeys/ExportReach.Tests.ps1` | Pester 5: runs last and fails, naming it, on each exported function no journey or table reached |
| the orchestrator's outside seams (`gh`, the engine, the repository) | `tests/fakes/` | the fakes the journeys and tables run on — not tests themselves |
| `.github/tasks/` | `tests/journeys/Commands.Tests.ps1` (sync, setup, protect, run in-process on the fake GitHub); `tests/journeys/` (the stages the other commands start); `tests/template/` (`test.ps1` in a generated project) | Pester; pytest |
| `.github/workflows/`, `Dockerfile`, `.dockerignore`, `.github/ISSUE_TEMPLATE/`, `.github/PULL_REQUEST_TEMPLATE.md`, `CONTRIBUTING.md` | `tests/repository/` | pytest, reading the files: a workflow job, a template heading, a Dockerfile stage |
| `.github/checks/` | `tests/decisions/` (`Check<Name>.Tests.ps1`, one per check) | Pester 5: a table per check, running it on a temporary repository and asserting its exit code and the violation lines it prints |
| `.agents/skills/` | `tests/evals/` | pytest `-m eval`: a stage's instructions on a stored case, on the stage's model (§ Evals) |
| `copier.yml`, the `.jinja2` twins, what travels | `tests/template/` | pytest: generates real projects and runs their tests and checks |
| `.devcontainer/` | `tests/template/` | pytest: the generated project's container definition |
| `docs/adr/`, `AGENTS.md`, `CONTEXT.md` and the other documents | `.github/checks/` (`check-references.ps1`, `check-module-map.ps1`) | the checks job, not a test |
| the PowerShell scripts as source: the Library/Runnable contract, the GraphQL budget, the engine boundary, the settings table | `.github/checks/` (`check-script-contract.ps1`, `check-no-graphql.ps1`, `check-engine-adapter.ps1`, `check-settings-read.ps1`) | the checks job, not a test |

`tests/conftest.py` holds the fixtures every pytest test shares (§ conftest.py).

## Running each kind

One command runs every test — pytest, then Pester — and is the command CI's `test` job,
the implement stage's verification and ship's local CI all run:

```bash
pwsh -NoProfile -File .github/tasks/test.ps1
```

It runs `uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80`, then one
Pester run over every decision table and every journey with the line coverage Pester
measures for `.github/orchestrator/`, the state-machine report last.
It prints the Pester version it runs on, before the run and on Pester's summary line, so a
difference between a machine and the runner shows in the output. It ends with one line per
runner: passed or failed, how long it took, and for Pester the measured line coverage and
the floor, and exits non-zero when either runner failed. When there are Pester tests it
needs Pester 5; without it, it stops and prints the line that installs it:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

With no Pester test folder — a generated project — it runs pytest alone and says Pester was
not run.

The Pester run holds three gates, so what the tables and journeys reached cannot slip back
unnoticed. The measured values are in the command's output; each limit is set in one place:

| Gate | Fails when | Set in |
|---|---|---|
| Coverage floor | the line coverage of `.github/orchestrator/` is below the floor, even when every test passed | `$CoverageFloor` in `.github/tasks/test.ps1` |
| Complete state machine | a designed transition — an `AllowedFrom` entry of `$PipelineStates` — was exercised by no table or journey | `$PipelineStates` in `.github/orchestrator/lib/Config.ps1`, checked by `tests/journeys/StateMachine.Tests.ps1` |
| Time budget | the run takes longer than the step allows | `timeout-minutes` of the step of the `test` job in `.github/workflows/checks.yml` that runs the command |

None of them applies in a generated project, where Pester does not run.

**The application** (pytest):

```bash
uv run pytest tests/app                                              # quick pass
uv run pytest tests/app --cov=src --cov-report=term-missing --cov-fail-under=80
uv run pytest -x tests/app/test_main.py                              # one file, stop on first failure
```

The coverage floor is 80% (`--cov-fail-under=80`); the `test` job fails below it.

**The repository's files and the template** (pytest):

```bash
uv run pytest                              # every pytest test; evals deselected
uv run pytest tests/template               # generates projects; needs pwsh
```

No Python test starts a PowerShell process except the template smoke test and the evals:
PowerShell code is tested by Pester.

**The orchestrator** (Pester) — see § Testing the orchestrator. **The evals** — see § Evals.

## What travels to a generated project

A project generated with Copier carries the tests of its own code only: `tests/app/`,
`tests/README.md` (this file), `tests/conftest.py` and the one test command, which runs
pytest alone there. Every other test folder tests the template — its orchestrator, its
workflows, its checks and its skills — and `copier.yml` `_exclude` keeps it home:
journeys, decisions, fakes, repository, template and evals. The orchestrator, the
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
file in `tests/journeys/`, named after the path it follows:

| File | Path |
|------|------|
| `Refine.Tests.ps1` | refine → architect → plan: nothing open, a question answered or left open with a follow-up, a body brought into the template's shape, an epic split into child issues, a plan proposing paths outside the writable ones, the questioning's tools and turn budget, an outsider's issue |
| `Build.Tests.ps1` | a queued issue through implement → review → ship: merged, held, failed verification, red or missing checks, a refused edit, the secrets denylist, a proposal, an issue shipped mid-round, the closing note carried in full and an implement run without a checked answer |
| `Conflict.Tests.ps1` | a branch that conflicts with the default branch: the post-merge conflict rounds, the agent settling the conflict, markers left behind, the default branch moving during a round |
| `Held.Tests.ps1` | a pull request held for the owner, or left by a failed issue: a revision started by a comment, the owner's merge or close |
| `Recovery.Tests.ps1` | a stalled issue moving again: re-entered after the stuck time and handed to the owner after the allowed re-entries (an issue without a carrier too), a state a person holds left alone, a pause on a spent usage allowance and its resume, an owner's comment on a failed issue or on one the agent holds |
| `Commands.Tests.ps1` | the Commands a person runs by hand: sync turns an ISSUES.md block into an issue on the board with its estimate and priority, refuses a block without a heading of the issue template or without its fence, and changes nothing in a dry run; setup writes the board's ids to `.env` and the Actions variables, the base labels and the code owners; protect applies the required checks, the branch rules and the merge settings, then verifies them |

A Command journey runs the Command itself, in-process with the call operator and its
`-Root` pointing at the journey's temporary repository, so it reads and writes that
repository's `.env`, `ISSUES.md` and code-owners file, never this one's.

A journey enters only through a public entry point the workflow calls — the conductor,
`Invoke-Orchestration -IssueNumber <n> -From refine|implement|comment`, or the function a
workflow step calls itself: `Complete-HeldPR -PRNumber <n> -Branch <branch> -Merged <bool>`
(afk.yml `pr-closed`), `Start-ConflictRounds -MergedPR <n>` (afk.yml `conflict-rounds`), and the
hourly job's `Invoke-Reconciliation` and `Resume-PausedIssues` (afk.yml `reconcile`). Time passes
through the fakes, not a clock: Set-FakeIssueIdle puts an issue's last activity in the past,
and a pause is seeded with its resume time (`New-PlannedIssueBody -State @{ paused_until = … }`). It
asserts only what the owner sees: the issue's label, the kind of comments posted (a 🤖 signal
and its heading, or a · noise line), the pull request's state, draft flag and timeline, and what
was pushed to the remote. Nothing in a journey reaches into a private function.

A **decision table** is a Pester 5 file in `tests/decisions/`, named after one decision the
orchestrator makes. Each row is one input — a pipeline state, say — and the outcome the owner
sees for it, each row one test result, entered through the module's public surface or a
Command. A table asserts what the decision produces, never the rows of `$PipelineStates` or
any other setting: those are written once, in `lib/Config.ps1`, and a second copy is removed,
not guarded by a test. A table dot-sources `tests/journeys/Journey.ps1` and runs on the same
fakes.

| File | Decision |
|------|----------|
| `OwnerComment.Tests.ps1` | what an owner's comment leads to in each pipeline state |
| `PipelineLabel.Tests.ps1` | where an issue goes from each label: re-entered (Restart-Issue) or left alone, and what the hourly warden does with a quiet issue (Invoke-Reconciliation) |
| `Paths.Tests.ps1` | a changed path: merged, held as a governance file or a proposal, or never staged (the secrets denylist) |
| `CheckVerdict.Tests.ps1` | ship's verdict on the pushed commit's checks: green, failed, or not passed at the ceiling |
| `UsageLimit.Tests.ps1` | which engine answers are a spent allowance, the time to resume, and when a paused issue resumes |
| `ModelTier.Tests.ps1` | task → tier → model, the missing value that stops a run, the engine the setting names, and the estimate that chooses the implement task |
| `IssueHeadings.Tests.ps1` | the issue template's headings and the style of each section |
| `CommentKinds.Tests.ps1` | pipeline history, owner comment or neither; the secrets a pipeline comment never shows |
| `EngineCall.Tests.ps1` | the engine call against a stand-in CLI: its flags, retries, turn budget, checked answer, tool calls and refused edits |
| `CommitMessage.Tests.ps1` | the commit message against a stand-in CLI: a reply used, its trailers removed, asked once more naming the broken rule, or the fallback cut to fit |
| `Check<Name>.Tests.ps1` | one per check in `.github/checks/`: its exit code and the violation lines it prints, on a temporary repository |

The engine call's table and the commit message's are the ones that enter below the public
surface: every journey replaces Invoke-EngineTask with the fake engine, so their tables call
the engine adapter at that seam, against the stand-in CLI.

The orchestrator has three outside seams, and each has one fake in `tests/fakes/`; a fourth
file stands in for the engine's CLI, below the fake engine, for the engine adapter's own tables:

| Fake | Stands in for | What a test does with it |
|------|---------------|--------------------------|
| `tests/fakes/GitHub.ps1` | the `gh` command | Seeds issues and comments, reads labels, comments and pull requests back. It holds issues, labels, comments, pull requests, check runs and job logs in memory, records what changed, and records every label change as a transition. Set-FakeChecks sets what every pushed commit's required checks conclude (failed, still running, missing) and each failed job's log; Complete-FakePullRequest is the owner merging or closing a PR by hand and returns the arguments `Complete-HeldPR` gets; Get-FakePrTimeline reads what happened to a PR (opened as draft, marked ready, back to draft, merged). Each issue has a last-activity time every change moves forward, served in the open-issues listing the warden reads; Set-FakeIssueIdle ages it. `Add-FakeIssue -Estimate -Priority` puts the issue on the board with those fields; `issue create` opens an issue (an epic's children); Get-FakeDispatches reads the workflow dispatches as { Stage; Issue }; the AFK runs listing answers no live run unless `LiveRuns` (a count) is set. A `gh` call it does not know fails the test and names the call. |
| `tests/fakes/Engine.ps1` | `Invoke-EngineTask`, the one function that starts a model | Scripts what each Task returns, in order: an outcome, a reply, a checked answer (the implement tasks' closing note, the review's verdict — a call with a schema that finishes without one fails, as the adapter's does), refused edits, and for an implement task the files it edits; `-During` is what someone else does while that call runs (the owner merging the PR, a change reaching the default branch). Each call is recorded with its Task, Label, Prompt, Tools and turn budget (MaxTurns). Get-EngineUsageLimitText is the engine's spent-allowance message, taken from the adapter's wording, for an `EngineCheck -Output`. A Task with nothing scripted fails the test and names it. |
| `tests/fakes/Repo.ps1` | the repository | Gives the journey a temporary git repository with a bare remote; git runs for real, so the test asks the remote what was pushed. The stand-in full test command reports one exit code per run (`Start-Journey -TestExit 1, 0`); Push-RemoteCommit pushes someone else's commit; Sync-FakeRepo fetches every branch, as a workflow's full checkout does. New-CheckRepo and Invoke-CheckScript give a check's table a repository of its own. |
| `tests/fakes/Cli.ps1` | the Claude CLI | Only for the engine adapter's own tables: stands in for `claude`, records each start's arguments and piped prompt, and replays the lines and exit code each attempt prints; a retry's back-off is recorded, not waited. |

No journey writes its own stand-in for `gh`: every one uses the fake GitHub. The fakes replace
`gh` and `Invoke-EngineTask` inside the module's scope with Pester mocks — and `gh` in the
caller's scope too, which a Command run with `&` inherits — so the orchestrator's own code
runs unchanged and the `Engine` setting is not touched.

**A test runs with the settings it states and none of the machine's.** Importing the module
reads no file: the one reader of `.env` is `.github/tasks/Settings.ps1`, which only the
Commands a person runs dot-source. The module reads the board's settings from the process
environment when it uses them, so Start-Journey clears every `KANBAN_*` variable of the
machine (and the CI run id and job summary), forgets the board an earlier journey read, and
Stop-Journey puts them back. A journey or table that needs a board states it:
Set-JourneyBoard puts the fake GitHub's board (its project, Status field and lanes, Estimate
and Priority) into the environment, as `task setup` leaves it in `.env`. No test reads or
writes this repository's own `.env`.
`tests/journeys/Journey.ps1` loads the module once per run (only when it is not loaded yet)
and starts each journey with a fresh set of fakes. `Start-Journey -ChecksTimeoutSeconds 0` lowers
ship's ceiling on the wait for the required checks for that journey, so "not passed at the
ceiling" ends at once; Get-OrchestratorSetting reads `MaxRetries` and the other settings from
the orchestrator, never from a copy:

```powershell
BeforeAll   { . (Join-Path $PSScriptRoot 'Journey.ps1') }
BeforeEach  { $script:repo = Start-Journey -Name 'Build: held for the owner' }
AfterEach   { Stop-Journey $script:repo }
It 'holds a change to a governance file for the owner' {
    Add-FakeIssue -Number 12 -Title 'Name the journeys' -Body (New-PlannedIssueBody -Number 12) -Labels 'agent:backlog'
    Add-EngineResult -Task ImplementSmall -Edits @{ 'CONTEXT.md' = '...' } -Answer (New-ClosingNote -Implemented 'Named the journeys')
    Add-EngineResult -Task CommitMessage -Reply 'docs(#12): name the journeys'
    Add-EngineResult -Task Review -Answer @{ verdict = 'approved'; report = 'ok' }
    Invoke-Orchestration -IssueNumber 12 -From implement
    Get-FakePipelineLabel 12 | Should -Be 'human:approval'
    Assert-JourneyClean
}
```

`tests/journeys/StateMachine.Tests.ps1` runs last in the same Pester run. It reads every label
transition the tables and journeys caused, fails — naming it — on one that `$PipelineStates` in
`lib/Config.ps1` does not allow, and fails once for each designed transition (an `AllowedFrom`
entry) that no table or journey exercised, naming it. Never widen `AllowedFrom` to make it
pass. A designed transition is caused by a journey or row entered the way the real run enters;
an entry nothing in the orchestrator can cause is removed from the table, never kept on a list
of exceptions. Setting the label an issue already carries is no transition. Run alone, no
journey ran: it lists the designed transitions and those not exercised, and passes.

`tests/journeys/ExportReach.Tests.ps1` runs beside it, last. `Journey.ps1` sets a
recording-only breakpoint on every function in `FunctionsToExport` when it imports the
module, so a call counts wherever it comes from — a journey, a table, a Command, the module
itself; the report fails once for each export nothing reached, naming it. Run alone, no
journey ran, and it is skipped.

Pester alone, without pytest or coverage:

```powershell
Invoke-Pester tests/journeys                               # every file, in file-name order
Invoke-Pester tests/journeys/Build.Tests.ps1 -Output Detailed
Invoke-Pester tests/decisions -Output Detailed             # every decision table
```

Run alone, a journey or table file passes on its own. Only `.github/tasks/test.ps1` is sure to
run the two reports after every table and journey: it lists them first, sorted by name, and
the reports last.
`Invoke-Pester tests/journeys` runs the files in file-name order, so a journey whose name sorts
after a report runs after it, and the report misses it. `$env:JOURNEY_LOG = 1` shows the orchestrator's own
log lines while a journey runs. The Python tests the journeys and tables replaced stay
readable in git at commit `b7ba709` (`tests/orchestrator/`, `tests/checks/`); a static rule they
held that still matters is a check in `.github/checks/`, and one that no longer matters is
listed under [Not covered yet](#not-covered-yet).

**Never widen `FunctionsToExport` to make a test pass.** That is how an explicit API
list decays back to `'*'`; `check-orchestrator-api.ps1` fails the build if an export goes
uncalled or a private function is called from outside.

### Not covered yet

This section lists the static rules that the deleted Python tests (commit `b7ba709`,
`tests/orchestrator/` and `tests/checks/`) held and that no longer matter, each with the
reason it was dropped.

| Static rule (deleted test file) | Why it is dropped |
|---|---|
| The conductor runs refine, architect and plan and grants agent:backlog; the old architect stub is gone; implement runs no alignment step; no `.planning/` file is written; the architecture impact is written into the issue body (`test_script_contract.py`) | Source scans of behaviour the Refine and Build journeys show: refine → architect → plan writes its sections into the issue body and queues it, and implement starts from agent:backlog |
| The grill library exists and declares no param() (`test_script_contract.py`) | The module does not load without it, and `check-script-contract.ps1` holds the no-param() rule for every library |
| The default branch is cached in `lib/Config.ps1`, and the stages name the cached value (`test_graphql_budget.py`) | A scan for a variable's name; `check-no-graphql.ps1` refuses the GraphQL call it guarded, and every journey runs on the default branch the run context gives |
| The label helpers call the REST labels endpoint (`test_graphql_budget.py`) | The fake GitHub answers label reads and writes only through REST, so a journey fails on any other; `check-no-graphql.ps1` refuses the GraphQL forms |
| setup's base labels: their number, a colour in hex, a description, `--force` (`test_setup_labels.py`) | The setup journey shows every pipeline label created with `--force`; a colour's format is GitHub's to refuse |
| setup calls the code-owners step (`test_setup_codeowners.py`) | A scan; the setup journey shows the file written |
| sync strips the header fields, matches the sentinel on its own line, uses the fenced-block pattern and resolves the root two levels up (`test_sync_issues.py`) | Scans of the source; the sync journeys show the issue body without its header fields, the sentinel mentioned in prose above the real one, the fence refused and burned down, and `check-script-contract.ps1` holds every `$PSScriptRoot` path |
| The settings keep the values a change gave them (`test_config_table.py`) | It pins values — a second copy of the settings table; `check-settings-read.ps1` holds the rule that every setting is read |
| No path merges without the required checks — a scan of the source (`test_ship.py`) | A source scan, not behaviour: the build journeys and the check-verdict table show that nothing merges with a red, missing or pending check |

These are the behaviours the deleted Python tests of refine and recovery (`test_refine.py`,
`test_grill.py`, `test_architect.py`, `test_plan.py`, `test_plan_writable_gate.py`,
`test_reconcile.py`, `test_usage_limit.py`, `test_trusted_author.py`, `test_signal_comments.py`)
guarded that no journey or table covers yet, each with where it will be covered or why it is
dropped. A journey or table that covers one removes its line.

| Behaviour (deleted test file) | Where it will be covered, or why it is dropped |
|---|---|
| `-WhatIf` reports the decision it would take, giving up included, and changes nothing; the job-summary table (`test_reconcile.py`) | Dropped from the journeys: the warden's survey output for a person running `reconcile.ps1`, not what the owner sees on the issue |
| Liveness is not asked when no in-flight state is in question, and a deferred state spends none of its re-entry budget (`test_reconcile.py`) | A Recovery journey; the deferral itself is a row of `PipelineLabel.Tests.ps1` |
| A failed dispatch is reported, not claimed as a re-entry (`test_reconcile.py`) | A Recovery journey once the fake GitHub can refuse `gh workflow run` |
| Pull requests are not issues in the warden's survey (`test_reconcile.py`) | Dropped: the fake's listing holds issues only; the filter is the `--jq` the orchestrator passes |
| The rows of `$PipelineStates`: every label has a holder, a recovery, `AllowedFrom` and `OnComment`; a disallowed transition throws (`test_reconcile.py`) | Dropped: a second copy of the table. `StateMachine.Tests.ps1` checks every transition the journeys cause against it |
| The owner's `human:approval` on a new issue survives refine (`approval_required`) (`test_reconcile.py`) | A Refine journey starting from an owner-labelled issue, then a Held one |
| A failing resume does not stop the run (`test_usage_limit.py`) | A Recovery journey once the fake GitHub can fail the resume's label change |
| The answer check: an unusable model reply or a failed comment read posts `🤖⚠️ Could not check your reply`; no new reply calls no model; the `since` format (`test_refine.py`) | A Refine journey each; the `since` format is dropped — the fake reads it as GitHub does |
| A held issue (planned, on `human:approval`) never re-enters refine; the attempt loop recovers on a second attempt (`test_refine.py`) | A Refine journey each |
| An issue missing from the board is added and cached; an unreadable board adds nothing (`test_refine.py`) | A Refine journey on a board stated with Set-JourneyBoard |
| An unreadable author is untrusted (`test_trusted_author.py`) | A Refine journey once the fake GitHub can fail the association read |
| The grill's command: it exists, its dry run, dot-source safety, the schema keys, an answer with prose around it, the `-Trace` tool list, gh noise on stderr, a failed issue fetch (`test_grill.py`) | Dropped from the journeys: the standalone `grill.ps1` and the parser; the refine eval runs the grill end to end. An answer reserved for the owner is the refine eval's |
| The architect's file-count gate, the trivial impact, the section upsert, a failed analysis flagged and never reported as safe (`test_architect.py`) | A Refine journey with an analysis that fails; the gate and formatting are dropped as unit tests |
| The epic's dedupe abort (`🤖❌ Plan Aborted — duplicate`), the planner note on a wide blast radius, zero children; key terms, out-of-scope overlap (`test_plan.py`) | A Refine journey each; the key-term and formatting helpers are dropped as unit tests — the epic journey shows the children's shape |
| An unreadable carrier does not stop the plan; an empty allowlist makes every path a proposal (`test_plan_writable_gate.py`) | Dropped as unit tests of the private classifier; the writable-path journey shows the note and the queue |

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
| `test_review_eval.py` | the review skill on an issue plus a change, three times per case | The verdict, read the way `stages/Review.ps1` reads it (the checked `verdict` field of the engine function's `Answer`, under `.agents/skills/review/answer.schema.json`), is right in all three runs: approve `clean`, reject `planted-bug` |
| `test_refine_eval.py` | the grill probe (`refine/scripts/grill.ps1 -Trace`) on an under-specified issue | Every tool the case expects was called; every open question has a recommendation and two alternatives; the agent brief names no source file (no `.py` or `.ps1` name, no `:<line>` reference) |
| `test_implement_eval.py` | the implement skill on a finished mini-task | The closing note, read the way `stages/Implement.ps1` reads it (the checked lists of the engine function's `Answer`, under `.agents/skills/implement/answer.schema.json`), holds all three lists, with `left_undone` filled when the case is flagged `skipped` and `issues_discovered` filled when it is flagged `noticed` |
| `test_commit_eval.py` | the orchestrator's commit-message generator (`Get-CommitMessage` in `.github/orchestrator/engines/Claude.ps1`) on a staged diff, in one `pwsh` call through the module | The engine wrote the message (`FromEngine` is true), not the fallback: the generator checks every reply against the commit-message rules written beside it, so the eval writes none |

An eval starts its model the way its stage does, through the orchestrator module.
`run_in_orchestrator` in `tests/evals/orchestrator_call.py` is the one `pwsh` call that
imports the module and runs a body in its scope; values such as a prompt, a schema or a
diff reach the body through `env`, never quoted into it. The review and implement evals
call `engine_task`, which runs `Invoke-EngineTask` (`.github/orchestrator/engines/Claude.ps1`)
one-shot on the `Review` and `ImplementLarge` tasks with the skill's text at the head of
the prompt and the skill's schema, and read `Answer` from the `{Outcome, Answer, Cause}`
it returns — a result whose `Outcome` is not `finished` fails the case. The engine
function picks the model from the task on the engine the `Engine` setting names. The
commit eval calls the generator through the same helper, so it runs on the
`CommitMessage` task's model. The refine eval's grill probe imports the module too, so it
runs on the `Refine` task's model and the `MaxTurns_Refine` budget, as the stage does.
Never write a model ID, the CLI's name or a CLI flag in `tests/evals/`. Without `pwsh`,
an eval fails rather than skips: a skipped gate reports green.

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
   case through the module (`engine_task` with the stage's task, or `run_in_orchestrator`
   for a function of the module), and assert the check.
4. **Gate it in CI** — give the target a `PATHS_<TARGET>` regex in the `eval-scope` job of
   `.github/workflows/checks.yml` naming exactly the files the eval reads: the stage's
   entry file or prompt source, its eval test and its stored cases, plus a run step in the
   `eval` job. `PATHS_SHARED` (`eval_goldens.py`, `orchestrator_call.py`,
   `.github/orchestrator/lib/Config.ps1` and `.github/orchestrator/engines/Claude.ps1`)
   fires every target.

**Running them**

```bash
uv run pytest -m eval                            # every eval (calls Claude)
uv run pytest -m eval tests/evals/test_review_eval.py
uv run pytest                                    # default run: evals deselected
```

The Claude CLI must be installed and signed in (in CI, with `CLAUDE_CODE_OAUTH_TOKEN`).

**In CI** — the `eval` job runs only on a PR that changes a file an eval reads, and then
only the evals whose files changed and whose eval file exists (a generated project has
none); skipped, it reports success, so it can be a required
check (`pwsh -NoProfile -File .github/tasks/protect.ps1`). The pipeline's ship stage never merges a PR with a red check.

## The local gate

Five commands, all clean, before any push — the last runs every check, as the checks job does:

```powershell
pwsh -NoProfile -File .github/tasks/test.ps1 ; uv run ruff check . ; uv run ruff format . ; uv run pyright
Get-ChildItem .github/checks -Filter 'check-*.ps1' | ForEach-Object { pwsh -NoProfile -File $_.FullName }
```

Self-review is not a gate. It approved two changes CI then rejected (#154, #192): a
reviewer reads the diff, it never executes it.
