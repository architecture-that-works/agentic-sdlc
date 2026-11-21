"""Tests for .github/tasks/protect.ps1.

Each test runs the real script against a stand-in for `gh`: a PowerShell function of
that name, defined before the script runs, which records every argument list and the
stdin it receives and answers with canned JSON. Assertions read what the script sent.
"""

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
_ROOT = Path(__file__).resolve().parents[2]
_SCRIPT = _ROOT / ".github" / "tasks" / "protect.ps1"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

_REQUIRED_CHECKS = ["lint", "typecheck", "test", "audit", "checks", "eval"]
_REPO = "owner/repo"

_STAND_IN = r"""
$ErrorActionPreference = 'Stop'
$global:GhLog = $env:GH_STANDIN_LOG

function gh {
    $argv  = @($args | ForEach-Object { "$_" })
    $stdin = @($input) -join "`n"
    $entry = [ordered]@{ args = $argv; stdin = $stdin } | ConvertTo-Json -Compress -Depth 5
    Add-Content -LiteralPath $global:GhLog -Value $entry

    $joined = $argv -join ' '
    $global:LASTEXITCODE = 0
    if ($joined -like 'repo view*') {
        return (@{ nameWithOwner = 'owner/repo'; visibility = $env:GH_STANDIN_VISIBILITY } |
            ConvertTo-Json -Compress)
    }
    if ($argv -contains 'PATCH') {
        if ($stdin -like '*security_and_analysis*') {
            $global:LASTEXITCODE = [int]$env:GH_STANDIN_PATCH_EXIT
            if ($global:LASTEXITCODE -ne 0) { return 'Secret scanning is not available (HTTP 422)' }
        } else {
            $global:LASTEXITCODE = [int]$env:GH_STANDIN_MERGE_EXIT
            if ($global:LASTEXITCODE -ne 0) { return 'Merge settings refused (HTTP 403)' }
        }
        return '{}'
    }
    if ($argv -contains 'PUT') { return '{}' }
    if ($joined -eq 'api repos/owner/repo/branches/main/protection') {
        return (@{
            required_status_checks        = @{ strict = $true; contexts = @('lint','typecheck','test','audit','checks','eval') }
            required_pull_request_reviews = @{ required_approving_review_count = 0 }
            enforce_admins                = @{ enabled = $true }
        } | ConvertTo-Json -Compress -Depth 5)
    }
    if ($joined -eq 'api repos/owner/repo') {
        $status = if ([int]$env:GH_STANDIN_PATCH_EXIT -eq 0) { 'enabled' } else { 'disabled' }
        return (@{
          allow_squash_merge = $true; allow_merge_commit = $false; allow_rebase_merge = $false
          squash_merge_commit_title = $env:GH_STANDIN_SQUASH_TITLE
          squash_merge_commit_message = 'COMMIT_MESSAGES'
          delete_branch_on_merge = $true; allow_update_branch = $true
          security_and_analysis = @{
            secret_scanning                 = @{ status = $status }
            secret_scanning_push_protection = @{ status = $status }
        } } | ConvertTo-Json -Compress -Depth 5)
    }
    $global:LASTEXITCODE = 1
    return "unexpected gh call: $joined"
}

& $env:GH_STANDIN_SCRIPT
exit $LASTEXITCODE
"""


@dataclass
class Run:
    returncode: int
    output: str
    calls: list[dict[str, Any]]

    def call(self, method: str, containing: str = "") -> dict[str, Any]:
        matches = [
            c for c in self.calls if method in c["args"] and containing in c["stdin"]
        ]
        assert len(matches) == 1, f"expected one {method} call, got {self.calls}"
        return matches[0]

    def body(self, method: str, containing: str = "") -> dict[str, Any]:
        return json.loads(self.call(method, containing)["stdin"])

    def secret_patch(self) -> dict[str, Any]:
        return self.call("PATCH", "security_and_analysis")

    def merge_patch(self) -> dict[str, Any]:
        return self.call("PATCH", "allow_squash_merge")


def _run(
    tmp_path: Path,
    *,
    visibility: str = "PUBLIC",
    patch_exit: int = 0,
    merge_exit: int = 0,
    squash_title: str = "PR_TITLE",
) -> Run:
    wrapper = tmp_path / "run-protect.ps1"
    wrapper.write_text(_STAND_IN, encoding="utf-8")
    log = tmp_path / "gh-calls.jsonl"
    log.touch()
    env = {
        **os.environ,
        "GH_STANDIN_LOG": str(log),
        "GH_STANDIN_SCRIPT": str(_SCRIPT),
        "GH_STANDIN_VISIBILITY": visibility,
        "GH_STANDIN_PATCH_EXIT": str(patch_exit),
        "GH_STANDIN_MERGE_EXIT": str(merge_exit),
        "GH_STANDIN_SQUASH_TITLE": squash_title,
    }
    result = subprocess.run(
        [PWSH, "-NoProfile", "-NonInteractive", "-File", str(wrapper)],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        cwd=tmp_path,
    )
    calls = [
        json.loads(line)
        for line in log.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    return Run(result.returncode, result.stdout + result.stderr, calls)


def _keys(node: Any) -> list[str]:
    if isinstance(node, dict):
        return [k for k, v in node.items() for k in (k, *_keys(v))]
    if isinstance(node, list):
        return [k for item in node for k in _keys(item)]
    return []


def test_public_run_enables_secret_scanning_and_requires_six_checks(
    tmp_path: Path,
) -> None:
    run = _run(tmp_path)
    assert run.returncode == 0, run.output

    patch = run.secret_patch()
    assert f"repos/{_REPO}" in patch["args"]
    assert "--input" in patch["args"]
    assert run.body("PATCH", "security_and_analysis") == {
        "security_and_analysis": {
            "secret_scanning": {"status": "enabled"},
            "secret_scanning_push_protection": {"status": "enabled"},
        }
    }

    assert f"repos/{_REPO}/branches/main/protection" in run.call("PUT")["args"]
    checks = run.body("PUT")["required_status_checks"]
    assert checks["contexts"] == _REQUIRED_CHECKS
    assert checks["strict"] is True


def test_branch_rules_allow_no_bypass_and_bind_admins(tmp_path: Path) -> None:
    # #349: every change, the orchestrator's included, goes through a pull request.
    run = _run(tmp_path)
    assert run.returncode == 0, run.output
    body = run.body("PUT")
    assert not [k for k in _keys(body) if "bypass" in k]
    assert body["enforce_admins"] is True
    reviews = body["required_pull_request_reviews"]
    assert reviews["required_approving_review_count"] == 0
    assert body["allow_force_pushes"] is False
    assert body["allow_deletions"] is False


def test_branch_rules_are_applied_before_secret_scanning(tmp_path: Path) -> None:
    run = _run(tmp_path)
    methods = [c["args"][2] for c in run.calls if c["args"][:2] == ["api", "--method"]]
    assert methods == ["PUT", "PATCH", "PATCH"]
    patches = [c for c in run.calls if "PATCH" in c["args"]]
    assert "allow_squash_merge" in patches[0]["stdin"]
    assert "security_and_analysis" in patches[1]["stdin"]


def test_public_refusal_fails_the_run(tmp_path: Path) -> None:
    run = _run(tmp_path, visibility="PUBLIC", patch_exit=1)
    assert run.returncode != 0, run.output
    assert run.call("PUT")  # main is protected even though the run failed


@pytest.mark.parametrize("visibility", ["PRIVATE", "INTERNAL"])
def test_private_refusal_reports_once_and_applies_branch_rules(
    tmp_path: Path, visibility: str
) -> None:
    run = _run(tmp_path, visibility=visibility, patch_exit=1)
    assert run.returncode == 0, run.output
    assert run.body("PUT")["required_status_checks"]["contexts"] == _REQUIRED_CHECKS
    lines = [ln for ln in run.output.splitlines() if "GitHub Secret Protection" in ln]
    assert len(lines) == 1, run.output
    assert "no secret scanning" in lines[0]


def test_verification_reports_both_features(tmp_path: Path) -> None:
    run = _run(tmp_path)
    assert run.returncode == 0, run.output
    assert ["api", f"repos/{_REPO}"] in [c["args"] for c in run.calls]
    lines = run.output.splitlines()
    assert any("secret_scanning: enabled" in ln for ln in lines), run.output
    assert any("secret_scanning_push_protection: enabled" in ln for ln in lines)


def test_verification_flags_features_left_off(tmp_path: Path) -> None:
    run = _run(tmp_path, visibility="PRIVATE", patch_exit=1)
    assert "secret_scanning: disabled" in run.output
    assert "secret_scanning_push_protection: disabled" in run.output


_MERGE_SETTINGS = {
    "allow_squash_merge": True,
    "allow_merge_commit": False,
    "allow_rebase_merge": False,
    "squash_merge_commit_title": "PR_TITLE",
    "squash_merge_commit_message": "COMMIT_MESSAGES",
    "delete_branch_on_merge": True,
    "allow_update_branch": True,
}


def test_merge_settings_are_sent_in_a_call_of_their_own(tmp_path: Path) -> None:
    run = _run(tmp_path)
    assert run.returncode == 0, run.output
    patch = run.merge_patch()
    assert f"repos/{_REPO}" in patch["args"]
    assert "--input" in patch["args"]
    assert json.loads(patch["stdin"]) == _MERGE_SETTINGS
    assert "security_and_analysis" not in patch["stdin"]
    assert not [k for k in _MERGE_SETTINGS if k in run.secret_patch()["stdin"]]


@pytest.mark.parametrize("visibility", ["PRIVATE", "INTERNAL"])
def test_private_refusal_of_secret_scanning_keeps_merge_settings(
    tmp_path: Path, visibility: str
) -> None:
    run = _run(tmp_path, visibility=visibility, patch_exit=1)
    assert run.returncode == 0, run.output
    assert json.loads(run.merge_patch()["stdin"]) == _MERGE_SETTINGS
    patches = [c for c in run.calls if "PATCH" in c["args"]]
    assert patches[0] is run.merge_patch()
    assert patches[1] is run.secret_patch()


def test_public_refusal_of_secret_scanning_keeps_merge_settings(
    tmp_path: Path,
) -> None:
    run = _run(tmp_path, visibility="PUBLIC", patch_exit=1)
    assert run.returncode != 0, run.output
    assert json.loads(run.merge_patch()["stdin"]) == _MERGE_SETTINGS


def test_merge_settings_failure_fails_the_run(tmp_path: Path) -> None:
    run = _run(tmp_path, merge_exit=1)
    assert run.returncode != 0, run.output
    assert "Failed to apply merge settings" in run.output
    assert not [c for c in run.calls if "security_and_analysis" in c["stdin"]]


def test_verification_reports_each_merge_setting(tmp_path: Path) -> None:
    run = _run(tmp_path)
    assert run.returncode == 0, run.output
    lines = run.output.splitlines()
    for key, value in _MERGE_SETTINGS.items():
        want = str(value).lower() if isinstance(value, bool) else value
        assert any("✅" in ln and f"{key}: {want}" in ln for ln in lines), run.output


def test_verification_flags_a_merge_setting_that_differs(tmp_path: Path) -> None:
    run = _run(tmp_path, squash_title="COMMIT_OR_PR_TITLE")
    lines = run.output.splitlines()
    assert any(
        "⚠️" in ln and "squash_merge_commit_title: COMMIT_OR_PR_TITLE" in ln
        for ln in lines
    ), run.output
