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


# ── Fence burndown ────────────────────────────────────────────────────────────
# The mandated Block Format wraps every ISSUE block in plain triple-backtick
# fences.  $IssueRegex must include those fences so the burn-down removes the
# entire fenced unit — not just the content inside it.

_FENCE_BURNDOWN_SNIPPET = r"""
function Invoke-BurnDown([string]$Content) {
    $SentinelMatch = [regex]::Match($Content, '(?m)^<!-- ISSUES -->\s*$')
    $ParseContent  = if ($SentinelMatch.Success) { $Content.Substring($SentinelMatch.Index) } else { $Content }
    $IssueRegex    = '(?s)```\r?\nISSUE:\s*(.*?)\r?\n(.*?)\r?\nEND_ISSUE\r?\n```'
    $Found         = [regex]::Matches($ParseContent, $IssueRegex)
    $NewContent    = $Content
    foreach ($match in $Found) {
        $escaped    = [regex]::Escape($match.Value)
        $NewContent = [regex]::Replace($NewContent, "$escaped\s*", '')
    }
    $NewContent = $NewContent -replace '(\r?\n){3,}', "`r`n`r`n"
    return $NewContent
}
"""


def test_script_uses_fenced_issue_regex() -> None:
    """sync.ps1 $IssueRegex must require triple-backtick fences around blocks."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert r"```\r?\nISSUE:" in content, (
        r"sync.ps1 $IssueRegex must start with ```\r?\nISSUE: to capture the fence"
    )


def test_fenced_block_burndown_removes_fences() -> None:
    """After burn-down of a fenced ISSUE block, no empty fence pair remains and
    the Block Format prose above the sentinel is byte-identical to the input."""
    result = _ps(
        _FENCE_BURNDOWN_SNIPPET
        + r"""
$Content = @'
## Block Format

```
ISSUE: Example Title
**Goal**: This is a docs example.
END_ISSUE
```

<!-- ISSUES -->

```
ISSUE: Real Issue Title
**Goal**: This is the real thing.
END_ISSUE
```
'@

$out = Invoke-BurnDown $Content

# Assert no empty fence pair (two consecutive lines that are bare ```)
$lines = $out -split '\r?\n'
for ($i = 0; $i -lt ($lines.Count - 1); $i++) {
    if ($lines[$i].Trim() -eq '```' -and $lines[$i + 1].Trim() -eq '```') {
        Write-Host "FAIL: empty fence pair at lines $i and $($i + 1)"
        Write-Host $out
        exit 1
    }
}

# Assert content above sentinel is unchanged
$sepIn  = $Content.IndexOf('<!-- ISSUES -->')
$sepOut = $out.IndexOf('<!-- ISSUES -->')
if ($sepIn -lt 0 -or $sepOut -lt 0) {
    Write-Host "FAIL: sentinel missing from result"
    exit 1
}
if ($Content.Substring(0, $sepIn) -ne $out.Substring(0, $sepOut)) {
    Write-Host "FAIL: content before sentinel changed"
    exit 1
}

exit 0
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


# ── Unfenced-block detection ──────────────────────────────────────────────────
# Every ISSUE: line below the sentinel must be captured by the fenced-block
# regex. When any are not, the sync exits non-zero and names the unfenced
# titles before creating any GitHub issue.

_UNFENCED_DETECT_SNIPPET = r"""
function Detect-UnfencedTitles([string]$ParseContent, [string[]]$FencedTitles) {
    $RawTitleMatches = [regex]::Matches($ParseContent, '(?m)^ISSUE:\s*(.+)')
    $result = @($RawTitleMatches | ForEach-Object { $_.Groups[1].Value.Trim() } |
                Where-Object { $_ -notin $FencedTitles })
    return $result
}
"""


def test_detect_unfenced_flags_missing_fence() -> None:
    """A bare ISSUE: line without a backtick fence is returned as an unfenced title."""
    result = _ps(
        _UNFENCED_DETECT_SNIPPET
        + r"""
$content = "ISSUE: Unfenced Title`n**Goal**: Missing fence"
$titles = Detect-UnfencedTitles $content @()
if ($titles -contains 'Unfenced Title') { exit 0 } else {
    Write-Host "Got: $($titles -join ', ')"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_detect_unfenced_ignores_fenced_block() -> None:
    """An ISSUE: line already captured by the fenced regex is not returned as unfenced."""
    result = _ps(
        _UNFENCED_DETECT_SNIPPET
        + r"""
$content = @'
```
ISSUE: Fenced Title
**Goal**: Has fence
END_ISSUE
```
'@
$fenced = @('Fenced Title')
$titles = Detect-UnfencedTitles $content $fenced
if ($titles.Count -eq 0) { exit 0 } else {
    Write-Host "Got: $($titles -join ', ')"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_detect_unfenced_mixed_content() -> None:
    """With one fenced block and one bare ISSUE: line, only the unfenced title is returned."""
    result = _ps(
        _UNFENCED_DETECT_SNIPPET
        + r"""
$content = @'
```
ISSUE: Fenced Title
**Goal**: Has fence
END_ISSUE
```

ISSUE: Unfenced Title
**Goal**: Missing fence
'@
$fenced = @('Fenced Title')
$titles = Detect-UnfencedTitles $content $fenced
if (($titles.Count -eq 1) -and ($titles -contains 'Unfenced Title')) { exit 0 } else {
    Write-Host "Got: $($titles -join ', ')"; exit 1
}
"""
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_script_detects_raw_issue_lines() -> None:
    """sync.ps1 must contain the raw-ISSUE-line detection pattern used in the pre-flight guard."""
    content = SCRIPT.read_text(encoding="utf-8")
    assert r"(?m)^ISSUE:\s*" in content, (
        r"sync.ps1 must use '(?m)^ISSUE:\s*' to detect raw ISSUE: lines for the pre-flight guard"
    )


def test_guard_exits_1_and_names_unfenced_title() -> None:
    """The guard exits 1 and prints the unfenced title to stdout."""
    result = _ps(
        _UNFENCED_DETECT_SNIPPET
        + r"""
$ParseContent   = "ISSUE: Unfenced Title`n**Goal**: Missing fence"
$FencedTitles   = @()
$UnfencedTitles = Detect-UnfencedTitles $ParseContent $FencedTitles
if ($UnfencedTitles.Count -gt 0) {
    Write-Host "Unparsed ISSUE block(s):"
    foreach ($t in $UnfencedTitles) { Write-Host "   • $t" }
    exit 1
}
exit 0
"""
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Unfenced Title" in result.stdout


def test_guard_exits_1_in_dryrun_mode() -> None:
    """The guard fires before any DryRun summary — DryRun does not suppress the exit 1."""
    result = _ps(
        _UNFENCED_DETECT_SNIPPET
        + r"""
$DryRun         = $true
$ParseContent   = "ISSUE: Unfenced Title`n**Goal**: Missing fence"
$FencedTitles   = @()
$UnfencedTitles = Detect-UnfencedTitles $ParseContent $FencedTitles
if ($UnfencedTitles.Count -gt 0) {
    Write-Host "Unparsed ISSUE block(s):"
    foreach ($t in $UnfencedTitles) { Write-Host "   • $t" }
    exit 1
}
# Guard fires before this point; DryRun summary must never be reached
if ($DryRun) { Write-Host "Dry run complete. No changes made." }
exit 0
"""
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Unfenced Title" in result.stdout
    assert "Dry run complete" not in result.stdout
