"""Tests for .github/checks/check-doc-functions.ps1.

The guard asserts that every backtick-quoted Verb-Noun function name in
load-bearing documents resolves to a function defined in .github/orchestrator/.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / ".github" / "checks" / "check-doc-functions.ps1"
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


def _scaffold(root: Path) -> None:
    """Minimal fixture tree: check script, one orchestrator function, and checked docs."""
    (root / ".github" / "checks").mkdir(parents=True)
    (root / ".github" / "orchestrator" / "lib").mkdir(parents=True)
    (root / ".agents" / "skills" / "demo").mkdir(parents=True)
    (root / ".template" / "adr").mkdir(parents=True)
    (root / "tests").mkdir()

    shutil.copy(SCRIPT, root / ".github" / "checks" / SCRIPT.name)
    # One real function in the orchestrator library.
    (root / ".github" / "orchestrator" / "lib" / "Fake.ps1").write_text(
        "function Get-FakeContext { }\n", encoding="utf-8"
    )
    (root / "AGENTS.md").write_text("# Agents\n", encoding="utf-8")
    (root / "tests" / "README.md").write_text("# Tests\n", encoding="utf-8")
    (root / ".agents" / "skills" / "demo" / "SKILL.md").write_text(
        "# Demo\n", encoding="utf-8"
    )
    (root / ".template" / "adr" / "README.md").write_text(
        "# ADR Index\n", encoding="utf-8"
    )


def test_resolving_name_passes(tmp_path: Path) -> None:
    """A backtick-quoted function name that exists in the orchestrator passes."""
    _scaffold(tmp_path)
    (tmp_path / ".template" / "adr" / "README.md").write_text(
        "Uses `Get-FakeContext` to hydrate the run context.\n", encoding="utf-8"
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr


def test_nonexistent_name_fails(tmp_path: Path) -> None:
    """A backtick-quoted function name that does not exist in the orchestrator fails."""
    _scaffold(tmp_path)
    (tmp_path / ".template" / "adr" / "README.md").write_text(
        "Uses `Get-BogusFunction` to hydrate the run context.\n", encoding="utf-8"
    )
    result = _run(tmp_path)
    assert result.returncode == 1
    assert "Get-BogusFunction" in result.stdout


def test_non_verb_noun_token_is_ignored(tmp_path: Path) -> None:
    """Tokens that do not match the Verb-Noun shape are silently skipped."""
    _scaffold(tmp_path)
    # Spans with spaces, parameter flags, and lowercase tokens all fail the shape filter.
    (tmp_path / ".template" / "adr" / "README.md").write_text(
        "Conducted via `Invoke-Orchestration -From refine`; media type `text/event-stream`.\n",
        encoding="utf-8",
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout


def test_examples_md_is_not_scanned(tmp_path: Path) -> None:
    """Worked examples may cite fictional function names; they must not be validated."""
    _scaffold(tmp_path)
    (tmp_path / ".agents" / "skills" / "demo" / "EXAMPLES.md").write_text(
        "The agent calls `Invoke-FictionalStage` in this walkthrough.\n",
        encoding="utf-8",
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout


def test_guards_the_real_repository() -> None:
    """The repository's own load-bearing documents must cite only live function names."""
    result = _run(REPO_ROOT)
    assert result.returncode == 0, (
        "Stale function names in documents every agent session loads:\n" + result.stdout
    )
