---
name: code-quality
description: Use when reviewing Python code, validating a pull request, approving a refactor, or enforcing code standards before merging
---

# Code Quality

## Overview

Enforces cognitive clarity, TDD compliance, and long-term codebase health at the function and module level. The goal is flat, typed, testable code — not merely functionally correct code.

## Scope

**Owns:** Python syntax standards (PEP-8, type hints, naming), function and module structure (indentation limits, size limits, guard clauses), TDD enforcement (failing test first, mocking), code review feedback format, standard library vs third-party dependency decisions.

**Does not own:** System or domain model design (→ `design-system`), domain-specific implementation patterns (→ domain skills), git operations or PR creation (→ `git-workflow`).

**Interfaces with:**
- `design-system` — architectural constraints define what code-quality enforces at the micro level
- Domain skills — code-quality applies universally; domain skills define what is being built

## When to Use

- **Trigger:** Code submitted for review or PR validation
- **Trigger:** Significant refactoring proposed
- **Trigger:** Modifying legacy code with no type hints, deep nesting, or missing tests

**Do NOT use for:**
- System design or bounded context mapping (→ `design-system`)
- Domain-specific implementation patterns (→ domain skills)

## Core Pattern

### Hard Limits — Immediate Rejection

| Constraint | Limit |
|---|---|
| Max indentation | 2 levels |
| Max function size | 30 lines |
| Max arguments | 4 |
| Type hints | 100% — no untyped functions |
| Style | Strict PEP-8 |
| Comments | "Why" only — never "What" |
| TDD | Logic changes require a failing test first |

### Guard Clauses & Loop Bouncers

Invert conditions to keep the happy path flat. Reject at the top of the function.

```python
# ❌ Nested
def process(data: dict):
    if data.get("valid"):
        if data.get("user"):
            execute_job(data["user"])

# ✅ Flat
def process(data: dict):
    if not data.get("valid"):
        return
    if not data.get("user"):
        return
    execute_job(data["user"])
```

Use `continue` and `break` aggressively in loops to avoid nesting.

### Immutability

- Prefer `frozen=True` dataclasses or strict Pydantic models
- All state variables initialized exclusively in `__init__`
- State modification through explicit methods on an Aggregate Root only

## Quick Reference

### Standard Library First

| Use | Instead of | Reason |
|---|---|---|
| `pathlib` | `os.path` | Object-oriented, cross-platform |
| `collections.Counter` | Manual loops/dicts | Optimized C implementation |
| `functools.lru_cache` | Custom cache dicts | Standardized, edge-case safe |
| `shutil` | Manual `os` file ops | Higher-level operations |

Exception: `requests` over `urllib` for HTTP calls. `numpy`/`pandas` for heavy analytical operations only — not basic math or CSV parsing.

### Naming Conventions

- Functions: Verb-Noun (`calculate_score`, `fetch_user`)
- No magic numbers — define in `constants.py`
- No single-letter variables except loop iterators

## Implementation

### Testing Strategy Taxonomy — Testing Trophy Model

The Testing Trophy guides *how many* of each type to write and *where to invest*. Unlike the old pyramid (many unit tests at the base), the Trophy reflects what actually catches bugs: integration tests dominate because they verify real behaviour at real boundaries.

```
         /\
        /E2E\          few — smoke tests for critical journeys post-deployment
       /------\
      /Integr- \       the bulk — test real components against mocked external boundaries
     / ation    \
    /------------\
   /  Unit Tests  \    targeted — pure functions, parsers, validators, retry decisions
  /________________\
 |   Static Types   |  mypy/pyright — free bug-catching before any test runs
```

**Layer decision rules:**

| Layer | Use when | Mechanism |
|---|---|---|
| Static types | Always — first line of defence | `mypy --strict`; types catch a class of bug before tests exist |
| Unit | Pure function with branching logic or edge cases: parsers, validators, transformers, retry decisions | Plain `pytest` assertions; zero I/O, no mocks of code you own |
| Integration | Orchestration logic, adapters, pipelines — anything with a real boundary (filesystem, DB, injected service mock) | `tmp_path` for filesystem; `MagicMock` on *external* boundaries only |
| E2E | Critical user journeys only — too slow and brittle for routine regression | Post-deployment smoke tests; not part of the unit suite |

**What NOT to test:**

- Standard library or well-tested framework calls — do not test that `pathlib.Path.write_text` writes a file or that `requests.get` makes an HTTP call
- Simple getters and plain assignments — constructing an object with known-good inputs is not a test case
- Mock infrastructure — a test that verifies only that mock A called mock B with argument C tests your wiring, not your logic; it will pass even when the real system breaks
- Exact log message text — messages change; assert log *level* and the presence of a key term, not the full string
- Live-API-only branches — credential loading that requires real auth state belongs under `# pragma: no cover`, not a mock-heavy test that proves nothing

**Complexity trade-off:**

Test code contains bugs, must be maintained, and creates false confidence when it over-specifies. A test that breaks on every internal refactor adds friction without safety benefit. Apply a cost–benefit gate before writing each test: *if removing this test would make you nervous about a real regression, keep it; if not, do not write it.*

**ML-specific rule:** Do not write unit tests for calls into scikit-learn, XGBoost, PyTorch, or any well-tested ML framework. Test your own data processing utilities, feature engineering functions, and validation logic only.

**ETL starting point:** Integration tests on pipeline outputs (expected row count, all IDs present, expected date range) catch more real bugs than unit tests on transformation logic.

### TDD Enforcement

Logic changes without a failing test first are an immediate rejection. No exceptions.

**Runner selection — choose based on project scope:**

| Context | Runner | Rationale |
|---|---|---|
| Simple scripts, utilities, learning context | `unittest` | Explicit class structure, no "magic" — every dependency is visible in the file. Hard to hide logic. Low setup overhead for isolated functions. |
| Full applications, data/ML pipelines | `pytest` | Assertion introspection shows colored diffs on complex failures. `@pytest.mark.parametrize` tests one function against N data distributions in 3 lines vs 30. Fixtures eliminate repeated DB/session setup. |

**Migration path for existing `unittest` projects:** `pytest` runs `unittest.TestCase` tests natively — switch the runner first (`uv run pytest`), keep existing tests untouched, write all new tests as plain functions with `assert`.

**`pytest` fixture discipline:** Define shared fixtures (DB sessions, test data) in `conftest.py`. Always add a comment on the fixture pointing to its `conftest.py` location — "spooky action at a distance" is the most common junior confusion point.

```python
# ✅ pytest — parametrize for data/ML testing
@pytest.mark.parametrize("input,expected", [
    ({"period": "2024Q1", "value": 10.0}, True),
    ({"period": "invalid",  "value": 10.0}, False),
])
def test_validate_record(input: dict, expected: bool) -> None:
    assert validate_record(input) == expected

# ✅ unittest — simple isolated function, no fixtures needed
class TestCalculateScore(unittest.TestCase):
    def test_returns_zero_for_empty_input(self) -> None:
        self.assertEqual(calculate_score([]), 0)
```

**Mocking:** `unittest.mock.MagicMock` — standard library only, no third-party mock alternatives. Works identically in both runners.

### Coverage Gate Philosophy

A numeric coverage threshold is a proxy, not a goal. The goal is confidence in real regressions. A gate at 80% on testable code is more honest than 90% achieved by writing tests that exist only to move a counter.

**Setting the threshold:**
- Measure only the code that can be unit- or integration-tested without live external services.
- Use `omit` in `[tool.coverage.run]` for adapter files that exclusively wrap live external APIs with no injected boundary — document the omission with an inline comment.
- Do not omit files that have testable logic reachable via mock service injection; those should have tests.

**`pragma: no cover` decision guide:**

| Situation | Action |
|---|---|
| Branch requires live credentials or auth state | `# pragma: no cover` + one-line explanation |
| `except ImportError` conditional import fallback | `# pragma: no cover` |
| Platform-specific branch unreachable in CI | `# pragma: no cover` |
| Logic reachable via injected mock boundary | Write the test; do not exclude |
| Hard-to-mock but injectable as a service object | Write the test using constructor injection; do not exclude |

**Shared test infrastructure:**

Every project with more than two test files needs a `conftest.py` with domain-entity factory functions that accept keyword overrides. Inline entity construction duplicated across test files becomes a maintenance burden on every model change.

```python
# conftest.py — shared factory pattern
def make_user(**overrides) -> User:
    defaults = {"id": "u1", "name": "Test User", "role": Role.VIEWER}
    return User(**{**defaults, **overrides})
```

Patch `time.sleep` in all tests that exercise retry or backoff logic — real delays make the suite unusably slow and add no regression signal.

```python
@patch("time.sleep")
def test_retries_on_transient_failure(mock_sleep) -> None:
    ...
```

### Communication Plan Gate

Require a bulleted implementation plan describing algorithmic intent before any code changes begin. No plan, no review.

### Feedback Format

Every review comment must follow this four-part format. Never critique without the paired solution.

- **[Observation]:** What is the violation? ("This function is 43 lines with 4 levels of nesting.")
- **[Principle]:** Why is it broken? ("High cognitive load makes this path error-prone.")
- **[Instruction]:** Before/after structural fix
- **[Reference]:** Which constraint was violated

## Common Mistakes

**Logic change without a failing test.**
Immediate rejection. No exceptions.

**Nested conditionals instead of guard clauses.**
Invert and return early. Two levels of nesting maximum.

**Missing type hints.**
Every function parameter and return type must be annotated. No untyped functions merge.

**Third-party dependency for standard library functionality.**
Exhaust stdlib options before introducing any PyPI package.
