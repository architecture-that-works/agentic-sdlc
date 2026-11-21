---
name: implement
description: Use when implementing a feature, fixing a bug, or refactoring — any time code needs to be written or changed against a defined acceptance criterion
---

# Implement

## Overview

Prevents implementation drift, untested code and bloat by enforcing a strict Red-Green-Refactor loop with the smallest complete change at every step. Every behaviour is proven by a failing test before implementation begins; every implementation stays minimal until the test passes; every refactor deletes before it adds. TDD is the method of this stage (`CONTEXT.md` glossary).

The rules below are the team's one coding standard: `review` judges a change against them, not against its own taste. Simpler code or a declared `Left undone:` chosen by these rules is a decision, not a finding.

**Primary artifact:** Passing pytest suite with minimal, refactored implementation code.

See [REFERENCE.md](REFERENCE.md) for the full decision tree, fixture conventions, coverage
threshold and parametrize patterns. See [EXAMPLES.md](EXAMPLES.md)
for worked Red-Green-Refactor sessions (new feature, regression, parametrize, a bug fix traced
through its callers).

## Scope

**Owns:** Red-Green-Refactor loop enforcement, the smallest-complete-change rule (reach of a change, reuse ladder, lean refactor), acceptance criteria traceability to the PRD, mocking rules, deep-module REFACTOR target, test suite ergonomics with pytest.

**Does not own:** Test infrastructure provisioning (`tests/README.md`), root-cause analysis of a failure (→ `diagnosis`), PR creation (the orchestrator), code review (→ `review`), performance infrastructure.

**Interfaces with:** `plan` — testing decisions in the PRD drive the RED phase. `diagnosis` — a bug fix starts from its root-cause statement. `review` — judges the change against these rules, the one standard for both stages; reads the closing `Left undone:` / `Issues discovered:` lines.

## When to Use

- Implementing any story or acceptance criterion from a GitHub Issue
- Fixing a bug (write a failing test reproducing the bug first)
- Refactoring a shallow module into a deep module

**Do NOT use for:** Setting up test infrastructure (`tests/README.md`), reviewing completed code (→ `review`).

## Required Inputs

- GitHub Issue with acceptance criteria or testing decisions from the Lean PRD
- Existing test suite (read before writing new tests)

## Primary Outputs

- Passing pytest suite (`uv run pytest` exits 0)
- Minimal implementation code that satisfies acceptance criteria
- Refactored modules with deeper interfaces and less duplication
- A closing note of one or two lines: `Left undone:` what you skipped or did not check; `Issues discovered:` what the owner must know — a risk, a bug outside scope, a stale document. In the pipeline these are the last bullets of the implementation summary, posted to the issue for `review` and the owner

## Core Pattern

### Before you write — the reach of the change

Read the task and the code it touches, then list every place the change must reach: callers, tests, fixtures, config, exports. That list is the scope. Features, options and flexibility nobody asked for are not — name them under `Left undone:` instead of building them.

- The Module Map says where to start (Context Protocol). The callers of a symbol you change come from a grep of that symbol — every one, tests and fixtures included. Finding callers is not orientation; it is the blast radius of the edit.
- Bug fix: find every caller first, then fix the root cause once in the shared code. A fix in one caller while the shared function stays broken is the most common half-fix.
- Check what the change could break for users — data it would destroy or expose, callers that stop working — before the first edit, not after the suite goes red.

### Red — Write One Failing Test

Write exactly one pytest test that verifies a specific behaviour through a public interface.

**Rules:**
- Test must fail before any implementation is written — verify this
- Test targets a public interface, never internal implementation details
- Mocks are allowed only at system boundaries: external APIs, databases, time (`datetime.now`), filesystem
- Internal collaborators are never mocked — test through them

```python
# ✅ Tests public interface
def test_order_total_includes_tax():
    order = Order(items=[Item("widget", 10.00)], tax_rate=0.1)
    assert order.total() == 11.00


# ❌ Mocks an internal collaborator
def test_order_total():
    with patch("orders.TaxCalculator") as mock:
        ...
```

### Green — The Smallest Complete Change

Write only enough code to make the current test pass. Take the first option in this ladder that fully works:

| Ask, in order | Then |
|---|---|
| Does it need to exist? | If nobody asked for it, skip it and name it under `Left undone:`. A vague request gets the smallest version that does the core job |
| Already in this codebase — a helper, pattern, module? | Use it the way the surrounding code does |
| In the standard library? | Use it — unless the project has its own (`CONTEXT.md`: Standard library first) |
| An installed dependency? | Use it. Never add a dependency for a few lines |
| One line a reader gets at a glance? | One line. A one-liner that needs decoding is not short |
| Otherwise | The minimum code that passes the test |

**Rules:**
- Do not anticipate future tests — implement only what the current test requires
- Do not write horizontal slices (e.g. the full data layer) while a single test is RED
- Hardcoding is acceptable in GREEN if it makes the test pass — REFACTOR will fix it
- Be lazy about the solution, never about the change: finish every caller, test and fixture the change breaks
- Between options of equal size, take the one that is correct on edge cases (empty, zero, last item, rounding, time zones)
### Refactor — Deep Modules, Nothing Extra

Once GREEN, refactor to make the implementation deep: maximum behaviour behind the smallest possible interface. Deletion beats addition.

**Deep module checklist:**
- [ ] Could the interface be smaller without losing expressiveness?
- [ ] Is there duplication that should move behind the interface?
- [ ] Does the module expose implementation details in its public surface?
- [ ] Are there two responsibilities that should be split?
- [ ] Is there code nobody asked for — an option, wrapper, type conversion, config knob, "for later" branch? Delete it

**Refactor rules:**
- All tests must remain GREEN throughout
- Public interface must stay constant or shrink — never grow during REFACTOR
- Keep the structure the codebase already has: its layers, interfaces and conventions. An interface the Architectural Constraints require (the I/O port behind Dependency Inversion) is structure, not speculation — keep it
- Code you move or merge keeps its error handling and validation
- Split a function by job, never by line count — a helper that exists only to make a function shorter is one more name the reader must chase
- Comment only the *why* the code cannot show, in one line- Never cut: validation at trust boundaries, error handling that prevents data loss, security, anything the issue asked for

### Acceptance Criteria Traceability

Every test must map to a user story or testing decision in the Lean PRD. If a test cannot be traced to the PRD, it is either out of scope (delete it) or the PRD is incomplete (update it before continuing).

## Quick Reference

| Phase | Goal | Forbidden |
|---|---|---|
| Before | List the reach: callers, tests, fixtures, config | Editing before the callers are known |
| RED | One failing test through public interface | Mocking internal collaborators |
| GREEN | Smallest complete change that passes the current test | Anticipating future tests; a new dependency for a few lines |
| REFACTOR | Deep module: shrink interface, delete what nobody asked for | Growing the public surface; helpers that only shorten |

**Context sensitivity:** High during RED and GREEN (precise instruction following required). REFACTOR is lower sensitivity. If context fill reaches Transition Zone mid-loop, compact before starting the next RED phase.

## Common Mistakes

**Writing implementation before the test is confirmed failing.**
Run `pytest -x` first. If it passes without any implementation, the test is testing nothing.

**Mocking internal collaborators.**
Internal mocks make tests pass without proving behaviour. When the implementation changes, the mock masks the regression. Only mock at system boundaries.

**REFACTOR grows the interface.**
Adding a new public method during REFACTOR is scope creep. New behaviour belongs in a new RED phase.

**Test cannot be traced to the PRD.**
Tests that aren't in the PRD represent undiscussed scope. Trace it or delete it.

**Fixing the symptom in one caller.**
The shared function stays broken for every other caller. Grep the symbol, fix the root cause once.

**Lazy about the change instead of the solution.**
The smallest diff that leaves a fixture, caller or config broken is not small — it is unfinished. The reach list from "Before you write" is the definition of done.

**A helper that exists only to make a function shorter.**
Split by job, never by line count. If the helper has one caller and no name a domain expert would use, inline it.

**A dependency for a few lines.**
Standard library first, then what is already installed. A new dependency is a supply-chain review in `ship` and a line in every fork's lockfile.
