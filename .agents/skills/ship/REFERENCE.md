# Ship — Reference

Deep-dive reference for the `ship` skill. See [SKILL.md](SKILL.md) for the overview,
scope, and quick start. See [EXAMPLES.md](EXAMPLES.md) for patch-release and rollback
walkthroughs.

---

## Pre-Merge Checklist — Expanded

### [BLOCK] Module Map check — full procedure

```bash
# Run the CI gate script
pwsh .github/checks/check-module-map.ps1

# Manual verification when the script is not available:
# 1. List all top-level src/ directories in this PR
git diff main...HEAD --name-only | grep '^src/' | cut -d'/' -f1-2 | sort -u

# 2. For each new directory, verify a Module Map row exists in CONTEXT.md
grep -E "^\|" CONTEXT.md | grep "src/<directory>"
```

**Failure:** Non-zero exit or missing row → add the missing row to `CONTEXT.md` before merge.

**Module Map row format:**

```
| <module-name> | src/<domain>/ | src/<domain>/ | <EntryClass> (<purpose>) |
```

### [BLOCK] Sandboxing verification — expanded

```bash
# Check for credential or secret files added in this PR
git diff main...HEAD --name-only | grep -E '\.(env|key|pem|p12|pfx|crt|cer)$'
git diff main...HEAD --name-only | grep -iE '(secret|credential|password|token|api.key)'

# Check for hardcoded secrets in changed Python and PowerShell files (heuristic)
git diff main...HEAD -- '*.py' '*.ps1' \
  | grep -iE '(api_key|secret|password|token)\s*=\s*["\x27][A-Za-z0-9+/]{20,}'
```

Any match → **block merge, investigate before proceeding.** Do not redact secrets
in-place — the secret is already in git history and must be rotated externally.

### [BLOCK] Supply chain review — expanded

```bash
# Show dependency changes
git diff main...HEAD -- pyproject.toml uv.lock

# For each NEW package added, verify:
# 1. It is pinned to a specific version in pyproject.toml
# 2. It is recorded in uv.lock (not a floating resolution)
# 3. It is a known, maintained package
```

**Unpinned dependency example (block):**

```toml
# ❌ Unpinned — block merge
dependencies = ["requests"]

# ✅ Pinned — allow
dependencies = ["requests==2.32.3"]
```

### [PASS] Auto-close validation — expanded

A PR's description follows `.github/PULL_REQUEST_TEMPLATE.md` (Summary, Left undone, Issues
discovered, Validation), whose last line is `Closes #<issue-number>`. The orchestrator fills it on
every round; a PR opened by hand gets it from GitHub. A body without the line still gets it added:

```bash
# Check PR body for Closes #N pattern
gh pr view <number> --json body | jq -r '.body' | grep -iE 'closes\s+#[0-9]+'

# If missing, add it before merge:
BODY=$(gh pr view <number> --json body --jq '.body')
gh pr edit <number> --body "${BODY}"$'\n\n'"Closes #<issue-number>"
```

---

## Merge — Squash Strategy Rules

```bash
gh pr merge <number> --squash --delete-branch
```

**Why squash only:**
- One commit per PR keeps `git log` readable at the feature level
- Merge commits pollute history with implementation-detail commits
- Rebase requires force-push if the branch was already reviewed — unsafe
- A branch that is behind is brought up to date by merging the default branch into it
  (GitHub's "Update branch"), never by rebasing it — the squash discards the branch's
  history anyway, so the merge costs nothing and every push stays a plain push

**If branch protection requires a different strategy:**
- Do not bypass the `ship` skill to accommodate the rule
- Change the branch protection rule, then merge with `--squash`
- Never use `--merge` or `--rebase` unless a protection rule change is impossible

---

## Knowledge Persistence — In the PR, Before Merge

Nothing is committed or pushed to the default branch after the merge: branch protection
requires a PR for every change, with no bypass for any user, team or app. Every knowledge
update is a commit on the feature branch, reviewed and merged with the rest of the PR.

### CONTEXT.md rules

1. **New `src/<domain>/` or a file the Map does not list?** Add the Module Map row.
2. **New kind of work?** Add the Issue-Type Index entry.
3. **New glossary term, bounded context or constraint?** Not in this PR — AGENTS.md Rule 2
   reserves those sections for a `refine` session. Open a follow-up issue naming the change.

### .out-of-scope.md rules

For every concept explicitly deferred during this PR's `review` or `plan`, append a section on
the feature branch:

```bash
cat >> .out-of-scope.md << EOF

## <Concept>

**Date:** $(date +%Y-%m-%d)
**Reason:** <why deferred — deferred in PR #<number>>
**Source ADR:** <ADR reference or N/A>

---
EOF
```

---

## Rollback Procedure

If a merge is discovered to be broken (CI fails on `main`, critical regression):

### Step 1 — Do not force-push main

Force-pushing `main` destroys the squash commit history. Use a revert commit instead:

```bash
# Identify the breaking commit
git log --oneline main | head -5

# Revert it on a branch, through a PR — protection refuses a direct push to main
git switch -c revert/<pr-number> origin/main
git revert <squash-commit-hash> --no-edit
git push -u origin revert/<pr-number>
gh pr create --fill
```

(Or click **Revert** on the merged PR.) Merging the revert PR adds a new "Revert" commit to
history, preserving the original commit.

### Step 2 — Re-open the linked issue

```bash
gh issue reopen <issue-number>
gh issue comment <issue-number> --body \
  "Reverted by <revert-commit-hash> — <reason>. Reopening for investigation."
```

### Step 3 — Label the reverted PR

```bash
gh pr edit <pr-number> --add-label "reverted"
gh pr comment <pr-number> --body \
  "Reverted in <revert-commit-hash>. Root cause: <description>."
```

### Step 4 — Investigate before re-implementing

A reverted PR cannot be re-merged without root-cause analysis. Open a new issue for the
root cause fix, reference the reverted PR, and run the full pipeline (refine → architecture
→ plan → tdd → harness → review → ship) for the fix.

**Rule:** Never re-merge the same PR after a revert — squash and open a new PR instead.
The reverted PR's commit hash is now part of history; a second merge would produce a
duplicate commit message.
