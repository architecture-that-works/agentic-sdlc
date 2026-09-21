"""Tests for .github/checks/check-doc-paths.ps1.

The guard asserts that every repo-relative path cited in a load-bearing document
resolves on disk. These tests pin the two properties that make it useful rather
than noisy: it catches a stale path, and it does not fire on prose or on the
template placeholders these documents legitimately contain.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / ".github" / "checks" / "check-doc-paths.ps1"
PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(root: Path) -> subprocess.CompletedProcess[str]:
    """Invoke the copy inside ``root`` — the script derives the repo root from its
    own location, so running the real one against a fixture would scan this repo."""
    return subprocess.run(
        [PWSH, "-NoProfile", "-File", str(root / ".github" / "checks" / SCRIPT.name)],
        cwd=str(root),
        capture_output=True,
        text=True,
        check=False,
    )


def _scaffold(root: Path, agents_md: str) -> None:
    """Minimal tree the guard walks: AGENTS.md, CONTEXT.md, the ADR index, a skill."""
    (root / ".github" / "checks").mkdir(parents=True)
    (root / "docs" / "adr").mkdir(parents=True)
    (root / ".agents" / "skills" / "demo").mkdir(parents=True)
    (root / "src").mkdir()

    shutil.copy(SCRIPT, root / ".github" / "checks" / SCRIPT.name)
    (root / "AGENTS.md").write_text(agents_md, encoding="utf-8")
    (root / "CONTEXT.md").write_text("# CONTEXT\n", encoding="utf-8")
    (root / "docs" / "adr" / "ADR_STRUCTURE.md").write_text(
        "# ADRs\n", encoding="utf-8"
    )
    (root / ".agents" / "skills" / "demo" / "SKILL.md").write_text(
        "# Demo\n", encoding="utf-8"
    )


def test_passes_when_every_cited_path_exists(tmp_path: Path) -> None:
    _scaffold(tmp_path, "See `src/` and [the index](docs/adr/ADR_STRUCTURE.md).\n")
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr


def test_fails_on_a_stale_backticked_path(tmp_path: Path) -> None:
    _scaffold(tmp_path, "The library lives in `.github/scripts/kanban/`.\n")
    result = _run(tmp_path)
    assert result.returncode == 1
    assert ".github/scripts/kanban/" in result.stdout


def test_fails_on_a_stale_markdown_link_target(tmp_path: Path) -> None:
    _scaffold(tmp_path, "[reference](.agents/skills/gone/REFERENCE.md)\n")
    result = _run(tmp_path)
    assert result.returncode == 1
    assert ".agents/skills/gone/REFERENCE.md" in result.stdout


@pytest.mark.parametrize(
    "citation",
    [
        "`Planner/Generator/Evaluator`",  # prose containing slashes
        "`text/event-stream`",  # a media type, not a path
        "`CI/CD`",
        "`src/<domain>/`",  # angle-bracket placeholder
        "`src/utils/m_*.py`",  # glob placeholder
        "`docs/adr/ADR-NNN-kebab-title.md`",  # naming template
        "`https://example.com/docs/thing.md`",  # URL
    ],
)
def test_does_not_fire_on_non_paths(tmp_path: Path, citation: str) -> None:
    """A noisy guard gets disabled, so the shape rule must reject these outright."""
    _scaffold(tmp_path, f"Prose mentioning {citation} inline.\n")
    result = _run(tmp_path)
    assert result.returncode == 0, (
        f"{citation} must not be treated as a repo path\n{result.stdout}"
    )


def test_examples_md_is_not_scanned(tmp_path: Path) -> None:
    """Worked examples describe a fictional feature; their paths are illustrative."""
    _scaffold(tmp_path, "# Agents\n")
    (tmp_path / ".agents" / "skills" / "demo" / "EXAMPLES.md").write_text(
        "The agent creates `src/payments/__init__.py` in this walkthrough.\n",
        encoding="utf-8",
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout


def test_guards_the_real_repository() -> None:
    """The repository's own load-bearing documents must cite only live paths."""
    result = _run(REPO_ROOT)
    assert result.returncode == 0, (
        "Stale paths in documents every agent session loads:\n" + result.stdout
    )
