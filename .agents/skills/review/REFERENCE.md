# Review — Reference

Deep-dive reference for the `review` skill. See [SKILL.md](SKILL.md) for the overview,
scope, and quick start. See [EXAMPLES.md](EXAMPLES.md) for worked review sessions.

---

## Finding Taxonomy — Full Criteria

### BLOCK severity criteria

A finding is BLOCK when ANY of the following is true:

- Violates a constraint in `CONTEXT.md` Architectural Constraints
- Introduces a circular dependency (detected by the `architecture` blast-radius report)
- Mocks an internal collaborator in a test (violates `tdd` mocking rule)
- Adds a new `src/<domain>/` directory without a Module Map row in `CONTEXT.md`
- Hardcodes a secret, API key, or credential (any literal string)
- Adds a new dependency that is unpinned or unvetted
- Missing `Closes #N` in the PR body when a linked issue exists
- A bounded context owns logic that `CONTEXT.md` says it does not own
- A test is not traceable to an acceptance criterion in the linked issue

### WARN severity criteria

A finding is WARN when:
- Code is functionally correct but violates the deep module standard (wide interface,
  exposed implementation detail, duplicate logic not yet at duplication threshold)
- A public interface grew during a REFACTOR phase (adds a method; doesn't break tests)
- A comment explains WHAT the code does instead of WHY
- A test uses a magic number without an `ids` parameter in `@pytest.mark.parametrize`
- A new fixture is defined in `conftest.py` but only used in one test module

### INFO severity criteria

A finding is INFO when:
- A naming improvement would help future readers but the current name is not wrong
- An optional abstraction would reduce future duplication
- Documentation is missing but behaviour is covered by tests

### Automatic elevation to BLOCK

If a finding maps to a constraint in `CONTEXT.md` or an ADR, elevate to BLOCK regardless
of initial severity. Constraints established in `refine` are not negotiable.

---

## Auto-Fix Loop — Full Protocol

### Iteration structure

Each iteration consists of:

1. **Generator:** Apply the minimal fix. Commit to the worktree:
   ```bash
   git -C <worktree-path> add -p
   git -C <worktree-path> commit -m "fix(<scope>): <finding-description>"
   ```

2. **Verify:** Run the test suite — all tests must remain GREEN:
   ```bash
   uv run pytest -x
   ```
   If tests fail after the fix, the fix introduced a regression. Revert and try again
   (counts as a new iteration).

3. **Evaluator:** Re-read the specific finding against the current diff:
   ```bash
   gh pr diff <number> | claude --system "Is this finding resolved? Finding: <description>.
   Answer RESOLVED or UNRESOLVED with one sentence of justification."
   ```

4. **Decision:**
   - RESOLVED → mark in the review report, move to next finding.
   - UNRESOLVED → increment counter, try next iteration.
   - Counter reaches 3 → escalate (see Escalation Protocol below).

### Worktree isolation

All fix iterations run in an isolated git worktree, never on the main checkout:

```bash
git worktree add ../review-worktree <branch-name>
# Apply fixes inside the worktree
git worktree remove ../review-worktree   # cleanup after all findings resolved
```

---

## Escalation Protocol — Full Steps

When a finding is not resolved after 3 iterations:

1. Write the escalation comment on the PR:

   ```bash
   gh pr comment <number> --body "$(cat << 'EOF'
   ## Review Escalation

   **Finding:** <description>
   **Root cause hypothesis:** <what the agent believes is blocking auto-fix>
   **Iterations attempted:** 3
   **Status:** UNRESOLVED — merge blocked

   **Action required:** Human review needed before this PR can proceed.
   EOF
   )"
   ```

2. Add the HITL label:

   ```bash
   gh pr edit <number> --add-label "HITL"
   ```

3. Stop all further auto-fix attempts on this finding.
4. Continue reviewing and fixing other independent findings that do not depend on the
   escalated one.
5. Do not merge. Post the full review summary and stop.

---

## Senior Architect Standard — Enforcement Checklist

Apply this checklist against every PR diff before generating findings:

| Standard | Check | Severity if violated |
|----------|-------|----------------------|
| Bounded context integrity | New logic belongs to the correct `Owns` context in `CONTEXT.md` | BLOCK |
| Module Map completeness | Every new `src/<domain>/` has a Module Map row | BLOCK |
| Circular dependency absence | No import cycle introduced (cross-check `architecture` report) | BLOCK |
| Mocking rule | Tests mock only at system boundaries | BLOCK |
| Secret hygiene | No hardcoded credentials, API keys, tokens | BLOCK |
| Deep module | Public interface is minimal; no leaking implementation details | WARN |
| Test traceability | Every test traces to a PRD criterion or acceptance criterion | BLOCK |
| Duplicate logic | No logic duplicated across two or more modules | WARN |
| Naming clarity | Identifiers name domain concepts, not mechanisms | INFO |

---

## Drift-Risk Heuristics

Findings in these categories are highest-drift-risk — prioritise them during review:

1. **Interface width growth during REFACTOR** — The most common drift. A REFACTOR phase
   that adds a public method is scope creep masquerading as cleanup. Flag as WARN; elevate
   to BLOCK if the method is not traced to any acceptance criterion.

2. **Internal mocking** — Agents default to mocking internal collaborators when tests are
   hard to write. Every internal mock is a test that cannot catch regressions. Flag as BLOCK.

3. **Bounded context bleed** — Logic added to the wrong context because the correct context
   "didn't exist yet" or "was too far away." Flag as BLOCK.

4. **Silent WARN drops** — WARN findings that are not addressed and not explicitly waived.
   These accumulate as silent debt. Every WARN must have either a fix commit or a waiver
   comment in the PR.

5. **Stale diff review** — Always review the current diff, not the diff at review start. A
   fix in iteration 2 may have already resolved a finding from iteration 1.
