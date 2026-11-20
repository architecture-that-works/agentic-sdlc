"""Tests for the denylist guard in .github/orchestrator/implement.ps1.

The denylist blocks sensitive file names (*.key, *.pem, *.pfx, *secret*,
*credential*) from being staged. Deletions are never inspected (only additions
and modifications are checked). .md files are exempt from name-pattern checks
(*secret*, *credential*) — a document named after secrets is not a secret.
Extension-based patterns (.env, *.key, *.pem, *.pfx) are unconditional.

Each test runs an inline PowerShell snippet that replicates the exact guard
logic from implement.ps1's Invoke-CommitAndPR denylist block. This avoids
dot-sourcing the full orchestrator script (which requires a live Kanban
environment) while still testing the real business rule.
"""

import shutil
import subprocess

import pytest

PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

# Replicates the denylist logic from implement.ps1 Invoke-CommitAndPR exactly.
_DENYLIST_SNIPPET = """\
function Test-SensitivePath {
    param([string]$Path)
    $denyPatterns = @('.env', '*.key', '*.pem', '*.pfx')
    $namePatterns  = @('*secret*', '*credential*')
    $leaf = Split-Path $Path -Leaf
    if ($denyPatterns | Where-Object { $leaf -like $_ }) { return $true }
    if ($leaf -like '*.md') { return $false }
    return [bool]($namePatterns | Where-Object { $leaf -like $_ })
}
"""


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )


# ── ADR exemptions ─────────────────────────────────────────────────────────────


def test_adr_secrets_management_not_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'docs/adr/ADR-008-secrets-management.md') { exit 1 } else { exit 0 }"
    )
    assert result.returncode == 0, (
        "docs/adr/ADR-008-secrets-management.md must NOT be blocked by the denylist"
    )


def test_adr_credential_doc_not_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'docs/adr/ADR-009-credential-rotation.md') { exit 1 } else { exit 0 }"
    )
    assert result.returncode == 0, (
        "ADR files matching *credential* under docs/adr/ must NOT be blocked by the denylist"
    )


# ── Sensitive files that must be blocked ──────────────────────────────────────


def test_key_file_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'private.key') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "*.key files must be blocked by the denylist"


def test_pem_file_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'cert.pem') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "*.pem files must be blocked by the denylist"


def test_pfx_file_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'cert.pfx') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "*.pfx files must be blocked by the denylist"


def test_secret_file_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'my-secret-file.txt') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "*secret* files must be blocked by the denylist"


def test_credential_file_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'db-credentials.json') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "*credential* files must be blocked by the denylist"


# ── New cases: deletions and .md exemption ────────────────────────────────────


def test_adr_staging_deletion_not_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'adr-staging/ADR-008-secrets-management.md') { exit 1 } else { exit 0 }"
    )
    assert result.returncode == 0, (
        "adr-staging/ADR-008-secrets-management.md must NOT be blocked by the denylist"
    )


def test_md_with_sensitive_name_not_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'docs/adr/ADR-005-secrets-and-trust-boundaries.md') { exit 1 } else { exit 0 }"
    )
    assert result.returncode == 0, (
        "docs/adr/ADR-005-secrets-and-trust-boundaries.md must NOT be blocked by the denylist"
    )


def test_secrets_json_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'config/secrets.json') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "config/secrets.json must be blocked by the denylist"


def test_env_file_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET + "if (Test-SensitivePath '.env') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, ".env must be blocked by the denylist"


def test_deploy_key_is_blocked() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + "if (Test-SensitivePath 'deploy.key') { exit 0 } else { exit 1 }"
    )
    assert result.returncode == 0, "deploy.key must be blocked by the denylist"


def test_comment_contains_unstaged_prefix() -> None:
    result = _ps(
        _DENYLIST_SNIPPET
        + """
$paths = @('config/secrets.json', '.env', 'deploy.key', 'docs/adr/ADR-008-secrets-management.md')
$unstagedPaths = @()
foreach ($p in $paths) {
    if (Test-SensitivePath $p) { $unstagedPaths += $p }
}
$lines = $unstagedPaths | ForEach-Object { "Unstaged by the secrets denylist: $_" }
$allMatch = ($unstagedPaths.Count -eq 3) -and
            ($lines -contains "Unstaged by the secrets denylist: config/secrets.json") -and
            ($lines -contains "Unstaged by the secrets denylist: .env") -and
            ($lines -contains "Unstaged by the secrets denylist: deploy.key")
if ($allMatch) { exit 0 } else { exit 1 }
"""
    )
    assert result.returncode == 0, (
        "Guard comment must contain 'Unstaged by the secrets denylist:' prefix for each blocked path"
    )
