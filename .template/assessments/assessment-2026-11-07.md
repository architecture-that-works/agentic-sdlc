# SDLC Maturity Assessment — 2026-11-07

**Repository:** `my_template_repo`
**Assessor role:** Uncompromising Principal AI Engineer (per `ASSESSMENT_PROMPT.md` persona)
**Rubric version:** `ASSESSMENT_PROMPT.md` (2026-05-12 edition)
**Assessment date:** 2026-11-07
**Prior assessed score:** 3.50 / 10 (2026-06-27, `assessment-2026-06-27.md`)

---

## 1. Executive Brutal Summary

This is a Copier template whose product is not the application in `src/` but the **harness**
around it: a six-stage agentic pipeline (`refine`→`architect`→`plan`→`implement`→`review`→`ship`)
driven entirely by GitHub issue events, with a single-setter label/lane state machine, an
enforced write allowlist, an LLM-judge eval gate, and a post-merge self-improvement loop — every
one of which is wired and exercised, not documented. The single biggest bottleneck is now
criterion **3.7**: the three domain skills (`application-engineering` 396 lines,
`agentic-engineering` 371, `data-engineering` 302) are the three largest `SKILL.md` files in the
tree and the only ones still carrying no `REFERENCE.md` / `EXAMPLES.md` split, so the heaviest
context load in the `implement` stage is also the least progressively disclosed — one unmet
criterion that holds the entire Tier 4 gate shut despite 8/10 of Tier 4 and 5/13 of Tier 5
already being met. Closing it unlocks Tier 4 scoring and promotes the two genuine Tier 4 gaps
(no local `pyright`/`pytest` backpressure, orphaned codebase-map tool) to the critical path,
which day-to-day would mean an AI Architect stops paying a CI round-trip to discover a type
error the pre-commit hook could have caught in 10 seconds.

---

## 2. Inventory Findings

| # | Category | Finding |
|---|---|---|
| 1 | Reproducibility surface | `pyproject.toml` (`requires-python = "==3.14.*"`), `uv.lock` committed, `.python-version` = 3.14; no `requirements.txt` / `Pipfile` / `poetry.lock`; `src/config.py` loads via pydantic-settings |
| 2 | CI/CD spine | `checks.yml` — 8 jobs: lint, typecheck, test (`--cov-fail-under=80`), audit, guards, eval-scope, eval, secret-scan. **Every** `uses:` in all 6 workflows is 40-char SHA-pinned (zero tag refs). `dependabot.yml` covers `github-actions` + `pip` (grouped) + `docker` |
| 3 | Agent-native context layer | `AGENTS.md` 95 lines (router only); `CONTEXT.md` 112 lines (glossary, bounded contexts, Module Map, Issue-Type Index, Architectural Constraints); conditional routing to `tests/README.md`, `.agents/skills/README.md`, and two ADR indexes. No `.cursorrules` / `.copilotrules` / `.windsurfrules` / `.aider.conf.yml` |
| 4 | Skill system | 12 skills under `.agents/skills/`, each with `SKILL.md` + frontmatter, all ≤500 lines; 8 carry the full `REFERENCE.md` + `EXAMPLES.md` + `scripts/` spec; `write-skills` has REFERENCE+EXAMPLES, no scripts; the 3 domain skills have `SKILL.md` only |
| 5 | Stage orchestration | Issue body is the sole cross-runtime carrier (ADR-011): fenced `AGENT-STATE` JSON (`open_questions[]`, `decided_questions[]`, `attempts[]`, `failed_at`, `attempt_count`, `paused_until`) + Agent Brief / Decisions / Attempts sections. `.planning/` deliberately retired; one `claude` invocation per stage |
| 6 | Pipeline trigger | `afk.yml`: issue `opened`→refine; `agent:backlog` label→implement→review→ship; owner comment→answer-check or retry; any `feature/*` PR close→reconcile; hourly schedule→resume paused. `MaxRetries` 3/round; usage-limit pause ≤5 h |
| 7 | Decision lineage | `template/adr/` — 8 MADR ADRs (7 Accepted, ADR-010 Proposed) + `README.md` index, routed from `AGENTS.md` step 3. `docs/adr/` intentionally holds only `ADR_STRUCTURE.md` + `ADR-000` template. `adr-staging/` holds 7 application-domain ADRs (Copier-excluded) |
| 8 | Dev & build environment | `.devcontainer/devcontainer.json` — `python:3.14-bookworm` + github-cli/powershell/docker-in-docker features + postCreate (uv, `uv sync`, Claude CLI). `Dockerfile` builder→runtime multi-stage. `astral-sh/setup-uv` with `enable-cache: true` on all 6 uv-using jobs |
| 9 | Secure deployment | `deploy.yml` — Azure via `azure/login` federated credential, GCP via `google-github-actions/auth` `workload_identity_provider`; no long-lived cloud credentials; `SECURITY.md` documents both provisioning paths |
| 10 | Governance & permissions | `.github/CODEOWNERS` — 8 entries covering `AGENTS.md`, `CONTEXT.md`, `SECURITY.md`, `CODEOWNERS`, `docs/adr/`, `.github/workflows/`, `.github/checks/`, `.github/orchestrator/`. `WritablePaths` allowlist enforced pre-`git add`; `GovernancePaths` forces `human:approval`. Module Map is the context graph, validated by `check-module-map.ps1` |
| 11 | Adversarial review | **Absent.** No post-commit hook, no queue/worker pool, no cross-model-family reviewer. `engines/Gemini.ps1` exists but is HITL-only and never the reviewer of a Claude-authored diff |
| 12 | Semantic verification | Hypothesis PBT in `tests/utils/test_m_planning.py` (composite strategy over the readiness FSM), blocking in the `test` job. DeepEval harness in `tests/evals/` — GEval + AnswerRelevancy + ToolCorrectness, `ClaudeJudge`, gated by `eval-scope` path filter |
| 13 | EU AI Act Annex IV evidence | **Absent.** Zero regulation links in any ADR; no data-lineage manifest, drift/bias job, signed artifacts, or structured decision telemetry. Partial substitute only: the 🤖 signal-comment trail on each issue |
| 14 | Self-improvement loop | `Invoke-ContextUpdate` (`stages/Ship.ps1`) runs Haiku post-merge on the diff, applies a patch to `CONTEXT.md`, commits `chore(context)` to the default branch; handled failures never fail the merge (#269) |

---

## 3. Per-Tier Scorecard

### Tier 1 — AI Student / Hobbyist (8/8 criteria met)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1.1 | Atomic, message-bearing Git history | ✅ | `git log --oneline` on `main` is conventional-commit throughout, one squash per issue (`fix(orchestrator): one shared predicate…`); no `wip` chains |
| 1.2 | UV-managed Python with committed lock | ✅ | `pyproject.toml` + `uv.lock` committed; no competing resolver file in `git ls-files` |
| 1.3 | Canonical project manifest | ✅ | `pyproject.toml` holds build system, deps, `[dependency-groups]`, `[project.scripts]`, `[tool.pytest.ini_options]`; no `setup.py` / `setup.cfg` / `ruff.toml` |
| 1.4 | Pinned Python version | ✅ | `pyproject.toml:4` `==3.14.*`; `.python-version` 3.14; devcontainer `python:3.14-bookworm`; Dockerfile `uv:python3.14-bookworm-slim` + `python:3.14-slim` |
| 1.5 | `.gitignore` rejects secret patterns | ✅ | `.gitignore:12-21` — `.env`, `.env.*`, `*.key`, `*.pem`, `*.pfx`, `*secret*`, `*credential*`, with `!.env.example` re-included |
| 1.6 | Environment-driven configuration | ✅ | `src/config.py` pydantic-settings; `CONTEXT.md` Architectural Constraints bind "No hardcoded secrets"; `.env.example` is the only committed env file |
| 1.7 | One-command cold-clone runnability | ✅ | `uv sync && uv run python -m src.main`; `README.md` Quickstart, plus `docker build`/`docker run` path |
| 1.8 | README documents the bootstrap path | ✅ | `README.md` states Python version, `uv sync`, and `src/main.py` entrypoint |

**Tier 1 FULLY MET → proceed to Tier 2.**

---

### Tier 2 — Junior AI Engineer (7/7 criteria met)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 2.1 | Blocking format / lint gate | ✅ | `checks.yml:10-28` `lint` job — `ruff check .` + `ruff format --check .`, push + PR, per-step 1-min budget |
| 2.2 | Blocking static type gate | ✅ | `checks.yml:30-38` `typecheck` job — `uv run pyright` |
| 2.3 | Blocking supply-chain audit | ✅ | `checks.yml:50-58` `audit` job — `uv run pip-audit` |
| 2.4 | Blocking test + explicit coverage floor | ✅ | `checks.yml:48` — `pytest --cov=src --cov-report=term-missing --cov-fail-under=80`; floor explicit |
| 2.5 | Blocking secret-scanning gate | ✅ | `checks.yml:140-151` `secret-scan` job — `gitleaks/gitleaks-action@e0c47f4f…` with `fetch-depth: 0` |
| 2.6 | Autonomous dependency updates | ✅ | **Closed since 2026-06-27.** `dependabot.yml` now has three stanzas: `github-actions`, `pip` (with `runtime`/`dev` groups), `docker` |
| 2.7 | SHA-pinned third-party actions | ✅ | **Closed since 2026-06-27.** `grep -rn "uses:" .github/workflows/ \| grep -v "@[0-9a-f]\{40\}"` returns zero rows across all 6 workflows |

**Tier 2 FULLY MET → proceed to Tier 3.**

---

### Tier 3 — Medior AI Engineer (11/12 criteria met) ◄ BLOCKING TIER

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 3.1 | Root `AGENTS.md` as router | ✅ | `AGENTS.md` 95 lines (≤200). Pure routing: session-init order, Context Protocol, 4 Rules, skill index tables, Conditional Context. No embedded rules — those live in `CONTEXT.md` |
| 3.2 | Progressive-disclosure document tree | ✅ | Four specialized docs reached by conditional routing: `AGENTS.md` step 3 branches on task type between `template/adr/README.md` and `docs/adr/ADR_STRUCTURE.md`; § Conditional Context routes to `tests/README.md` and `.agents/skills/README.md`. **Path deviation, declared:** these sit beside what they describe rather than under `docs/`, by the 2026-11-06 segregation decision (`docs/` holds only empty templates for the generated project). The rubric names `docs/TESTING.md` as an *example* and declares file paths volatile (§7); the mechanism — conditional "for X, read Y" disclosure — is present and is what is scored |
| 3.3 | `CONTEXT.md` codifies design principles | ✅ | `CONTEXT.md` § Architectural Constraints binds **KISS** ("`src/main.py` uses `http.server`, not a web framework"), **Dependency Inversion** ("external I/O sits behind an interface declared in `src/`; `src/tools/` is exempt"), **DRY (Rule of Three)** ("extract to `src/utils/` only once duplicated three times; `architect` flags it"). TDD is bound as the method of `implement` (glossary § Method + `AGENTS.md` skill table). Each carries a named pattern example |
| 3.4 | No tool-specific rule silos | ✅ | No `.cursorrules` / `.copilotrules` / `.windsurfrules` / `.aider.conf.yml` anywhere. `.claude/settings.json` is permissions, not duplicated rules, and is itself validated by `check-settings` |
| 3.5 | `SKILL.md` files follow the open spec | ✅ | 12 skill directories, each with `SKILL.md` carrying `name` + `description` frontmatter |
| 3.6 | `SKILL.md` token discipline | ✅ | Largest is `application-engineering/SKILL.md` at 396 lines; all 12 ≤500 |
| 3.7 | Full skill-directory spec where complexity warrants | ❌ | `application-engineering` (396 lines), `agentic-engineering` (371), `data-engineering` (302) carry **`SKILL.md` only** — no `REFERENCE.md`, no `EXAMPLES.md`, no `scripts/`. These are the three largest skill files in the repository and `AGENTS.md` loads exactly one of them on **every** `implement` run, so the heaviest single context load in the pipeline is the least progressively disclosed. The "trivial conversational skills are exempt" carve-out does not reach a 396-line pattern library. Secondary: `write-skills` has REFERENCE+EXAMPLES but no `scripts/` (defensible — no deterministic operation to script) |
| 3.8 | MECE SDLC coverage | ✅ | Non-overlapping triggers across all five required phases: alignment `refine`, decomposition `plan`, TDD implementation `implement`, diagnosis `diagnosis` ("CI fails and the root cause is unclear — before attempting a fix"), architectural refinement `architect`. `AGENTS.md` tables assign exactly one trigger each; stage names match library script and label 1:1 (ADR-015) |
| 3.9 | Idempotent skill scripts | ✅ | 8 skills ship `scripts/`. State-check-before-mutate is observable: `stale-prs.ps1` upserts on a `<!-- stale-pr-check -->` marker rather than appending; `New-FeatureBranch` tests the remote before creating; `Set-AgentState` reads current labels and removes only what differs; `Add-IssueToBoard` resolves an existing item id first |
| 3.10 | Fresh-context-per-stage via on-disk state | ✅ | Externalized per-stage state with one model invocation per stage — the mechanism §2 describes. **Medium deviation, declared:** the carrier is the **issue body**, not local disk (ADR-011), chosen because the pipeline spans laptop and ephemeral GHA runners that share no filesystem; `.planning/` was retired for exactly that reason. State is a fenced `AGENT-STATE` JSON block read by `Get-IssueState` and written by `Set-PlanningState` at every transition, so a lost runner resumes the round rather than restarting it. Strictly more durable than the on-disk option the rubric names |
| 3.11 | Label-or-human-triggered agentic loop | ✅ | `afk.yml` `implement` job fires on `agent:backlog` label → `Invoke-Orchestration` → implement → review → ship → PR. Exercised continuously: 25 successful AFK runs in the last 200, PRs #253–#276 merged through it |
| 3.12 | Substantive ADR practice | ✅ | `template/adr/` — 8 ADRs in MADR format (Status / Context and Problem Statement / Considered Options / Decision Outcome / Consequences), 7 `Accepted`; indexed in `template/adr/README.md` and referenced from `AGENTS.md` step 3 and the `CONTEXT.md` Module Map. **Path deviation, declared:** the harness's own decisions live in `template/adr/` and `docs/adr/` starts empty on purpose — a template cannot ship another project's application decisions. The rubric scores *this repo as a harness*, and the harness's lineage is exactly what `template/adr/` holds |

**Tier 3 NOT fully met — score calculated here (blocking tier).**

---

### Tier 4 — Senior AI Engineer (8/10 criteria met, informational)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 4.1 | Devcontainer with AI toolchain | ✅ | `devcontainer.json` — `python:3.14-bookworm` + github-cli/powershell/docker-in-docker features; `postCreateCommand` installs uv, runs `uv sync`, installs `@anthropic-ai/claude-code`; no manual post-create steps |
| 4.2 | Multi-stage production Dockerfile | ✅ | `Dockerfile` — `builder` (`uv:python3.14-bookworm-slim`, deps) → `runtime` (`python:3.14-slim`, no build tooling); verified by `tests/test_dockerfile.py` |
| 4.3 | UV cache in CI | ✅ | `astral-sh/setup-uv@68559e99…` with `enable-cache: true` on lint, typecheck, test, audit, eval |
| 4.4 | OIDC / Workload Identity Federation | ✅ | `deploy.yml` — Azure federated credential, GCP `workload_identity_provider` + `service_account`; `SECURITY.md` § Deployment Credentials confirms no JSON key or SP secret is stored |
| 4.5 | `CODEOWNERS` gates governance files | ✅ | **Closed since 2026-06-27.** All seven rubric-named targets plus `.github/checks/` and `.github/orchestrator/`. Reinforced in-pipeline by `GovernancePaths`, which holds any PR touching them at `human:approval` regardless of branch protection |
| 4.6 | Substantive `SECURITY.md` | ✅ | **Closed since 2026-06-27.** (i) § Reporting a vulnerability — private GitHub advisory channel; (ii) § Secrets — per-secret scope/rotation/accepted-risk table; (iii) § Agent permission model — names `WritablePaths`, its enforcement point, and its test |
| 4.7 | Agent file-path permission boundaries | ✅ | `WritablePaths` in `lib/Config.ps1:78-82`; `Invoke-CommitAndPR` enumerates every changed path before any `git add` and aborts naming each offender; empty allowlist is itself a hard failure; `tests/orchestrator/test_implement_allowlist.py` covers in- and out-of-bounds. No `git add .` in the tree |
| 4.8 | Pre-computed codebase map / context graph | ❌ | No generated index is committed. `src/tools/codebase_map.py` (PageRank symbol map, `codebase-map` console entry point, full test file) **exists but is orphaned** — ADR-009's addendum deliberately removed the committed artifact and made the `CONTEXT.md` Module Map the single source of truth, yet left the generator and its tests behind. Nothing in `AGENTS.md`, any workflow, or any skill invokes it |
| 4.9 | LLM-optimized error messages | ✅ | `Format-ErrorBlock` (`lib/Util.ps1:88-104`) pipes raw pytest/ruff/traceback output through `src/utils/m_error_formatter.py` → error class, likely cause, salient frames, failing assertion, full output preserved in `<details>`. Injected back into agent context as a 🤖 signal comment, which `Invoke-Develop` feeds into the next attempt's prompt. Kill criterion documented (#119) |
| 4.10 | Local pre-commit harness mirrors CI | ❌ | `.pre-commit-config.yaml` runs `ruff check` + `ruff format --check` only — 2 of the 7 blocking CI gate classes. `pyright` and `pytest`, the two that actually catch agent errors, are absent, so the agent first meets that backpressure in CI, one full round trip late. The config's own 60 s/hook budget note (#120) is the stated reason |

---

### Tier 5 — Principal AI Engineer (5/13 criteria met, informational)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 5.1 | Label-triggered fully autonomous SDLC | ✅ | `agent:backlog` → implement → review → ship → PR, zero human keystrokes. Backlog drain re-dispatches while labelled issues remain. Exercised throughout PRs #253–#276 |
| 5.2 | Autonomous CI-failure diagnose-and-patch loop | ✅ | `Invoke-Ship` polls `gh pr checks`; on red it pulls `gh run view --log-failed` (`Get-FailedCheckLog`), posts it as a 🤖❌ signal comment, and throws. The conductor catches, records the attempt in the carrier, and re-enters `Invoke-Develop`, whose instruction 0 directs the agent to the `diagnosis` skill with the failure logs in context — a new commit lands before any human is paged. Exhaustion explicit: `MaxRetries` 3/round → `agent:failed`; usage limit pauses instead of counting an attempt |
| 5.3 | Multi-model review on every commit | ❌ | Absent. No post-commit hook, no queue/worker pool. `Invoke-Review` is the same model family as the author (`engines/Claude.ps1`), and `Gemini.ps1` is HITL-only — never wired as reviewer of a Claude-authored diff |
| 5.4 | Adversarial review covers structural drift | ❌ | Absent as a distinct mechanism. `architect` computes blast radius and flags Rule-of-Three duplication, but no reviewing agent systematically checks cyclomatic complexity, dead code, missing fixtures, or drift against `CONTEXT.md`/ADRs and feeds findings back as a refinement loop |
| 5.5 | Property-Based Testing as a blocking gate | ✅ | `hypothesis>=6.170.15`; `tests/utils/test_m_planning.py` uses a composite `_planning_state` strategy over the readiness FSM (`is_ready_for_backlog` iff-invariant, `model_dump` round-trip, `@settings(max_examples=50)`). Runs under the default `pytest` invocation → blocking in the `test` job |
| 5.6 | LLM-as-a-judge evaluation harness | ✅ | DeepEval in `tests/evals/` with **three** of the named metric families — `GEval` (`conventional_commit`, `refine_rules`), `AnswerRelevancyMetric`, `ToolCorrectnessMetric` — judged by `ClaudeJudge`, thresholds 0.7. Gated by `checks.yml` `eval-scope`/`eval`: blocking on any PR touching `.agents/skills/`, `orchestrator/stages/`, `lib/Grill.ps1`, `src/tools/commit.py`, or `tests/evals/` |
| 5.7 | Architecture-decision lineage linked to regulation | ❌ | Zero EU AI Act article references across `template/adr/`, `docs/adr/`, `adr-staging/`; no CI script validating linkage |
| 5.8 | Data lineage & provenance manifest | ❌ | Absent. No DVC / lakeFS / content-addressed manifest. (Arguably not applicable until a generated project carries model-influencing data — but the rubric is binary) |
| 5.9 | Drift / bias / performance monitoring in CI | ❌ | Absent. The `eval` job scores component quality against goldens; it does not track drift, audit bias, or trend metrics across runs |
| 5.10 | Signed & archived validation artifacts | ❌ | `eval` uploads `logs/evals/` via `actions/upload-artifact`, but nothing is signed — no `gh attestation`, Sigstore, or cosign anywhere in `.github/workflows/` |
| 5.11 | Immutable agent decision telemetry | ❌ | No structured per-action trace to an append-only sink. Partial substitute: the 🤖 signal-comment trail plus the carrier's `attempts[]` give a reviewable decision history, and `tests/evals/eval_results.py` emits OTLP — but only for evals, and the carrier is a mutable issue body |
| 5.12 | Documented human-override workflow | ✅ | `SECURITY.md` § Human Oversight — Halt / Override / Roll back, each with a runnable mechanism (`gh workflow disable afk.yml`, `gh run cancel`, close/reopen the issue, `workflow_dispatch` with `stage`, `task retry ISSUE=<n>`, PR Revert) and each explicitly usable from the GitHub mobile app |
| 5.13 | Self-updating context | ✅ | `Invoke-ContextUpdate` (`stages/Ship.ps1:23`) runs post-merge on the squashed diff, applies a unified patch to `CONTEXT.md`, commits `chore(context)` to the default branch. Observable in `git log -- CONTEXT.md`. Handled failures reset `$LASTEXITCODE` so the merge step never fails on a context miss (#269) |

---

## 4. Critical Weaknesses & Vulnerabilities

**Criterion 3.7 — three domain skills carry no `REFERENCE.md` / `EXAMPLES.md` (blocking)**
`application-engineering/SKILL.md` (396 lines), `agentic-engineering/SKILL.md` (371) and
`data-engineering/SKILL.md` (302) are the three largest skill files in the repository, and
`AGENTS.md` instructs the agent to "load exactly one" on **every** `implement` run. Their content
is reference material — patterns, library choices, worked idioms — all of it loaded
unconditionally even when the task touches one pattern. This is the exact failure mode
progressive disclosure exists to prevent, and it is worst in the hottest path. No open issue
tracks it. **New issue required.**

**Criterion 4.8 — orphaned codebase-map generator (Tier 4 gap)**
`src/tools/codebase_map.py` is a complete PageRank symbol-map generator with a `codebase-map`
console entry point in `pyproject.toml` and a dedicated test file — and **nothing invokes it**.
ADR-009's addendum deliberately removed the committed map artifact, declaring the `CONTEXT.md`
Module Map the single source of truth and 4.8 "no longer satisfied"; the generator was left
behind. The repository therefore maintains a tool and its tests for a decision it already
reversed. Two coherent resolutions — wire it (regenerate script + `AGENTS.md` reference +
committed artifact) to close 4.8, or delete it and record 4.8 as permanently waived by ADR-009.
Carrying it unreferenced is the one option that is wrong either way. **New issue required
(decision).**

**Criterion 4.10 — pre-commit covers 2 of 7 CI gate classes (Tier 4 gap)**
`.pre-commit-config.yaml` runs only `ruff check` and `ruff format --check`. `pyright` and
`pytest` — the gates that actually catch what an agent gets wrong — run exclusively in CI, so
every type error or broken test costs a full implement→push→CI→retry cycle instead of being
caught before the commit. The config's 60 s/hook budget (#120) is the stated reason and is
sound for `pytest` on a large suite; it does not rule out `pyright` on changed files, or a
fast-subset `pytest`. **New issue required.**

**Criteria 5.3 / 5.4 — no adversarial cross-family review (Tier 5 gap)**
`Invoke-Review` judges a Claude-authored diff with Claude. Same family, same blind spots — the
cycle-of-self-deception the rubric's §12 exists to break. `engines/Gemini.ps1` already
implements the adapter surface needed to make Gemini the reviewer; it is only ever selected for
local HITL runs, and `afk.yml` pins `KANBAN_ENGINE: claude` because the cloud runners install
only the Claude CLI. The gap is wiring and a CLI install, not architecture.

**Criteria 5.7–5.11 — EU AI Act Annex IV evidence absent (Tier 5 gap)**
No ADR carries a regulation link, nothing is signed or attested, and no per-action structured
trace reaches an append-only sink. For a template that intends to be used on regulated work
this is the largest remaining block of the rubric, and 5.10 (sign and archive what CI already
uploads) is the cheapest entry point into it.

**Not a rubric criterion — the pipeline cannot heal a dead runner (highest practical risk)**
Four non-terminal states have **no detection and no automatic recovery**:

| Stuck state | Cause | Detected? | Recovered? |
|---|---|---|---|
| `agent:implementing` | runner lost, job cancelled, 6 h GHA timeout, OOM | ❌ | manual `task retry` |
| `agent:reviewing` | same, after review set the label | weekly comment only, and only while an open PR exists | manual |
| `agent:backlog` | the drain step's `gh workflow run` re-dispatch failed | ❌ | manual |
| *no label at all* | the `refine` job died before labelling (npm/uv install 503, CLI 500) | ❌ | manual dispatch |

Only `agent:paused` self-heals (hourly `resume` job), and `stale-prs.yml` only *comments*, weekly,
and explicitly never touches a label. `SECURITY.md:97-98` documents the recovery as a manual
`task retry`. Every automatic recovery path the pipeline has depends on the conductor's own
`try`/`catch` — which a killed process never runs. For the stated goal (file an issue from
mobile and not think about it again) this, not any rubric criterion, is the binding constraint.
**New issue required.**

**Minor — stale function names in the template ADR index**
`template/adr/README.md` cites `Get-KanbanContext` (ADR-013 row) and `Invoke-Alignment`
(ADR-014 row). Both were renamed — `Get-OrchestratorContext` and `Invoke-Orchestration -From
refine`. `check-doc-paths.ps1` validates paths, not symbol names, so nothing caught it.

**Minor — `ASSESSMENT_PROMPT.md` § After Assessment is stale**
It instructs the assessor to "Update `README.md` — change the SDLC Maturity section". That
section was deliberately removed from `README.md` on 2026-11-06 because it shipped into every
generated project. The instruction now points at nothing; the artifact belongs in
`template/dev-notes/`.

---

## 5. Strengths & Foundation

**One setter for the label/lane state machine.** `Set-AgentState` (`lib/GitHub.ps1:652`) is the
sole writer of every `agent:*`/`human:*` label, and it moves the board lane in the same call
from a switch table — so a label and its lane cannot disagree. It also enforces the readiness
gate on `agent:backlog` entry and preserves an owner's `human:approval` as `approval_required`
in the carrier when a later state replaces the label. Three separate bugs (#252, #266, #275)
traced to this rule being *duplicated*; the fix was to collapse it to one exported predicate,
`Test-IssueShipped`, called by both `Complete-HeldPR` and `afk.yml`'s cheap pre-check.

**The write allowlist is enforced, not advised.** `Invoke-CommitAndPR` enumerates every changed
path against `WritablePaths` before any `git add` and aborts with each offender named; a missing
or empty allowlist is itself a hard failure. The `plan` stage checks the same list *before*
granting `agent:backlog` (`Get-UnwritablePaths`, #223), so work the agent structurally cannot
commit is held for a human up front rather than burning three failed attempts — a genuinely
unusual piece of design, and it caught #273 live.

**Failure context is engineered for the next attempt.** Raw pytest/ruff/traceback output goes
through `m_error_formatter` into error class / likely cause / salient frames / full output, posts
as a 🤖 signal comment, and `Invoke-Develop` replays the whole signal history into the retry
prompt with instruction 0 pointing at the `diagnosis` skill. The retry is strictly better
informed than the attempt that failed, which is what makes 5.2 real rather than a retry counter.

**The carrier survives the runtime.** ADR-011's choice to put `AGENT-STATE` in the issue body
means a lost GHA runner resumes a round instead of restarting it, the laptop and the cloud read
identical state, and the audit trail is where the human already looks. `.planning/` was
retired for this; the decision is documented and the mechanism is consistent.

**Governance is enforced twice, independently.** `CODEOWNERS` covers the eight governance
targets, and `GovernancePaths` independently holds any PR touching them at `human:approval`
regardless of branch-protection configuration. The agent's own review cannot be the last word
on the rules binding it — and that is true even on a fresh clone with no branch protection set.

**Supply chain is fully closed.** Zero tag-pinned actions across all six workflows (the 2026-06-27
blocker), three Dependabot ecosystems including `docker`, `pip-audit` blocking, gitleaks with
full history. Both Tier 2 failures from the last assessment are closed with observable artifacts.

**Human oversight is written for the phone.** `SECURITY.md` § Human Oversight gives halt,
override and rollback paths that each work from the GitHub mobile app — which is the actual
deployment target for how this repo is meant to be driven.

---

## 6. The Verdict (Score & Role Mapping)

```
5.75 / 10 — Medior AI Engineer
11/12 criteria met at [5–6] — full tier above is not yet unlocked
```

Tier 1 (AI Student / Hobbyist): **8/8** — fully met. Reproducibility, hygiene and bootstrap are
complete; the Python pin is consistent across `pyproject.toml`, `.python-version`, the
devcontainer and both Dockerfile stages.

Tier 2 (Junior AI Engineer): **7/7** — fully met, and both blockers from 2026-06-27 are closed.
Criterion 2.7: every `uses:` across all six workflows is 40-char SHA-pinned (zero tag
references). Criterion 2.6: `dependabot.yml` now carries the `docker` ecosystem alongside
`github-actions` and a grouped `pip`.

Tier 3 (Medior AI Engineer): **11/12** — blocking tier. Ten criteria are met outright. Two are
met on mechanism with a declared path/medium deviation that the rubric's own §7 ("mechanism, not
file path — those are volatile") authorises: 3.2 places its specialized docs beside what they
describe rather than under `docs/`, and 3.10 externalizes per-stage state to the issue body
rather than local disk because the pipeline spans a laptop and ephemeral runners with no shared
filesystem (ADR-011). One criterion fails outright: **3.7** — `application-engineering`,
`agentic-engineering` and `data-engineering` carry `SKILL.md` only, at 396/371/302 lines, and one
of them loads on every `implement` run.

Tier 4 (Senior AI Engineer): **8/10** (informational — not claimable while Tier 3 is open).
Gaps: 4.8 (no committed map; the generator is orphaned) and 4.10 (pre-commit covers 2 of 7 CI
gate classes).

Tier 5 (Principal AI Engineer): **5/13** (informational). Met: 5.1, 5.2, 5.5, 5.6, 5.12, 5.13.
Open: adversarial cross-family review (5.3, 5.4) and the whole Annex IV block (5.7–5.11).

Score formula, blocking tier Tier 3: `base(4) + (11/12) × 2 = 4 + 1.8333 = 5.8333` → rounded to
nearest 0.25 → **5.75 / 10**.

Movement since 2026-06-27: **3.50 → 5.75** (+2.25). The jump is structural, not cosmetic — it
closed an entire tier gate (Tier 2) and then 11 of 12 criteria of the next one, while Tier 4
independently went 4/10 → 8/10 and Tier 5 went 2/13 → 5/13.

---

## 7. The Path to the Next Tier

**Step 1 — Split the three domain skills into the full directory spec (unlocks 3.7, closes Tier 3)**
Extract pattern catalogues and worked idioms out of `application-engineering`,
`agentic-engineering` and `data-engineering` into `REFERENCE.md` + `EXAMPLES.md` beside each,
leaving a `SKILL.md` that states the trigger, the non-negotiables, and when to read the adjacent
files. Target ≤150 lines per `SKILL.md`. Omit `scripts/` where there is no deterministic
operation — and say so in the skill, so the absence reads as a decision rather than an
oversight. This is the single criterion standing between 5.75 and Tier 4 scoring. No existing
issue. Unlocks: **3.7**.

**Step 2 — Add the missing CI gates to pre-commit (unlocks 4.10)**
Add `pyright` on changed files and a fast `pytest` subset to `.pre-commit-config.yaml`, keeping
the 60 s/hook budget by scoping both to the staged set rather than the whole tree. The win is
agent round-trip latency: every type error caught locally is one implement→push→CI→retry cycle
not spent. No existing issue. Unlocks: **4.10**.

**Step 3 — Resolve the orphaned codebase-map generator (unlocks 4.8, or waives it on the record)**
Decide and execute: wire `src/tools/codebase_map.py` into a regenerate step, reference it from
`AGENTS.md`, and commit the artifact — or delete the tool and its test and amend ADR-009 to
record 4.8 as permanently waived in favour of the `CONTEXT.md` Module Map. Recommended: delete
and waive, because a second map competing with the Module Map contradicts ADR-009's own single-
source-of-truth decision, and a generated artifact nothing reads is rubric-chasing. No existing
issue. Unlocks: **4.8** (or removes it from scope with a documented rationale).

**Step 4 — Make the pipeline reconcile its own stuck states (unlocks no criterion; highest practical value)**
Extend the existing hourly `schedule` job from "resume `agent:paused`" to a full reconciler over
the label state machine: for every open issue, compare its label against live workflow runs and
last activity, and re-dispatch the owning stage when the label claims work that nothing is
doing — bounded by a reconcile counter in the carrier so a genuinely broken issue lands on
`agent:failed` with an explanation instead of looping. Derive the behaviour from one table keyed
on the same labels `Set-AgentState` writes, so the state machine stays single-sourced. This
closes the four undetected stuck states in §4 and is what makes "file it from mobile and forget
it" true. No existing issue.

**Step 5 — Make Gemini the reviewer of Claude-authored diffs (unlocks 5.3, partially 5.4)**
Install the Gemini CLI on the AFK runner and route `Invoke-Review` to the non-authoring family
while `implement` stays on Claude. The engine adapter (`engines/Gemini.ps1`) and the
`KANBAN_ENGINE` indirection already exist; this is a per-stage engine selection plus a runner
install, not new architecture. Extend the review rubric to name duplication, dead code, missing
fixtures and drift against `CONTEXT.md`/ADRs explicitly, and the same change reaches 5.4.
Unlocks: **5.3**, and **5.4** with the rubric extension.

---

## After Assessment

This artifact is the record — there is no longer an SDLC Maturity section in `README.md` to
update (removed 2026-11-06: it shipped into every generated project, where a score about the
*template* is meaningless). Keep assessments in `template/dev-notes/`, which `copier.yml`
excludes.
