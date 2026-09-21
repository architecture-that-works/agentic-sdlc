# Diagnosis — Examples

Worked end-to-end diagnoses using the `diagnosis` skill. See [SKILL.md](SKILL.md) for the
overview and Core Pattern. See [REFERENCE.md](REFERENCE.md) for mechanism-level detail on
each of the six steps.

---

## Example 1: Test Failure — TypeError in Fixture from Missing Env Var

**Context:** The CI run fails on `tests/test_config.py`. The test was passing yesterday;
no code was changed in `src/config.py`. The most recent commit added a new test file for
a different module.

### Step 1 — Read the Error in Full

```bash
uv run pytest tests/test_config.py 2>&1 | tee /tmp/test-failure.txt
```

Full output:

```
FAILED tests/test_config.py::test_settings_log_level_default - TypeError: setLevel: level
must be an integer or a string

======= short test summary info =======
FAILED tests/test_config.py::test_settings_log_level_default
1 failed in 0.43s
```

Full traceback (from the captured file):

```
tests/test_config.py::test_settings_log_level_default
  src/config.py:31: in __init__
    logging.getLogger().setLevel(self.LOG_LEVEL)
E TypeError: setLevel: level must be an integer or a string
```

Reading protocol applied:
- **Error type and message:** `TypeError: setLevel: level must be an integer or a string`
- **Origin frame:** `src/config.py:31` — `logging.getLogger().setLevel(self.LOG_LEVEL)`
- **Call chain:** Test fixture calls `Settings()`, which calls `setLevel(self.LOG_LEVEL)`
- **Secondary clue:** No secondary errors; the failure is clean

Identify the origin frame:

```bash
grep -n 'src/' /tmp/test-failure.txt
# src/config.py:31: in __init__
```

`src/config.py:31` is the origin. `self.LOG_LEVEL` is `None` when `setLevel` is called.

### Step 2 — Symptom vs. Root Cause

```
Symptom  : TypeError in logging.setLevel at src/config.py:31 — LOG_LEVEL is None
Hypothesis: Settings.LOG_LEVEL is not declared Optional, but the test fixture
            does not set the LOG_LEVEL env var, so pydantic-settings defaults it to None.
```

These are different: the symptom is `TypeError`; the root cause is about how `LOG_LEVEL`
is declared and what the fixture provides.

### Step 3 — Generate and Rank Hypotheses

```
H1: [most likely] Test fixture does not set LOG_LEVEL — Settings.LOG_LEVEL defaults to None
    when the env var is absent and the field has no default value defined.
H2: Recent commit to tests/conftest.py removed LOG_LEVEL from the shared fixture env dict.
H3: pydantic-settings version bump changed how missing Optional fields are handled.
H4: Settings.__init__ was refactored and the setLevel call was added without a None guard.
H5: [least likely] LOG_LEVEL env var is set globally on the developer machine but not in CI.
```

Last-commit delta check:

```bash
git log -1 --stat
# tests/conftest.py | 3 +--
```

H2 is elevated — the last commit touched `tests/conftest.py`.

```bash
git diff HEAD~1 -- tests/conftest.py
```

Output shows `LOG_LEVEL` was removed from the `monkeypatch.setenv` block in the shared fixture
when the fixture was refactored to be "minimal". This confirms H2.

### Step 4 — Minimal Reproduction

```bash
# Full suite (already failing)
uv run pytest tests/test_config.py::test_settings_log_level_default
# FAILED in 0.43s
```

Try reproducing without the fixture:

```bash
uv run python -c "import os; os.environ.pop('LOG_LEVEL', None); from src.config import Settings; Settings()"
# TypeError: setLevel: level must be an integer or a string
```

One command, reproducible in under 2 seconds. Minimal reproduction confirmed.

### Step 5 — Test One Hypothesis (H2)

Candidate fix: restore `LOG_LEVEL` in the shared fixture.

```python
# tests/conftest.py  — add back LOG_LEVEL
@pytest.fixture(autouse=True)
def base_env(monkeypatch):
    monkeypatch.setenv("LOG_LEVEL", "INFO")
```

```bash
uv run pytest tests/test_config.py::test_settings_log_level_default
# PASSED
```

Revert to confirm:

```python
# Remove LOG_LEVEL from the fixture again
```

```bash
uv run pytest tests/test_config.py::test_settings_log_level_default
# FAILED — TypeError returns
```

Re-apply the fix — failure disappears. Root cause confirmed.

### Step 6 — Root-Cause Statement

```
The shared test fixture in tests/conftest.py was refactored in the last commit to remove
LOG_LEVEL from the monkeypatch.setenv block, causing Settings() to receive LOG_LEVEL=None
from pydantic-settings, which passes None to logging.setLevel() and raises TypeError.
```

**Minimal reproduction:**

```bash
uv run pytest tests/test_config.py::test_settings_log_level_default
```

**Ruled-out hypotheses:**
- H1: Partially correct — None is the mechanism, but the cause is the missing fixture env, not a missing default value.
- H3: Ruled out — no pydantic-settings version change in the last commit.
- H4: Ruled out — `src/config.py` was not modified.
- H5: Ruled out — failure reproduces both locally and in CI when LOG_LEVEL is absent.

**Handoff to `implement`:** Write a regression test that sets `LOG_LEVEL` explicitly and verifies
that `Settings()` does not raise, then fix `tests/conftest.py` to restore the env var.

---

## Example 2: CI/Workflow Failure — Environment Variable Divergence

**Context:** The CI run on `feature/88-module-map-gate` fails at the `check-module-map`
step. The same command passes locally. No changes were made to the module map check script.

### Step 1 — Read the Error in Full

Retrieve the CI failure log from GitHub Actions:

```bash
gh run view --log-failed 2>&1 | tee /tmp/ci-failure.txt
```

Relevant excerpt:

```
Run pwsh .github/scripts/ci/check-module-map.ps1
FAIL: Module Map is missing a row for src/payments/
Expected row: | payments | src/payments/ | ...
  at .github/scripts/ci/check-module-map.ps1:47
```

Reading protocol applied:
- **Error type:** Script exits non-zero with `FAIL:` message
- **Origin frame:** `.github/scripts/ci/check-module-map.ps1:47`
- **Mechanism:** The script expects `CONTEXT.md` to contain a row for `src/payments/`
- **Secondary clue:** None visible in the truncated log

```bash
grep -n 'FAIL\|ERROR\|src/' /tmp/ci-failure.txt | head -10
```

### Step 2 — Symptom vs. Root Cause

```
Symptom  : check-module-map.ps1 exits 1 — "Module Map is missing a row for src/payments/"
Hypothesis: CONTEXT.md was not updated when src/payments/ was added in this branch,
            but local testing did not run check-module-map.ps1.
```

### Step 3 — Generate and Rank Hypotheses

```
H1: [most likely] src/payments/ was added in this branch but CONTEXT.md Module Map
    was not updated — the check-module-map.ps1 gate detects the missing row.
H2: The check-module-map.ps1 script itself changed and its detection logic is broken.
H3: CI is checking a different branch than expected — git checkout mismatch.
H4: CONTEXT.md was updated but the update was not committed.
H5: [least likely] The Module Map row exists but uses a different key name.
```

Last-commit delta:

```bash
git log --oneline feature/88-module-map-gate..HEAD
git diff origin/main...HEAD -- CONTEXT.md src/
```

Output shows: `src/payments/__init__.py` was added three commits ago; `CONTEXT.md` has no
change. H1 is confirmed before the reproduction step.

### Step 4 — Minimal Reproduction

Replicate the CI command locally:

```bash
# From the project root
pwsh .github/scripts/ci/check-module-map.ps1
# FAIL: Module Map is missing a row for src/payments/
```

Reproduced locally in under 3 seconds. The divergence was not between CI and local
environments — it was that the developer did not run the check locally before pushing.

### Step 5 — Test One Hypothesis (H1)

Candidate fix: add the Module Map row to `CONTEXT.md`.

```markdown
<!-- CONTEXT.md — Module Map table -->
| payments | `src/payments/` | `src/payments/` | `PaymentsHandler`, `PaymentsClient` |
```

```bash
pwsh .github/scripts/ci/check-module-map.ps1
# All module map checks passed.
```

Revert:

```bash
git stash
pwsh .github/scripts/ci/check-module-map.ps1
# FAIL: Module Map is missing a row for src/payments/
```

Re-apply:

```bash
git stash pop
pwsh .github/scripts/ci/check-module-map.ps1
# All module map checks passed.
```

Root cause confirmed.

### Step 6 — Root-Cause Statement

```
The src/payments/ directory was added in this branch without a corresponding Module Map
row in CONTEXT.md, causing check-module-map.ps1 to exit non-zero in CI. The failure
did not surface locally because the script was not run before the push.
```

**Minimal reproduction:**

```bash
pwsh .github/scripts/ci/check-module-map.ps1
```

**Ruled-out hypotheses:**
- H2: Ruled out — script was not modified in this branch.
- H3: Ruled out — `gh run view` confirmed the correct branch was checked out.
- H4: Ruled out — `git status` showed CONTEXT.md as clean (no staged or unstaged changes).
- H5: Ruled out — `grep 'payments' CONTEXT.md` returns no results.

**Handoff to `implement`:** This is a documentation change, not a code defect. The acceptance
criterion is: `check-module-map.ps1` exits 0 on `feature/88-module-map-gate` after adding
the `payments` row to CONTEXT.md. No RED/GREEN cycle needed — add the row, verify the script
passes, and commit.
