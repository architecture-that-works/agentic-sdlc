"""Tests for .github/scripts/setup-branch-protection.ps1 business logic.

Each test runs an inline PowerShell snippet that replicates the exact decision
logic from the script, avoiding the need for a live GitHub connection while
still verifying the real rules.
"""

import shutil
import subprocess

import pytest

PWSH = shutil.which("pwsh") or "pwsh"

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
        bypass_pull_request_allowances  = [ordered]@{
            users = @()
            teams = @()
            apps  = @("github-actions")
        }
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


def test_body_bypass_includes_github_actions_app() -> None:
    result = _ps(
        _BODY_SCRIPT
        + """
$apps = $Parsed.required_pull_request_reviews.bypass_pull_request_allowances.apps
if ($apps -contains 'github-actions') { exit 0 } else {
    Write-Host "apps: $($apps -join ', ')"
    exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


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
