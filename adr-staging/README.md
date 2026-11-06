# ADR Staging — Temporary Holding

This folder holds architecture decisions that are reusable across **any** project built
from this template — not decisions about the template itself. It is excluded from every
generated project (`copier.yml` `_exclude`): a fresh project starts with an empty
`docs/adr/`, not a pre-written library of decisions someone else made.

**This is a temporary location, not the final home.** These ADRs should eventually move
to a proper cross-project knowledge store the owner manages directly (a dedicated repo, a
published decision log, or similar) — staged here for now so the content isn't lost while
that store is still to be decided.

## What's here

See [`ADR_INDEX.md`](ADR_INDEX.md) — 7 ADRs covering data science tooling, MLOps/experiment
tracking, observability stack selection, IAM provider selection, data-pipeline
orchestration, agent observability tooling, and secrets management. Each carries an
`applies_to:` tag (project type) in its frontmatter, same MADR format as
`docs/adr/ADR-000-template-architecture-decision.md`.

## What's NOT here

Decisions about building or evolving the template's own orchestrator/pipeline mechanism —
those live in [`template/adr/`](../template/adr/) instead, because that mechanism ships
with every generated project and needs to stay there.
