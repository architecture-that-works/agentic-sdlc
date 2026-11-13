# .template — The Template's Own Material

Everything in this folder is about building and evolving *this template repository*. The
folder is never copied by Copier — it does not ship to generated projects. Working on the
template means working here; working on a generated project means ignoring it.

## How to work on the template

1. Read [`.template/adr/README.md`](adr/README.md) first — the index of decisions about the
   orchestrator and pipeline mechanism itself (project-type routing, the context protocol,
   the GraphQL budget, the state-carrier format, the pipeline taxonomy, and so on).
2. Follow the ownership rule in `AGENTS.md`: template-owned paths are not edited in a
   generated project; improvements flow upstream as issues on this repo and arrive in
   projects via `copier update`.

## Contents

- `adr/` — architecture decisions about the template mechanism itself. Not application
  architecture — for that, a generated project has its own `docs/adr/`.
- `ASSESSMENT_PROMPT.md` — the reusable SDLC-maturity rubric used to produce an assessment.
- `assessments/` — dated self-assessment reports of this repo's own tooling (`assessment-<YYYY-MM-DD>.md`).
- `tests/` — the template-only test suite: the Copier smoke test, the dependency-parity
  guard, and the template-twins invariant.

## Bounded context

| Context | Owns | Does Not Own |
|---------|------|--------------|
| `.template/adr/` | Decisions about the orchestrator/pipeline mechanism itself | A generated project's own ADRs (`docs/adr/`) |

## Module Map row

| Module | Path | Bounded Context | Entry points |
|---|---|---|---|
| ADRs (the template mechanism) | `.template/adr/` | `.template/adr/` | `README.md` (master index) |

## Issue-Type → Files Index rows

| Working on... | Read first (nothing else unless surprised) |
|---|---|
| ADR addition (the orchestrator/pipeline mechanism) | `.template/adr/README.md` |
| template / Copier change | `pyproject.toml.jinja2`, plus copier.yml and .template/tests/test_copier_template.py — both template-only, copier excludes them from generated projects |
