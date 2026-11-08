# Review — Examples

Worked end-to-end review sessions demonstrating the `review` skill. See [SKILL.md](SKILL.md)
for the method and the output shape, and [REFERENCE.md](REFERENCE.md) for the finding
categories, the verdict rule and the fix loop.

---

## Example 1: BLOCK Finding Fixed in One Round

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

### Round 1 — Report (posted to the issue)

```
REJECTED — fix 1 and 2

What this change does: Adds an Order class with total(), which sums item prices and applies
a tax rate. checkout.py calls it to show the price before confirmation.

1. **Empty cart crashes checkout** (`src/orders/__init__.py:L14`) — BLOCK
   - **What this is:** total() sums self._items.
   - **Problem:** checkout.py:31 passes items=None for an empty cart; sum(None) raises
     TypeError. The "empty order totals 0.0" criterion is not met.
   - **Fix:** `items: list = field(default_factory=list)`; keep sum() as is. One line.
   - **If we skip it:** Every empty-cart visit to checkout returns a 500.

2. **Test proves nothing** (`tests/test_orders.py:L8-12`) — BLOCK
   - **What this is:** test_order_total_with_no_items patches src.orders.TaxCalculator.
   - **Problem:** TaxCalculator is an internal collaborator; with it mocked the test passes
     whether or not total() handles an empty order (implement mocking rule, CONTEXT.md).
   - **Fix:** Drop the patch; call Order(items=[], tax_rate=0.1).total() and assert 0.0.
   - **If we skip it:** Finding 1 ships green.

3. **items is a public field** (`src/orders/__init__.py:L11`) — WARN
   - **What this is:** The dataclass exposes the item list.
   - **Problem:** checkout.py can mutate the list after total() was shown.
   - **Fix:** Rename to `_items`; the constructor keeps the `items` keyword. Two lines.
   - **If we skip it:** A later caller edits the list and the shown total is stale.

Not checked: rounding of fractional tax rates — no criterion asks for it.
```

The pipeline posts this as `🤖❌ Review Rejected` and sets `agent:implementing`.

### Round 2 — `implement` fixes all three; review re-reads the current diff

```
APPROVED

What this change does: Adds an Order class with total(); an empty order totals 0.0; the
item list is private.

Looks good. Checked: both callers, the three tests through the public interface, the
signal history (5 passed).
```

---

## Example 2: Clean Approval

**Context:** PR #55 adds a `DEFAULT_TIMEOUT` field to `Settings` with its test.

```
APPROVED

What this change does: Adds DEFAULT_TIMEOUT (30 s) to Settings, read from .env like every
other field, with one test for the default and one for the override.

1. **Why 30 seconds** (`src/config.py:L22`) — INFO
   - **What this is:** The new default.
   - **Problem:** Nothing says where 30 came from; the next reader will guess.
   - **Fix:** One comment: `# 30 s: the upstream API's own timeout — never wait longer than it does`.
   - **If we skip it:** Someone "tunes" it without knowing the constraint.

Looks good. Checked: the one caller of Settings, extra="ignore" still set, the two tests.
```

INFO never changes the verdict. The pipeline proceeds to `ship`.

---

## Example 3: Escalation After Three Rejections

**Context:** PR #61 moves response formatting into `src/utils/m_response.py`, which now
imports from `src/domain/` — a bounded-context bleed (`src/utils/` is generic, CONTEXT.md).

| Round | Finding 1 | Why it stands |
|---|---|---|
| 1 | REJECTED | `src/utils/m_response.py` imports `src/domain/`; three callers depend on the util |
| 2 | REJECTED | Import moved, but the validation is now duplicated in `src/utils/` and `src/domain/` |
| 3 | REJECTED | Duplication extracted into a shared helper both contexts import — a God Object candidate per the blast-radius report |

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
