# CONTEXT.md — {{ project_name }}

{{ description }}

---

## Glossary

| Term | Definition | Disambiguation |
|------|------------|----------------|
| | | |

## Bounded Contexts

| Context | Owns | Does Not Own |
|---------|------|--------------|
| | | |

## Architectural Constraints

Invariants that must not be violated in any implementation.

- **UV only** — `uv add`, `uv sync`, `uv run`. Never `pip install`.
- **No hardcoded secrets** — all config via `.env` + `src/config.py`.
- **Test parity** — every `src/**/*.py` has a matching test file in `tests/`.
- **Lint gate** — `ruff check` + `ruff format --check` must pass before any commit.
- **`src/utils/` is generic** — no project-specific logic in `m_*.py` modules.
- **Standard library first** — prefer stdlib over third-party packages.

## Out of Scope

Concepts explicitly deferred or rejected. Prevents re-proposal in planning sessions.

| Concept | Reason deferred | Date |
|---------|-----------------|------|
| | | |
