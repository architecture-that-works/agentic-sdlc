---
name: version-control
description: Use when creating a branch, making commits, pushing to remote, opening a pull request, or automating the full branch-to-PR flow linked to a GitHub Issue
---

# Version Control

## Overview

Enforces consistent branch, commit, and PR conventions so that every piece of work is traceable from GitHub Issue to squash-merged commit. Used by every workflow phase that touches git or the GitHub API.

**Primary artifact:** Linked branch → commit(s) → PR tied to a GitHub Issue.

## Scope

**Owns:** Branch naming convention, commit message format, PR creation with issue auto-close (`Closes #N`), GitHub CLI (`gh`) command patterns, agent-driven automation of the branch → commit → PR flow, worktree creation for isolated fix branches.

**Does not own:** CI/CD pipeline configuration (→ `harness`), code review standards (→ `review`), PR merge and security governance (→ `ship`).

**Interfaces with:** All workflow skills — every phase that touches git or the GitHub API uses the conventions defined here.

## When to Use

- Starting work on a GitHub Issue — create the branch
- Committing implementation or test changes
- Opening a PR for review
- Automating the full flow from an agent-driven task completion

**Do NOT use for:** Configuring CI/CD (→ `harness`), reviewing PR content (→ `review`), merging (→ `ship`).

## Core Pattern

### Branch Naming

```
feature/<short-description>     # New feature
fix/<short-description>         # Bug fix
refactor/<short-description>    # Refactoring with no behaviour change
docs/<short-description>        # Documentation only
```

Use kebab-case. Keep descriptions under 5 words. No issue numbers in branch names.

```bash
git checkout -b feature/user-auth
git checkout -b fix/order-total-rounding
```

### Commit Message Format

```
<type>(<scope>): <short description>

[optional body — explain WHY, not WHAT]

Closes #<issue-number>
```

**Types:** `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
**Scope:** module or domain area affected (e.g. `orders`, `auth`, `pipeline`)
**Closes #N:** required on the final commit before PR creation

```bash
git commit -m "feat(orders): add tax calculation to order total

Resolves rounding error in multi-item orders with fractional tax rates.

Closes #42"
```

### PR Creation

```bash
gh pr create \
  --title "feat(orders): add tax calculation to order total" \
  --body "## Summary
- Added tax calculation logic to Order.total()
- Covered by 4 new pytest cases

## Closes
Closes #42" \
  --base main
```

**PR body must contain `Closes #N`.** Validated by `ship` before merge.

### Worktree for Isolated Fix Branches

When the review auto-fix loop needs an isolated environment:

```bash
git worktree add ../fix-branch-<description> -b fix/<description>
# Work in ../fix-branch-<description>
# On completion:
git worktree remove ../fix-branch-<description>
```

## Quick Reference

| Convention | Pattern | Example |
|---|---|---|
| Feature branch | `feature/<desc>` | `feature/user-auth` |
| Fix branch | `fix/<desc>` | `fix/order-rounding` |
| Commit type | `feat\|fix\|refactor\|test\|docs\|chore` | `feat(orders): ...` |
| Auto-close | `Closes #N` in commit or PR body | `Closes #42` |
| Merge strategy | Squash only (owned by `ship`) | `gh pr merge --squash` |

**Context sensitivity:** Low. Version-control operations are stateless and safe at any context fill level.

## Common Mistakes

**Missing `Closes #N` in PR body.**
`ship` validates this before merge. If it's missing, the issue stays open after merge and the traceability link is broken.

**Committing directly to `main`.**
All changes go through a branch and PR. No exceptions. Direct commits to `main` bypass `review` and `ship`.

**Long, descriptive branch names.**
Branch names are navigational, not descriptive. Keep under 5 words. The PR title and commit message carry the description.

**Forgetting to remove worktrees.**
Abandoned worktrees accumulate as stale directories. Always `git worktree remove` after the fix branch is merged or abandoned.
