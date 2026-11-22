"""Tests for Write-CodeOwners — setup.ps1's code-owners step (#393).

Each test imports the real orchestrator module and calls Write-CodeOwners against a
temp directory, with a stand-in for `gh`: a global PowerShell function of that name
that answers `gh api user` with a canned login. The expected paths are read from
GovernancePaths in lib/Config.ps1, the one list the file is written from.
"""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
_ROOT = Path(__file__).resolve().parents[2]
_MODULE = _ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
_CONFIG = _ROOT / ".github" / "orchestrator" / "lib" / "Config.ps1"
_SETUP = _ROOT / ".github" / "tasks" / "setup.ps1"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)


def _governance_paths() -> list[str]:
    text = _CONFIG.read_text(encoding="utf-8")
    match = re.search(r"^\s*GovernancePaths\s*=\s*@\(([^)]*)\)", text, re.MULTILINE)
    assert match, "no GovernancePaths list in lib/Config.ps1"
    return re.findall(r"'([^']+)'", match.group(1))


def _write_codeowners(root: Path, login: str) -> subprocess.CompletedProcess[str]:
    script = f"""
$ErrorActionPreference = 'Stop'
# Pin what Config.ps1 resolves on import, so loading the module never falls back
# to `gh repo view` (the temp dir has no git remote, and CI sets no default branch).
$env:GITHUB_REPOSITORY = 'octocat/sandbox'
$env:GITHUB_DEFAULT_BRANCH = 'main'
function global:gh {{
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -like 'api user*') {{ return '{login}' }}
    throw "unexpected gh call: $args"
}}
Import-Module '{_MODULE}' -Force
$null = Write-CodeOwners -Root '{root}'
"""
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
        cwd=root,
    )


def test_writes_one_line_per_governance_path_owned_by_the_login(
    tmp_path: Path,
) -> None:
    result = _write_codeowners(tmp_path, "stand-in-user")
    assert result.returncode == 0, result.stdout + result.stderr

    codeowners = tmp_path / ".github" / "CODEOWNERS"
    assert codeowners.exists(), result.stdout + result.stderr
    lines = codeowners.read_text(encoding="utf-8").splitlines()
    rules = [ln for ln in lines if ln.strip() and not ln.startswith("#")]

    expected = [p[:-1] if p.endswith("/*") else p for p in _governance_paths()]
    assert [r.split()[0] for r in rules] == expected
    assert all(r.split()[1:] == ["@stand-in-user"] for r in rules), rules
    assert ".github/workflows/" in expected and ".github/workflows/*" not in [
        r.split()[0] for r in rules
    ]


def test_an_existing_file_is_left_as_it_is(tmp_path: Path) -> None:
    codeowners = tmp_path / ".github" / "CODEOWNERS"
    codeowners.parent.mkdir(parents=True)
    original = b"* @someone-else\r\n# kept\n"
    codeowners.write_bytes(original)

    result = _write_codeowners(tmp_path, "stand-in-user")
    assert result.returncode == 0, result.stdout + result.stderr
    assert codeowners.read_bytes() == original


def test_a_second_run_leaves_the_written_file_as_it_is(tmp_path: Path) -> None:
    assert _write_codeowners(tmp_path, "stand-in-user").returncode == 0
    codeowners = tmp_path / ".github" / "CODEOWNERS"
    first = codeowners.read_bytes()

    result = _write_codeowners(tmp_path, "another-user")
    assert result.returncode == 0, result.stdout + result.stderr
    assert codeowners.read_bytes() == first


def test_nothing_is_written_without_a_login(tmp_path: Path) -> None:
    result = _write_codeowners(tmp_path, "")
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (tmp_path / ".github" / "CODEOWNERS").exists()


def test_setup_calls_the_code_owners_step() -> None:
    text = _SETUP.read_text(encoding="utf-8")
    assert "Write-CodeOwners -Root $_Root" in text
