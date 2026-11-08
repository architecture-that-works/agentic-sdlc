---
name: review
description: Use when validating a pull request, running the fix loop on review findings, or enforcing architectural standards before a PR is approved for merge
---

# Review

## Overview

Prevents defects, architectural drift and bloat from reaching `main`. Review a change like the senior developer who will be paged when it breaks: read the connected code, not only the diff; report only findings with a concrete case; propose the smallest fix. Order of importance: correct, safe, holds under load, tested, fast, lean. Lean still matters — every extra line must be read, tested and fixed later. Implement and review share one standard — the rules in `implement` § Green and § Refactor. Review catches what breaks them or the correctness bar; it never undoes a choice made by them.

**Primary artifact:** A verdict a busy human understands in one read, with numbered findings that each carry their own fix — all resolved or escalated before `ship`.

See [REFERENCE.md](REFERENCE.md) for the finding categories and their severities, the verdict
rule, the fix loop and escalation. See [EXAMPLES.md](EXAMPLES.md) for worked reviews (a BLOCK
fixed in one round, a clean approval, escalation after three rejections).

## Scope

**Owns:** PR review execution, the finding method (understand → look for → check → report), the fix loop and its rejection budget, Senior Architect standard enforcement against `CONTEXT.md` principles, escalation to a human when the budget is spent.

**Does not own:** Code implementation and fixing findings (→ `implement`), static topology analysis and the repo-wide audit (→ `architect`), merge and security governance (→ `ship`), lint and format (the `ruff` gate in CI).

**Interfaces with:** `implement` — review validates that GREEN and REFACTOR produced code compliant with `implement`'s own rules, the team's one standard; a rejection hands the numbered findings back to `implement`; a `shortcut:` line from `implement` is listed under `Not checked:`, never as a finding. `architect` — the blast-radius report is surfaced in the review; the repo audit reuses the finding categories defined here. `ship` — a clean review is the gate for `ship`.

## When to Use

- A PR is open and ready for review
- An `implement` cycle has completed and findings need independent validation
- An `architect` blast-radius report flagged at-risk modules that need code-level inspection

**Do NOT use for:** Writing implementation code (→ `implement`), running topology analysis or auditing the whole repo (→ `architect`), merging or closing issues (→ `ship`), style — lint and format are CI's job.

## Required Inputs

- Open PR number
- The linked issue — acceptance criteria, owner comments, signal history (test output, the implementation's `Left undone:` / `Issues discovered:` lines, prior rejections)
- `CONTEXT.md` (architectural constraints for Senior Architect enforcement)
- Blast-radius report from `architect` (if available)

## Primary Outputs

- Review report: verdict first, then numbered three-part findings, most important first
- In the pipeline: `APPROVED` proceeds to `ship`; `REJECTED` returns the issue to `implement` with the findings
- Escalation when the rejection budget is spent (the issue lands on `agent:failed`)

## Core Pattern

### Step 1 — Understand first

- Read the diff, then the code it touches: callers of every changed function, the functions it calls, the tests, the fixtures.
- Trace the real flow: where data comes in, what is stored, what goes out.
- A change can break code it does not touch. When a signature, return value or behaviour changes, grep every caller.
- Find the expected load in the repo (README, deploy config): one person running a script, or many users and processes at once. Judge scale against that, and say which load you assumed.
- Re-read the acceptance criteria in the issue. The signal history holds the test output and what the implementation says it left undone — nothing left undone may be an acceptance criterion.

### Step 2 — Look for, in this order

1. **Bug** — wrong result, crash, missed edge case (empty, zero, last item, rounding, time zones), a caller broken by the change, a fix in one caller while the shared function stays broken.
2. **Risk** — security (injection, weak randomness, secrets, missing checks on input from users), data loss (errors swallowed, writes in the wrong order, no transaction).
3. **Scale** — fine for one user, wrong for many: check-then-write races, work repeated by every process, lists that only grow, a query per item, O(n²) on big input.
4. **Missing test** — risky new logic (a branch, a parser, money, security, data writes, a bug fix) with no test that fails when it breaks. One good test, not coverage.
5. **Speed** — big slowdowns are problems; small wins are suggestions.
6. **Lean** — code that breaks `implement`'s rules (§ Green ladder, § Refactor): dead code, a helper the repo already has (name the path), stdlib doing the same, an abstraction with one implementation, near-copies that must change together, a function doing several unrelated jobs. Simpler code chosen by those rules is not lean debt.

Plus the governance checks — `CONTEXT.md` constraints, internal mocks, Module Map rows, secrets, test traceability. The severity of each is in REFERENCE § Finding categories.

### Step 3 — Check before you report

- Every finding needs a concrete case: "this input or situation leads to this wrong result". No case, no finding.
- Re-read the lines and confirm: the caller exists, the value can really be empty, the code really is unused (grep the whole tree, tests and fixtures included).
- A line bearing a `shortcut:` comment is a known gap with a named follow-up: list it under `Not checked:`, never as a finding.
- Never overrule a choice `implement` made by the shared rules: simpler code, a marked `shortcut:`, a declared `Left undone:` that no criterion requires. A finding that asks for more code than the rules require is not a finding.
- Propose the smallest fix that works. Prefer fixes that delete code. Never add layers, frameworks or config the problem does not need.
- No style taste, no "consider", no vague worries. Lint and format belong to the `ruff` gate.

### Step 4 — Report

First line: the verdict — `APPROVED`, or `REJECTED — fix 1 and 3`, naming every finding that must be fixed. The pipeline reads this line.
Then `What this change does:` in two or three sentences.
Then the findings, numbered, most important first (the order of Step 2), so the owner can say "fix 2 and 5". No severity tag on a finding — the verdict line says which numbers block; the rest are suggestions. Every finding has three parts, each one or two short sentences:

```
2. **Orders land on the wrong day** (`billing/close_day.py:L40-52`)
   - **Defect:** The job takes "today" from the server clock, which runs in UTC.
   - **Case:** An order placed at 00:30 in Berlin is billed on the day before.
   - **Fix:** Compute the day once in the shop's time zone:
     `datetime.now(ZoneInfo("Europe/Berlin")).date()`. One line, nothing else changes.
```

End with `Lean: -<N> lines possible.` when lean findings exist, then `Not checked:` — a heading listing the `shortcut:` lines you passed over and anything that mattered but you could not check.

Nothing found: the verdict, `What this change does:`, `Looks good.` and one line on what you checked.

**Verdict rule.** A finding's severity (REFERENCE § Finding categories) is the reviewer's rule, never printed: `REJECTED` names every BLOCK and every WARN that is not waived. A WARN is waived only when the fix would be larger than the problem; the waiver is one line inside the finding. INFO never changes the verdict.

### Step 5 — Fix loop and escalation

A rejection hands the numbered findings to `implement`, which fixes the root cause and pushes; the next review re-reads the *current* diff — a fix may already have resolved an earlier finding. Each rejection is one attempt. After `MaxRetries` (3) the issue lands on `agent:failed` with every attempt listed and a human takes over; no label is set by hand (ADR-015). Do not attempt a fourth round.

HITL: the same loop by hand on the feature branch (an isolated worktree if the main checkout must stay clean → `version-control`). On the third unresolved round post the escalation comment from REFERENCE and stop.

### Senior Architect Standard Enforcement

If a finding maps to a principle from `CONTEXT.md` or a constraint established in `refine` (encapsulation leak, tracer-bullet violation, mocking rule breach), it is automatically elevated to BLOCK regardless of initial severity. These are not negotiable.

## Quick Reference

Severity is the reviewer's internal rule for the verdict line; it is never printed on a finding.

| Severity | Holds | Gate | Resolution |
|---|---|---|---|
| BLOCK | bug, security, data loss, breaks at the expected load, a `CONTEXT.md` constraint, an unmet criterion | Merge prohibited | `implement` fixes it, or escalate |
| WARN | risky code without a test, real slowness, duplication, mixed jobs, code that should not exist | Fix, or waive with a one-line reason | Fix, or waiver inside the finding |
| INFO | small speed-ups, shorter forms, naming | No gate | Noted |
| Budget spent (3 rejections) | — | Merge prohibited | `agent:failed`; a human takes over |

**Context sensitivity:** Low for individual commit reviews. High for the fix loop — each round should start from a compact context to avoid compounding drift.

## Common Mistakes

**Reviewing stale diff.**
Always review the current diff, not an earlier snapshot. A fix may have already resolved the finding.

**Reviewing only the diff.**
A changed signature breaks callers the diff never shows. Grep every caller before approving.

**A finding without a case.**
"This might be slow" and "consider extracting" are not findings. Name the input and the wrong result, or drop it.

**Undoing what `implement` did on purpose.**
Simpler code, a marked `shortcut:` or a declared `Left undone:` is a decision made by the shared rules — the same team standard the reviewer holds. One implementation needs no interface beyond what the Architectural Constraints require; three copies do (Rule of Three). The reviewer's job is to shrink the change, not to grow it.

**Continuing past the rejection budget.**
Three rounds is the cap. A fourth compounds drift and wastes context. Escalate and stop.

**WARN findings silently dropped.**
Every WARN must have either a fix or a one-line waiver inside the finding. Silent drops become silent debt.

**Skipping blast-radius cross-reference.**
If `architect` produced a blast-radius report for this PR, it must be referenced in the review. At-risk modules flagged there get BLOCK-severity treatment.

## Self-review is not a gate

A review reads the diff; it never executes it. This review approved both #154 and #192,
which CI then rejected. Run the full local gate (`tests/README.md` § The local gate)
before pushing — do not lean on the reviewer to catch what only running the code can.
