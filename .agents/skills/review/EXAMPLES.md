# Review — Examples

Worked end-to-end review sessions demonstrating the `review` skill. See [SKILL.md](SKILL.md)
for the quick-start and [REFERENCE.md](REFERENCE.md) for the full finding taxonomy,
auto-fix protocol, and drift-risk heuristics.

---

## Example 1: PR with a BLOCK Finding (Internal Mock)

**Context:** PR #42 adds `Order.total()` with tax calculation. The `tdd` cycle completed
but the reviewer finds a test that mocks an internal collaborator.

### Step 1 — Run the review

```bash
gh pr diff 42 | claude --system "You are a Senior Architect. Review this diff for:
(1) violations of boundaries in CONTEXT.md, (2) shallow modules, (3) internal mocking
in tests, (4) missing acceptance criteria coverage.
List findings with severity: BLOCK | WARN | INFO."
```

Claude response:

```
FINDINGS

[BLOCK] Internal mock in test_order_total_includes_tax
  tests/test_orders.py, line 8: TaxCalculator is mocked via patch('src.orders.TaxCalculator').
  TaxCalculator is an internal collaborator — mock only at system boundaries.

[WARN] Order.items is a public field exposing the internal list representation.
  Consider a read-only property or private field.

[INFO] No docstring on Order.total() — low priority.
```

### Step 2 — Auto-fix loop: BLOCK finding

**Iteration 1 — Generator:**

Generator removes the internal mock and rewrites the test to call `Order.total()` directly:

```python
# Before (mocked internal collaborator)
def test_order_total_includes_tax():
    with patch("src.orders.TaxCalculator") as mock_calc:
        mock_calc.return_value.calculate.return_value = 1.00
        order = Order(items=[Item("widget", 10.00)], tax_rate=0.1)
        assert order.total() == 11.00


# After (through public interface)
def test_order_total_includes_tax():
    order = Order(items=[Item("widget", 10.00)], tax_rate=0.1)
    assert order.total() == 11.00
```

```bash
uv run pytest -x
# → PASSED
```

**Evaluator re-review:**

```
Is this finding resolved? Finding: Internal mock of TaxCalculator in test_order_total_includes_tax.
Answer RESOLVED or UNRESOLVED with one sentence of justification.

→ RESOLVED — the test now calls Order.total() directly through the public interface
  without patching any internal collaborator.
```

BLOCK finding resolved in iteration 1.

### Step 3 — Auto-fix loop: WARN finding

Generator makes `items` private:

```python
@dataclass
class Order:
    _items: list
    tax_rate: float

    def __init__(self, items: list, tax_rate: float) -> None:
        self._items = items
        self.tax_rate = tax_rate

    def total(self) -> float:
        return sum(i.price for i in self._items) * (1 + self.tax_rate)
```

```bash
uv run pytest -x
# → PASSED
```

Evaluator: RESOLVED — `_items` is now private; callers cannot mutate the internal list.

### Step 4 — Final verification

```bash
# Re-read all findings against the current diff
gh pr diff 42 | claude --system "Confirm all findings from the initial review are resolved.
Findings: (1) internal mock BLOCK, (2) public items field WARN, (3) missing docstring INFO."
# → All BLOCK and WARN findings resolved. INFO noted.
```

Post summary comment:

```bash
gh pr comment 42 --body "## Review Complete

All findings resolved.

| Finding | Severity | Status |
|---------|----------|--------|
| Internal mock of TaxCalculator | BLOCK | Fixed (iteration 1) |
| Order.items public field | WARN | Fixed (iteration 1) |
| Missing docstring on total() | INFO | Noted — no action required |

PR is clean. Ready for \`ship\`."
```

---

## Example 2: PR Approved Without BLOCK or WARN Findings

**Context:** PR #55 refactors `src/config.py` to add a new `Settings` field.
Review runs cleanly — no structural issues found.

### Step 1 — Run the review

```bash
gh pr diff 55 | claude --system "You are a Senior Architect. Review this diff for:
(1) violations of boundaries in CONTEXT.md, (2) shallow modules, (3) internal mocking
in tests, (4) missing acceptance criteria coverage.
List findings with severity: BLOCK | WARN | INFO."
```

Claude response:

```
FINDINGS

No BLOCK or WARN findings.

[INFO] New field DEFAULT_TIMEOUT could benefit from a comment explaining why 30s
was chosen — low priority, not blocking.
```

### Step 2 — INFO finding handling

INFO findings do not gate merge. Post as a note and proceed immediately to `ship`.

```bash
gh pr comment 55 --body "## Review Complete

No BLOCK or WARN findings.

[INFO] DEFAULT_TIMEOUT — a comment explaining the 30s choice would help future
readers. Not blocking.

PR is clean. Ready for \`ship\`."
```

No auto-fix loop required. No HITL escalation.

---

## Example 3: Escalation After 3 Iterations

**Context:** PR #61 has a bounded context bleed: an HTTP handler is writing to
`src/utils/`, which is a generic module that must not contain project logic.

### Step 1 — BLOCK finding identified

```
[BLOCK] Bounded context bleed: src/utils/m_response.py now imports from src/domain/,
violating "src/utils/ stays generic" (CONTEXT.md Architectural Constraints).
```

### Step 2 — Iteration 1 fails

Generator moves the domain import to `src/domain/response.py`. Tests fail: three
other modules import from `src/utils/m_response.py` and now break.

```bash
uv run pytest -x
# → FAILED: ImportError in 3 test files
```

Evaluator: UNRESOLVED — tests still fail after the move. Iteration 2.

### Step 3 — Iteration 2 fails

Generator updates the three broken imports. Tests pass but the Evaluator finds the
logic is now split across two modules with duplicated validation.

Evaluator: UNRESOLVED — duplicate validation logic across src/utils and src/domain.
Iteration 3.

### Step 4 — Iteration 3 fails

Generator extracts the duplicated logic into a shared helper. The architecture blast-radius
report flags the new shared helper as a potential God Object. Tests pass but the structural
problem remains contested.

Evaluator: UNRESOLVED — bounded context bleed converted to a potential God Object; this
requires a human architectural decision.

### Step 5 — Escalate

```bash
gh pr comment 61 --body "## Review Escalation

**Finding:** Bounded context bleed — src/utils/ importing from src/domain/
**Root cause hypothesis:** The correct home for the shared logic is not mechanically
determinable without a refine session (two valid bounded context designs exist).
**Iterations attempted:** 3
**Status:** UNRESOLVED — merge blocked

**Action required:** Human review needed before this PR can proceed."

gh pr edit 61 --add-label "HITL"
```

Stop. Do not attempt iteration 4.
