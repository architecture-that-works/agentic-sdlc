# Review — Examples

Worked end-to-end review sessions demonstrating the `review` skill. See [SKILL.md](SKILL.md)
for the method and the output shape, and [REFERENCE.md](REFERENCE.md) for the finding
categories, the verdict rule and the fix loop.

---

## Example 1: Blocking Findings Fixed in One Round

**Context:** PR #42 adds `Order.total()` with tax calculation. The issue's acceptance
criteria: "total includes tax", "an empty order totals 0.0".

### Round 1 — Understand, look, check

```bash
gh pr diff 42                                  # the diff
grep -rn "Order(" src/ tests/                  # callers: src/checkout.py:31, tests/test_orders.py
sed -n 20,45p src/checkout.py                  # the one production caller
```

The signal history holds `🤖✅ Tests Passing — 3 passed` and `Left undone: none`. The test for
the empty order mocks `TaxCalculator`, an internal class. `checkout.py` passes `items=None`
when the cart is empty.

### Round 1 — Answer: `verdict` `rejected`; `report` (posted to the issue)

```
Fix 1, 2 and 3.

What this change does: Adds an Order class with total(), which sums item prices and applies
a tax rate. checkout.py calls it to show the price before confirmation.

1. **Empty cart crashes checkout** (`src/orders/__init__.py:L14`)
   - **Defect:** total() sums self._items, which checkout.py:31 sets to None for an empty cart.
   - **Case:** An empty cart → sum(None) raises TypeError; the "empty order totals 0.0"
     criterion is not met.
   - **Fix:** `items: list = field(default_factory=list)`; keep sum() as is. One line.

2. **Test proves nothing** (`tests/test_orders.py:L8-12`)
   - **Defect:** test_order_total_with_no_items patches src.orders.TaxCalculator, an internal
     collaborator (implement mocking rule, CONTEXT.md).
   - **Case:** With the mock in place the test passes whether or not total() handles an empty
     order, so finding 1 ships green.
   - **Fix:** Drop the patch; call Order(items=[], tax_rate=0.1).total() and assert 0.0.

3. **items is a public field** (`src/orders/__init__.py:L11`)
   - **Defect:** The dataclass exposes the item list.
   - **Case:** checkout.py appends to it after total() was shown → the displayed total is stale.
   - **Fix:** Rename to `_items`; the constructor keeps the `items` keyword. Two lines.

Not checked: rounding of fractional tax rates — no criterion asks for it.
```

Findings 1 and 2 are BLOCK and 3 is an unwaived WARN by the reviewer's rule, so the verdict
is `rejected` and the report names all three; no tag is printed. The pipeline posts this as `🤖❌ Review Rejected` and sets
`agent:implementing`.

### Round 2 — `implement` fixes all three; review re-reads the current diff

Answer: `verdict` `approved`; `report`:

```
What this change does: Adds an Order class with total(); an empty order totals 0.0; the
item list is private.

Looks good. Checked: both callers, the three tests through the public interface, the
signal history (5 passed).
```

---

## Example 2: Clean Approval

**Context:** PR #55 adds a `DEFAULT_TIMEOUT` field to `Settings` with its test.

Answer: `verdict` `approved`; `report`:

```
What this change does: Adds DEFAULT_TIMEOUT (30 s) to Settings, read from .env like every
other field, with one test for the default and one for the override.

1. **Why 30 seconds** (`src/config.py:L22`)
   - **Defect:** Nothing says where the 30 s default came from.
   - **Case:** The next reader "tunes" it without knowing the upstream API itself times out
     at 30 s.
   - **Fix:** One comment: `# 30 s: the upstream API's own timeout — never wait longer than it does`.

Looks good. Checked: the one caller of Settings, extra="ignore" still set, the two tests.
```

A suggestion like this never changes the verdict; a rejected report names only what must be
fixed. The pipeline proceeds to `ship`.

---

## Example 3: Escalation After Three Rejections

**Context:** PR #61 moves response formatting into `src/utils/m_response.py`, which now
imports from `src/domain/` — a bounded-context bleed (`src/utils/` is generic, CONTEXT.md).

| Round | Finding 1 | Why it stands |
|---|---|---|
| 1 | `rejected` | `src/utils/m_response.py` imports `src/domain/`; three callers depend on the util |
| 2 | `rejected` | Import moved, but the validation is now duplicated in `src/utils/` and `src/domain/` |
| 3 | `rejected` | Duplication extracted into a shared helper both contexts import — a God Object candidate per the blast-radius report |

Each rejection is one attempt in the issue's `attempts[]`. After the third the orchestrator
sets `agent:failed`; nobody sets a label by hand. The reviewer posts the escalation and stops:

```bash
gh pr comment 61 --body "$(cat << 'EOF'
## Review Escalation

**Finding:** 1 — bounded-context bleed, src/utils/ imports src/domain/
**Root cause hypothesis:** two valid homes for the shared validation exist; choosing one is
a boundary decision, not a mechanical fix.
**Rounds attempted:** 3
**Status:** UNRESOLVED — merge blocked

**Action required:** a human decides; answer in the issue.
EOF
)"
```

The owner answers in the issue; `refine` records the decision; the retry implements it.
