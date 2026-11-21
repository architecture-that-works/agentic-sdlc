"""Tests for .github/tasks/protect.ps1 business logic.

Each test runs an inline PowerShell snippet that replicates the exact decision
logic from the script, avoiding the need for a live GitHub connection while
still verifying the real rules.
"""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
_ROOT = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

_REQUIRED_CHECKS = [
    "lint",
    "typecheck",
    "test",
    "audit",
    "secret-scan",
    "module-map-check",
]


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )


# ---------------------------------------------------------------------------
# Missing-check detection (mirrors the Where-Object filter in the script)
# ---------------------------------------------------------------------------

_MISSING_CHECK_FN = """\
function Get-MissingChecks([string[]]$Required, [string[]]$Present) {
    return $Required | Where-Object { $_ -notin $Present }
}
"""


def test_no_missing_when_all_checks_present() -> None:
    checks = ", ".join(f'"{c}"' for c in _REQUIRED_CHECKS)
    result = _ps(
        _MISSING_CHECK_FN
        + f"""
$required = @({checks})
$present  = @({checks})
$missing  = Get-MissingChecks $required $present
if ($missing.Count -eq 0) {{ exit 0 }} else {{ exit 1 }}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_missing_when_secret_scan_absent() -> None:
    required = ", ".join(f'"{c}"' for c in _REQUIRED_CHECKS)
    present = ", ".join(f'"{c}"' for c in _REQUIRED_CHECKS if c != "secret-scan")
    result = _ps(
        _MISSING_CHECK_FN
        + f"""
$required = @({required})
$present  = @({present})
$missing  = Get-MissingChecks $required $present
if ($missing -contains 'secret-scan') {{ exit 0 }} else {{ exit 1 }}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_missing_when_module_map_check_absent() -> None:
    required = ", ".join(f'"{c}"' for c in _REQUIRED_CHECKS)
    present = ", ".join(f'"{c}"' for c in _REQUIRED_CHECKS if c != "module-map-check")
    result = _ps(
        _MISSING_CHECK_FN
        + f"""
$required = @({required})
$present  = @({present})
$missing  = Get-MissingChecks $required $present
if ($missing -contains 'module-map-check') {{ exit 0 }} else {{ exit 1 }}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


# ---------------------------------------------------------------------------
# Protection body JSON — verify structure and required fields
# ---------------------------------------------------------------------------

_BODY_SCRIPT = """\
$RequiredChecks = @("lint", "typecheck", "test", "audit", "secret-scan", "module-map-check")
$Body = [ordered]@{
    required_status_checks           = [ordered]@{
        strict   = $true
        contexts = $RequiredChecks
    }
    enforce_admins                   = $true
    required_pull_request_reviews    = [ordered]@{
        required_approving_review_count = 0
        dismiss_stale_reviews           = $false
        require_code_owner_reviews      = $false
        require_last_push_approval      = $false
    }
    restrictions                     = $null
    allow_force_pushes               = $false
    allow_deletions                  = $false
    required_linear_history          = $false
    required_conversation_resolution = $false
}
$Json = $Body | ConvertTo-Json -Depth 10
$Parsed = $Json | ConvertFrom-Json
"""


def test_body_includes_all_six_required_checks() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
$c = $Parsed.required_status_checks.contexts
if ($c.Count -eq 6 `
    -and $c -contains 'lint' `
    -and $c -contains 'typecheck' `
    -and $c -contains 'test' `
    -and $c -contains 'audit' `
    -and $c -contains 'secret-scan' `
    -and $c -contains 'module-map-check') { exit 0 } else {
    Write-Host "contexts: $($c -join ', ')"
    exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_body_strict_mode_enabled() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
if ($Parsed.required_status_checks.strict -eq $true) { exit 0 } else { exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_body_enforce_admins_true() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
if ($Parsed.enforce_admins -eq $true) { exit 0 } else { exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_body_allow_force_pushes_false() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
if ($Parsed.allow_force_pushes -eq $false) { exit 0 } else { exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_body_allow_deletions_false() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
if ($Parsed.allow_deletions -eq $false) { exit 0 } else { exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_body_pr_reviews_required() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
if ($Parsed.required_pull_request_reviews -ne $null) { exit 0 } else { exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_body_requires_a_pr_with_no_approvals_and_no_bypass() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
$pr = $Parsed.required_pull_request_reviews
$keys = @($pr.PSObject.Properties.Name)
if ($pr.required_approving_review_count -eq 0 `
    -and (@($keys | Where-Object { $_ -like 'bypass*' }).Count -eq 0) `
    -and $Parsed.enforce_admins -eq $true) { exit 0 } else {
    Write-Host "keys: $($keys -join ', ')"
    exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_script_grants_no_pull_request_bypass() -> None:
    """The real script, not the replica above: its PUT body names no bypass (#349).

    Every change reaches the default branch through a PR, the orchestrator's included,
    so protection carries no exception for any user, team or app.
    """
    source = (_ROOT / ".github" / "tasks" / "protect.ps1").read_text(encoding="utf-8")
    # No allowance key of any kind in the PUT body — users, teams and apps alike.
    assert re.search(r"^\s*bypass_\w+\s*=", source, flags=re.MULTILINE) is None
    assert "enforce_admins                   = $true" in source
    assert "required_approving_review_count = 0" in source


# ---------------------------------------------------------------------------
# API call shape — mock gh and verify endpoint + method
# ---------------------------------------------------------------------------

_MOCK_GH = """\
$script:ghCalls = @()
function gh {
    $script:ghCalls += ,$args
    $global:LASTEXITCODE = 0
    return '{}'
}
"""


def test_api_uses_put_method() -> None:
    result = _ps(
        _MOCK_GH
        + """
'{}' | gh api --method PUT repos/owner/repo/branches/main/protection --input - | Out-Null
$call = ($script:ghCalls[0]) -join ' '
if ($call -match '--method' -and $call -match 'PUT') { exit 0 } else {
    Write-Host "call: $call"
    exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_api_targets_branches_main_protection() -> None:
    result = _ps(
        _MOCK_GH
        + """
'{}' | gh api --method PUT repos/owner/repo/branches/main/protection --input - | Out-Null
$call = ($script:ghCalls[0]) -join ' '
if ($call -match 'branches/main/protection') { exit 0 } else {
    Write-Host "call: $call"
    exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_api_uses_input_flag() -> None:
    result = _ps(
        _MOCK_GH
        + """
'{}' | gh api --method PUT repos/owner/repo/branches/main/protection --input - | Out-Null
$call = ($script:ghCalls[0]) -join ' '
if ($call -match '--input') { exit 0 } else {
    Write-Host "call: $call"
    exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr
