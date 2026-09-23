"""Tests for the WritablePaths allowlist gate in Invoke-CommitAndPR.

The allowlist is the primary staging layer: only changed paths that match one
of the WritablePaths patterns in $OrchestratorConfig may be staged. Any path
outside the allowlist aborts staging with the offending paths named.

Each test runs an inline PowerShell snippet that replicates the allowlist logic
from Implement.ps1's Invoke-CommitAndPR, avoiding a live Kanban environment
while still testing the real business rule.
"""

import shutil
import subprocess

import pytest

PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

# Mirrors the WritablePaths from $OrchestratorConfig in lib/Config.ps1 and the
# -like matching logic applied in Invoke-CommitAndPR.
_ALLOWLIST_SNIPPET = """\
function Test-AllowlistPath {
    param([string]$Path)
    $writablePaths = @(
        'src/*', 'tests/*', 'docs/*', '.agents/skills/*',
        'CONTEXT.md', '.out-of-scope.md', 'SECURITY.md',
        'pyproject.toml', 'uv.lock'
    )
    return [bool]($writablePaths | Where-Object { $Path -like $_ })
}
"""


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )


# ── In-bounds paths ────────────────────────────────────────────────────────────


def test_src_file_is_allowed() -> None:
    result = _ps(
        _ALLOWLIST_SNIPPET
        + "if (Test-AllowlistPath 'src/foo.py') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "src/foo.py must be allowed by WritablePaths"


def test_tests_file_is_allowed() -> None:
    result = _ps(
        _ALLOWLIST_SNIPPET
        + "if (Test-AllowlistPath 'tests/orchestrator/test_foo.py') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, (
        "tests/orchestrator/test_foo.py must be allowed by WritablePaths"
    )


def test_docs_file_is_allowed() -> None:
    result = _ps(
        _ALLOWLIST_SNIPPET
        + "if (Test-AllowlistPath 'docs/adr/ADR-001.md') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, (
        "docs/adr/ADR-001.md must be allowed by WritablePaths"
    )


def test_security_md_is_allowed() -> None:
    result = _ps(
        _ALLOWLIST_SNIPPET
        + "if (Test-AllowlistPath 'SECURITY.md') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "SECURITY.md must be allowed by WritablePaths"


# ── Out-of-bounds paths — hard failure with path name in error ────────────────


def test_github_workflow_is_blocked_with_name_in_error() -> None:
    target = ".github/workflows/x.yml"
    script = (
        _ALLOWLIST_SNIPPET
        + f"""\
$path = '{target}'
if (-not (Test-AllowlistPath $path)) {{
    throw "Agent staging blocked — path outside WritablePaths: $path"
}}
exit 0
"""
    )
    result = _ps(script)
    assert result.returncode != 0, (
        ".github/workflows/x.yml must be blocked by WritablePaths"
    )
    assert target in (result.stderr + result.stdout), (
        f"Error message must name the offending path '{target}'"
    )


def test_github_orchestrator_is_blocked() -> None:
    target = ".github/orchestrator/stages/Implement.ps1"
    script = (
        _ALLOWLIST_SNIPPET
        + f"""\
$path = '{target}'
if (-not (Test-AllowlistPath $path)) {{
    throw "Agent staging blocked — path outside WritablePaths: $path"
}}
exit 0
"""
    )
    result = _ps(script)
    assert result.returncode != 0, (
        ".github/orchestrator/stages/Implement.ps1 must be blocked by WritablePaths"
    )
    assert target in (result.stderr + result.stdout), (
        f"Error message must name the offending path '{target}'"
    )
