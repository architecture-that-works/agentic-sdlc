"""Tests for .github/scripts/tasks/sync-issues.ps1.

Layers of coverage:

1. Oracle snippet tests — replicate a piece of the script's logic as a PS
   function and verify its behaviour (metadata-header stripping; sentinel
   resolution).

2. File-based checks — assert the script implements the expected patterns:
   regex -replace header stripping (not Select-Object -Skip), a line-anchored
   sentinel match (not a bare IndexOf), and a three-levels-up repo-root path
   (the script lives in .github/scripts/tasks/).
"""

import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parent.parent.parent / ".github" / "tasks" / "sync.ps1"
PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

# Oracle: the strip logic replicated from sync-issues.ps1.
# These tests verify the Oracle behaviour; the file-based tests verify the
# actual script implements the same pattern.
_STRIP_SNIPPET = r"""
function Strip-MetadataHeaders([string]$Body) {
    $Body = $Body -replace '(?m)^LABELS:\s*.+(\r?\n|$)', ''
    $Body = $Body -replace '(?m)^ESTIMATE:\s*\d+(\r?\n|$)', ''
    $Body = $Body -replace '(?m)^PRIORITY:\s*P[0-4](\r?\n|$)', ''
    return $Body.TrimStart()
}
"""


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )


# ── Oracle snippet tests ──────────────────────────────────────────────────────


def test_strip_removes_labels_header() -> None:
    """LABELS: header line is removed from the body."""
    result = _ps(
        _STRIP_SNIPPET
        + r"""
$body = "LABELS: enhancement`n**Goal**: Foo"
$out = Strip-MetadataHeaders $body
if ($out -notmatch 'LABELS:' -and $out -match '\*\*Goal\*\*: Foo') { exit 0 } else {
    Write-Host "Got: $out"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_strip_removes_estimate_header() -> None:
    """ESTIMATE: header line is removed from the body."""
    result = _ps(
        _STRIP_SNIPPET
        + r"""
$body = "ESTIMATE: 5`n**Goal**: Bar"
$out = Strip-MetadataHeaders $body
if ($out -notmatch 'ESTIMATE:' -and $out -match '\*\*Goal\*\*: Bar') { exit 0 } else {
    Write-Host "Got: $out"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_strip_removes_priority_header() -> None:
    """PRIORITY: header line is removed from the body."""
    result = _ps(
        _STRIP_SNIPPET
        + r"""
$body = "PRIORITY: P2`n**Goal**: Baz"
$out = Strip-MetadataHeaders $body
if ($out -notmatch 'PRIORITY:' -and $out -match '\*\*Goal\*\*: Baz') { exit 0 } else {
    Write-Host "Got: $out"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_strip_removes_all_three_headers_in_sequence() -> None:
    """All three metadata headers are removed; markdown body is preserved."""
    result = _ps(
        _STRIP_SNIPPET
        + r"""
$body = "LABELS: enhancement`nESTIMATE: 3`nPRIORITY: P2`n**Goal**: Keep this"
$out = Strip-MetadataHeaders $body
$ok = ($out -notmatch 'LABELS:') -and ($out -notmatch 'ESTIMATE:') -and ($out -notmatch 'PRIORITY:') -and ($out -match '\*\*Goal\*\*: Keep this')
if ($ok) { exit 0 } else { Write-Host "Got: $out"; exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_strip_removes_headers_in_any_order() -> None:
    """Headers in a non-standard order are all stripped."""
    result = _ps(
        _STRIP_SNIPPET
        + r"""
$body = "PRIORITY: P1`nLABELS: AFK`nESTIMATE: 8`n**Goal**: Content"
$out = Strip-MetadataHeaders $body
$ok = ($out -notmatch 'LABELS:') -and ($out -notmatch 'ESTIMATE:') -and ($out -notmatch 'PRIORITY:') -and ($out -match '\*\*Goal\*\*: Content')
if ($ok) { exit 0 } else { Write-Host "Got: $out"; exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_strip_preserves_body_without_headers() -> None:
    """Body with no metadata headers is returned unchanged (modulo TrimStart)."""
    result = _ps(
        _STRIP_SNIPPET
        + r"""
$body = "**Goal**: Just content`n**Description**: More content"
$out = Strip-MetadataHeaders $body
if ($out -eq $body) { exit 0 } else {
    Write-Host "Expected: $body`nGot: $out"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_strip_removes_headers_separated_by_blank_line() -> None:
    """Headers separated by a blank line are all stripped.

    Regression: the previous Select-Object -Skip approach stopped stripping on
    the first empty line, leaving subsequent headers in the body.
    """
    result = _ps(
        _STRIP_SNIPPET
        + r"""
$body = "LABELS: enhancement`n`nESTIMATE: 3`n**Goal**: Content"
$out = Strip-MetadataHeaders $body
$ok = ($out -notmatch 'LABELS:') -and ($out -notmatch 'ESTIMATE:') -and ($out -match '\*\*Goal\*\*: Content')
if ($ok) { exit 0 } else { Write-Host "Got: $out"; exit 1 }
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


# ── File-based checks ─────────────────────────────────────────────────────────


def test_script_strips_labels_with_regex_replace() -> None:
    """sync-issues.ps1 uses -replace to strip LABELS: header lines."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert "(?m)^LABELS:" in content, (
        "sync-issues.ps1 must use -replace '(?m)^LABELS:...' to strip LABELS headers"
    )


def test_script_strips_estimate_with_regex_replace() -> None:
    """sync-issues.ps1 uses -replace to strip ESTIMATE: header lines."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert "(?m)^ESTIMATE:" in content, (
        "sync-issues.ps1 must use -replace '(?m)^ESTIMATE:...' to strip ESTIMATE headers"
    )


def test_script_strips_priority_with_regex_replace() -> None:
    """sync-issues.ps1 uses -replace to strip PRIORITY: header lines."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert "(?m)^PRIORITY:" in content, (
        "sync-issues.ps1 must use -replace '(?m)^PRIORITY:...' to strip PRIORITY headers"
    )


# ── Sentinel resolution ───────────────────────────────────────────────────────
# The <!-- ISSUES --> sentinel divides header docs (above) from syncable blocks
# (below). The header docs themselves mention the marker in prose/backticks, so
# the divider must be matched on its OWN LINE — a bare IndexOf splits on the
# first (prose) mention and parses the documentation as an ISSUE block.

_SENTINEL_SNIPPET = r"""
function Get-ParseContent([string]$Content) {
    $m = [regex]::Match($Content, '(?m)^<!-- ISSUES -->\s*$')
    if ($m.Success) { return $Content.Substring($m.Index) } else { return $Content }
}
"""


def test_sentinel_ignores_inline_mention_above_real_divider() -> None:
    """A <!-- ISSUES --> mentioned inline in the docs must not be treated as the
    divider — only content below the marker on its own line is parsed."""
    result = _ps(
        _SENTINEL_SNIPPET
        + r"""
$content = "Docs mention the <!-- ISSUES --> sentinel inline.`nISSUE: doc-example END_ISSUE`n`n<!-- ISSUES -->`n`nISSUE: RealItem`n**Goal**: keep`nEND_ISSUE"
$parse = Get-ParseContent $content
if (($parse -match 'RealItem') -and ($parse -notmatch 'doc-example')) { exit 0 } else {
    Write-Host "Got: $parse"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_script_matches_sentinel_on_its_own_line() -> None:
    """sync-issues.ps1 must anchor the sentinel to its own line, not use a bare
    IndexOf that matches the prose mention in the header docs."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert "(?m)^<!-- ISSUES -->" in content, (
        "sync-issues.ps1 must match the sentinel line-anchored ((?m)^<!-- ISSUES -->)"
    )
    assert ".IndexOf('<!-- ISSUES -->')" not in content, (
        "bare IndexOf('<!-- ISSUES -->') matches the first (prose) occurrence above "
        "the real divider — use the line-anchored regex instead"
    )


# ── Repo-root resolution ──────────────────────────────────────────────────────


def test_root_resolves_two_levels_up_from_tasks_dir() -> None:
    """sync.ps1 lives in .github/tasks/, so $_Root must climb
    two levels to the repo root."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert r"$PSScriptRoot\..\.." in content, (
        r"$_Root must be $PSScriptRoot\..\.. (two levels up to the repo root)"
    )
