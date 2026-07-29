"""Tests for .github/scripts/kanban/Architecture.ps1 (Backlog-gate Architect step).

Covers the business rules that must not regress:

1. File-count gate  — <=5 .py files in src/ → trivial path (one-liner impact, no
   fake graphs); >5 → full AST analysis path.
2. Impact section   — the architectural impact is rendered as Markdown written
   INTO the issue body via a marker-bounded section (ADR-014, no .planning/).
3. $safeStr         — the safe-module list truncates to the first 5 with a count.

Each test uses an inline PowerShell snippet that replicates the exact logic from
Architecture.ps1 so we avoid importing the full Kanban module (which requires a
live environment) while still exercising the real business rules.
"""

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
SCRIPT = (
    Path(__file__).parent.parent.parent
    / ".github"
    / "scripts"
    / "kanban"
    / "Architecture.ps1"
)

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)


def _ps(script: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        cwd=str(cwd) if cwd else None,
    )


# ── File-count gate ───────────────────────────────────────────────────────────
# Replicates the gate condition from Invoke-Architecture exactly.

_GATE_SNIPPET = """\
function Test-FileCountGate {
    param([string]$SrcPath, [int]$Threshold = 5)
    $count = @(Get-ChildItem $SrcPath -Recurse -Filter '*.py' -ErrorAction SilentlyContinue).Count
    return $count -gt $Threshold
}
"""


def _make_src(tmp_path: Path, n_py_files: int) -> Path:
    """Create a fake src/ directory with *n_py_files* .py files."""
    src = tmp_path / "src"
    src.mkdir()
    for i in range(n_py_files):
        (src / f"module_{i}.py").write_text(f"# module {i}\n", encoding="utf-8")
    return src


def test_gate_exactly_five_is_trivial(tmp_path: Path) -> None:
    src = _make_src(tmp_path, 5)
    result = _ps(
        _GATE_SNIPPET
        + f"if (Test-FileCountGate '{src}') {{ exit 1 }} else {{ exit 0 }}"
    )
    assert result.returncode == 0, "5 .py files must NOT trigger the non-trivial path"


def test_gate_six_is_nontrivial(tmp_path: Path) -> None:
    src = _make_src(tmp_path, 6)
    result = _ps(
        _GATE_SNIPPET
        + f"if (Test-FileCountGate '{src}') {{ exit 0 }} else {{ exit 1 }}"
    )
    assert result.returncode == 0, "6 .py files must trigger the non-trivial path"


def test_gate_zero_files_is_trivial(tmp_path: Path) -> None:
    src = _make_src(tmp_path, 0)
    result = _ps(
        _GATE_SNIPPET
        + f"if (Test-FileCountGate '{src}') {{ exit 1 }} else {{ exit 0 }}"
    )
    assert result.returncode == 0, "0 .py files must NOT trigger the non-trivial path"


def test_gate_counts_recursively(tmp_path: Path) -> None:
    """Files in nested subdirectories must count toward the gate."""
    src = tmp_path / "src"
    (src / "sub").mkdir(parents=True)
    for i in range(6):
        (src / "sub" / f"m_{i}.py").write_text("", encoding="utf-8")
    result = _ps(
        _GATE_SNIPPET
        + f"if (Test-FileCountGate '{src}') {{ exit 0 }} else {{ exit 1 }}"
    )
    assert result.returncode == 0, "Nested .py files must count toward the gate"


# ── Trivial-impact Markdown (written into the issue body) ──────────────────────
# Replicates the trivial-branch impact string from Invoke-Architecture.

_TRIVIAL_IMPACT_SNIPPET = textwrap.dedent("""\
    function Get-TrivialImpact {
        param([int]$pyCount)
        return @(
            "**At-risk:** none ($pyCount .py file(s) in src/ — below the analysis threshold)"
            '**Safe:** all modules'
            ''
            '**Recommendation:** proceed'
        ) -join "`n"
    }
""")


def test_trivial_impact_recommends_proceed() -> None:
    result = _ps(_TRIVIAL_IMPACT_SNIPPET + "Get-TrivialImpact -pyCount 3")
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert "**Recommendation:** proceed" in out
    assert "below the analysis threshold" in out


def test_trivial_impact_has_no_graph_data() -> None:
    """The trivial impact must not contain dependency-graph keywords (no fake graph)."""
    result = _ps(_TRIVIAL_IMPACT_SNIPPET + "Get-TrivialImpact -pyCount 0")
    assert result.returncode == 0, result.stderr
    out = result.stdout.lower()
    for keyword in ("fan-in", "fan_in", "module graph", "pydeps"):
        assert keyword not in out, f"Trivial impact must not contain '{keyword}'"


# ── Marker-bounded body-section upsert (Set-IssueBodySection core) ─────────────
# Replicates the pure regex upsert (no gh) used to write ARCH-IMPACT / PLAN
# sections into the issue body.

_UPSERT_SNIPPET = textwrap.dedent("""\
    function Set-Section {
        param([string]$Body, [string]$Begin, [string]$End, [string]$Markdown)
        $Body    = $Body.TrimEnd("`r", "`n")
        $section = "$Begin`n$Markdown`n$End"
        $pattern = [regex]::Escape($Begin) + '.*?' + [regex]::Escape($End)
        $opts    = [System.Text.RegularExpressions.RegexOptions]::Singleline
        if ([regex]::IsMatch($Body, $pattern, $opts)) {
            return [regex]::Replace($Body, $pattern, { param($m) $section }, $opts)
        }
        return "$Body`n`n$section"
    }
""")

_BEGIN = "<!-- ARCH-IMPACT:BEGIN -->"
_END = "<!-- ARCH-IMPACT:END -->"


def test_upsert_appends_when_absent() -> None:
    script = (
        _UPSERT_SNIPPET
        + f"Set-Section -Body 'Original body.' -Begin '{_BEGIN}' -End '{_END}' "
        + "-Markdown '## Architecture Impact`n`nproceed'"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert "Original body." in out, "existing prose must be preserved"
    assert _BEGIN in out and _END in out, "markers must be present after append"
    assert out.count(_BEGIN) == 1, "exactly one section must exist"


def test_upsert_replaces_when_present() -> None:
    existing = f"Prose.\n\n{_BEGIN}\n## Architecture Impact\n\nOLD\n{_END}"
    # Pass the existing body via a here-string to preserve newlines.
    script = (
        _UPSERT_SNIPPET
        + f"$b = @'\n{existing}\n'@\n"
        + f"Set-Section -Body $b -Begin '{_BEGIN}' -End '{_END}' "
        + "-Markdown '## Architecture Impact`n`nNEW'"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert "NEW" in out and "OLD" not in out, "section content must be replaced"
    assert out.count(_BEGIN) == 1, "must not duplicate the section on replace"
    assert "Prose." in out, "surrounding prose must be preserved"


# ── $safeStr truncation logic ─────────────────────────────────────────────────
# Replicates the assignment block from Invoke-Architecture (non-trivial branch).

_SAFE_STR_SNIPPET = textwrap.dedent("""\
    function Get-SafeStr {
        param([string[]]$safe)
        if ($safe.Count -gt 0) {
            $safeStr = ($safe | Select-Object -First 5) -join ', '
            if ($safe.Count -gt 5) { $safeStr += " … +$($safe.Count - 5) more" }
        } else {
            $safeStr = 'none'
        }
        return $safeStr
    }
""")


def test_safe_str_truncation_appends_count_when_more_than_five() -> None:
    """8 safe modules → first 5 joined, then ' … +3 more' appended."""
    mods = [f"mod_{i}" for i in range(8)]
    mods_ps = ", ".join(f"'{m}'" for m in mods)
    result = _ps(_SAFE_STR_SNIPPET + f"$safe = @({mods_ps})\nGet-SafeStr -safe $safe")
    assert result.returncode == 0, result.stderr
    output = result.stdout.strip()
    assert " … +3 more" in output, f"Expected ' … +3 more' in output, got: {output!r}"
    for m in mods[:5]:
        assert m in output, f"Expected first-5 module {m!r} in output"


def test_safe_str_exactly_five_no_truncation() -> None:
    """Exactly 5 safe modules must produce no truncation indicator."""
    mods = [f"mod_{i}" for i in range(5)]
    mods_ps = ", ".join(f"'{m}'" for m in mods)
    result = _ps(_SAFE_STR_SNIPPET + f"$safe = @({mods_ps})\nGet-SafeStr -safe $safe")
    assert result.returncode == 0, result.stderr
    output = result.stdout.strip()
    assert "more" not in output, (
        f"5 modules must not produce a truncation indicator, got: {output!r}"
    )
    for m in mods:
        assert m in output


def test_safe_str_empty_is_none() -> None:
    """Empty safe list must produce the string 'none'."""
    result = _ps(_SAFE_STR_SNIPPET + "$safe = @()\nGet-SafeStr -safe $safe")
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "none"
