"""Architecture contract for the kanban PowerShell scripts (ADR-013).

The scripts split cleanly into two roles:

* **Libraries** — dot-sourced (``. "$PSScriptRoot\\x.ps1"``) for their functions.
  They MUST NOT declare a top-level ``param()`` block: dot-sourcing runs that
  block in the *caller's* scope, injecting the parameter defaults and silently
  clobbering the caller's variables. That is exactly how ``grill.ps1``'s
  ``param([int]$Issue = 0)`` once zeroed ``run.ps1``'s issue number, running the
  whole pipeline against #0.
* **Entry points** — own a ``param()`` and are invoked with ``&`` / ``pwsh``,
  never dot-sourced.

These static checks enforce that separation so the scope-leak class cannot
return. Run parameters flow via the env transport + ``Get-KanbanContext``
instead of script-scope variables.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = [
    ROOT / ".github" / "scripts" / "kanban",
    ROOT / ".agents" / "skills" / "refine" / "scripts",
]

# `. "$PSScriptRoot\..\foo.ps1"` — capture the trailing basename being sourced.
_DOT_SOURCE_RE = re.compile(r'^\s*\.\s+"\$PSScriptRoot[^"]*?([A-Za-z0-9_]+\.ps1)"')
# A top-level param() block sits at column 0 (function params are indented).
_TOP_LEVEL_PARAM_RE = re.compile(r"^param\s*\(")


def _ps1_files() -> list[Path]:
    files: list[Path] = []
    for d in SCAN_DIRS:
        files.extend(sorted(d.glob("*.ps1")))
    return files


def _has_top_level_param(path: Path) -> bool:
    return any(
        _TOP_LEVEL_PARAM_RE.match(line)
        for line in path.read_text(encoding="utf-8").splitlines()
    )


def _dot_sourced_basenames() -> set[str]:
    names: set[str] = set()
    for f in _ps1_files():
        for line in f.read_text(encoding="utf-8").splitlines():
            m = _DOT_SOURCE_RE.match(line)
            if m:
                names.add(m.group(1))
    return names


def _resolve(name: str) -> Path | None:
    for d in SCAN_DIRS:
        p = d / name
        if p.exists():
            return p
    return None


def test_dot_sourced_libraries_have_no_top_level_param() -> None:
    """The core contract: nothing that is dot-sourced may carry a top-level
    param() block (it would leak into the caller's scope)."""
    offenders = {}
    for name in sorted(_dot_sourced_basenames()):
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
    dot-sourced — implement.ps1 dot-sources the _grill.ps1 library instead."""
    assert "grill.ps1" not in _dot_sourced_basenames(), (
        "grill.ps1 (the param()-carrying CLI) must not be dot-sourced; "
        "dot-source _grill.ps1 (the library) instead."
    )


def test_grill_library_exists_and_has_no_param() -> None:
    lib = ROOT / ".agents" / "skills" / "refine" / "scripts" / "_grill.ps1"
    assert lib.exists(), f"missing grill library: {lib}"
    assert not _has_top_level_param(lib), (
        "_grill.ps1 must not declare a top-level param()"
    )


def test_entry_points_are_not_dot_sourced() -> None:
    """Entry points own a param() and are invoked, never dot-sourced."""
    sourced = _dot_sourced_basenames()
    for entry in ("run.ps1", "start.ps1", "retry.ps1", "runner.ps1"):
        assert entry not in sourced, (
            f"{entry} is an entry point and must not be dot-sourced"
        )
