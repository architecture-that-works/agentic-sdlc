# Template — Building and Evolving This Template Itself

This folder holds everything about developing *this template repository* — its
orchestrator, its pipeline, its Copier mechanism — as distinct from `docs/`, which is what
a generated project sees, and [`adr-staging/`](../adr-staging/), which holds reusable
app/domain architecture decisions.

## `adr/`

Architecture decisions about the orchestrator and pipeline mechanism (project-type
routing, the context protocol, the GraphQL budget, the state-carrier format, the pipeline
taxonomy, and so on). **This subfolder ships with every generated project** — it is NOT in
`copier.yml`'s `_exclude` — because the orchestrator and skill system it documents ship
too, and `AGENTS.md`'s Context Protocol cites these ADRs operationally wherever that
mechanism runs.

## `dev-notes/`

Artifacts about assessing or developing this specific template repository. Zero relevance
to a generated project — excluded from Copier output entirely.

- `assessment-2026-06-27.md` — dated SDLC-maturity self-assessment of this repo's own tooling.
- `ASSESSMENT_PROMPT.md` — the reusable rubric used to produce one; re-run it to re-assess.
