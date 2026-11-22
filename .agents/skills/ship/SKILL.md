---
name: ship
description: Use when merging a reviewed PR, running pre-merge security checks, closing the linked GitHub Issue, or adding CONTEXT.md Module Map rows and out-of-scope records to the PR before merge
---

# Ship

## Overview

Prevents insecure or incomplete merges by running mandatory security gates, enforcing squash-merge discipline, and making sure the PR itself carries its Module Map rows and deferrals — nothing is pushed to the default branch after the merge.

**Primary artifact:** Squash-merged PR with clean history, closed GitHub Issue, and updated knowledge base.

See [REFERENCE.md](REFERENCE.md) for the expanded pre-merge checklist, squash strategy
rules, knowledge persistence rules, and rollback procedure. See [EXAMPLES.md](EXAMPLES.md)
for a standard patch release walkthrough and a rollback scenario.

## Scope

**Owns:** Pre-merge security gates (sandboxing verification, supply chain review), `gh pr merge --squash` execution, auto-close enforcement (`Closes #N`), `.out-of-scope.md` and `CONTEXT.md` Module Map entries carried in the PR.

**Does not own:** Code review findings (→ `review`), branch and commit operations (the orchestrator), container and environment teardown (`.devcontainer/`).

**Interfaces with:** `review` — a passing review is the prerequisite for ship. `refine` — `CONTEXT.md` updates feed back into the next session's initialisation.

## When to Use

- `review` has completed with all BLOCKs resolved or explicitly escalated and accepted
- PR has a linked issue with `Closes #N` in the body
- Ready to merge to `main`

**Do NOT use for:** Running code review (→ `review`), creating commits or branches (the orchestrator).

## Required Inputs

- Open PR with all review BLOCKs resolved
- `Closes #N` present in the PR body
- Access to `gh` CLI and git

## Primary Outputs

- Squash-merged PR with deleted branch
- Closed GitHub Issue (via `Closes #N` auto-close)
- `CONTEXT.md` Module Map / Index rows and `.out-of-scope.md` deferrals, merged as part of the PR

## Core Pattern

### Pre-Merge Checklist

Run in order. All BLOCK items must pass before merge is attempted.

**[BLOCK] Module Map check**
Verify every new `src/<domain>/` directory in this PR has a matching Module Map row in `CONTEXT.md` (ADR-009):
```powershell
pwsh .github/checks/check-module-map.ps1
```
Non-zero exit → add the missing row(s) to the Module Map in `CONTEXT.md` before merge.

**[BLOCK] Sandboxing verification**
Confirm all agent-generated code was produced inside the Dev Container environment. No host credentials should have been accessible during generation. Check:
```bash
# Verify no .env or credential files were added
git diff main...HEAD --name-only | grep -E '\.env|credentials|secrets'
```
Any match → block merge, investigate before proceeding.

**[BLOCK] Supply chain review**
Check the dependency manifest for new or unpinned packages introduced in this PR:
```bash
git diff main...HEAD -- requirements*.txt pyproject.toml package*.json
```
For each new dependency: verify it is pinned to a specific version and is a known, maintained package. Unpinned or unvetted packages → block merge.

**[PASS] Auto-close validation**
A PR's description is what `.github/PULL_REQUEST_TEMPLATE.md` defines — Summary, Left undone,
Issues discovered, Validation — and the template's last line carries `Closes #N`. Confirm the
PR body contains `Closes #N` referencing the linked issue:
```bash
gh pr view <number> --json body | jq '.body | test("Closes #[0-9]+")'
```
If missing → add it before merge, do not skip.

### Bring the Branch Up to Date

Branch protection requires a branch that is up to date with the default branch. Merge the
default branch into the feature branch — what GitHub's "Update branch" button does — and push
without force:

```bash
git fetch origin main && git merge --no-ff origin/main && git push origin HEAD
```

Never rebase the feature branch: the PR is squash-merged, so its history never reaches the
default branch, and a rebase only forces a forced push. The orchestrator does the same
(`Update-Branch`): a conflict found at ship ends the attempt, and the next attempt's agent
settles it, keeping what both sides changed.

### Merge

```bash
gh pr merge <number> --squash --delete-branch
```

Squash merge only. No merge commits, no rebase. `--delete-branch` keeps the remote clean.

### Knowledge Rides in the PR

Nothing is committed or pushed to the default branch after the merge — branch protection
has no exception for it, the orchestrator's included. Knowledge reaches the default branch
inside the reviewed PR, before `gh pr merge`:

- **`CONTEXT.md`** — Module Map rows and Issue-Type Index entries the change needs (Context
  Protocol step 3). Glossary, Bounded Contexts and Architectural Constraints change only in a
  `refine` session (AGENTS.md Rule 2) — raise those as a follow-up issue.
- **`.out-of-scope.md`** — a new `## ` section for every improvement deferred during `review`
  or `plan` that this PR does not include:

```bash
cat >> .out-of-scope.md << EOF

## <Concept>

**Date:** $(date +%Y-%m-%d)
**Reason:** <why deferred — deferred in PR #<number>>
**Source ADR:** <ADR reference or N/A>

---
EOF
git add CONTEXT.md .out-of-scope.md
git commit -m "docs: record Module Map rows and deferrals for #<issue>"
git push   # to the feature branch — the PR carries it
```

Both files are governance paths, so a PR that touches them is held at `human:approval` for
the owner's merge.

## Quick Reference

| Gate | Severity | Failure action |
|---|---|---|
| Module Map check | BLOCK | Add missing row(s) to `CONTEXT.md` Module Map |
| Sandboxing verification | BLOCK | Investigate, do not merge |
| Supply chain review | BLOCK | Pin or remove package, do not merge |
| Auto-close `Closes #N` | BLOCK | Add to PR body |
| `CONTEXT.md` Module Map / Index | Required | Commit to the feature branch before merge |
| `.out-of-scope.md` deferrals | Required | Commit to the feature branch before merge |

**Context sensitivity:** Low. Merge and knowledge persistence operations are stateless and safe at any context fill level.

## Common Mistakes

**Merging without running the security checklist.**
The checklist is not optional for "small" PRs. Supply chain and sandboxing checks take minutes and prevent hard-to-reverse incidents.

**Committing to the default branch after the merge.**
Branch protection refuses a direct push, with no exception. A Module Map row or deferral left out of the PR is lost — the next session starts without it. Put it in the PR before merging.

**Using merge commit instead of squash.**
Merge commits pollute history. `--squash` is the only permitted merge strategy. If the repository has a branch protection rule requiring a different strategy, update the rule — do not bypass the skill.

**Closing the issue manually before confirming `Closes #N` in the PR body.**
The PR body must auto-close the issue on merge. Manual close breaks the traceability link between commit and issue.
