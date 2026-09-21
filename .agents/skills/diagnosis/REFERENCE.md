# Diagnosis — Reference

Mechanism-level detail for the `diagnosis` skill. See [SKILL.md](SKILL.md) for the
overview, scope, and six-step Core Pattern. See [EXAMPLES.md](EXAMPLES.md) for worked
diagnoses (test failure and CI/workflow failure).

---

## Step 1 — Read the Error in Full: Protocol

### Full-trace capture

Before reading anything, capture the complete output to a file so you can refer back to it
without re-running the failing command:

```bash
uv run pytest 2>&1 | tee /tmp/test-failure.txt
# or for a CI script:
bash .github/scripts/ci/check-module-map.ps1 2>&1 | tee /tmp/ci-failure.txt
```

Capturing prevents the output from scrolling past the terminal buffer and makes `grep` possible.

### Origin-frame identification

The origin frame is the first frame in the traceback that points to code you own — not to a
library or framework. It is almost always the root cause location.

```bash
# Find the first frame in your source tree
grep -n 'src/' /tmp/test-failure.txt | head -5
```

**Reading order:**
1. Error type and message (last line of traceback) — tells you _what_ failed.
2. Origin frame (first `src/` or `tests/` line) — tells you _where_ it failed.
3. Call chain (frames between origin and error) — tells you _how_ execution reached the failure.
4. Secondary errors or warnings printed before the traceback — tells you _what triggered it_.

**Pitfall:** Python tracebacks print the call chain top-to-bottom (outermost to innermost).
The _last_ frame before the error type is closest to the failure, but the origin is the
_first_ frame in your code — not the last library frame.

---

## Step 2 — Symptom vs. Root Cause: Heuristic Table

The symptom is what failed. The root cause is why it failed. They are never the same thing.

### Heuristic table

| Symptom | Likely root cause class | Diagnostic next step |
|---------|------------------------|----------------------|
| `AttributeError: 'NoneType' object has no attribute 'X'` | A function returns `None` when the caller expects an object | Trace who returns `None` — is it a missing return, a guard that silently returns, or an optional that is not checked? |
| `KeyError: 'X'` | A dict or config does not contain the expected key | Check the dict/config construction site — was the key ever written, or was the name misspelled? |
| `ImportError: cannot import name 'X' from 'Y'` | Module renamed, or a circular import was introduced | Check `git log --oneline -- src/Y.py` for recent renames; run `python -c "import Y"` to isolate circular imports |
| `TypeError: X() takes N positional arguments but M were given` | Signature changed but all callers were not updated | `grep -rn 'X(' src/` to find all call sites |
| CI fails, local passes | Environment variable or dependency version divergence | Compare `uv lock` output between CI and local; check CI env var set |
| Test passes alone, fails in suite | Test pollution — a previous test mutates shared state | Run the failing test with `--randomly-seed=<seed>` to isolate ordering dependency |
| `AssertionError` in an unrelated test after your change | Side-effect regression — your change mutated global state | `git stash`, re-run the unrelated test; if it passes, your change introduced the regression |

### Writing the two-line separation

Before moving to Step 3, write these two lines explicitly:

```
Symptom  : <what failed — error type, file, line>
Hypothesis: <why it might have failed — one sentence, specific>
```

This forces separation between observation (symptom) and explanation (hypothesis). If you
cannot write the hypothesis line without waffling, you have not read the error in full.

---

## Step 3 — Hypothesis Ranking: Algorithm

### Hypothesis sources (in priority order)

Rank sources by their prior probability of being the root cause:

1. **Last-commit delta** — what files did the most recent commit touch? If the failing frame
   is in a file that was just modified, start here. Use `git diff HEAD~1 -- <failing-file>`.

2. **Environment delta** — does the failure occur only in CI or only on a specific machine?
   If yes, the root cause is almost certainly an environment difference. Check:
   - Missing or different env vars (`env | sort` locally vs. CI env dump)
   - Dependency version differences (`uv lock --check` locally; `cat uv.lock | grep <pkg>`)
   - Python version differences (`python --version`)

3. **Shared-state delta** — does the failure occur only when running the full suite, not in
   isolation? The root cause is test pollution. Check for module-level mutable state, class
   variables, or fixtures with `session` scope that accumulate mutations.

4. **Latent bug** — the code path existed before the most recent change but was never exercised.
   The new change added a test or a call path that exposes it. Confirm by checking `git log`
   for when the failing code was introduced.

### Maximum five hypotheses

Write no more than five hypotheses, ranked 1 (most likely) to 5. If you cannot narrow to five,
you have not read the error in full (return to Step 1). More hypotheses signal confusion, not
thoroughness.

```
H1: [most likely] Settings.LOG_LEVEL is not Optional — raises ValidationError when env var absent
H2: Test fixture does not set LOG_LEVEL — only an environment problem in tests
H3: Recent commit to config.py changed field type — regression
H4: pydantic-settings version upgrade changed Optional handling
H5: [least likely] A different Settings field is triggering the error
```

---

## Step 4 — Minimal Reproduction: Narrowing Commands

The goal is: one command, one input, one failure, reproducible in under 10 seconds.

### Narrowing sequence

```bash
# 1. Full suite
uv run pytest

# 2. Narrow to the failing directory
uv run pytest tests/path/

# 3. Narrow to the failing file
uv run pytest tests/path/test_foo.py

# 4. Narrow to the failing test node
uv run pytest tests/path/test_foo.py::test_function_name

# 5. For parametrized tests, narrow to the failing parameter set
uv run pytest "tests/path/test_foo.py::test_function_name[param-id]"

# 6. If a unit test, reproduce in a REPL
uv run python -c "from src.config import Settings; s = Settings()"
```

### CI-only failure reproduction

If the failure only occurs in CI, replicate the CI environment locally:

```bash
# 1. Identify the env vars set in CI (from the workflow YAML)
#    e.g. .github/workflows/ci.yml sets: DATABASE_URL, LOG_LEVEL, PYTHONDONTWRITEBYTECODE

# 2. Set those vars locally and re-run
DATABASE_URL=sqlite:///test.db LOG_LEVEL='' uv run pytest tests/path/test_foo.py::test_name

# 3. If still does not reproduce, check the dependency lock
uv lock --check   # confirm local lock matches CI lock
```

**Done when:** You can paste one command into a terminal and reliably trigger the failure
within 10 seconds. If you cannot, the failure is not yet understood.

---

## Step 5 — Test One Hypothesis: Confirmation Protocol

### Revert–reapply cycle

The only valid confirmation of a root cause is the revert–reapply cycle:

```
1. Apply the candidate fix (change the one thing the hypothesis predicts).
2. Run the minimal reproduction command → failure disappears.
3. Revert the candidate fix (restore the original code).
4. Run the minimal reproduction command → failure returns.
5. Re-apply the candidate fix.
```

If step 4 does not restore the failure, you fixed a symptom — the root cause is still present
somewhere else. Start over at Step 2 with the original hypothesis invalidated.

### One change at a time

Change only the single thing the hypothesis predicts. If you change two things and the failure
disappears, you cannot know which change was effective. Revert both, then test each in isolation.

### When a new failure appears

If your candidate change makes the original failure disappear but a new failure appears:
- You fixed a symptom — the new failure is closer to the root cause.
- Do NOT continue with the new failure as if it were unrelated.
- Return to Step 1 and read the new failure in full.
- Update your hypothesis list.

---

## Step 6 — Root-Cause Statement: Template

The root-cause statement is a single, unambiguous sentence that:
1. Names the defective component (module, function, class, env var, dependency).
2. States the defect (missing guard, wrong type, absent env var, version mismatch).
3. Explains the failure mechanism (how the defect produces the symptom).

### Template

```
The <component> <defect description>, causing <failure mechanism>
when <trigger condition>.
```

### Examples

```
❌ "The test was failing because of a config issue."
   (No component named, no defect described, no mechanism explained.)

✅ "The Settings class initialises LOG_LEVEL to None when the env var is absent,
   causing logging.setLevel(None) to raise TypeError in the test fixture
   that omits LOG_LEVEL from its environment."

✅ "The CI workflow sets PYTHONDONTWRITEBYTECODE=1 but the local environment does not,
   causing importlib to skip the compiled .pyc cache and trigger a module-level
   side effect in src/config.py that the test fixture does not clean up."
```

### Required attachments

Attach to the root-cause statement:
- **Minimal reproduction command** — one line, copy-pasteable.
- **Ruled-out hypotheses** — one line each: `H2: ruled out — env var was set; ValidationError persists.`

The root-cause statement with attachments is the input to `implement`. The `implement` RED phase begins
with the statement as the acceptance criterion for the regression test.
