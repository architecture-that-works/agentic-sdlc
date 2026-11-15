"""Tests for .github/checks/check-shortcuts.ps1.

The guard asserts that every shortcut comment names its follow-up with the
canonical em-dash form. These two tests pin the core invariant: a bare shortcut
fails CI; the full contract form passes.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / ".github" / "checks" / "check-shortcuts.ps1"
PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _scaffold(root: Path, content: str) -> None:
    """Minimal tree the guard scans: src/ with a fixture file and the script itself."""
    (root / ".github" / "checks").mkdir(parents=True)
    (root / "src").mkdir(parents=True)
    shutil.copy(SCRIPT, root / ".github" / "checks" / SCRIPT.name)
    (root / "src" / "fixture.py").write_text(content, encoding="utf-8")


def _run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-File", str(root / ".github" / "checks" / SCRIPT.name)],
        cwd=str(root),
        capture_output=True,
        text=True,
        check=False,
    )


def test_passes_when_shortcut_has_follow_up(tmp_path: Path) -> None:
    _scaffold(tmp_path, "# shortcut: linear scan — to be fixed in orders-index\n")
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr


def test_fails_when_shortcut_lacks_follow_up(tmp_path: Path) -> None:
    _scaffold(tmp_path, "# shortcut: linear scan\n")
    result = _run(tmp_path)
    assert result.returncode != 0
    assert "shortcut: linear scan" in result.stdout
