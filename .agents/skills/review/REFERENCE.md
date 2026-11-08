# Review — Reference

Deep-dive reference for the `review` skill. See [SKILL.md](SKILL.md) for the method and the
output shape. See [EXAMPLES.md](EXAMPLES.md) for worked review sessions.

---

## Finding categories

Severity follows what happens if the finding ships, not how big the fix is. It is the reviewer's
rule for the verdict line and for what `architect`'s repo audit turns into an issue; it is never
printed on a finding.

### BLOCK — merge prohibited

Any of:

- **Bug:** wrong result, crash, missed edge case (empty, zero, last item, rounding, time zones),
  a caller broken by a changed signature or return value, a fix applied in one caller while the
  shared function stays broken
- **Risk:** injection, weak randomness, a hardcoded secret or credential (any literal string),
  missing checks on input from users or other trust boundaries, data loss (errors swallowed,
  writes in the wrong order, no transaction)
- **Scale:** breaks at the expected load — a check-then-write race, state that must be shared
  but is per-process, lists or caches that only grow, a query per item on a big input
- An acceptance criterion in the linked issue not met, or listed under `Left undone:`
- Governance (automatic elevation, see below): violates a `CONTEXT.md` Architectural
  Constraint; introduces a circular dependency (`architect` report); mocks an internal
  collaborator; adds a `src/<domain>/` without a Module Map row; adds an unpinned or unvetted
  dependency; missing `Closes #N`; a bounded context owns logic `CONTEXT.md` says it does not;
  a test not traceable to an acceptance criterion

### WARN — fix, or waive with a one-line reason

- **Missing test:** risky new logic (a branch, a parser, money, security, a data write, a bug
  fix) with no test that fails when it breaks. Ask for one good test, not coverage
- **Speed:** a real slowdown on the expected load
- **Lean:** code that breaks `implement`'s rules — it should not exist or should be smaller —
  - *delete:* dead code, unused options, flags and config, speculative features
  - *reuse:* the repo already has this helper (name the path)
  - *stdlib / native:* the standard library or platform already does it; a new dependency for
    a few lines
  - *yagni:* an interface with one implementation (beyond the I/O port the Architectural
    Constraints require), a factory with one product, a wrapper that only passes calls through
  - *merge:* near-copies that must change together
  - *split:* one function doing several unrelated jobs, so it is hard to read or test — split
    by job, never by line count, never into helpers that exist only to make a function shorter
- The public interface grew during REFACTOR (adds a method; tests still pass) — elevate to
  BLOCK when the method traces to no acceptance criterion
- Moved or merged code lost its error handling or validation
- A comment explains WHAT the code does instead of WHY

### INFO — no gate

- A small speed-up (work repeated in a hot loop) or a shorter form
- A naming improvement when the current name is not wrong
- `@pytest.mark.parametrize` without `ids`; a `conftest.py` fixture used by one module
- Documentation missing where tests cover the behaviour

### What is not a finding

- A line bearing a `shortcut:` comment — a known gap with a named follow-up; list it under
  `Not checked:`
- Style and formatting — the `ruff` gate owns them
- "Consider…", "might…", "could be cleaner" — no concrete case, no finding
- Something the implementation declared under `Left undone:` that no acceptance criterion
  requires
- Code simpler than the reviewer would have written, when it meets the acceptance criteria and
  `implement`'s rules — the team holds one standard, and review does not undo a choice made by it

### Automatic elevation to BLOCK

If a finding maps to a constraint in `CONTEXT.md` or an ADR, elevate to BLOCK regardless of
initial severity. Constraints established in `refine` are not negotiable.

---

## Verdict rule

| Findings | Verdict |
|---|---|
| Any BLOCK | `REJECTED — fix <numbers>` |
| A WARN that is not waived | `REJECTED — fix <numbers>` |
| Only waived WARN and INFO | `APPROVED` |
| None | `APPROVED` + `Looks good.` |

A waiver is one line inside the finding — `Waived: the fix is a new module for a two-line
gain` — never a silent drop.

---

## Fix loop

The loop is the pipeline's implement ↔ review bounce; there is no separate fixer agent (the
Planner/Generator/Evaluator split is in `.out-of-scope.md`).

1. `REJECTED` posts the review to the issue as a signal comment and sets `agent:implementing`.
2. `implement` reads the signal history, fixes the root cause once (`implement` § Before you
   write), runs the suite, pushes.
3. Review runs again against the **current** diff. Resolved findings are not repeated; new
   ones are numbered on.
4. Each rejection is one attempt in the issue's `attempts[]`. After `MaxRetries` (3, in
   `.github/orchestrator/lib/Config.ps1`) the issue lands on `agent:failed`.

**HITL variant.** Fix on the feature branch — or an isolated worktree when the main checkout
must stay clean (→ `version-control`) — then re-run the review against the current diff:

```bash
uv run pytest -x
gh pr diff <number>     # re-read, then re-apply Steps 1–4 of SKILL.md
```

---

## Escalation

When the budget is spent (pipeline: `agent:failed`, set by the orchestrator; HITL: three
unresolved rounds):

1. Post the escalation comment on the PR:

   ```bash
   gh pr comment <number> --body "$(cat << 'EOF'
   ## Review Escalation

   **Finding:** <number and title>
   **Root cause hypothesis:** <what blocks the fix — usually a boundary decision>
   **Rounds attempted:** 3
   **Status:** UNRESOLVED — merge blocked

   **Action required:** a human decides; answer in the issue.
   EOF
   )"
   ```

2. Stop fixing that finding. Set no label — labels are the pipeline's output (ADR-015).
3. Continue with independent findings that do not depend on the escalated one.
4. Do not merge.

---

## Senior Architect Standard — Enforcement Checklist

Apply this checklist against every PR diff before generating findings:

| Standard | Check | Severity if violated |
|----------|-------|----------------------|
| Bounded context integrity | New logic belongs to the correct `Owns` context in `CONTEXT.md` | BLOCK |
| Module Map completeness | Every new `src/<domain>/` has a Module Map row | BLOCK |
| Circular dependency absence | No import cycle introduced (cross-check `architect` report) | BLOCK |
| Mocking rule | Tests mock only at system boundaries | BLOCK |
| Secret hygiene | No hardcoded credentials, API keys, tokens | BLOCK |
| Test traceability | Every test traces to a PRD criterion or acceptance criterion | BLOCK |
| Deep module | Public interface is minimal; no leaking implementation details | WARN |
| Duplicate logic | No logic duplicated across two or more modules | WARN |
| Naming clarity | Identifiers name domain concepts, not mechanisms | INFO |

---

## Drift-Risk Heuristics

Findings in these categories are highest-drift-risk — prioritise them during review:

1. **Interface width growth during REFACTOR** — The most common drift. A REFACTOR phase that
   adds a public method is scope creep masquerading as cleanup. Flag as WARN; elevate to
   BLOCK if the method is not traced to any acceptance criterion.

2. **Internal mocking** — Agents default to mocking internal collaborators when tests are
   hard to write. Every internal mock is a test that cannot catch regressions. Flag as BLOCK.

3. **Bounded context bleed** — Logic added to the wrong context because the correct context
   "didn't exist yet" or "was too far away." Flag as BLOCK.

4. **Silent WARN drops** — WARN findings that are not fixed and not waived accumulate as
   silent debt. Every WARN has a fix or a one-line waiver inside the finding.

5. **Stale diff review** — Always review the current diff, not the diff at review start. A
   fix in round 2 may have already resolved a finding from round 1.

6. **Reviewer-added scope** — A review that asks for an abstraction, option or config the
   issue did not need grows the change it was meant to shrink. Every proposed fix is smaller
   than the problem, or deletes code.
