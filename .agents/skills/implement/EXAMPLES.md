# TDD — Examples

Golden end-to-end sessions demonstrating the `implement` skill. See [SKILL.md](SKILL.md) for the
quick-start and [REFERENCE.md](REFERENCE.md) for the full decision tree, fixture conventions,
and parametrize patterns.

The session below continues from the `plan` example. See
[plan/EXAMPLES.md](../plan/EXAMPLES.md) for the preceding session.

---

## Example 1: New Feature — Order Total with Tax

**Context:** Issue #1 (tracer bullet) asks for a function that calculates the total of an
order including tax. The Lean PRD specifies: "As a customer, I want the order total to
include tax, so I see the full price before I confirm."

### Step 0 — RED pre-conditions

```bash
# Read the test suite first
uv run pytest --collect-only tests/ | head -20
# → (no test_orders.py yet — the file does not exist)
```

Target public interface: `Order.total()` method on a new `Order` class.

### Step 1 — RED: Write one failing test

```python
# tests/test_orders.py

from src.orders import Order, Item


def test_order_total_includes_tax():
    order = Order(items=[Item("widget", 10.00)], tax_rate=0.1)
    assert order.total() == 11.00
```

```bash
uv run pytest -x tests/test_orders.py::test_order_total_includes_tax
# → FAILED: ModuleNotFoundError: No module named 'src.orders'
# Confirmed RED.
```

### Step 2 — GREEN: Minimal implementation

```python
# src/orders/__init__.py
from dataclasses import dataclass


@dataclass
class Item:
    name: str
    price: float


@dataclass
class Order:
    items: list
    tax_rate: float

    def total(self) -> float:
        subtotal = sum(i.price for i in self.items)
        return subtotal * (1 + self.tax_rate)
```

```bash
uv run pytest -x tests/test_orders.py::test_order_total_includes_tax
# → PASSED
# Confirmed GREEN.
```

### Step 3 — REFACTOR: Apply deep module checklist

Apply checklist from [REFERENCE.md](REFERENCE.md#refactor-phase--deep-module-checklist):

1. **Duplication:** No duplication yet (single implementation path). No change.
2. **Interface width:** `Order` exposes `items` and `tax_rate` as public fields. The PRD
   only requires `total()` — make `items` private, accept via `__init__` only.
3. **Leaking internals:** `items` as a public list leaks the internal storage type.
4. **Responsibility count:** `Item` and `Order` are separate domain concepts — correct.
5. **Naming clarity:** `total()` names the domain concept. Accepted.

Refactor applied:

```python
from dataclasses import dataclass, field


@dataclass
class Item:
    name: str
    price: float


@dataclass
class Order:
    _items: list = field(repr=False)
    tax_rate: float

    def __init__(self, items: list, tax_rate: float) -> None:
        self._items = items
        self.tax_rate = tax_rate

    def total(self) -> float:
        subtotal = sum(i.price for i in self._items)
        return subtotal * (1 + self.tax_rate)
```

```bash
uv run pytest tests/test_orders.py
# → PASSED (all GREEN throughout REFACTOR)
```

**Next RED:** Add `test_order_total_with_multiple_items` for the next acceptance criterion.

---

## Example 2: Bug Regression — Zero-Item Order Produces Negative Zero

**Context:** Bug report: `Order(items=[], tax_rate=0.1).total()` returns `-0.0` in some
Python versions due to a float arithmetic edge case. Correct behaviour: `0.0` (positive zero).

### Step 1 — RED: Write the regression test first

```python
# tests/test_orders.py  (add to existing file)


def test_order_total_with_no_items():
    order = Order(items=[], tax_rate=0.1)
    result = order.total()
    assert result == 0.0
    assert not (1 / result < 0), "total() must not return negative zero"
```

```bash
uv run pytest -x tests/test_orders.py::test_order_total_with_no_items
# → FAILED: ZeroDivisionError or AssertionError depending on environment
# Confirmed RED — the bug is reproduced.
```

### Step 2 — GREEN: Fix the implementation

Add explicit `float()` conversion to guarantee positive zero:

```python
def total(self) -> float:
    subtotal = float(sum(i.price for i in self._items))
    return subtotal * (1 + self.tax_rate)
```

```bash
uv run pytest tests/test_orders.py
# → PASSED (all GREEN)
```

### Step 3 — REFACTOR

No structural improvement warranted — the fix is minimal and correct. REFACTOR checklist
passes without changes.

### Why write the test first (even for a bug)?

Writing the test first (before the fix) locks the failure mode:
- The test is evidence that the bug existed.
- If the fix regresses in a future change, the test catches it.
- "Fix first, test second" produces tests that verify the fix, not the behaviour.

---

## Example 3: Parametrize for Multiple Tax Scenarios

**Context:** A new acceptance criterion: "Tax rate must round correctly to 2 decimal places
for rates 0%, 5%, 10%, 20%."

### Step 1 — RED: Parametrized failing test

```python
# tests/test_orders.py

import pytest


@pytest.mark.parametrize(
    "tax_rate,expected_total",
    [
        (0.00, 10.00),
        (0.05, 10.50),
        (0.10, 11.00),
        (0.20, 12.00),
    ],
    ids=["no-tax", "5pct", "10pct", "20pct"],
)
def test_order_total_tax_rates(tax_rate, expected_total):
    order = Order(items=[Item("widget", 10.00)], tax_rate=tax_rate)
    assert round(order.total(), 2) == expected_total
```

```bash
uv run pytest -x tests/test_orders.py::test_order_total_tax_rates
# → FAILED for 20pct: 12.000000000000002 != 12.0
# Confirmed RED.
```

### Step 2 — GREEN

```python
def total(self) -> float:
    subtotal = float(sum(i.price for i in self._items))
    return round(subtotal * (1 + self.tax_rate), 2)
```

```bash
uv run pytest tests/test_orders.py
# → PASSED (all 4 parametrized cases GREEN)
```

### Step 3 — REFACTOR

No duplication introduced. Interface width unchanged. REFACTOR checklist passes clean.

---

## Example 4: Bug Fix Traced Through Its Callers

**Context:** Bug report: the report job crashes with `TypeError` on an empty CSV cell. The
`diagnosis` root-cause statement: `normalise_score` in `src/scores.py` assumes an `int`; two
callers pass the raw cell, which is `None` when empty.

### Step 0 — The reach of the change

```bash
grep -rn "normalise_score" src/ tests/
# → src/scores.py:12      def normalise_score(value: int) -> float:
# → src/report.py:40      row["score"] = normalise_score(cell)
# → src/export.py:77      scores = [normalise_score(c) for c in cells]
# → tests/test_scores.py  (3 tests, all with ints)
```

Two callers, one shared function. The fix lives in `normalise_score`; a guard in `report.py`
alone would leave `export.py` broken.

### Step 1 — RED

```python
def test_normalise_score_treats_empty_cell_as_zero():
    assert normalise_score(None) == 0.0
```

```bash
uv run pytest -x tests/test_scores.py::test_normalise_score_treats_empty_cell_as_zero
# → FAILED: TypeError: unsupported operand type(s) for /: 'NoneType' and 'int'
# Confirmed RED — the bug is reproduced.
```

### Step 2 — GREEN: one line, in the shared function

```python
def normalise_score(value: int | None) -> float:
    return 0.0 if value is None else value / 10
```

Both callers are fixed by the one change. Neither caller is touched.

### Step 3 — REFACTOR: nothing to add, one shortcut to mark

One legacy export still hands over strings for non-empty cells. That is a known limit, not
this issue's scope:

```python
    # shortcut: numeric cells only; the legacy export (issue N) still needs str parsing
```

### Closing note

```
- Left undone: str cells from the legacy export — marked as a shortcut, tracked in issue N.
- Issues discovered: none; both callers are covered by the new test and the existing three.
```
