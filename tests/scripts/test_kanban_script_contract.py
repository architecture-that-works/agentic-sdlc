"""Architecture contract for the orchestrator PowerShell scripts (ADR-013).

The scripts split into roles:

* **Library** — `.github/scripts/kanban/` (the Kanban module) plus generic shared
  helpers (`Claude.ps1`). The module's loader (`Kanban.psm1`) dot-sources these.
  A dot-sourced file MUST NOT declare a top-level ``param()`` block: dot-sourcing
  runs that block in the *caller's* scope, injecting the parameter defaults and
  silently clobbering the caller's variables. That is how ``grill.ps1``'s
  ``param([int]$Issue = 0)`` once zeroed the orchestrator's issue number, running
  the whole pipeline against #0.
* **Tasks** — `.github/scripts/tasks/` thin Taskfile/workflow commands. They own a
  ``param()`` and are invoked (Import-Module), never dot-sourced.

These static checks enforce that separation so the scope-leak class cannot
return. Run parameters flow via the env transport + ``Get-KanbanContext``.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github" / "scripts"
REFINE = ROOT / ".agents" / "skills" / "refine" / "scripts"

# `. "$PSScriptRoot\..\foo.ps1"` — capture the trailing basename being sourced.
_DOT_SOURCE_RE = re.compile(r'^\s*\.\s+"\$PSScriptRoot[^"]*?([A-Za-z0-9_]+\.ps1)"')
# A top-level param() block sits at column 0 (function params are indented).
_TOP_LEVEL_PARAM_RE = re.compile(r"^param\s*\(")


def _script_files() -> list[Path]:
    """All PowerShell source under .github/scripts (incl. the .psm1 loader) plus
    the refine skill scripts."""
    files = list(SCRIPTS.rglob("*.ps1")) + list(SCRIPTS.rglob("*.psm1"))
    files += list(REFINE.glob("*.ps1"))
    return sorted(set(files))


def _has_top_level_param(path: Path) -> bool:
    return any(
        _TOP_LEVEL_PARAM_RE.match(line)
        for line in path.read_text(encoding="utf-8").splitlines()
    )


def _dot_sourced_basenames() -> set[str]:
    names: set[str] = set()
    for f in _script_files():
        for line in f.read_text(encoding="utf-8").splitlines():
            m = _DOT_SOURCE_RE.match(line)
            if m:
                names.add(m.group(1))
    return names


def _resolve(name: str) -> Path | None:
    for base in (SCRIPTS, REFINE):
        for p in base.rglob(name):
            return p
    return None


def test_dot_sourced_libraries_have_no_top_level_param() -> None:
    """The core contract: nothing that is dot-sourced may carry a top-level
    param() block (it would leak into the caller's scope)."""
    sourced = _dot_sourced_basenames()
    assert sourced, "expected the Kanban.psm1 loader to dot-source library files"
    offenders = {}
    for name in sorted(sourced):
        path = _resolve(name)
        assert path is not None, f"dot-sourced file not found: {name}"
        if _has_top_level_param(path):
            offenders[name] = str(path)
    assert not offenders, (
        "dot-sourced libraries must not declare a top-level param() — it leaks "
        f"into the caller's scope (ADR-013):\n{offenders}"
    )


def test_grill_cli_is_not_dot_sourced() -> None:
    """The grill.ps1 CLI wrapper has a param() block, so it must never be
    dot-sourced — the module dot-sources the _grill.ps1 library instead."""
    assert "grill.ps1" not in _dot_sourced_basenames(), (
        "grill.ps1 (the param()-carrying CLI) must not be dot-sourced; "
        "dot-source _grill.ps1 (the library) instead."
    )


def test_grill_library_exists_and_has_no_param() -> None:
    lib = REFINE / "_grill.ps1"
    assert lib.exists(), f"missing grill library: {lib}"
    assert not _has_top_level_param(lib), (
        "_grill.ps1 must not declare a top-level param()"
    )


def test_task_scripts_are_not_dot_sourced() -> None:
    """Task entry points own a param() and are invoked, never dot-sourced."""
    sourced = _dot_sourced_basenames()
    for entry in (
        "start.ps1",
        "runner.ps1",
        "retry.ps1",
        "setup.ps1",
        "sync-issues.ps1",
    ):
        assert entry not in sourced, (
            f"{entry} is a task entry point and must not be dot-sourced"
        )
