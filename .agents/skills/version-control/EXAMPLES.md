# Version Control — Examples

Worked end-to-end patterns for the `version-control` skill. See [SKILL.md](SKILL.md) for the
quick-start and [REFERENCE.md](REFERENCE.md) for the branch-naming grammar, commit format
specification, and worktree lifecycle detail.

---

## Example 1: Feature Branch — Issue to Squash-Merge

**Context:** Issue #42 — "Add tax calculation to order total". The branch will carry a
three-commit series: test (RED), implementation (GREEN), and a refactor commit. The PR is
created after the final commit and squash-merged.

### Step 1 — Create the branch

```bash
# Verify you are on main and it is up to date
git checkout main
git pull --ff-only origin main

# Create the feature branch
git checkout -b feature/42-order-tax-calculation
```

Branch name breakdown:
- Prefix: `feature` (always, regardless of change type — the commit message carries that)
- Issue number: `42`
- Slug: `order-tax-calculation` (3 words, lowercase, hyphens)

Verify it satisfies the grammar:

```bash
pwsh .agents/skills/version-control/scripts/check-branch-name.ps1
# → Branch name OK: feature/42-order-tax-calculation
```

### Step 2 — Commit the RED test

```bash
git add tests/test_orders.py
git commit -m "test(orders): add failing test for tax calculation

RED phase — verifies Order.total() includes tax rate.

Closes #42"
```

Wait — `Closes #N` on every commit is redundant; only the **final** commit before PR creation
needs it. Revise:

```bash
git add tests/test_orders.py
git commit -m "test(orders): add failing test for tax calculation

RED phase — verifies Order.total() includes tax rate."
```

### Step 3 — Commit the GREEN implementation

```bash
git add src/orders/__init__.py
git commit -m "feat(orders): implement tax calculation in Order.total"
```

### Step 4 — Commit the REFACTOR

```bash
git add src/orders/__init__.py
git commit -m "refactor(orders): hide items list behind private interface"
```

### Step 5 — Final commit (if any) carries `Closes #N`

If the refactor commit is the last commit, amend it to add `Closes #N`:

```bash
git commit --amend -m "refactor(orders): hide items list behind private interface

Closes #42"
```

Or if there is a separate chore commit (e.g., updating docs):

```bash
git commit -m "docs(orders): document Order.total tax-rate contract

Closes #42"
```

### Step 6 — Push and open the PR

```bash
git push -u origin feature/42-order-tax-calculation

gh pr create \
  --title "feat(orders): add tax calculation to order total" \
  --body "## Summary
- Adds tax_rate parameter to Order constructor
- Order.total() now returns subtotal × (1 + tax_rate)
- Covered by 3 new pytest cases (parametrized across 0%, 5%, 10%, 20%)

## Closes
Closes #42" \
  --base main
```

**PR title** matches the `feat` commit type — it is the squash-commit message that lands on
`main`. Keep it consistent with the branch's primary type.

### Step 7 — After merge

Once `ship` squash-merges the PR:

```bash
# Return to main and pull the squash commit
git checkout main
git pull --ff-only origin main

# Delete the now-merged branch locally
git branch -d feature/42-order-tax-calculation
```

---

## Example 2: Conventional Commit Series

**Context:** Issue #77 — "Refactor config loader to support optional LOG_LEVEL". Three
commits in sequence: a `test` commit (RED), a `feat` commit (GREEN), and a `chore` commit
(dependency bump). Demonstrates type selection and scope discipline.

### Commit 1 — RED test

```bash
git commit -m "test(config): add failing test for optional LOG_LEVEL

Settings must not raise when LOG_LEVEL is absent from the environment.
Currently raises ValidationError."
```

Why `test` type:
- Only test code is changing.
- No production code has been modified yet.
- `config` scope matches `src/config.py` — the module under test.

### Commit 2 — GREEN implementation

```bash
git commit -m "feat(config): make LOG_LEVEL optional with INFO default

Adds Optional[str] annotation and default='INFO' to Settings.LOG_LEVEL.
Resolves ValidationError when env var is absent."
```

Why `feat` type:
- New behaviour is exposed: `LOG_LEVEL` now has a default value.
- Users who previously had to set `LOG_LEVEL` explicitly no longer need to.

### Commit 3 — Dependency bump (chore)

```bash
git commit -m "chore(deps): bump pydantic-settings to 2.4.0

Required for Optional field default handling in strict mode.

Closes #77"
```

Why `chore` type:
- Only `pyproject.toml` and `uv.lock` change — no production or test logic.
- `deps` scope is conventional for dependency updates.
- `Closes #77` appears here because this is the final commit before PR creation.

### Type selection decision tree

```
Does this commit add new user-visible behaviour?         → feat
Does this commit fix a defect?                           → fix
Does this commit change only tests?                      → test
Does this commit change only docs/comments?              → docs
Does this commit change only tooling/deps/CI?            → chore
Does this commit restructure without behaviour change?   → refactor
```

---

## Example 3: Worktree-Isolated Fix Branch

**Context:** The `review` skill's auto-fix loop has identified a security issue in
`feature/99-admin-endpoint` that must be isolated. Meanwhile, the agent must continue
working on `feature/99-admin-endpoint` in the main worktree.

### Step 1 — Create the fix worktree

```bash
# From the project root (main worktree on feature/99-admin-endpoint)
# Same issue number, different slug — still feature/, so Complete-HeldPR and the
# orchestrator's branch matcher pick it up like any other issue-linked branch.
git worktree add ../fix-branch-99-auth-guard -b feature/99-auth-guard

# Verify both worktrees are registered
git worktree list
# /home/user/my-project                   abc1234 [feature/99-admin-endpoint]
# /home/user/fix-branch-99-auth-guard     abc1234 [feature/99-auth-guard]
```

The fix worktree starts at the same HEAD as the main worktree. Both branches are now
independent; commits to one do not affect the other.

### Step 2 — Work in the fix worktree

```bash
cd ../fix-branch-99-auth-guard

# Make the security fix
# ... edit src/admin/auth.py ...

git add src/admin/auth.py
git commit -m "fix(admin): add authentication guard to admin endpoint

Missing @require_auth decorator allowed unauthenticated access.

Closes #99"
```

### Step 3 — Push the fix branch

```bash
git push -u origin feature/99-auth-guard

gh pr create \
  --title "fix(admin): add authentication guard to admin endpoint" \
  --body "## Summary
- Adds @require_auth decorator to all /admin/* routes
- Closes authentication gap identified in review

## Closes
Closes #99" \
  --base main
```

### Step 4 — Return to main worktree and merge the fix back

```bash
cd /home/user/my-project    # return to project root

# Once the fix PR is merged to main, rebase the feature branch on top
git fetch origin main
git rebase origin/main
```

### Step 5 — Remove the fix worktree

```bash
# From the project root
git worktree remove ../fix-branch-99-auth-guard

# Verify it is gone
git worktree list
# /home/user/my-project  def5678 [feature/99-admin-endpoint]

# Optionally delete the remote tracking branch
git push origin --delete feature/99-auth-guard
```

### Stale worktree cleanup

If the directory was deleted manually (e.g. by `rm -rf`), the worktree entry stays in Git's
index until pruned:

```bash
git worktree prune --dry-run   # preview what will be pruned
git worktree prune             # remove stale entries
git worktree list              # confirm clean state
```
