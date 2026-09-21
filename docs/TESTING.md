# Testing Guide

Conventions for writing and running the pytest suite in this repository.

## Running the Suite

```bash
# Quick pass — same command CI uses:
uv run pytest

# With coverage (required before committing):
uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80

# Stop on first failure:
uv run pytest -x

# Run a single file:
uv run pytest tests/test_main.py
```

Coverage floor is 80% (`--cov-fail-under=80`). The CI gate fails below this threshold.

## File-Mirroring Rule (Test Parity)

`tests/` mirrors the structure of `src/` and `tools/` exactly. Every source module must have a corresponding test file.

```
src/main.py               → tests/test_main.py
src/config.py             → tests/test_config.py   (if config logic exists)
src/utils/m_log.py        → tests/utils/test_m_log.py
src/utils/m_error_formatter.py → tests/utils/test_m_error_formatter.py
src/tools/commit.py       → tests/tools/test_commit.py
src/tools/codebase_map.py → tests/tools/test_codebase_map.py
src/tools/setup.py        → tests/tools/test_setup.py
```

**Rule 3 of AGENTS.md** enforces this: a PR that adds a new `src/**/*.py` or `tools/*.py` without a matching test file will be rejected.

## conftest.py — Shared Fixtures

`tests/conftest.py` defines fixtures available to every test in the suite. Add project-wide fixtures here; keep module-local fixtures in the test file itself.

**`reset_logging` (autouse=True)**
Clears logging state between every test — prevents handler accumulation when tests run in the same process. This fixture runs unconditionally; never disable it.

**`mock_settings` (on demand)**
Overrides pydantic-settings values via `monkeypatch` to prevent tests from reading `.env` from disk:

```python
def test_something(mock_settings):
    # settings.log_profile == "TEST"
    # settings.google_api_key == "test-key"
    ...
```

Use `mock_settings` in any test that exercises code paths gated on `Settings` fields. Do not load real `.env` values in tests — that breaks CI on clean runners.

## Fixture Patterns

**`monkeypatch` for env vars and module state**
`monkeypatch` is the standard way to swap config values, environment variables, and module-level singletons for a single test:

```python
def test_with_custom_env(monkeypatch):
    monkeypatch.setenv("LOG_PROFILE", "DEBUG")
    monkeypatch.setattr("src.config.settings.log_profile", "DEBUG")
    ...
```

Prefer `monkeypatch` over `unittest.mock.patch` for settings overrides — the attribute is restored automatically after the test.

**Mocking at system boundaries only**
Per the `implement` skill: mock only at system boundaries — external APIs, databases, `datetime.now`, and filesystem I/O. Never mock internal collaborators. Tests that mock collaborators pass without proving behaviour.

```python
# ✅ Mock at the HTTP boundary
def test_handler_returns_200(monkeypatch):
    # patch the external call, test through the real handler
    ...


# ❌ Mock an internal collaborator
def test_handler(monkeypatch):
    monkeypatch.setattr("src.main.SomeInternalHelper", FakeHelper)
    ...
```

**`tmp_path` for filesystem tests**
Use pytest's built-in `tmp_path` fixture for tests that write or read files. Never write to the repository root or a hardcoded `/tmp` path — it races when tests run in parallel.

## Test Naming and Structure

- Test files: `test_<module>.py`
- Test functions: `test_<behaviour>` — describe what the test asserts, not what it calls
- Group related tests in a class only when shared setup (e.g. a `setup_method`) justifies it; otherwise use plain functions

```python
# ✅ Describes behaviour
def test_order_total_includes_tax(): ...


# ❌ Describes a call
def test_order_total(): ...
```

## Parametrize for Data-Driven Tests

Use `@pytest.mark.parametrize` when the same assertion applies across multiple inputs:

```python
@pytest.mark.parametrize(
    "profile,level",
    [
        ("DEBUG", logging.DEBUG),
        ("INFO", logging.INFO),
        ("TEST", logging.WARNING),
    ],
)
def test_log_level_from_profile(profile, level, monkeypatch):
    monkeypatch.setattr("src.config.settings.log_profile", profile)
    ...
```

Avoid copy-pasting similar test functions — parametrize instead.

## What Tests Live Where

| Path | What goes here |
|------|----------------|
| `tests/test_main.py` | HTTP handler and entry point behaviour |
| `tests/utils/test_m_*.py` | Generic utility module tests |
| `tests/tools/test_*.py` | Developer tool tests (`commit`, `codebase_map`, `setup`) |
| `tests/orchestrator/` | Orchestrator module tests — mirrors `.github/orchestrator/` |
| `tests/checks/` | Validator tests — mirrors `.github/checks/` |
| tests/test_copier_template.py | Template generation and structure tests — template-only; copier excludes it from generated projects |
| `tests/conftest.py` | Project-wide fixtures only |
