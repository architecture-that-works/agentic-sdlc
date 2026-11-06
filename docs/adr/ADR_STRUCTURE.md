---
name: ADR_STRUCTURE
description: Master index of this project's own Architecture Decision Records — load this at session start to filter which ADRs apply to the current project_type without reading every file
---

# ADR Structure

Master index for this project's **own** Architecture Decision Records — the real
decisions made while building *this* application, not the template it was generated
from. A freshly generated project starts with this index empty of entries: add a row
here the same PR you merge a new ADR in, never after.

---

## How to Use

1. Write a new ADR from [`ADR-000-template-architecture-decision.md`](ADR-000-template-architecture-decision.md)
   (the blank MADR template) — copy it, number it the next `ADR-NNN`, fill it in.
2. Add a row to the **Index** below in the same PR. Never merge an ADR without a
   corresponding index update.
3. Use the **Applies To** column to filter which ADRs are relevant to the current
   `project_type`, once this project has more than one.
4. Read this index at session start alongside `CONTEXT.md` and `AGENTS.md`. Load an
   individual ADR only when you need the full context, considered options, or
   confirmation steps.
5. Looking for decisions about developing *this template itself* (its orchestrator,
   pipeline, or Copier mechanism), not this generated project's own application? Those
   live in [`template/adr/`](../../template/adr/) instead, kept separate on purpose —
   different concern, different audience.

---

## Index

| ADR | Title | Status | Applies To | Decision |
|---|---|---|---|---|
| [ADR-000](ADR-000-template-architecture-decision.md) | Template Architecture Decision | Template | all | MADR format — use this template for every new ADR in this project |

*(No other rows yet — this project hasn't made its first real architecture decision.)*
