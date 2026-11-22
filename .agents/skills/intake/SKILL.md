---
name: intake
description: Use when converting raw owner thoughts into a pipeline-ready GitHub issue, before any pipeline stage runs
---

# Intake

## Overview

Turns unstructured owner thoughts into a well-formed GitHub Issue that the AFK pipeline immediately recognises. The agent drafts a title and body in the ISSUES.md schema, presents the draft for owner confirmation, and only then creates the issue — no labels, no reformatting needed downstream.

**Primary artifact:** A GitHub Issue whose body follows the issue template, `.github/ISSUE_TEMPLATE/issue.md`, and no labels.

## Scope

**Owns:** Raw-thought → structured draft (the issue template's headings), owner confirmation gate, `gh issue create` execution with no labels.

**Does not own:** Pipeline stages (→ `refine`, `architect`, `plan`, `implement`, `review`, `ship`), label assignment of any kind (→ orchestrator), editing or updating existing issues, unattended / AFK issue creation.

**Interfaces with:** `refine` — the AFK pipeline's refine stage reads the issue body this skill writes. The issue template, `.github/ISSUE_TEMPLATE/issue.md`, is the contract between intake and refine.

## When to Use

- Owner has raw thoughts, a problem statement, or a brief feature idea they want to push into the pipeline
- Before any pipeline stage — intake is the entry point, not a stage itself

**Do NOT use for:**
- Editing or updating an existing GitHub Issue (open it directly)
- Automated / unattended issue creation — intake requires owner confirmation and a `gh`-capable Claude Code session
- Label assignment — labels are the pipeline's output (ADR-015 amendment 2026-09-23)

## Required Inputs

- Owner's raw thought(s) — one sentence to a few paragraphs; any level of structure is acceptable

## Primary Output

- A GitHub Issue URL with:
  - A short action-oriented title
  - Body written under the issue template's headings
  - No labels

## Core Pattern

### Step 1 — Accept raw thoughts

Read the owner's input in full. Do not ask clarifying questions before drafting. Use what is given; mark gaps as placeholder prompts in the body.

### Step 2 — Draft title and body

Produce one draft whose body is the issue template, `.github/ISSUE_TEMPLATE/issue.md`: every heading below its front matter, in its order and style, filled from the owner's input. The template is the one place the headings are written — read it rather than recalling them.

Fill every heading. If the owner's input does not supply enough for a heading, use explicit placeholder prompts (see REFERENCE.md § Body Schema Template) — never omit a heading.

### Step 3 — Present draft

Show the full draft (title + body) to the owner. Do not call `gh issue create` yet. Await an explicit `yes` before continuing.

### Step 4 — Wait for confirmation

**Gate: do not proceed without an explicit `yes`.**

- `yes` → go to Step 5
- `no` / `cancel` / `abort` → stop; do not create the issue
- Any edit request → revise the draft, return to Step 3
- Silence / ambiguity → ask "Shall I create this issue? (yes / no)" before continuing

### Step 5 — Create the issue

Call exactly:

```powershell
gh issue create --title "<title>" --body "<body>"
```

**No `--label` flags. No exceptions.**

Print the returned URL to confirm success.

## Constraints

The following constraints close specific loopholes observed in the baseline:

**C-1 — Never create without confirmation.**
`gh issue create` is called only after the owner types `yes` or an unambiguous equivalent. Creating on the first turn, before showing the draft, is a violation.

**C-2 — Never add labels.**
The `gh issue create` command MUST NOT include any `--label` flag. Labels are the pipeline's exclusive output. Adding labels "as a convenience" or "to help routing" is a violation.

**C-3 — Every template heading, always.**
Every created issue body MUST contain every heading of the issue template, `.github/ISSUE_TEMPLATE/issue.md`. Omitting any heading, even when the owner's input is thin, is a violation. Use placeholder prompts rather than omitting.

**C-4 — No pipeline-stage work.**
Intake drafts and creates. It does not refine, architect, plan, or implement. If the owner asks intake to do any of those, route to the correct skill.

**C-5 — HITL only.**
Intake requires an interactive Claude Code session with `gh` CLI access. It MUST NOT be invoked from an AFK / unattended context.

**C-6 — One issue per session.**
Each intake session creates at most one issue. If the owner has multiple thoughts, run intake once per issue.

## Common Mistakes

**Drafting and creating in one turn.**
Show the draft first. Wait for `yes`. Skipping the confirmation gate is the most common failure.

**Adding a label to "help the pipeline".**
The pipeline assigns its own labels. Any label added at intake time interferes with the state machine (ADR-015 amendment 2026-09-23).

**Omitting a heading when the owner's input is thin.**
Use the placeholder prompts from REFERENCE.md § Body Schema Template. A heading with a placeholder is correct; a missing heading breaks the refine parser.

**Asking clarifying questions before drafting.**
Draft first with what you have. Present the draft. Let the owner correct it. Asking questions before drafting wastes a turn and delays alignment.

**Inferring confirmation from silence or partial text.**
Only an explicit `yes` (or equivalent like "do it", "create it", "looks good") is sufficient. Never infer consent.
