# TDD — Reference

Deep-dive reference for the `implement` skill. See [SKILL.md](SKILL.md) for the overview, scope,
and quick start. See [EXAMPLES.md](EXAMPLES.md) for worked Red-Green-Refactor sessions.

---

## Red Phase — Full Decision Tree

### Pre-conditions

1. Read the full test suite once before writing any new test.
2. Read the relevant bounded context rows from `CONTEXT.md`.
3. Identify the public interface under test — never the implementation.

### Writing the failing test

**Rule 1 — One assertion per test.**
Each test verifies exactly one behaviour. Multiple assertions in one test hide which
behaviour is broken when the test fails.

**Rule 2 — Name the observable behaviour, not the method.**
`test_order_total_includes_tax` not `test_total`.

**Rule 3 — The test must fail before any implementation.**
Run `uv run pytest -x tests/path/to/test_module.py::test_function` and confirm it
fails with the right error. If it passes without implementation, the test is vacuous
and must be rewritten.

**Rule 4 — Mocking boundary rule.**
Mocks are allowed only at system boundaries:

| Allowed mock target | Reason |
|---------------------|--------|
| External HTTP APIs (Claude, third-party services) | Process boundary |
| Database / filesystem | I/O boundary |
| `datetime.now`, `time.time`, `uuid.uuid4` | Non-deterministic state |
| `subprocess.run`, `os.system` | Process fork boundary |

Never mock:
- Internal functions in the same module
- Internal classes or collaborators the implementation owns
- Business logic functions called by the unit under test

**Common mistake: mocking to avoid side effects.**
If the side effect is local (e.g., a dict update, an in-memory list append), test through
it — do not mock it away. Mocking internal state is testing implementation, not behaviour.

---

## Green Phase — Minimal Implementation Rules

**The Minimum Viable Implementation (MVI) rule.**
Write exactly and only the code needed to make the current failing test pass.

Allowed heuristics:
- Hardcode the return value if the test uses a single known input.
- Use `raise NotImplementedError` for branches not yet tested.
- Empty body for classes — only add what tests demand.

Forbidden patterns:
- Adding logic for a case not yet tested ("I'll need this later").
- Extracting abstractions (helper functions, base classes) before there is duplication.
- Writing more than one test's worth of code per Green phase.

---

## Refactor Phase — Deep Module Checklist

After GREEN, apply this checklist in order. Stop at the first item that changes code;
re-run the full test suite; repeat from the top.

1. **Duplication:** Is any logic repeated in two or more places? Extract behind the interface.
2. **Interface width:** Can any public method be removed or merged without losing expressiveness?
3. **Leaking internals:** Does the public interface expose an implementation detail (a class
   name, a data structure type, an algorithm parameter)? Replace with a stable abstraction.
4. **Responsibility count:** Does this module own more than one domain concept? If yes, split.
5. **Naming clarity:** Do all public identifiers name the domain concept, not the mechanism?

**Domain extension:** After this checklist, load the domain skill (`application-engineering`,
`data-engineering`, or `agentic-engineering`) for language- and stack-specific REFACTOR
patterns. Do not apply domain patterns before the checklist above completes.

---

## pytest Fixture Conventions

### Fixture scope selection

| Scope | Use when | Do NOT use when |
|-------|----------|-----------------|
| `function` (default) | Any state that can be mutated by the test | Never upscope to session to save time |
| `module` | Read-only expensive objects shared across a file | Object has mutable state |
| `session` | Read-only constants or immutable connections | Object can be mutated |

**Rule:** Prefer `function` scope. Opt up only when the cost is proven (e.g., real network call).

### Fixture file location

- Fixtures that apply to one test module: define them in that module.
- Fixtures that apply to one test directory: define them in `tests/<dir>/conftest.py`.
- Fixtures that apply to the full suite: define them in `tests/conftest.py`.
- Never define fixtures in `conftest.py` that are only used in one test module.

---

## Parametrize Patterns

### When to use `@pytest.mark.parametrize`

Use parametrize when:
- Two or more test cases verify the same behaviour with different inputs.
- The test body would be identical except for the input/expected values.

Do NOT use parametrize when:
- Each case has different setup or teardown.
- Each case tests a meaningfully different behaviour (give them separate names).

### Parametrize format

```python
@pytest.mark.parametrize(
    "input_val,expected",
    [
        (0, 0.0),
        (10, 1.0),
        (-5, -0.5),
    ],
    ids=["zero", "positive", "negative"],
)
def test_normalise_score(input_val, expected):
    assert normalise_score(input_val) == expected
```

**Rule: always provide `ids`** when the parameter values are not self-explanatory. IDs appear
in the failure message and in `pytest -v` output — they are the reader's only context.

---

## Coverage Threshold

The project's coverage floor is enforced by `pyproject.toml`. Do not lower it. Do not skip
lines with `# pragma: no cover` unless the line is an `if TYPE_CHECKING:` guard or a
`__main__` block.

To run with coverage locally:

```bash
uv run pytest --cov=src --cov-report=term-missing
```

Lines that cannot be tested must be justified by a comment — if you cannot justify the
exemption in one sentence, the line should be tested instead.

---

## Acceptance Criteria Traceability — Full Rules

Every test function must trace to a testing decision in the Lean PRD or a user story in the
GitHub Issue. The tracing is checked during `review`:

1. Read the acceptance criteria in the GitHub Issue.
2. For each criterion, find the test that verifies it. If no test covers a criterion, that
   criterion is in RED — add the test before declaring any phase GREEN.
3. If a test cannot be traced to any criterion, it is one of:
   - Implementation detail masquerading as a test — delete it.
   - An undiscovered acceptance criterion — add it to the issue before keeping the test.

**Tracer bullet rule:** The first criterion in any issue is always the tracer bullet. The
tracer bullet test must be RED before any other test is written.
