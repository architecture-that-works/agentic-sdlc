---
name: ADR-015-pipeline-taxonomy
description: Unified taxonomy for the agentic pipeline — six stages (refine, architect, plan, implement, review, ship) named identically as skill, library script and label across four board lanes; AFK/HITL demoted from issue labels to execution modes; approval and decision concerns split out of the overloaded HITL label
applies_to: all
---

# ADR-015: Unified Pipeline Taxonomy

## Status

Proposed

## Context and Problem Statement

The pipeline accumulated four independent vocabularies for the same seven concepts. Nothing maps 1:1:

| What it does | README phase | Skill | Lane label | Script | Workflow | Task |
|---|---|---|---|---|---|---|
| agree requirements | Align | `refine` | — | `Refine.ps1` | `align.yml` | `task align` |
| blast radius | Map | `architecture` | — | `Architecture.ps1` | *(in align)* | — |
| decompose | Specify | `plan` | — | `Plan.ps1` | *(in align)* | — |
| write code | Build | `tdd` | `agent:implementing` | `Implement.ps1` | `orchestrator.yml` | `start`/`runner` |
| environment | Run | `harness` | — | — | — | — |
| check work | Verify | `review` | `agent:review` | `Review.ps1` | `orchestrator.yml` | — |
| land it | Merge | `ship` | `agent:merged` | `Merge.ps1` | `orchestrator.yml` | — |

Four failures follow from this:

1. **One concept, five names.** Agreeing requirements is phase "Align", skill `refine`, `align.yml`, `task align`, and `Invoke-Alignment` — which lives in a file called `Refine.ps1`.
2. **`review` denotes two opposed things.** The skill is the agent's self-review. The label `agent:review` is documented as *"self-review passed — awaiting human approval"*. A reader cannot tell which is meant, and the label is load-bearing: it triggers the merge job.
3. **Labels carry stale claims.** `agent:implementing`'s description reads *"(refine + develop)"*, false since ADR-014 moved refine into the pre-backlog gate.
4. **Stages and techniques are presented as peers.** `tdd` and `harness` appear in the seven-phase chain, but nothing invokes them as stages. `tdd` is *how* code gets written; `harness` is *how* context stays clean throughout. Listing them beside `refine` and `ship` is what forced the vocabularies apart.

Separately, the `HITL` label is overloaded across three unrelated concerns: the venue a run executes in, whether a PR may be merged without human sign-off, and whether an issue is a work item at all. ADR-013's `HITL + AFK` pair was a workaround for having no way to express the second.

## Considered Options

* **Option A — Rename in place.** Harmonise the visible names (phase table, workflows, tasks) and leave the structure alone. Cheap, but leaves `tdd`/`harness` mis-cast as stages and the `HITL` overload intact.
* **Option B — Unified taxonomy.** One name per concept across every layer; demote techniques out of the stage list; split the three concerns tangled in `HITL`. Wide rename, but every layer becomes derivable from the stage name.

## Decision Outcome

Chosen: **Option B.**

### Definitions

| Term | Definition |
|---|---|
| **Stage** | One of the six units of work an issue passes through: `refine`, `architect`, `plan`, `implement`, `review`, `ship`. Each stage has one skill and one library script of the same name. Three carry a label. |
| **Lane** | A column on the GitHub Project board. There are four: Backlog, Implementing, Review, Shipped. A lane holds work; a stage does work. |
| **Method** | How a stage is carried out. TDD is the method of `implement`. A stage may change method without changing its name. |
| **Pipeline** | The PowerShell module at `.github/pipeline/`. A library: one file per stage, plus shared helpers (`Config`, `Util`, `GitHub`). It sequences nothing. Imported as `Pipeline`; run context from `Get-PipelineContext`. |
| **Orchestrator** | `Orchestrator.ps1`. Sequences stages for one issue and owns every lane transition. The only component that decides what runs next. |
| **Engine** | An LLM provider adapter in `.github/pipeline/engines/`. One file per provider: `Claude.ps1`, `Gemini.ps1`. Selected by the `KANBAN_ENGINE` variable. |
| **Check** | A validator in `.github/checks/`, run by `checks.yml`. Named `check-<thing>.ps1`. |
| **Task** | A command in `Taskfile.yml`. Each target `X` is backed by `.github/tasks/X.ps1`, named identically. |
| **Skill** | A constraint document at `.agents/skills/<name>/SKILL.md`, with optional `REFERENCE.md`, `EXAMPLES.md` and `scripts/`. |
| **Library** | A PowerShell file dot-sourced by the module loader. PascalCase. Declares no top-level `param()`. |
| **Runnable** | A PowerShell file invoked directly. lowercase. Owns its `param()`. |
| **Carrier** | The GitHub issue body. Holds the AGENT-STATE block, `open_questions[]`, `decided_questions[]`, `failed_at`, and the Architecture Impact, Implementation Plan and Agent Brief sections. |
| **AFK** | Execution mode: unattended, on GitHub Actions. Entry point `task afk`, workflow `afk.yml`. The default. |
| **HITL** | Execution mode: interactive, on the local machine. Entry point `task hitl`. Has no workflow. |
| **`agent:`** | Label prefix. The agent holds the ball. Exactly one `agent:` label at a time. |
| **`human:`** | Label prefix. A human holds the ball; nothing advances until they act. |

### Terms not used

| Term | Status |
|---|---|
| **Step** | Not used for pipeline units. GitHub Actions defines `steps:` in every workflow file. |
| **Phase** | Not used. Superseded by *stage*. |
| **Alignment** | Not used. The pre-backlog gate is the `refine` stage. |
| **Kanban** | Not used as a module or directory name. Retained only in `Kanban lane` and the `KANBAN_*` variables. |

### One conductor, six stages, no intermediate abstractions

`Orchestrator.ps1` holds the six stages in order and sequences them. A stage file contains its own stage and nothing else. There is no second conductor and no named sub-sequence.

This is violated today: `Invoke-Alignment` sequences `refine → architect → plan` from inside `Refine.ps1`, so the Orchestrator conducts only three of six stages. `Invoke-Alignment` is **deleted**, not renamed — a wrapper around "run the first three stages" earns nothing over the orchestrator simply running them.

```powershell
# Orchestrator.ps1
$Stages = 'refine', 'architect', 'plan', 'implement', 'review', 'ship'

function Invoke-Orchestration {
    param([int]$IssueNumber, [ValidateSet('refine','implement')] [string]$From)
    # 'refine'    → runs refine, architect, plan; stops at agent:backlog
    # 'implement' → runs implement, review, ship
}
```

The stop after `plan` is ADR-014's gate — "ready" is not "go" — expressed as where the sequence ends rather than as a separate function. `-From` takes the same values as `afk.yml`'s `stage:` input, so the workflow and the conductor read alike.

`Refine.ps1` keeps `Invoke-Refine` only. Callers to update: `tasks/align.ps1`, `align.yml`.

### One word for the unit: *stage*

The repo currently uses three words for the same thing — `phase` (11 occurrences), `step` (8) and `stage` (8). This ADR standardises on **stage**, for three reasons: `orchestrator.yml` already exposes it as a machine-readable `stage:` input; "stage gate" is the established term for a checkpoint in an engineering process; and **`step` is disqualified outright** because GitHub Actions uses `steps:` natively in every workflow file, so reusing it for our concept would be ambiguous exactly where people read YAML.

`phase` is retired from the README in PR 7.

### Six stages, four lanes

The chain is **six stages**, each reading as a verb, each named identically as skill and library script:

```
refine → architect → plan → implement → review → ship
```

Those six stages occupy **four board lanes**, because the first three are one continuous push to "workable":

```
issue created  (purpose: collect information and thoughts)
     │
     │  refine → architect → plan                        lane: Backlog
     ▼              │
     │              └─ open questions ──▶ human:decision issues
     │                 failure ──────────▶ agent:failed (failed_at: refine)
agent:backlog   ── refined, architected, planned: ready to implement
     │
     ▼  implement  ── code written test-first             agent:implementing
     ▼  review     ── agent validates the PR              agent:reviewing
     │                    │
     │                    └─ human:approval ──▶ holds here for human merge
     ▼  ship       ── merge + CONTEXT.md update           agent:shipped
```

| Stage | Skill | Library script | Label |
|---|---|---|---|
| refine | `refine` | `Refine.ps1` | — |
| architect | `architect` | `Architect.ps1` | — |
| plan | `plan` | `Plan.ps1` | — |
| implement | `implement` | `Implement.ps1` | `agent:implementing` |
| review | `review` | `Review.ps1` | `agent:reviewing` |
| ship | `ship` | `Ship.ps1` | `agent:shipped` |

**Six stages but four lanes is the one deliberate non-1:1**, and it is correct: a lane records where work *sits*, a stage records what *happens*. `refine`, `architect` and `plan` run back-to-back in seconds and nothing ever rests between them, so three extra columns would sit permanently empty.

Refine therefore has **no in-progress label**. It yields `agent:backlog` or `agent:failed` with `failed_at: refine`. A label for a two-minute state is noise; the outcomes are what matter, and `failed_at` already carries the diagnostic detail.

### Skills that are not stages

| Kind | Members | Invoked |
|---|---|---|
| **Domain patterns** | `application-engineering`, `data-engineering`, `agentic-engineering` | within `implement`, selected by project type |
| **Cross-cutting** | `version-control`, `diagnosis` | in any stage, as needed |
| **Meta** | `write-skills` | when authoring a skill |

`architecture` is renamed `architect` so every stage reads as a verb.

### `harness` is retired as a stage and a skill

`harness` owns Dev Container provisioning, the Planner/Generator/Evaluator split, the event log, tool-call offloading, `compact()` and the context-reset protocol. None of that is a stage an *issue* passes through — no issue ever sits in a "Harness" lane. It describes the workspace the agent operates in, and this repository **is** that harness, so naming a stage after it is circular.

Its content is preserved, not deleted: it moves to `docs/HARNESS.md`, routed from `AGENTS.md`, following the progressive-disclosure pattern already established by `docs/TESTING.md` and `docs/SKILLS.md` (criterion 3.2). The Dev Container portion is already realised in `.devcontainer/`.

What `harness` contributed to the *stage* model — "code must comply with this repository's structure and conventions" — is carried instead by the domain-engineering skills, which is where repo-compliant implementation patterns belong. For an agentic project that is `agentic-engineering`; for the others, `application-engineering` or `data-engineering`.

### Execution modes are not labels

`AFK` and `HITL` describe **how a run is invoked**, not a property of the work:

| Mode | Venue | Interactivity | Entry point |
|---|---|---|---|
| **AFK** | GitHub Actions | unattended, drains the queue | `task afk` |
| **HITL** | local laptop | interactive, one issue | `task hitl` |

Both modes run the *same* stages through the *same* library. Because the mode is chosen at dispatch, it is expressed by which command the operator runs — **not** by a label on the issue. The `AFK` and `HITL` labels are therefore retired.

### Two prefixes: who holds the ball

The `agent:` prefix already answers "what is the agent doing". Human actions get the mirror-image prefix, so the label namespace itself says who is expected to act next:

| Prefix | Meaning |
|---|---|
| `agent:` | the agent holds the ball — pipeline state |
| `human:` | a human holds the ball — nothing advances until they act |

### Three concerns, three names

What `HITL` previously conflated:

| Concern | New name | Meaning |
|---|---|---|
| execution venue | `task afk` / `task hitl` | a command, not a label |
| merge authority | label `human:approval` | pipeline implements and self-reviews, then holds at `agent:reviewing` for a human to merge |
| is it work at all | label `human:decision` | a question for a human; never enters the pipeline |

`human:approval` — not `human:review` — because `human:review` sits one inflection away from `agent:reviewing`, and "review means two things" is the exact defect this ADR exists to remove. `approval` is also the established term for a merge gate in agentic pipelines. It replaces the `AFK + HITL` pair and the `HITL and not AFK` condition in the gate. `human:decision` replaces `HITL` on the children refinement spawns for open questions.

### What runs unattended, and what needs attention

AFK is the **default**, not a label. Any issue at `agent:backlog` is eligible for the drain; `human:*` labels are the opt-out, and they mark the exact point where the agent stops:

* **No `human:` label** → runs Refine through Ship unattended.
* **`human:approval`** → runs Implement and Review unattended, then stops before Ship.
* **`human:decision`** → never enters the pipeline at all.

"What needs my attention" therefore becomes one query rather than a judgement call:

```
is:open is:issue label:human:approval,human:decision
```

A third label for "do not let the drain take this, I will drive it myself" is deliberately **not** introduced. Because the mode is a command, running `task hitl ISSUE=N` already claims an issue, and the drain only runs when you start it. If that proves insufficient in practice, `human:implement` can be added later — but not before the need is demonstrated.

### State labels

Exactly one `agent:` label at a time, matching the stage in progress. A `human:` label may accompany it.

| Label | Lane | Meaning |
|---|---|---|
| *(none)* | Backlog | created, not yet refined |
| `agent:backlog` | Backlog | refined, architected, planned — **ready to implement** |
| `agent:implementing` | Implementing | Implement in progress |
| `agent:reviewing` | Review | Review in progress |
| `agent:shipped` | Shipped | merged and closed |
| `agent:failed` | Backlog | a stage errored unrecoverably — see `failed_at` |

`agent:backlog` is **kept**, not renamed: in this project the Backlog *is* the set of refined issues ready to implement, so the label and the lane agree by design rather than duplicating each other.

### `agent:failed` records where it stopped

`agent:failed` is not a terminal state — it parks an issue so a later run can resume it. A flat label loses the one fact needed to resume: which stage failed. Today `task retry` resets to `agent:backlog` regardless, so a failure during Review re-enters as though implementation had never happened.

Rather than a label per failure point (`agent:failed-implement`, …), which explodes the namespace, the stage is recorded **in the issue-carried state** alongside the error, consistent with ADR-011:

```json
{ "failed_at": "implement", "failed_reason": "CI checks failed for PR #194" }
```

`task retry` reads `failed_at` and resumes that stage. `agent:failed` stays a single label; the carrier holds the detail.

### File and command layout

Every workflow's helpers live in the directory of the same name.

| Old | New |
|---|---|
| `workflows/ci.yml` | `workflows/checks.yml` |
| `scripts/ci/` | `.github/checks/` |
| `workflows/align.yml` + `workflows/orchestrator.yml` | `workflows/afk.yml` (merged, `stage` input) |
| `scripts/kanban/` | `.github/pipeline/` (module) with `stages/`, `engines/`, `lib/` |
| `Kanban.psd1` / `.psm1` | `Pipeline.psd1` / `.psm1` |
| `Get-KanbanContext` | `Get-PipelineContext` |
| `Architecture.ps1` | `Architect.ps1` |
| `Merge.ps1` | `Ship.ps1` |
| `Claude.ps1`, `Gemini.ps1` *(loose)* | `pipeline/engines/` |
| `scripts/tasks/align.ps1` | `.github/tasks/refine.ps1` |
| `scripts/tasks/runner.ps1` | `.github/tasks/afk.ps1` |
| `scripts/tasks/start.ps1` | `.github/tasks/hitl.ps1` |
| `scripts/tasks/sync-issues.ps1` | `.github/tasks/sync.ps1` |
| `scripts/setup-branch-protection.ps1` | `.github/tasks/protect.ps1` |
| `tests/scripts/` | `tests/pipeline/` |
| `task align` / `runner` / `start` | `task refine` / `afk` / `hitl` |
| `AFK` / `HITL` labels | *retired* — modes are commands |
| `agent:review` / `agent:merged` | `agent:reviewing` / `agent:shipped` |
| `HITL` on approval-gated work | `human:approval` |
| `HITL` on decision children | `human:decision` |

`kanban` becomes `pipeline` because the library manages pipeline state and stages; the Kanban board is one *view* of that state, not the thing itself. `agent` was rejected as too vague — every component here is agent-related — and `core` as meaningless.

### Folder structure

Renaming alone leaves four structural problems, found by auditing every script in the repo rather than only the ones the renames touch.

**1. `scripts/` root is a junk drawer.** Three files sit loose beside the subdirectories: `Claude.ps1`, `Gemini.ps1` and `setup-branch-protection.ps1`. The first two are LLM **engine adapters** — the dual-engine capability is a first-class concern and should be legible as one folder, not two loose files whose relationship is invisible. The third is the helper for `branch-protection.yml` and `task protect`, filed nowhere.

**2. No workflow can be named after a stage, because no workflow *is* a stage.** The rule works for `checks.yml` ⇒ `scripts/checks/`, but the pipeline workflows break it three ways: both share one library, one of them runs *three* stages, and splitting Implement / Review / Ship apart is not possible — they share a runner session and a working branch, so separate workflows would each get a fresh clone and lose the branch.

Naming one of them `process.yml` was a mis-step: it invents a fifth vocabulary word for something that is not a phase, which is the same debt this ADR is paying off.

Reverting to two workflows named `refine.yml` and `afk.yml` does not work either, because **`refine.yml` runs on GitHub Actions too** — refinement is equally AFK. The name would not distinguish them.

The honest structure is **one cloud workflow with the stage as an input**:

| Axis | Unit | Maps to |
|---|---|---|
| **Stage** | unit of *work* an issue passes through | skill, label, library script — 1:1 |
| **Venue** | unit of *execution* — where stages run | `afk.yml` (cloud) / `task hitl` (local) |

```yaml
# .github/workflows/afk.yml
on:
  issues: [opened, labeled]
  workflow_dispatch:
    inputs:
      stage:  { type: choice, options: [refine, implement, ship] }
      issue_number: { type: string }
```

This is not a new pattern — it is what the repo already does. `orchestrator.yml` already carries a `stage` input (`options: [implement, merge]`), already mixes `issues` and `workflow_dispatch` triggers, and already gates its two jobs on `github.event_name`. Consolidating `align.yml` into it extends that by one job and one stage option. Per-job `concurrency` groups (`align-<issue>`, `implement-pipeline`) survive unchanged.

What this buys: **`afk.yml` is the only workflow the pipeline needs**, and it is named for the one thing that genuinely distinguishes it — the venue. AFK is not insider jargon here; it is front-page vocabulary, with README sections titled *"5-Minute AFK Setup"* and *"AFK Issue → PR Flow"*. HITL needs no workflow at all, because local runs invoke the library directly. So `task afk` ⇒ `afk.yml`, `task hitl` ⇒ no workflow, and the asymmetry is the point rather than an inconsistency.

Runnables a workflow invokes live in a directory named for their role (`checks/`, `tasks/`); the library lives in `pipeline/`.

**3. `tasks/` has no naming rule, so two names are wrong.** `Taskfile.yml` exposes `setup, sync, align, start, runner, retry, protect`, but the files are `setup.ps1, sync-issues.ps1, align.ps1, start.ps1, runner.ps1, retry.ps1` — and `protect` reaches outside the directory entirely to `scripts/setup-branch-protection.ps1`. Adopting **one file per task target, named identically** fixes both: `sync-issues.ps1` → `sync.ps1`, and `setup-branch-protection.ps1` → `tasks/protect.ps1`. Then `task X` ⇒ `scripts/tasks/X.ps1`, with no exceptions to remember.

**4. Two casing conventions are in use with no stated rule.** This one is not an aesthetic choice — it names an invariant the test suite **already enforces**. `tests/.../test_kanban_script_contract.py` defines exactly two roles:

* **Library** — dot-sourced by the module loader. MUST NOT declare a top-level `param()`, because dot-sourcing executes that block in the *caller's* scope. That is how `grill.ps1`'s `param([int]$Issue = 0)` once zeroed the orchestrator's issue number and ran the entire pipeline against issue #0.
* **Runnable** — owns a `param()`, is invoked, never dot-sourced.

The casing rule simply makes that contract visible at a glance:

> **PascalCase = library** (dot-sourced, no top-level `param()`). **lowercase = runnable** (owns `param()`, invoked directly).

Verified against the files: `Claude.ps1` and `Gemini.ps1` both declare zero top-level `param()` blocks and are dot-sourced at `Kanban.psm1:35-36`. They are libraries, already correctly cased, and merely filed in the wrong place.

### Four directories, four growth axes

The structure is future-proof to the extent that each directory answers "where does the next one of these go?" without debate:

| Directory | Grows with | Next addition lands as |
|---|---|---|
| `pipeline/stages/` | pipeline stages | `<Stage>.ps1` |
| `pipeline/engines/` | LLM providers | `OpenAI.ps1` (cf. #89, cross-family critique) |
| `checks/` | validators run by `checks.yml` | `check-<thing>.ps1` |
| `tasks/` | CLI commands | `<task-target>.ps1` |

Each is a single question with a single answer. That is the test this structure has to pass, not tidiness.

**5. Everything here ships to strangers.** `copier.yml`'s `_exclude` does not list `.github/`, so **every generated project inherits these workflows verbatim**. That is the constraint that settles naming arguments: a name has to be legible to someone who did not build this. It is also why `afk.yml` passes — AFK is documented on the front page of the README, not buried — and why `process.yml` would not: "process what?" has no answer in the filename.

**7. `scripts/` is the abstract intermediate.** It groups by file *type*, not purpose — every child is scripts, so the word carries no information and costs a level of nesting. `.github/` already scopes "GitHub automation"; `scripts/` inside it says only "and these are files".

Removing it leaves four purpose-named peers that read as a set: **what runs** (`workflows/`), **what it runs** (`pipeline/`), **what validates** (`checks/`), **what you type** (`tasks/`).

`pipeline/` does earn its place, for a reason `scripts/` does not: it is the **module boundary**. Everything inside is dot-sourced library; everything outside it is a runnable. That is the distinction the contract test already enforces, made visible as a directory.

Inside it, `stages/` puts the taxonomy in the filesystem — open it and there are exactly six files, named for the six stages.

Target tree:

```
.github/
  workflows/
    afk.yml                 ← orchestrator.yml + align.yml merged; stage as input
    checks.yml              ← ci.yml
    build.yml  deploy.yml  branch-protection.yml
  pipeline/                 ← the module; everything here is library
    Pipeline.psd1  Pipeline.psm1
    Orchestrator.ps1        sequences the six stages
    stages/
      Refine.ps1  Architect.ps1  Plan.ps1
      Implement.ps1  Review.ps1  Ship.ps1
    engines/
      Claude.ps1  Gemini.ps1
    lib/
      Config.ps1  Util.ps1  GitHub.ps1
  checks/                   ← runnables, invoked by checks.yml
    check-module-map.ps1  check-script-paths.ps1
    verify-settings.ps1     ← rescued from the retiring harness skill
  tasks/                    ← runnables, one per Taskfile target
    refine.ps1  afk.ps1  hitl.ps1  retry.ps1
    setup.ps1  sync.ps1  protect.ps1
tests/
  pipeline/                 ← tests/scripts/, mirrors .github/pipeline/
  checks/                                      mirrors .github/checks/
```

Cost, stated plainly: this supersedes the `.github/scripts/` layout ADR-013 established, and `test_kanban_script_contract.py` hardcodes `ROOT/".github"/"scripts"` as its root — that constant changes with the move. `.github/` conventionally holds GitHub metadata rather than application directories, which is the one argument for keeping `scripts/`; it is outweighed by the fact that every directory here *is* GitHub automation.

`tests/scripts/` becomes `tests/pipeline/` so the test tree mirrors the source tree the way `tests/utils/` and `tests/tools/` already mirror `src/utils/` and `src/tools/`. "Which scripts?" is not a question a directory name should leave open.

`harness/scripts/verify-settings.ps1` survives the skill's retirement: it validates `.claude/settings.json`, which makes it a check, so it moves to `scripts/checks/`. Checked rather than assumed — `.claude` **is** in copier's `_exclude`, so the file it validates is absent from generated projects; the script already handles that (`".claude/settings.json not found — using default Claude Code settings"`) and so does not reintroduce the #192 failure mode.

**6. A missed path reference has no guard, and the contract test is not one.** `test_kanban_script_contract.py` discovers files with `rglob` over `.github/scripts`, so it is indifferent to which directory a file sits in. It catches a renamed *dot-sourced* file (the resolver returns nothing) but is blind to a stale directory path in a workflow or Taskfile. The only current signal for that is `Import-Module` failing on the runner — a late, expensive signal, and precisely how #154 burned a full pipeline run.

This refactor therefore adds one check, `.github/checks/check-script-paths.ps1`: every `.ps1`/`.psd1` path referenced from `.github/workflows/*.yml` and `Taskfile.yml` must exist on disk. It is a few lines, runs in milliseconds, and converts the next rename from a runtime failure into a failed check. Without it, this ADR's own execution plan is unguarded.

### Deliberately not renamed

* **`Implement` does not become `Build`.** `workflows/build.yml` already exists and builds the container image, and "build" means compile/package in ordinary CI usage. `Build` is reserved for that meaning; `Implement` is where code is written.
* **`Merge.ps1` becomes `Ship.ps1`, and the stage is `Ship`.** This matches the existing `ship` skill, and the stage does more than merge — security checks, squash merge, and the CONTEXT.md update.
* **Accepted ADRs are not rewritten.** ADR-011/012/013/014 are historical records that used the old names correctly at the time. MADR convention is to supersede, not edit. This ADR is the pointer; the old text stands.

### Skill inventory after this ADR

| Skill | Fate |
|---|---|
| `refine` | stage — unchanged |
| `architecture` | **renamed `architect`** — stage, consistent verb |
| `plan` | stage — unchanged |
| `tdd` | **renamed `implement`** — stage; TDD becomes its content, not its name |
| `review` | stage — unchanged |
| `ship` | stage — unchanged |
| `harness` | **retired** — content moves to `docs/HARNESS.md` |
| `version-control`, `diagnosis` | cross-cutting — unchanged |
| `application-engineering`, `data-engineering`, `agentic-engineering` | domain patterns within Implement — unchanged |
| `write-skills` | meta — unchanged |

Twelve skills remain, down from thirteen. The chain reads in one vocabulary:

```
refine → architect → plan → implement → review → ship
```

### Why `tdd` becomes `implement`

Every other stage names *what happens*; `tdd` named *how*. That made it the last row where the skill, the script and the label disagreed — skill `tdd`, script `Implement.ps1`, label `agent:implementing`.

Renaming it `implement` makes the stage the container and the **method a choice inside it**. Test-driven development is the current default and the whole of the skill's present content, but spec-driven development or another discipline can be added as an alternative method without renaming the stage, the script, or the label. Naming the stage after one method would have frozen that choice into the directory structure.

TDD loses no prominence: it remains the sanctioned way code is written, stated in `CONTEXT.md`, and remains the substance of `implement/SKILL.md`. What changes is that a reader opening `skills/implement/` learns the method, rather than needing to know already that `tdd` is where code gets written.

## Consequences

### Positive

* Any layer is derivable from the stage name: stage `Refine` ⇒ skill `refine`, label `agent:refining`, `Refine.ps1`, `refine.yml`, `task refine`.
* `review` becomes unambiguous — `agent:reviewing` means Review is running, and merge authority is carried by `approval:required` instead of being implied by a lane.
* Governance work reaches the pipeline through a label that says what it means, rather than through a two-label pair whose meaning had to be documented.

### Risks and required care

* **Label renames must use `gh label edit`, never delete-and-recreate** — recreating drops the association with every issue that carried the label.
* **There is no existing guard against a stale path reference.** The contract test globs rather than asserting paths, so it will not catch one (see finding 6). `check-script-paths.ps1` must land in PR 3, *before* the renames in PR 4 that need it.
* **Everything here ships to generated projects.** `copier.yml` excludes only `.git`, `.venv`, `.claude`, `uv.lock`, `copier.yml`, `logs` and `tests/test_copier_template.py`. `.github/` and `.agents/skills/` propagate in full, so every name must be legible to someone who did not build this — and any test moved into `tests/pipeline/` must pass inside a generated project, or carry the skip guard that #192 taught us to add.
* **`Import-Module` needs the absolute path** to the renamed manifest in both workflows; a bare relative path is treated as a module *name* (ADR-013).
* **Renaming a workflow file discards its run history continuity** — GitHub treats `checks.yml` as a new workflow, and past `ci.yml` runs stay under the old name.
* **Copier template parity.** Any path reference inside `.jinja2` files or `copier.yml` must be updated; the parity guard from #192 covers dependencies, not paths.
* A find-and-replace across the repo is **not** sufficient on its own: directory moves, label edits via API, and the ADR exemption all need doing deliberately.

## Execution plan

Not a single find-and-replace. Six ordered PRs, each independently reviewable and each leaving `main` green:

| # | Scope | Why this order |
|---|---|---|
| 1 | **Labels** — `agent:review` → `agent:reviewing`, `agent:merged` → `agent:shipped` via `gh label edit`; `agent:implementing` kept (its stale *"(refine + develop)"* description corrected). Plus the `setup.ps1` provisioning list and the `Set-AgentState` / `Test-Readiness` constants. | State names are referenced by everything downstream, so later PRs get written against the final vocabulary. `edit` preserves issue associations; recreating would drop them. |
| 2 | **Library** — `.github/scripts/kanban/` → `.github/pipeline/` with `stages/`, `engines/`, `lib/`; `Kanban.ps*` → `Pipeline.ps*`; `Get-KanbanContext` → `Get-PipelineContext`; `Architecture.ps1` → `Architect.ps1`; `Merge.ps1` → `Ship.ps1`; `tests/scripts/` → `tests/pipeline/`; the `Import-Module` absolute paths in both workflows; the `ROOT/".github"/"scripts"` constant in `test_kanban_script_contract.py` — **and delete `Invoke-Alignment`, folding refine/architect/plan into `Invoke-Orchestration -From refine`**. | The largest mechanical change, plus the structural fix: one conductor, six stages, no intermediate wrapper. Callers to update: `tasks/align.ps1`, `align.yml`. |
| 3 | **Structure + the missing guard** — create `pipeline/engines/` and move `Claude.ps1` + `Gemini.ps1` into it; `scripts/ci/` → `.github/checks/`; add `scripts/checks/check-script-paths.ps1` and wire it into `checks.yml`. | Pure moves, plus the guard that makes PR 4 safe. The guard must exist *before* the workflow and task renames, not after. |
| 4 | **Workflows + tasks** — `ci.yml` → `checks.yml`; **merge `align.yml` into `orchestrator.yml` → `afk.yml`** with `stage: [refine, implement, ship]`; `tasks/{align,runner,start}.ps1` → `{refine,afk,hitl}.ps1`; `sync-issues.ps1` → `sync.ps1`; `setup-branch-protection.ps1` → `tasks/protect.ps1`; `Taskfile.yml` targets aligned 1:1 with filenames. | Depends on PRs 2–3. Now guarded: a stale path fails a check instead of a runner. The workflow merge is the riskiest step here — it changes triggers, so verify each of the three entry paths (issue opened, dispatch per stage, `agent:reviewing` label) fires once and only once. |
| 5 | **Execution modes** — retire the `AFK` / `HITL` labels; add `human:approval` and `human:decision`; drop the `HITL and not AFK` condition in the gate and rewrite the hold gate's label check; record `failed_at` / `failed_reason` in the carrier and teach `task retry` to resume from it. | The only behavioural change in the sequence. It deserves its own review rather than being buried in a rename, and it supersedes the merge-hold mechanism from #195 — which was never exercised end-to-end, so there is no working behaviour to regress. |
| 6 | **Skill tree** — rename `architecture/` → `architect/` and `tdd/` → `implement/`; retire `harness/` (content to `docs/HARNESS.md`, `verify-settings.ps1` to `scripts/checks/`); fix the **"Interfaces with" cross-references in all 27 skill files** that name a renamed or retired skill; rename `tests/scripts/test_grill_harness.py`. | Touches the Copier-propagated skill tree, so it lands once the pipeline is stable. The cross-references are the hidden bulk — every `SKILL.md` declares what it interfaces with by name, so a rename that stops at directory level leaves 27 files lying. |
| 7 | **Docs** — `README.md` (skill chain, phase table, Repository Structure, Orchestrator Workflow), `docs/SKILLS.md` (skill table, lifecycle, "extend the tdd REFACTOR phase"), `AGENTS.md` router, `CONTEXT.md`, `ISSUES.md` label list, `ASSESSMENT_PROMPT.md`. | Last, so it describes a repo that already behaves this way. |

**Explicitly not edited** — historical records that were accurate when written: `docs/adr/ADR-000` through `ADR-014`, and `docs/assessment-2026-06-27.md` (a dated snapshot). Rewriting either would falsify the record. This ADR is the pointer forward.

Accepted ADRs (011–014) are **not** edited in any of these. They remain historical record; this ADR is the pointer.

## More Information

Supersedes the `HITL + AFK` label-pair mechanism introduced for the merge hold, and the `HITL and not AFK` alignment condition. Builds on ADR-011 (issue-carried state), ADR-013 (module structure and parameter passing) and ADR-014 (pre-backlog gate) — all of which keep their original terminology as historical record.
