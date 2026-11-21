# Ship — Examples

Worked walkthroughs demonstrating the `ship` skill. See [SKILL.md](SKILL.md) for the
quick-start and [REFERENCE.md](REFERENCE.md) for the full pre-merge checklist, squash
strategy rules, and rollback procedure.

---

## Example 1: Standard Patch Release (PR #42)

**Context:** PR #42 adds `Order.total()` with tax calculation. The `review` skill completed
with all BLOCK and WARN findings resolved. Ready to ship.

### Step 1 — Module Map check

```bash
pwsh .github/checks/check-module-map.ps1
# → Exit 0: all new src/ directories have Module Map rows.
```

PR adds `src/orders/`. Confirmed it has a Module Map row in `CONTEXT.md`:

```
| orders | src/orders/ | src/orders/ | Order, Item (domain model) |
```

### Step 2 — Sandboxing verification

```bash
git diff main...HEAD --name-only | grep -E '\.(env|key|pem)$'
# → (no output — no credential files added)

git diff main...HEAD -- '*.py' | grep -iE '(api_key|secret|password)\s*=\s*["\x27][A-Za-z0-9]'
# → (no output — no hardcoded secrets)
```

### Step 3 — Supply chain review

```bash
git diff main...HEAD -- pyproject.toml
# → (no new dependencies — pure Python implementation, no third-party packages added)
```

### Step 4 — Auto-close validation

```bash
gh pr view 42 --json body | jq -r '.body' | grep -iE 'closes\s+#[0-9]+'
# → Closes #38
```

Confirmed: `Closes #38` is present. Issue #38 will auto-close on merge.

### Step 5 — Merge

```bash
gh pr merge 42 --squash --delete-branch
# → ✓ Squashed and merged pull request #42
# → ✓ Deleted branch feature/38-order-total
```

### Step 6 — Post-merge: CONTEXT.md update

New bounded context `src/orders/` was added. Update `CONTEXT.md`:

```markdown
## Bounded Contexts addition
| src/orders/ | Domain model: Order, Item, tax calculation | Does not own: HTTP endpoints, persistence |

## Module Map addition
| orders | src/orders/ | src/orders/ | Order (domain model), Item (value object) |
```

Commit:

```bash
git add CONTEXT.md
git commit -m "docs: update CONTEXT.md after PR #42 — add orders bounded context"
git push origin main
```

### Step 7 — Post-merge: .out-of-scope.md update

During review, multi-currency support was explicitly deferred:

```bash
cat >> .out-of-scope.md << 'EOF'

## Multi-currency order totals

**Date:** 2026-07-29
**Reason:** Deferred in PR #42 — single-currency implementation is sufficient for the
tracer bullet. Multi-currency requires a new refine session to agree on rounding rules.
**Source ADR:** N/A

---
EOF

git add .out-of-scope.md
git commit -m "docs: record multi-currency deferral after PR #42"
git push origin main
```

---

## Example 2: Rollback — CI Fails on main After Merge

**Context:** PR #55 was merged. Twenty minutes later, CI reports `test_config.py` fails
on `main` — a new `DEFAULT_TIMEOUT` field in `Settings` conflicts with a pydantic-settings
validation constraint.

### Step 1 — Identify the breaking commit

```bash
git log --oneline main | head -5
# d4f8a1b feat(config): add DEFAULT_TIMEOUT setting (#55)
# 3c2e91a feat(orders): add Order.total() with tax (#42)
# ...
```

Breaking commit: `d4f8a1b`.

### Step 2 — Revert (do not force-push)

```bash
git revert d4f8a1b --no-edit
# → [main e9f1234] Revert "feat(config): add DEFAULT_TIMEOUT setting (#55)"
git push origin main
```

CI re-runs on the revert commit and passes. `main` is stable again.

### Step 3 — Re-open the linked issue

```bash
gh issue reopen 52
gh issue comment 52 --body "Reverted by e9f1234 — DEFAULT_TIMEOUT conflicts with
pydantic-settings validation. Reopening for investigation. See PR #55."
```

### Step 4 — Label the reverted PR

```bash
gh pr edit 55 --add-label "reverted"
gh pr comment 55 --body "Reverted in e9f1234. Root cause: DEFAULT_TIMEOUT field name
conflicts with a pydantic-settings environment variable prefix. Investigation tracked
in issue #52."
```

### Step 5 — Investigate before re-implementing

Open a new issue for the root cause fix:

```bash
gh issue create \
  --title "fix(config): diagnose DEFAULT_TIMEOUT pydantic conflict before re-implementing" \
  --label "human:approval" \
  --body "PR #55 was reverted (see e9f1234). Root cause: pydantic-settings rejects
DEFAULT_TIMEOUT because the field name clashes with an env var prefix. A refine
session is needed to agree on the correct field naming convention before
re-implementing. Ref: reverted PR #55, issue #52."
```

Do not re-merge PR #55. Open a new PR after root cause is resolved.
