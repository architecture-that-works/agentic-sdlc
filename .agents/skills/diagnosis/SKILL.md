---
name: diagnosis
description: Use when implementation or CI fails and the root cause is unclear — before attempting a fix
---

# Diagnosis

## Overview

Prevents trial-and-error debugging by enforcing a structured fault-isolation protocol. Every fix attempt is preceded by a confirmed hypothesis; every hypothesis is derived from observed evidence, not guesses.

**Primary artifact:** A written root-cause statement with supporting evidence, ready to hand off to `tdd` for the fix.

See [REFERENCE.md](REFERENCE.md) for mechanism-level guidance on each of the six Core Pattern
steps — full-trace capture, symptom-vs-root-cause heuristics, hypothesis ranking algorithm,
minimal-reproduction narrowing commands, and the root-cause statement template. See
[EXAMPLES.md](EXAMPLES.md) for two worked diagnoses running all six steps to a root-cause
statement (a test failure and a CI/workflow failure).

## Scope

**Owns:** Structured fault-isolation protocol, hypothesis-driven debugging, error-reading discipline, minimal reproduction procedure, symptom-vs-root-cause distinction.

**Does not own:** Writing the fix (→ `tdd`), provisioning test environments (→ `harness`), code review after the fix (→ `review`).

**Interfaces with:** `implement` — diagnosis ends when the root cause is confirmed; `implement` begins with that root-cause statement as the RED-phase acceptance criterion. `docs/HARNESS.md` — when minimal reproduction requires an isolated environment.

## When to Use

- A `uv run pytest` run or CI job fails and the cause is not immediately obvious from the error
- A previously passing test regresses without an obvious change
- A feature appears correct in isolation but fails end-to-end
- CI passes locally but fails remotely (environment divergence suspected)

**Do NOT use for:** Failures with an obvious, self-evident cause — read the error, fix it, move on. **Do NOT start a fix before completing diagnosis** — the fix is `tdd`'s job; this skill's job is confirming _what_ to fix.

## Required Inputs

- Full error output (stack trace, log lines, CI failure summary)
- Reproducible trigger — the exact command or condition that produces the failure
- Recent change set (git diff, PR diff, or description of what changed before the failure appeared)

## Primary Outputs

- Written root-cause statement: one sentence identifying the defect, not the symptom
- Minimal reproduction: the smallest command, test, or input that reliably triggers the failure
- Ruled-out hypotheses: documented so the next agent session does not re-investigate them

## Core Pattern

### Step 1 — Read the Error in Full

**Read the entire error output before forming any hypothesis.** Skimming for a familiar keyword misses the actual cause line, which is often buried after the traceback.

Rules:
- Copy the full stack trace; do not truncate
- Identify: error type, error message, file and line, call chain
- Mark the _first_ error frame — that is the origin; later frames are propagation
- Note any secondary errors or warnings immediately before the failure

```
❌ See "KeyError" → assume missing dict key → start patching

✅ Read full trace → notice KeyError in config loader at line 47
   → caused by env var missing from .env.test fixture
   → root cause: test fixture is incomplete, not application code
```

### Step 2 — Distinguish Symptom from Root Cause

A symptom is what failed. A root cause is why it failed. They are almost never the same.

**Symptom heuristic:** if removing or patching the failing line makes a different failure appear at a different location, you fixed a symptom, not the root cause.

| Symptom | Possible Root Cause |
|---|---|
| `AttributeError: 'NoneType'` | Caller does not guard a nullable return |
| `ImportError: cannot import name X` | Module renamed, or circular import introduced |
| CI fails, local passes | Environment variable or dependency version divergence |
| Test passes in isolation, fails in suite | Test pollution — shared mutable state |
| `AssertionError` in an unrelated test after your change | Regression introduced by your change's side-effect |

Write the symptom and the hypothesised root cause as two separate lines before proceeding.

### Step 3 — Generate and Rank Hypotheses

List every plausible root cause. Rank by prior probability (most likely first).

**Hypothesis sources:**
- The change set: what did you (or someone) just change?
- The error location: what module, function, or config does the failing frame live in?
- The environment: does this fail only in CI? Only on a specific Python version?
- The data: does it fail only with certain inputs?

**Rank rules:**
1. Changes in the last commit touching the failing module — highest prior
2. Environment differences (missing env var, different dep version)
3. Indirect effects (a shared fixture or global state modified upstream)
4. Pre-existing latent bug exposed by the new code path

Write no more than five hypotheses. If you cannot narrow to five, the error has not been read in full (return to Step 1).

### Step 4 — Minimal Reproduction

Reduce the failure to the smallest command or test that reliably triggers it.

**Protocol:**
1. Start with the full failing command (`uv run pytest tests/`)
2. Narrow to the failing test file: `uv run pytest tests/path/to/test_foo.py`
3. Narrow to the failing test: `uv run pytest tests/path/to/test_foo.py::test_name`
4. If a unit test, try running the function directly in a REPL with the minimal inputs
5. If CI-only, replicate the CI environment variable set locally and re-run

**Done when:** One command, one input, one failure — reproducible in under 10 seconds.

A failure that cannot be minimally reproduced is not understood. Do not proceed to a fix.

### Step 5 — Test One Hypothesis at a Time

Test the highest-ranked hypothesis first. One change, one re-run.

Rules:
- Change only the thing the hypothesis predicts — nothing else
- If the failure disappears: confirm by reverting the change and verifying the failure returns
- If the failure persists: rule out the hypothesis, move to the next
- If a new failure appears: re-read in full (Step 1) before forming new hypotheses

**Confirmation test:** The root cause is confirmed when:
1. Reverting the candidate change restores the failure
2. Applying the candidate change removes the failure
3. The fix is coherent — it explains all observed symptoms

### Step 6 — Write the Root-Cause Statement

One sentence. No ambiguity. Specific enough to hand to `tdd` as an acceptance criterion.

```
❌ "The test was failing because of a config issue."

✅ "The `Settings` object initialises `LOG_LEVEL` to `None` when the env var is absent,
    causing `logging.setLevel(None)` to raise `TypeError` in the test fixture that
    omits LOG_LEVEL from its environment."
```

Attach:
- Minimal reproduction command
- List of ruled-out hypotheses (one line each, with the reason they were ruled out)

## Quick Reference

| Step | Goal | Done When |
|---|---|---|
| 1. Read error | Identify origin frame | Full trace read; origin line identified |
| 2. Symptom vs root cause | Separate observation from explanation | Two separate written statements |
| 3. Hypotheses | Ranked list of ≤5 candidates | Ranked by prior probability |
| 4. Minimal reproduction | Smallest reproducing case | One command, reproducible in <10s |
| 5. Test one hypothesis | Rule in or out | Confirmed by revert + reapply |
| 6. Root-cause statement | Handoff to `tdd` | One sentence, specific, actionable |

**Context sensitivity:** Medium. Diagnosis requires holding the error context in mind across steps. If context fill reaches the Transition Zone mid-diagnosis, write the current hypothesis list and ruled-out hypotheses to a scratch note before compacting.

## Common Mistakes

**Skimming the error for a familiar keyword.**
The familiar keyword is usually a symptom, not the cause. Read the full trace from the first error frame.

**Fixing the symptom.**
If you patched the failing line and a different error appeared elsewhere, you fixed a symptom. Stop. Return to Step 2.

**Testing multiple hypotheses simultaneously.**
Changing two things at once means you cannot know which change fixed the failure. Revert both, then test each in isolation.

**Skipping minimal reproduction.**
A failure you cannot reproduce in isolation is a failure you do not understand. A fix for it is a guess.

**Writing the root-cause statement after starting the fix.**
The root-cause statement is the input to `tdd`, not a post-hoc description. If you cannot write it before writing code, diagnosis is incomplete.

**Treating CI-only failures as flakes without evidence.**
Re-run once to rule out transient flakes. If it fails consistently, it is a real failure — reproduce locally by matching the CI environment.
