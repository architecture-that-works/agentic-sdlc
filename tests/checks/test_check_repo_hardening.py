"""Tests for .github/checks/check-repo-hardening.ps1."""

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).parent.parent.parent
    / ".github"
    / "checks"
    / "check-repo-hardening.ps1"
)
PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

NWO = "test-owner/test-repo"


def _init_git_repo(path: Path) -> None:
    subprocess.run(["git", "init", str(path)], check=True, capture_output=True)


def _write_stub_gh(
    stub_dir: Path,
    *,
    private: bool,
    approval_policy: str,
    runner_profile: str,
    runner_count: int,
) -> None:
    repo_json = '{"private":' + ("true" if private else "false") + "}"
    fork_json = '{"approval_policy":"' + approval_policy + '"}'
    var_json = '{"value":"' + runner_profile + '"}'
    runners_json = '{"total_count":' + str(runner_count) + "}"

    script_lines = [
        "#!/bin/bash",
        'ARGS="$*"',
        f'if [[ "$ARGS" == *"fork-pr-contributor-approval"* ]]; then echo \'{fork_json}\'',
        f'elif [[ "$ARGS" == *"KANBAN_RUNNER_PROFILE"* ]]; then echo \'{var_json}\'',
        f'elif [[ "$ARGS" == *"actions/runners"* ]]; then echo \'{runners_json}\'',
        f"else echo '{repo_json}'",
        "fi",
    ]
    gh_stub = stub_dir / "gh"
    gh_stub.write_text("\n".join(script_lines) + "\n", encoding="utf-8")
    gh_stub.chmod(gh_stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _run(
    tmp_path: Path, stub_dir: Path | None = None
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["GITHUB_REPOSITORY"] = NWO
    if stub_dir is not None:
        env["PATH"] = str(stub_dir) + os.pathsep + env.get("PATH", "")
    return subprocess.run(
        [PWSH, "-NoProfile", "-File", str(SCRIPT)],
        cwd=str(tmp_path),
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


# ── Tests ──────────────────────────────────────────────────────────────────────


def test_passes_outside_template_repo(tmp_path: Path) -> None:
    """Script exits 0 silently when .template/ is absent (no-op in generated projects)."""
    _init_git_repo(tmp_path)
    result = _run(tmp_path)
    assert result.returncode == 0, result.stderr


def test_all_assertions_pass(tmp_path: Path) -> None:
    """Script exits 0 when all four REST assertions pass."""
    _init_git_repo(tmp_path)
    (tmp_path / ".template").mkdir()
    stub_dir = tmp_path / "_stub"
    stub_dir.mkdir()
    _write_stub_gh(
        stub_dir,
        private=False,
        approval_policy="all_external_contributors",
        runner_profile="hosted",
        runner_count=0,
    )
    result = _run(tmp_path, stub_dir)
    assert result.returncode == 0, result.stdout + result.stderr


def test_fails_repo_private(tmp_path: Path) -> None:
    """Script exits 1 and names Step 1 when the repository is private."""
    _init_git_repo(tmp_path)
    (tmp_path / ".template").mkdir()
    stub_dir = tmp_path / "_stub"
    stub_dir.mkdir()
    _write_stub_gh(
        stub_dir,
        private=True,
        approval_policy="all_external_contributors",
        runner_profile="hosted",
        runner_count=0,
    )
    result = _run(tmp_path, stub_dir)
    assert result.returncode == 1
    assert "Step 1" in result.stdout


def test_fails_fork_pr_approval(tmp_path: Path) -> None:
    """Script exits 1 and names Step 2 when the fork-PR approval policy is wrong."""
    _init_git_repo(tmp_path)
    (tmp_path / ".template").mkdir()
    stub_dir = tmp_path / "_stub"
    stub_dir.mkdir()
    _write_stub_gh(
        stub_dir,
        private=False,
        approval_policy="none",
        runner_profile="hosted",
        runner_count=0,
    )
    result = _run(tmp_path, stub_dir)
    assert result.returncode == 1
    assert "Step 2" in result.stdout


def test_fails_self_hosted_runner(tmp_path: Path) -> None:
    """Script exits 1 and names Step 3 when KANBAN_RUNNER_PROFILE is self-hosted."""
    _init_git_repo(tmp_path)
    (tmp_path / ".template").mkdir()
    stub_dir = tmp_path / "_stub"
    stub_dir.mkdir()
    _write_stub_gh(
        stub_dir,
        private=False,
        approval_policy="all_external_contributors",
        runner_profile="self-hosted",
        runner_count=0,
    )
    result = _run(tmp_path, stub_dir)
    assert result.returncode == 1
    assert "Step 3" in result.stdout


def test_fails_runner_registered(tmp_path: Path) -> None:
    """Script exits 1 and names Step 3 when a self-hosted runner is registered."""
    _init_git_repo(tmp_path)
    (tmp_path / ".template").mkdir()
    stub_dir = tmp_path / "_stub"
    stub_dir.mkdir()
    _write_stub_gh(
        stub_dir,
        private=False,
        approval_policy="all_external_contributors",
        runner_profile="hosted",
        runner_count=1,
    )
    result = _run(tmp_path, stub_dir)
    assert result.returncode == 1
    assert "Step 3" in result.stdout
