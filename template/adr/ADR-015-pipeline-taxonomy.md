---
name: ADR-015-pipeline-taxonomy
description: Unified taxonomy for the agentic pipeline — six stages (refine, architect, plan, implement, review, ship) named identically as skill, library script and label across four board lanes; AFK/HITL demoted from issue labels to execution modes; approval and decision concerns split out of the overloaded HITL label
applies_to: all
---

# ADR-015: Unified Pipeline Taxonomy

## Status

Accepted. Implemented — see [Implementation](#implementation).

## Context and Problem Statement

The pipeline accumulated four independent vocabularies for the same seven concepts, and
nothing mapped 1:1. Agreeing requirements was phase "Align", skill `refine`, workflow
`align.yml`, command `task align`, and function `Invoke-Alignment` — which lived in a file
called `Refine.ps1`.

Four failures followed:

1. **One concept, five names.** No layer was derivable from any other.
2. **`review` denoted two opposed things.** The skill was the agent's self-review; the
   label `agent:review` meant *"self-review passed — awaiting human approval"*. A reader
   could not tell which was meant, and the label was load-bearing: it triggered the merge.
3. **Labels carried stale claims.** `agent:implementing` was described as
   *"(refine + develop)"*, false since ADR-014 moved refine into the pre-backlog gate.
4. **Stages and techniques were presented as peers.** `tdd` and `harness` sat in the
   seven-phase chain, but nothing invoked them as stages. `tdd` is *how* code gets written;
   `harness` is *where* the agent works. Listing them beside `refine` and `ship` is what
   forced the vocabularies apart.

Separately, `HITL` was overloaded across three unrelated concerns: the venue a run executes
in, whether a PR may merge without human sign-off, and whether an issue is a work item at
all. The `HITL + AFK` label pair was a workaround for having no way to express the second.

## Considered Options

* **Option A — Rename in place.** Harmonise the visible names, leave the structure alone.
  Cheap, but leaves `tdd`/`harness` mis-cast as stages and the `HITL` overload intact.
* **Option B — Unified taxonomy.** One name per concept across every layer; demote
  techniques out of the stage list; split the three concerns tangled in `HITL`.

## Decision Outcome

Chosen: **Option B.** Every layer is derivable from the stage name.

### Definitions

| Term | Definition |
|---|---|
| **Stage** | One of the six units of work an issue passes through: `refine`, `architect`, `plan`, `implement`, `review`, `ship`. Each has one skill and one library script of the same name. Three carry a label. |
| **Lane** | A column on the GitHub Project board. There are four: Backlog, Implementing, Review, Shipped. A lane holds work; a stage does work. |
| **Method** | How a stage is carried out. TDD is the method of `implement`. A stage may change method without changing its name. |
| **Orchestrator** | The PowerShell module at `.github/orchestrator/`. `Orchestrator.psm1` loads the library and sequences all six stages; `Orchestrator.psd1` declares the public surface. Owns every lane transition and is the only component that decides what runs next. Run context from `Get-OrchestratorContext`. |
| **Engine** | An LLM provider adapter in `.github/orchestrator/engines/`. One file per provider. Selected by `KANBAN_ENGINE`. |
| **Check** | A validator in `.github/checks/`, run by `checks.yml`. Named `check-<thing>.ps1`. |
| **Task** | A command in `Taskfile.yml`. Each target is backed by one runnable of the same name in `.github/tasks/`. |
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
| **Step** | Not used for stages. GitHub Actions defines `steps:` in every workflow file. |
| **Phase** | Not used for pipeline units. Superseded by *stage*. Still valid for roadmap phases. |
| **Alignment** | Not used. The pre-backlog gate is the `refine` stage. |
| **Kanban** | Not used as a module or directory name. Retained only in the `KANBAN_*` variables, which are live GitHub repository variables — renaming those means touching repository Settings and every generated project's setup for no functional gain. |

### Six stages, four lanes

```
refine → architect → plan → implement → review → ship
```

| Stage | Skill | Library script | Label |
|---|---|---|---|
| refine | `refine` | `stages/Refine.ps1` | — |
| architect | `architect` | `stages/Architect.ps1` | — |
| plan | `plan` | `stages/Plan.ps1` | — |
| implement | `implement` | `stages/Implement.ps1` | `agent:implementing` |
| review | `review` | `stages/Review.ps1` | `agent:reviewing` |
| ship | `ship` | `stages/Ship.ps1` | `agent:shipped` |

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

**Six stages but four lanes is the one deliberate non-1:1**, and it is correct: a lane
records where work *sits*, a stage records what *happens*. `refine`, `architect` and `plan`
run back-to-back in seconds and nothing ever rests between them, so three extra columns
would sit permanently empty. Refine therefore has **no in-progress label** — it yields
`agent:backlog` or `agent:failed` with `failed_at: refine`.

### One conductor, six stages, no intermediate abstractions

`Orchestrator.psm1` loads the library and sequences the six stages. A stage file contains
its own stage and nothing else. There is no second conductor and no named sub-sequence —
the module root *is* the conductor.

```powershell
$Stages = 'refine', 'architect', 'plan', 'implement', 'review', 'ship'

function Invoke-Orchestration {
    param([int]$IssueNumber, [ValidateSet('refine','implement')] [string]$From)
    # 'refine'    → runs refine, architect, plan; stops at agent:backlog
    # 'implement' → runs implement, review, ship
}
```

The stop after `plan` is ADR-014's gate — "ready" is not "go" — expressed as where the
sequence ends rather than as a separate function. `Invoke-Alignment` was **deleted**, not
renamed: a wrapper around "run the first three stages" earns nothing over the orchestrator
simply running them. `-From` takes the same values as `afk.yml`'s `stage:` input, so the
workflow and the conductor read alike.

### Declaring the public API

The API is an explicit `FunctionsToExport` array in `Orchestrator.psd1` — a literal
hashtable with zero executable statements. `Export-ModuleMember` was rejected because it is
code that runs at import time, which is the loose logic this ADR removes.

Beyond avoiding logic, the explicit list buys a concrete behaviour: PowerShell can resolve
"which module provides `Invoke-Orchestration`?" from the manifest **without loading or
executing the module**. A wildcard forces a full module load to answer the same question,
defeating command discovery and auto-loading.

Anything absent from the list is private automatically. No `_`-prefix convention, no
`internal/` directory — the manifest **is** the boundary, and `check-module-api.ps1`
asserts it holds: every function called from `tasks/`, `workflows/` or skill scripts must
be exported, and nothing exported may be uncalled.

### Skills that are not stages

| Kind | Members | Invoked |
|---|---|---|
| **Domain patterns** | `application-engineering`, `data-engineering`, `agentic-engineering` | within `implement`, selected by project type |
| **Cross-cutting** | `version-control`, `diagnosis` | in any stage, as needed |
| **Meta** | `write-skills` | when authoring a skill |

### `harness` is retired as a stage and a skill

`harness` described the workspace the agent operates in, and this repository **is** that
harness, so naming a stage after it was circular. No issue ever sat in a "Harness" lane.

Its content moved to `docs/HARNESS.md`, routed from `AGENTS.md`, following the
progressive-disclosure pattern of `docs/TESTING.md` and `docs/SKILLS.md`. What `harness`
contributed to the *stage* model — "code must comply with this repository's structure and
conventions" — is carried by the domain-engineering skills, which is where repo-compliant
implementation patterns belong.

### Why `tdd` becomes `implement`

Every other stage names *what happens*; `tdd` named *how*. That made it the last row where
skill, script and label disagreed — skill `tdd`, script `Implement.ps1`, label
`agent:implementing`.

Renaming it makes the stage the container and the **method a choice inside it**. TDD remains
the sanctioned way code is written, stated in `CONTEXT.md` and the whole of
`implement/SKILL.md`, but spec-driven development or another discipline can be added without
renaming the stage, the script or the label. Naming the stage after one method would have
frozen that choice into the directory structure.

### Execution modes are not labels

| Mode | Venue | Interactivity | Entry point |
|---|---|---|---|
| **AFK** | GitHub Actions | unattended, drains the queue | `task afk` |
| **HITL** | local laptop | interactive, one issue | `task hitl` |

Both run the *same* stages through the *same* library. Because the mode is chosen at
dispatch, it is expressed by which command the operator runs — not by a label. The `AFK` and
`HITL` labels are retired.

### Three concerns, three names

What `HITL` conflated:

| Concern | New name | Meaning |
|---|---|---|
| execution venue | `task afk` / `task hitl` | a command, not a label |
| merge authority | label `human:approval` | pipeline implements and self-reviews, then holds at `agent:reviewing` for a human to merge |
| is it work at all | label `human:decision` | a question for a human; never enters the pipeline |

`human:approval` — not `human:review` — because `human:review` sits one inflection away from
`agent:reviewing`, and "review means two things" is the exact defect this ADR removes.

The `agent:` prefix answers "what is the agent doing"; `human:` is its mirror, so the label
namespace itself says who is expected to act next.

### What runs unattended, and what needs attention

AFK is the **default**. Any issue at `agent:backlog` is eligible for the drain; `human:*`
labels are the opt-out, and they mark the exact point where the agent stops:

* **No `human:` label** → runs refine through ship unattended.
* **`human:approval`** → runs implement and review unattended, then stops before ship.
* **`human:decision`** → never enters the pipeline at all.

"What needs my attention" is therefore one query rather than a judgement call:

```
is:open is:issue label:human:approval,human:decision
```

A third label for "do not let the drain take this, I will drive it myself" is deliberately
**not** introduced: running `task hitl ISSUE=N` already claims an issue, and the drain only
runs when you start it.

### State labels

Exactly one `agent:` label at a time, matching the stage in progress. A `human:` label may
accompany it.

| Label | Lane | Meaning |
|---|---|---|
| *(none)* | Backlog | created, not yet refined |
| `agent:backlog` | Backlog | refined, architected, planned — **ready to implement** |
| `agent:implementing` | Implementing | implement in progress |
| `agent:reviewing` | Review | review in progress |
| `agent:shipped` | Shipped | merged and closed |
| `agent:failed` | Backlog | a stage errored unrecoverably — see `failed_at` |

`agent:backlog` is **kept**, not renamed: in this project the Backlog *is* the set of
refined issues ready to implement, so the label and the lane agree by design.

### `agent:failed` records where it stopped

`agent:failed` parks an issue so a later run can resume it. A flat label loses the one fact
needed to resume: which stage failed. Rather than a label per failure point, which explodes
the namespace, the stage is recorded **in the carrier** alongside the error, consistent with
ADR-011:

```json
{ "failed_at": "implement", "failed_reason": "CI checks failed for PR #194" }
```

`task retry` reads `failed_at` and resumes that stage.

### Folder structure

Every workflow's helpers live in the directory of the same name. `scripts/` was removed
because it groups by file *type*: every child is scripts, so the word carries no information
and costs a level of nesting. `.github/` already scopes "GitHub automation".

`orchestrator/` earns its place because it is the **module boundary** — everything inside is
dot-sourced library, everything outside is a runnable, which is the distinction the contract
test enforces, made visible as a directory.

```
.github/
  workflows/
    afk.yml                 ← the pipeline, unattended; stage as input
    checks.yml              ← lint, typecheck, test, audit, guards
    build.yml  deploy.yml  branch-protection.yml
  orchestrator/             ← the module; everything here is library
    Orchestrator.psd1       manifest — explicit FunctionsToExport
    Orchestrator.psm1       loads lib/ stages/ engines/, then sequences the six stages
    stages/
      Refine.ps1  Architect.ps1  Plan.ps1
      Implement.ps1  Review.ps1  Ship.ps1
    engines/
      Claude.ps1  Gemini.ps1
    lib/
      Config.ps1  Util.ps1  GitHub.ps1  Grill.ps1
  checks/                   ← runnables, invoked by checks.yml
    check-module-map.ps1  check-script-paths.ps1
    check-doc-paths.ps1   check-module-api.ps1  verify-settings.ps1
  tasks/                    ← runnables, one per Taskfile target
    refine.ps1  afk.ps1  hitl.ps1  retry.ps1
    setup.ps1  sync.ps1  protect.ps1
tests/
  orchestrator/             ← mirrors .github/orchestrator/
  checks/                   ← mirrors .github/checks/
```

**One cloud workflow, with the stage as an input.** No workflow can be named after a stage,
because no workflow *is* a stage: the pipeline workflows share one library, one of them runs
*three* stages, and splitting implement / review / ship apart is impossible — they share a
runner session and a working branch, so separate workflows would each get a fresh clone and
lose the branch. The honest axes are:

| Axis | Unit | Maps to |
|---|---|---|
| **Stage** | unit of *work* an issue passes through | skill, label, library script — 1:1 |
| **Venue** | unit of *execution* — where stages run | `afk.yml` (cloud) / `task hitl` (local) |

So `afk.yml` is the only workflow the orchestrator needs, named for the one thing that
genuinely distinguishes it. HITL needs no workflow at all, because local runs invoke the
library directly — the asymmetry is the point.

**Casing is the library/runnable contract, made visible.** PascalCase = library
(dot-sourced, no top-level `param()`). lowercase = runnable (owns `param()`, invoked
directly). This is not aesthetic: dot-sourcing executes a `param()` block in the *caller's*
scope, which is how `grill.ps1`'s `param([int]$Issue = 0)` once zeroed the orchestrator's
issue number and ran the entire pipeline against issue #0.

### Four directories, four growth axes

Each directory answers "where does the next one of these go?" without debate:

| Directory | Grows with | Next addition lands as |
|---|---|---|
| `orchestrator/stages/` | stages | `<Stage>.ps1` |
| `orchestrator/engines/` | LLM providers | `OpenAI.ps1` |
| `checks/` | validators run by `checks.yml` | `check-<thing>.ps1` |
| `tasks/` | CLI commands | `<task-target>.ps1` |

**Everything here ships to strangers.** `copier.yml`'s `_exclude` does not list `.github/`,
so every generated project inherits these workflows verbatim. That is the constraint that
settles naming arguments: a name has to be legible to someone who did not build this.

### Guards, not conventions

Three of this ADR's rules are enforced rather than documented, because a convention nobody
checks is a convention that rots:

| Guard | Asserts |
|---|---|
| `check-script-paths.ps1` | every `.ps1`/`.psd1` referenced from a workflow or `Taskfile.yml` exists |
| `check-doc-paths.ps1` | every repo path cited in a load-bearing document exists |
| `check-module-api.ps1` | `FunctionsToExport` matches what is actually called across the boundary |

`check-script-paths.ps1` exists because the contract test globs rather than asserting paths:
it catches a renamed *dot-sourced* file but is blind to a stale directory path in a workflow,
where the only other signal is `Import-Module` failing on the runner — a late, expensive
signal. `check-doc-paths.ps1` exists because the same was true of documentation, and the
documentation is what every agent session loads first.

### Deliberately not renamed

* **`Implement` does not become `Build`.** `workflows/build.yml` already builds the
  container image, and "build" means compile/package in ordinary CI usage.
* **`Merge.ps1` becomes `Ship.ps1`.** This matches the existing `ship` skill, and the stage
  does more than merge — security checks, squash merge, and the CONTEXT.md update.
* **Accepted ADRs are not rewritten.** ADR-011/012/013/014 are historical records that used
  the old names correctly at the time. MADR convention is to supersede, not edit. This ADR
  is the pointer; the old text stands.

## Consequences

### Positive

* Any layer is derivable from the stage name: stage `Implement` ⇒ skill `implement`, label
  `agent:implementing`, `stages/Implement.ps1`.
* `review` is unambiguous — `agent:reviewing` means the review stage is running, and merge
  authority is carried explicitly by `human:approval`.
* Governance work reaches the pipeline through a label that says what it means, rather than
  through a two-label pair whose meaning had to be documented.
* Three guards make the structure checkable rather than aspirational.

### Risks and required care

* **Label renames must use `gh label edit`, never delete-and-recreate** — recreating drops
  the association with every issue that carried the label.
* **Everything here ships to generated projects.** `.github/` and `.agents/skills/`
  propagate in full, so every name must be legible to someone who did not build this, and
  any test under `tests/` must pass inside a generated project or carry a skip guard.
* **`Import-Module` needs the absolute path** to the manifest in workflows; a bare relative
  path is treated as a module *name* (ADR-013).
* **Renaming a workflow file discards its run history continuity** — GitHub treats
  `checks.yml` as a new workflow.
* **Casing is load-bearing on a case-insensitive filesystem.** `stages/Refine.ps1` and
  `tasks/refine.ps1` are distinct by directory but identical to a case-insensitive lookup,
  so any tooling that resolves by basename must match case exactly.

## Implementation

Landed across eight PRs. The taxonomy, the folder structure, the labels and the guards are
all in place; `docs/HARNESS.md` holds only what the repository actually implements.

| Area | State |
|---|---|
| Labels | `agent:reviewing`, `agent:shipped`, `human:approval`, `human:decision` live. `AFK` and `HITL` deleted; `HITL` was renamed into `human:approval` to preserve its 19 issue associations, then the seven decision issues hand-corrected. |
| Module | `.github/orchestrator/` with `stages/`, `engines/`, `lib/`. `Invoke-Alignment` deleted; `Invoke-Orchestration -From refine\|implement` is the single conductor. `FunctionsToExport` is an explicit list of 13. |
| Workflows | `checks.yml`, `afk.yml` (`stage` input: refine / implement / ship). |
| Tasks | `Taskfile.yml` 1:1 with `.github/tasks/`: `refine`, `afk`, `hitl`, `retry`, `setup`, `sync`, `protect`. |
| Checks | Five validators in `.github/checks/`, all run by `checks.yml`. |
| Skills | Twelve, down from thirteen. `architecture`→`architect`, `tdd`→`implement`, `harness` retired to `docs/HARNESS.md`. |
| Tests | `tests/orchestrator/` and `tests/checks/` mirror their source trees. |
| Board | Column `Merged` renamed `Shipped` in the Project UI. |

**Not yet exercised:** the `human:approval` merge hold has never run end-to-end. Before
2026-09-21 the label carried zero issues, so the branch was unreachable; it now guards seven.
The hold's notification was silent until the re-entry guard was rekeyed off the hold comment
rather than the `agent:reviewing` label, which the review stage always sets first.

## Amendments

**2026-09-21** — two decisions that change this ADR's original text:

1. **`docs/HARNESS.md` is not a verbatim preservation.** §`harness` is retired said its
   content was "preserved, not deleted". Reviewed against the repository, the
   Planner/Generator/Evaluator split, the `emitEvent` log and the tool-call offloading rules
   are implemented nowhere in `.github/orchestrator/`. Documentation carries settled
   knowledge; in-flight intent belongs on an issue (ADR-011). `docs/HARNESS.md` keeps the
   context-management thresholds and a Dev Container pointer — roughly 100 lines, matching
   `TESTING.md` and `SKILLS.md` — and the rest became a `human:decision` issue.
2. **The README section was retitled to make this ADR's argument true.** The naming case for
   `afk.yml` rested on AFK already being front-page vocabulary, citing a README section
   *"5-Minute AFK Setup"*. The README said "5-Minute Cloud Runner Setup". The section was
   renamed rather than the claim softened.

**2026-09-23** — `docs/HARNESS.md` removed. Its context-health thresholds moved to `AGENTS.md`
§ Session Initialisation and its Dev Container invariants to the `CONTEXT.md` Architectural
Constraints; the rest restated the `implement` skill. Skills that pointed to it for CI/CD,
deployment, telemetry and secrets now point to where those live.

**2026-09-23** — `human:decision` is a state of the issue, not a separate issue. Refine asks its
open questions in the issue it blocks — multiple choice, recommendation first — and labels it
`human:decision`; the owner's comment is read back, and the label is removed when nothing is
open. One attempt budget (`KANBAN_MAX_RETRIES`) now covers every failure after `agent:backlog`
(tests, review rejection, CI, conflicts), recorded in an Attempts section; `agent:failed` means
the budget ran out, and a comment starts a new round. The file-based review counter is gone.

**2026-09-23 (later)** — labels are the pipeline's output, never written into a new issue.
`human:approval` is now a state set by the ship stage: once CI is green, a PR whose diff touches
a governance path (`GovernancePaths` in `lib/Config.ps1`) is held and the issue labelled; any
other PR merges. The owner can still add the label to force a hold. The plan stage no longer
labels child issues; its human:decision heuristic becomes a note in the child's body for refine.

**2026-09-23 (exercised)** — the hold ran end-to-end on #212 and exposed its missing end: after
the owner merged the held PR the issue kept `agent:reviewing` + `human:approval` and CONTEXT.md
was never updated. The PR's closed event now finishes a held issue (`Complete-HeldPR`): merged →
`agent:shipped` and the CONTEXT.md update, the same path as the pipeline's own merge; closed
unmerged → `agent:failed` at review, so the owner's comment starts the next attempt.

**2026-10-02** — one pipeline label per issue (#225). The pipeline labels are the `agent:*`
states plus the two `human:*` holds, and an issue carries exactly one: `Set-AgentState` is the
single setter and replaces whichever the issue has, so a held PR shows only `human:approval`
(Review lane) instead of `agent:reviewing` + `human:approval`, and `agent:backlog` replaces
`human:decision`. An owner's `human:approval` stays a merge-hold request: when a later state
replaces the label, `approval_required` in the carrier keeps it, and ship honours the flag. A
planned issue on `human:approval` never re-enters refine — neither the `afk.yml` comment
trigger nor the refine entry point picks it up.

Amendment rather than supersession: this ADR carries a living Implementation section by its
own design, and the refactor it describes had not finished landing when these surfaced.

## More Information

Supersedes the `HITL + AFK` label-pair mechanism and the `HITL and not AFK` alignment
condition. Builds on ADR-011 (issue-carried state), ADR-012 (GraphQL budget), ADR-013
(module structure and parameter passing) and ADR-014 (pre-backlog gate) — all of which keep
their original terminology as historical record.
