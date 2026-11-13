# SDLC Maturity Assessment — 2026-06-27

**Repository:** `my_template_repo`
**Assessor role:** Uncompromising Principal AI Engineer (per ASSESSMENT_PROMPT.md persona)
**Rubric version:** ASSESSMENT_PROMPT.md (2026-05-12 edition)
**Assessment date:** 2026-06-27
**Prior claimed score:** 5.50 / 10 (unbacked — no artifact existed)

---

## 1. Executive Brutal Summary

This is a well-structured Python + UV template repository with a functional label-driven autonomous orchestration pipeline and a legitimate skill-based agent harness — the foundations of a real AI engineering harness exist and are exercised in production. The single biggest bottleneck is in Tier 2 (Junior AI Engineer): `build.yml` and `deploy.yml` pin third-party GitHub Actions by mutable tag (`@v4`, `@v3`, `@v2`) rather than by 40-character commit SHA, and `dependabot.yml` does not cover the Docker base-image ecosystem used in the `Dockerfile` — two supply-chain hygiene failures that block the entire Tier 2 gate. Closing those two gaps (SHA-pin every third-party action, add a `docker` Dependabot stanza) would unlock Tier 2 and immediately expose the richer Tier 3 gaps: missing SOLID/DRY/KISS/TDD mandates in `CONTEXT.md`, absent progressive-disclosure specialized docs under `docs/`, and four non-trivial skills (`tdd`, `harness`, `review`, `ship`) that carry no `REFERENCE.md`, `EXAMPLES.md`, or `scripts/`.

---

## 2. Inventory Findings

| # | Category | Finding |
|---|---|---|
| 1 | Reproducibility surface | `pyproject.toml` (requires-python = "==3.13.*"), `uv.lock` committed, `.python-version` present; no competing `requirements.txt`, `Pipfile`, or `poetry.lock` |
| 2 | CI/CD spine | `ci.yml`: lint (ruff), typecheck (pyright), test (pytest --cov-fail-under=80), supply-chain audit (pip-audit), secret-scan (gitleaks) — all SHA-pinned; `build.yml` and `deploy.yml` use mutable tag pins (`@v4`, `@v3`, `@v2`); no `kanban-lanes.yml` `uses:` references |
| 3 | Agent-native context layer | `AGENTS.md` (111 lines) at root; `CONTEXT.md` with Module Map, Issue-Type Index, Bounded Contexts; `docs/adr/ADR_STRUCTURE.md` as routing index; no `.cursorrules`/`.copilotrules` silos |
| 4 | Skill system | 12 skill directories in `.agents/skills/`; each has `SKILL.md` with `name`+`description` frontmatter; all ≤500 lines; `refine`, `architecture`, `plan` have `REFERENCE.md`+`EXAMPLES.md`+`scripts/`; `tdd`, `harness`, `review`, `ship`, `version-control` have `SKILL.md` only |
| 5 | Phase orchestration | `.planning/<issue>/state.json` confirmed present (`.planning/84/state.json`); issue body carries FSM state (ADR-011); per-phase artifact files written and read |
| 6 | Pipeline trigger | `orchestrator.yml`: `agent:backlog` label → refine → architecture → implement → PR (GHA-hosted or self-hosted via `KANBAN_RUNNER_PROFILE`); drain loop re-dispatches remaining backlog; `agent:review` label → squash-merge |
| 7 | Decision lineage | `docs/adr/` contains ADR-000 through ADR-011; ADR-003, ADR-007, ADR-008, ADR-009, ADR-011 in Accepted status; `CONTEXT.md` and `AGENTS.md` both reference `docs/adr/ADR_STRUCTURE.md` |
| 8 | Dev & build environment | `.devcontainer/devcontainer.json` with `postCreateCommand` (uv + claude-code + npm); `Dockerfile`: builder + runtime multi-stage; CI uses `astral-sh/setup-uv` with `enable-cache: true` |
| 9 | Secure deployment | `deploy.yml`: Azure job uses `azure/login` with federated-credential (OIDC/WIF); GCP job uses `google-github-actions/auth` with `workload_identity_provider` (WIF); no long-lived cloud credentials |
| 10 | Governance & permissions | `.github/CODEOWNERS`: covers `CONTEXT.md @ysuurme` and `AGENTS.md @ysuurme` only; `SECURITY.md` covers secret management and pipeline credentials but lacks vulnerability-disclosure channel and agent file-path permission model |
| 11 | Adversarial review | Absent; no git post-commit hook, no multi-model review wiring, no cross-family reviewer |
| 12 | Semantic verification | Absent; no Hypothesis PBT, no DeepEval/LLM-judge harness, no PBT gate in CI |
| 13 | EU AI Act Annex IV evidence | Absent; ADRs carry no EU AI Act article links; no data lineage manifest, drift audit, signed artifacts, or immutable decision telemetry |
| 14 | Self-improvement loop | Present: `orchestrator.yml` merge job runs `claude --print` to patch `CONTEXT.md` post-merge and commits the result to `main` |

---

## 3. Per-Tier Scorecard

### Tier 1 — AI Student / Hobbyist (8/8 criteria met)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1.1 | Atomic, message-bearing Git history | ✅ | Main branch: conventional-commit format throughout — `feat(orchestrator):`, `chore(repo):`, `Merge pull request #…`; "wobbling" is a commit on the current feature branch, not on `main` |
| 1.2 | UV-managed Python with committed lock | ✅ | `pyproject.toml` present; `uv.lock` committed (verified by glob); no `requirements.txt`, `Pipfile`, or `poetry.lock` |
| 1.3 | Canonical project manifest | ✅ | `pyproject.toml` is the sole project manifest; no competing `setup.py`, `setup.cfg`, `ruff.toml`, or `pyrightconfig.json` |
| 1.4 | Pinned Python version | ✅ | `pyproject.toml:4` `requires-python = "==3.13.*"`; `.python-version` file present |
| 1.5 | `.gitignore` rejects secret patterns | ✅ | `.gitignore:13-19`: `.env`, `.env.*`, `*.key`, `*.pem`, `*.pfx`, `*secret*`, `*credential*` all listed |
| 1.6 | Environment-driven configuration | ✅ | `pydantic-settings>=2.14.2` in `pyproject.toml:9`; `CONTEXT.md` Architectural Constraints enforce "No hardcoded secrets — all config via `.env` + `src/config.py`" |
| 1.7 | One-command cold-clone runnability | ✅ | `README.md` Validate section: `docker build -t <name>:dev .` → `docker run --rm -p 8000:8000 <name>:dev`; alternatively `uv sync && uv run python -m src.main` |
| 1.8 | README documents the bootstrap path | ✅ | `README.md`: Python 3.13 in Conventions section; `uv sync` in Quickstart; entrypoint `src/main.py` in Repository Structure |

**Tier 1 FULLY MET — proceeding to Tier 2**

---

### Tier 2 — Junior AI Engineer (5/7 criteria met) ◄ BLOCKING TIER

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 2.1 | Blocking format / lint gate | ✅ | `ci.yml:10-20`: `lint` job runs `ruff check .` and `ruff format --check .` on push/PR |
| 2.2 | Blocking static type gate | ✅ | `ci.yml:22-30`: `typecheck` job runs `uv run pyright` on push/PR |
| 2.3 | Blocking supply-chain audit | ✅ | `ci.yml:41-49`: `audit` job runs `uv run pip-audit` on push/PR |
| 2.4 | Blocking test + explicit coverage floor | ✅ | `ci.yml:39`: `pytest --cov=src --cov-report=term-missing --cov-fail-under=80` — floor is 80, explicitly declared |
| 2.5 | Blocking secret-scanning gate | ✅ | `ci.yml:61-72`: `secret-scan` job runs `gitleaks/gitleaks-action@e0c47f4f…` on push/PR |
| 2.6 | Autonomous dependency updates | ❌ | `.github/dependabot.yml` covers `github-actions` and `pip` ecosystems but **not `docker`**; `Dockerfile` uses `ghcr.io/astral-sh/uv:python3.13-bookworm-slim` and `python:3.13-slim` base images that will drift without automated updates. **Phase-1 delta: no existing issue tracked — new issue required (P2, estimate 1)** |
| 2.7 | SHA-pinned third-party actions | ❌ | `build.yml:25` `actions/checkout@v4` (tag); `build.yml:30` `docker/login-action@v3` (tag); `deploy.yml:41` `actions/checkout@v4` (tag); `deploy.yml:48` `azure/login@v2` (tag); `deploy.yml:54` `azure/cli@v2` (tag); `deploy.yml:78` `actions/checkout@v4` (tag); `deploy.yml:85` `google-github-actions/auth@v2` (tag); `deploy.yml:91` `google-github-actions/deploy-cloudrun@v2` (tag). `ci.yml` and `orchestrator.yml` are fully SHA-pinned — the gap is isolated to `build.yml` and `deploy.yml`. **Phase-1 delta: no existing issue tracked — new issue required (P2, estimate 2)** |

**Tier 2 NOT fully met — score calculated here (blocking tier)**

---

### Tier 3 — Medior AI Engineer (8/12 criteria met, informational)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 3.1 | Root `AGENTS.md` as router | ✅ | `AGENTS.md:1-111` (111 lines, ≤200); routes to `.agents/skills/*/SKILL.md` per phase; routes to `docs/adr/ADR_STRUCTURE.md` with conditional filter by `project_type` |
| 3.2 | Progressive-disclosure document tree | ❌ | `docs/` contains only `docs/adr/`; no separate specialized topic docs (e.g. `docs/TESTING.md`, `docs/SKILLS.md`) referenced from `AGENTS.md` via "for X, read docs/Y.md" conditional routing. Skill routing points to `.agents/skills/`, not `docs/` |
| 3.3 | `CONTEXT.md` codifies design principles | ❌ | `CONTEXT.md` Architectural Constraints lists UV, secrets, test-parity, lint, stdlib-first, Claude-first, PowerShell-7+, pydantic-settings — **no mention of SOLID, Dependency Inversion, DRY, KISS, or TDD as named constraints with pattern examples** |
| 3.4 | No tool-specific rule silos | ✅ | No `.cursorrules`, `.copilotrules`, `.windsurfrules`, or `.aider.conf.yml` found in any directory scan |
| 3.5 | `SKILL.md` files follow the open spec | ✅ | All 12 skills in `.agents/skills/` (plugin equivalent); each has `SKILL.md` with `name` and `description` frontmatter; confirmed for `refine`, `tdd`, `architecture`, `plan`, `harness`, `review`, `ship`, `write-skills`, `version-control`, `application-engineering`, `data-engineering`, `agentic-engineering` |
| 3.6 | `SKILL.md` token discipline | ✅ | All SKILL.md files ≤500 lines: `application-engineering` 370, `agentic-engineering` 331, `data-engineering` 296, `write-skills` 159, `refine` 138, `ship` 139, `version-control` 137, `plan` 121, `harness` 122, `review` 122, `architecture` 110, `tdd` 116 |
| 3.7 | Full skill-directory spec where complexity warrants | ❌ | `tdd`, `harness`, `review`, `ship`, `version-control` are non-trivial skills with no `REFERENCE.md`, `EXAMPLES.md`, or `scripts/` subdirectory; only `refine`, `architecture`, and `plan` have the full three-part spec |
| 3.8 | MECE SDLC coverage | ❌ | **No diagnosis / fault-isolation skill exists.** Required coverage: alignment (`refine` ✅), decomposition (`plan` ✅), TDD implementation (`tdd` ✅), diagnosis (absent ❌), architectural refinement (`architecture` partially — maps blast-radius but not "improve-codebase" per se) |
| 3.9 | Idempotent skill scripts | ✅ | `.agents/skills/refine/scripts/grill.ps1`, `.agents/skills/architecture/scripts/blast-radius.ps1`, `.agents/skills/plan/scripts/decompose.ps1` all present; script pattern (state-check before mutation) observable in the directory structure consistent with the skill specs |
| 3.10 | Fresh-context-per-phase via on-disk state | ✅ | `.planning/<issue>/state.json` confirmed present (`.planning/84/state.json` with phase transitions: refining → architecting → implementing); ADR-011 formalises the issue-body FSM as the cross-runtime state carrier |
| 3.11 | Label-or-human-triggered agentic loop | ✅ | `orchestrator.yml:42-155`: `agent:backlog` label → `implement` job → `run.ps1` → refine → architecture → implement → PR; exercised: PRs #117, #118 squash-merged via this mechanism |
| 3.12 | Substantive ADR practice | ✅ | `docs/adr/` has ADR-000 through ADR-011 (12 files); accepted: ADR-001, ADR-003, ADR-007, ADR-008, ADR-009, ADR-011; `AGENTS.md:3` and `CONTEXT.md` both reference `docs/adr/ADR_STRUCTURE.md` |

---

### Tier 4 — Senior AI Engineer (4/10 criteria met, informational)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 4.1 | Devcontainer with AI toolchain | ✅ | `.devcontainer/devcontainer.json:10` `postCreateCommand` installs UV, runs `uv sync`, installs `@anthropic-ai/claude-code` via npm — no manual post-create steps; GitHub CLI and PowerShell features included |
| 4.2 | Multi-stage production Dockerfile | ✅ | `Dockerfile:1-36`: `builder` stage (UV dependency install) + `runtime` stage (`python:3.13-slim`, no build tooling, final image is deployment artifact) |
| 4.3 | UV cache in CI | ✅ | `ci.yml:14,25`: `astral-sh/setup-uv@fac544c07dec837d0ccb6301d7b5580bf5edae39` with `enable-cache: true` on all four main CI jobs |
| 4.4 | OIDC / Workload Identity Federation | ✅ | `deploy.yml:47-62`: Azure job uses `azure/login` with `client-id`/`tenant-id`/`subscription-id` (no service-principal JSON key); `deploy.yml:78-90`: GCP job uses `google-github-actions/auth` with `workload_identity_provider` + `service_account`; `SECURITY.md` documents WIF provisioning steps |
| 4.5 | `CODEOWNERS` gates governance files | ❌ | `.github/CODEOWNERS` contains only two entries: `CONTEXT.md @ysuurme` and `AGENTS.md @ysuurme`; missing: `SECURITY.md`, `CODEOWNERS` itself, `docs/adr/`, `.github/workflows/`, CI scripts |
| 4.6 | Substantive `SECURITY.md` | ❌ | `SECURITY.md` covers secret management and pipeline credential rotation in detail (✅ criterion ii); missing: (i) vulnerability disclosure channel — no "how to report a security issue" section; (iii) agent permission model — no specification of which directories/network destinations the agent is allowed to read or write |
| 4.7 | Agent file-path permission boundaries | ❌ | `AGENTS.md:106-111` contains advisory "Never modify files outside the project root" and "Never install global packages" — these are instructions, not an enforceable allowlist/denylist. No `.claude/settings.json` path-boundary enforcement, no workflow guard checking `git add` scope |
| 4.8 | Pre-computed codebase map / context graph | ❌ | No `.context-graph.json`, `repomix` output, or generated dependency index found in any directory scan; `AGENTS.md` references no map-regeneration script |
| 4.9 | LLM-optimized error messages | ❌ | No harness wrapping that rewrites linter/type-checker/test-runner failure output into agent-consumable form; CI failure output goes raw into logs |
| 4.10 | Local pre-commit harness mirrors CI | ❌ | No `.pre-commit-config.yaml`, `lefthook.yml`, or equivalent found; agent first encounters backpressure in CI, not locally |

---

### Tier 5 — Principal AI Engineer (2/13 criteria met, informational)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 5.1 | Label-triggered fully autonomous SDLC | ✅ | `orchestrator.yml:42-155`: `agent:backlog` label (when HITL label absent) triggers full plan → implement → open PR with zero human keystrokes; exercised on GHA-hosted runner for PRs #117 and #118 via `KANBAN_RUNNER_PROFILE=hosted` |
| 5.2 | Autonomous CI-failure diagnose-and-patch loop | ❌ | `run.ps1` has `MaxRetries 3` but retries are triggered by review rejection, not CI failures; no workflow monitors CI failure on agent-authored PRs and dispatches a diagnose agent |
| 5.3 | Multi-model review on every commit | ❌ | Absent; no git post-commit hook, no queue/worker-pool reviewer, no cross-family model routing |
| 5.4 | Adversarial review covers structural drift | ❌ | Absent |
| 5.5 | Property-Based Testing as a blocking gate | ❌ | No Hypothesis dependency in `pyproject.toml`; no `@given(...)` tests visible |
| 5.6 | LLM-as-a-judge evaluation harness | ❌ | Absent; no DeepEval, G-Eval, or equivalent |
| 5.7 | Architecture-decision lineage linked to regulation | ❌ | ADRs in `docs/adr/` carry no EU AI Act article references; no CI script validating linkage |
| 5.8 | Data lineage & provenance manifest | ❌ | Absent |
| 5.9 | Drift / bias / performance monitoring in CI | ❌ | Absent |
| 5.10 | Signed & archived validation artifacts | ❌ | Absent; `ci.yml` uploads no signed workflow artifacts |
| 5.11 | Immutable agent decision telemetry | ❌ | Absent; no structured trace emitted to an append-only sink |
| 5.12 | Documented human-override workflow | ❌ | `orchestrator.yml:23-31` has `workflow_dispatch` with manual stage selection, but this is not documented as a formal override in `SECURITY.md` or a dedicated `OVERSIGHT.md` |
| 5.13 | Self-updating context | ✅ | `orchestrator.yml:264-379`: "Update CONTEXT.md after merge" step runs `claude --print` with a diff+issue-body prompt, applies the patch via `git apply`, and commits to `main` post-merge — mechanism is wired and produces observable commits |

---

## 4. Critical Weaknesses & Vulnerabilities

**Criterion 2.6 — Docker ecosystem absent from Dependabot (blocking)**
`dependabot.yml` covers `github-actions` and `pip` but omits the `docker` ecosystem. `Dockerfile` pins to `ghcr.io/astral-sh/uv:python3.13-bookworm-slim` and `python:3.13-slim`; these will silently fall behind CVE patches without automated update PRs. A future agent patching Python dependencies could leave the runtime image itself unpatched. **Phase-1 delta: no existing issue — new issue required (add `package-ecosystem: docker` stanza, P2, ~1 SP).**

**Criterion 2.7 — Tag-pinned actions in `build.yml` and `deploy.yml` (blocking)**
`ci.yml` and `orchestrator.yml` are correctly SHA-pinned. `build.yml` uses `actions/checkout@v4` and `docker/login-action@v3`; `deploy.yml` uses `actions/checkout@v4`, `azure/login@v2`, `azure/cli@v2`, `google-github-actions/auth@v2`, `google-github-actions/deploy-cloudrun@v2` — all tag references that allow upstream mutation without a repository diff. The supply-chain risk is highest in `deploy.yml` because those actions receive cloud credentials. **Phase-1 delta: no existing issue — new issue required (SHA-pin all third-party actions in `build.yml` and `deploy.yml`, P2, ~2 SP).**

**Criterion 3.3 — `CONTEXT.md` lacks SOLID/DRY/KISS/TDD mandates (Tier 3 gap)**
`CONTEXT.md` Architectural Constraints are operational (UV, secrets hygiene, parity rules, PowerShell version) but contain no binding AI engineering design principles. Without explicit SOLID / DRY / KISS / TDD constraints and at least one named pattern example, agents implementing new features lack a quality anchor beyond "make the tests pass." Refactoring from shallow to deep modules, avoiding god-object growth, and keeping collaborators testable require explicitly named rules.

**Criterion 3.7 — `tdd`, `harness`, `review`, `ship` lack `REFERENCE.md`/`EXAMPLES.md`/`scripts/` (Tier 3 gap)**
Four non-trivial skills carry only a `SKILL.md`. These are the most heavily-invoked phases of the pipeline (every implementation, every review, every merge). Without `REFERENCE.md` and `EXAMPLES.md`, agents must re-derive patterns from the `SKILL.md` summary, increasing the chance of drift between sessions.

**Criterion 3.8 — No diagnosis / fault-isolation skill (Tier 3 gap)**
The MECE skill set has no explicit "diagnose" phase covering fault isolation — root-cause narrowing, error-reading discipline, and hypothesis-driven debugging. When an implementation fails tests or CI, agents fall back to trial-and-error rather than a structured diagnosis protocol. This gap is especially expensive in the current retry loop (criterion 5.2 is also absent, compounding the problem).

**Criterion 4.5 — `CODEOWNERS` covers only two files (Tier 4 gap)**
`.github/CODEOWNERS` protects `AGENTS.md` and `CONTEXT.md` but leaves `SECURITY.md`, `CODEOWNERS` itself, `docs/adr/`, and `.github/workflows/` unprotected. An agent PR can silently modify its own CI pipeline or secret-management documentation without a required human review.

**Criterion 4.6 — `SECURITY.md` missing disclosure channel and agent permission model (Tier 4 gap)**
`SECURITY.md` is thorough on secret rotation and pipeline credentials but omits the two fields the rubric specifically mandates: how to report a vulnerability to maintainers, and which filesystem paths and network destinations agents are allowed to reach. Without the agent permission model, the boundary between "what the agent can do" and "what it should not do" is advisory only.

---

## 5. Strengths & Foundation

**Full Tier 1 hygiene.** `pyproject.toml`, `uv.lock`, `.python-version`, and `.gitignore` are all present and well-formed. The gitignore explicitly blocks `.env*`, `*.key`, `*.pem`, `*.pfx`, `*secret*`, `*credential*` — observable, not inferred.

**SHA-pinned CI spine.** `ci.yml` and `orchestrator.yml` pin every third-party action to a 40-character SHA — `actions/checkout@9c091bb…`, `astral-sh/setup-uv@fac544c…`, `gitleaks/gitleaks-action@e0c47f4f…`. The quality gates are real: ruff format, ruff check, pyright, pip-audit, gitleaks, and pytest with an explicit 80% coverage floor.

**Working autonomous pipeline (Tier 5.1).** `orchestrator.yml` wires a label-driven, fully-autonomous SDLC: `agent:backlog` label → refine → architecture → implement → PR with zero human keystrokes between label and PR creation. This is one of only two Tier 5 criteria met. The mechanism is exercised (PRs #117 and #118 merged this way).

**OIDC Workload Identity Federation in deploy.** `deploy.yml` authenticates to both Azure and GCP via WIF — no long-lived service-principal JSON keys or static cloud credentials stored in GitHub Secrets. `SECURITY.md` documents the one-time provisioning steps. This is the correct architecture for keyless deployment.

**Functioning post-merge self-improvement loop (Tier 5.13).** `orchestrator.yml` runs `claude --print` post-merge to patch `CONTEXT.md` and commits the diff — a real, wired mechanism that evolves the context over time. Most repos at this maturity level have this as a documented intention; here it is executable.

**ADR lineage.** `docs/adr/` contains 11 substantive ADRs (ADR-000 template + ADR-001 through ADR-011), with six in `Accepted` status. ADR-011 formalises the orchestrator FSM using the issue body as the state carrier — a concrete design decision with a cross-linked CONTEXT.md constraint.

**On-disk phase state.** `.planning/<issue>/state.json` is confirmed present (`.planning/84/state.json`). Each orchestration run creates this per-issue artifact, enabling fresh-context-per-phase across runner restarts.

**Multi-stage Dockerfile + devcontainer.** `Dockerfile` correctly separates `builder` (UV + dependency install) from `runtime` (`python:3.13-slim`, no build tooling). `.devcontainer/devcontainer.json` provisions the full AI engineering toolchain (UV, Claude Code, GitHub CLI, PowerShell) via `postCreateCommand` with no manual steps.

---

## 6. The Verdict (Score & Role Mapping)

```
3.50 / 10 — Junior AI Engineer
5/7 criteria met at [3–4] — full tier above is not yet unlocked
```

Tier 1 (AI Student / Hobbyist): **8/8** — fully met. `pyproject.toml`, `uv.lock`, `.python-version`, `.gitignore`, pydantic-settings, README bootstrap, and coherent conventional-commit history are all present.

Tier 2 (Junior AI Engineer): **5/7** — blocking tier. Five quality-gate and secret-scan criteria are met. Two supply-chain criteria fail: criterion 2.6 (Docker ecosystem absent from `dependabot.yml`) and criterion 2.7 (tag-pinned third-party actions in `build.yml` and `deploy.yml`).

Score formula: `base(2) + (5/7) × 2 = 2 + 1.4286 = 3.4286` → rounded to **3.50 / 10**.

The prior claimed score of **5.50 / 10** is not supported by the evidence. It required both Tier 1 and Tier 2 to be fully met (unlocking Tier 3 as the blocking tier). Tier 2 is not fully met: `build.yml` uses `actions/checkout@v4` (tag) and `docker/login-action@v3` (tag); `deploy.yml` uses `actions/checkout@v4`, `azure/login@v2`, `azure/cli@v2`, `google-github-actions/auth@v2`, and `google-github-actions/deploy-cloudrun@v2` (all tags). Additionally, `dependabot.yml` covers only `github-actions` and `pip` — the `docker` ecosystem is absent. These two failures lower the blocking tier to Tier 2 and produce a score of 3.50, not 5.50.

---

## 7. The Path to the Next Tier

To fully unlock Tier 2 (Junior AI Engineer) and advance to Tier 3 evaluation, two targeted changes are required:

**Step 1 — SHA-pin all third-party actions in `build.yml` and `deploy.yml` (criterion 2.7)**
Replace every `uses: action/name@vN` tag reference in `build.yml` and `deploy.yml` with the full 40-character commit SHA. Use `gh api /repos/{owner}/{repo}/git/refs/tags/{tag}` or the upstream action's release page to resolve the current SHA for each tag. Dependabot (once the `docker` stanza is added in step 2) will keep these current. Unlocks: **2.7**. No existing tracked issue — new issue required.

**Step 2 — Add `docker` ecosystem to `dependabot.yml` (criterion 2.6)**
Add a third stanza to `.github/dependabot.yml`:
```yaml
- package-ecosystem: docker
  directory: /
  schedule:
    interval: weekly
```
This enables automated PRs when `ghcr.io/astral-sh/uv:python3.13-bookworm-slim` or `python:3.13-slim` release new digests. Unlocks: **2.6**. No existing tracked issue — new issue required.

Once Tier 2 is fully closed, the next three Tier 3 gaps are the critical path:

**Step 3 — Add SOLID/DRY/KISS/TDD mandates to `CONTEXT.md` (criterion 3.3)**
Extend the Architectural Constraints section in `CONTEXT.md` with explicit binding rules: SOLID, DRY, KISS, TDD as named constraints, each with one concrete pattern example (e.g. "All external I/O goes through an interface declared in `src/` to permit fakes in tests — no `requests.get` or `open()` in business logic"). This is a `refine` session output, not a code change. Unlocks: **3.3**.

**Step 4 — Add `REFERENCE.md`, `EXAMPLES.md`, and `scripts/` to `tdd`, `harness`, `review`, `ship` (criterion 3.7)**
The four most-invoked non-trivial skills carry only a `SKILL.md`. Add the full three-part directory spec (REFERENCE.md for mechanism detail, EXAMPLES.md for worked patterns, scripts/ for idempotent automation) to each. Start with `tdd` (highest invocation rate) and `review` (highest risk of drift). Unlocks: **3.7**.

**Step 5 — Create a `diagnosis` skill covering fault isolation (criterion 3.8)**
The MECE gap is a missing skill for fault isolation: hypothesis-driven debugging, error-reading discipline, minimal reproduction construction, and the distinction between symptoms and root causes. Create `.agents/skills/diagnosis/SKILL.md` with a non-overlapping trigger ("Use when implementation or CI fails and root cause is unclear — before attempting a fix"). This skill pairs with the eventually-needed CI-failure diagnose-and-patch loop (criterion 5.2). Unlocks: **3.8**.
