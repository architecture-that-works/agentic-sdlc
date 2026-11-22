"""The issue template is the one place an issue's headings are written (#369).

- lib/Util.ps1 — Get-IssueTemplate returns the body below the front matter and stops,
  naming the file, when it is missing or holds no heading; Get-IssueHeadings gives the
  headings in order, each with the style the template writes it in.
- With the template stubbed to two made-up headings, refine's check, the epic
  child-issue body (Format-ChildIssue) and sync.ps1's block refusal all use exactly
  those two.

The module tests point the module's $_Root at a tmp directory that holds a stub
template, so the real reader runs. The sync tests run a copy of the module and of
sync.ps1 in a tmp repository with a fake `gh` on PATH.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
REPO_ROOT = Path(__file__).parent.parent.parent
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
TEMPLATE_PATH = ".github/ISSUE_TEMPLATE/issue.md"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")

# Two made-up headings: one written inline, one as checkboxes.
STUB = "---\nname: Stub\nabout: Made up\n---\n\n**Outcome**: <text>\n**Checks**:\n- [ ] <item>\n"


def _write_template(root: Path, text: str) -> None:
    path = root / TEMPLATE_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _run(root: Path, body: str) -> dict:
    """Run `body` in the module's session state with $_Root at `root`."""
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        f"$script:_Root = '{root}'\n"
        f"{body}\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _headings(root: Path) -> dict:
    return _run(
        root,
        r"""
$err = $null; $h = @()
try { $h = @(Get-IssueHeadings) } catch { $err = $_.Exception.Message }
[pscustomobject]@{ err = $err; names = @($h.Name); styles = @($h.Style) } | ConvertTo-Json -Compress
""",
    )


# ── Reader and headings ──────────────────────────────────────────────────────


def test_headings_below_front_matter_in_order_with_styles(tmp_path: Path) -> None:
    _write_template(
        tmp_path,
        "---\nname: x\nabout: '**Fake**: not a heading'\n---\n"
        "**Alpha**: text\n**Beta**:\n1. one\n**Gamma**:\n- [ ] box\n**Delta**:\n- dot\n",
    )
    out = _headings(tmp_path)
    assert out["err"] is None
    assert out["names"] == ["Alpha", "Beta", "Gamma", "Delta"]
    assert out["styles"] == ["inline", "numbered", "checkbox", "bullet"]


def test_template_without_front_matter_is_read_whole(tmp_path: Path) -> None:
    _write_template(tmp_path, "**Only**: text\n")
    assert _headings(tmp_path) == {"err": None, "names": ["Only"], "styles": ["inline"]}


def test_template_without_a_heading_stops_naming_the_file(tmp_path: Path) -> None:
    _write_template(tmp_path, "---\nname: x\nabout: y\n---\nJust prose.\n")
    out = _headings(tmp_path)
    assert TEMPLATE_PATH in out["err"]


def test_the_real_template_has_headings() -> None:
    out = _headings(REPO_ROOT)
    assert out["err"] is None and len(out["names"]) >= 1


def test_acceptance_criteria_heading_is_a_checkbox_list() -> None:
    out = _headings(REPO_ROOT)
    styles = dict(zip(out["names"], out["styles"]))
    assert styles["Acceptance Criteria"] == "checkbox"


# ── Refine ───────────────────────────────────────────────────────────────────

_REFINE_FAKES = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:Body = ''
function script:gh { $global:LASTEXITCODE = 0
    [pscustomobject]@{ title = 't'; body = $script:Body; comments = @([pscustomobject]@{ body = '· refined — ok' }) } | ConvertTo-Json -Compress }
# Past the heading check refine reads the board: stop there and record it.
function script:Get-ProjectFieldValues { param($IssueNumber) $script:Log.Add('body-refine'); throw 'stop' }
function script:Set-PlanningReadiness { param($IssueNumber, $Stage, $StageLabel, $PopulatedBy) $script:Log.Add("ready:$Stage") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add('comment') }
function script:Refine-With { param($Body)
    $script:Log.Clear(); $script:Body = "$Body`n$KanbanBriefBeginMarker"
    $err = $null
    try { Invoke-Refine -Number 7 } catch { $err = $_.Exception.Message }
    [pscustomobject]@{ err = $err; log = @($script:Log) } }
"""


def test_refine_checks_the_stubbed_headings(tmp_path: Path) -> None:
    _write_template(tmp_path, STUB)
    out = _run(
        tmp_path,
        _REFINE_FAKES
        + r"""
[pscustomobject]@{
    both    = Refine-With "**Outcome**: o`n**Checks**:`n- [ ] c"
    missing = Refine-With "**Outcome**: o"
} | ConvertTo-Json -Compress -Depth 4
""",
    )
    # Both stub headings present: nothing to rewrite, refine stops at its short-circuit.
    assert out["both"] == {"err": None, "log": []}
    # One missing: refine goes on to rewrite the body.
    assert out["missing"]["log"] == ["body-refine"]


def test_missing_template_stops_refine_naming_the_file(tmp_path: Path) -> None:
    out = _run(
        tmp_path,
        _REFINE_FAKES
        + r"""
Refine-With "**Outcome**: o" | ConvertTo-Json -Compress
""",
    )
    assert TEMPLATE_PATH in out["err"]
    assert out["log"] == []


# ── Child-issue body ─────────────────────────────────────────────────────────


def test_child_issue_body_uses_the_stubbed_headings(tmp_path: Path) -> None:
    _write_template(tmp_path, STUB)
    out = _run(
        tmp_path,
        r"""
$full  = Format-ChildIssue -Estimate 2 -Sections ([pscustomobject]@{ Outcome = 'done'; Checks = @('a', 'b'); Goal = 'ignored' }) -Footer 'Parent: #1'
$empty = Format-ChildIssue -Sections @{}
[pscustomobject]@{ full = $full; empty = $empty } | ConvertTo-Json -Compress
""",
    )
    assert out["full"] == (
        "ESTIMATE: 2\n\n**Outcome**: done\n**Checks**:\n- [ ] a\n- [ ] b\n\nParent: #1"
    )
    placeholder = "_(populated by plan synthesis)_"
    assert (
        out["empty"] == f"**Outcome**: {placeholder}\n**Checks**:\n- [ ] {placeholder}"
    )


# ── Sync refusal ─────────────────────────────────────────────────────────────


def _sync_repo(tmp_path: Path, blocks: str) -> Path:
    root = tmp_path / "repo"
    shutil.copytree(
        REPO_ROOT / ".github" / "orchestrator", root / ".github" / "orchestrator"
    )
    (root / ".github" / "tasks").mkdir(parents=True)
    shutil.copy(
        REPO_ROOT / ".github" / "tasks" / "sync.ps1", root / ".github" / "tasks"
    )
    _write_template(root, STUB)
    (root / "ISSUES.md").write_text(
        f"# ISSUES.md\n\n<!-- ISSUES -->\n\n{blocks}", encoding="utf-8"
    )
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "gh"
    fake.write_text(
        f'#!/bin/sh\necho "$*" >> "{tmp_path / "gh.log"}"\n'
        'case "$1 $2" in "repo view") echo octocat/sandbox;; "issue create") '
        "echo https://github.com/octocat/sandbox/issues/9;; *) echo '[]';; esac\n"
    )
    fake.chmod(0o755)
    return root


def _sync(tmp_path: Path, root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("KANBAN_")}
    env["PATH"] = f"{tmp_path / 'bin'}{os.pathsep}{env.get('PATH', '')}"
    env["GITHUB_REPOSITORY"] = "octocat/sandbox"
    env["GITHUB_DEFAULT_BRANCH"] = "main"
    return subprocess.run(
        [
            PWSH,
            "-NoProfile",
            "-File",
            str(root / ".github" / "tasks" / "sync.ps1"),
            *args,
        ],
        capture_output=True,
        text=True,
        cwd=str(root),
        env=env,
        check=False,
    )


def _gh_calls(tmp_path: Path) -> str:
    log = tmp_path / "gh.log"
    return log.read_text() if log.exists() else ""


_GOOD = "```\nISSUE: Good one\nESTIMATE: 2\n**Outcome**: o\n**Checks**:\n- [ ] c\nEND_ISSUE\n```\n\n"
_BAD = "```\nISSUE: Bad one\n**Outcome**: o\nEND_ISSUE\n```\n"


@pytest.mark.parametrize("args", [(), ("-DryRun",)])
def test_sync_refuses_a_block_missing_a_stubbed_heading(
    tmp_path: Path, args: tuple[str, ...]
) -> None:
    root = _sync_repo(tmp_path, _GOOD + _BAD)
    result = _sync(tmp_path, root, *args)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "'Bad one' lacks **Checks**" in result.stdout
    assert "Good one" not in result.stdout.split("missing a heading", 1)[1]
    assert "issue create" not in _gh_calls(tmp_path)
    assert "Bad one" in (root / "ISSUES.md").read_text()


def test_sync_accepts_blocks_with_exactly_the_stubbed_headings(tmp_path: Path) -> None:
    root = _sync_repo(tmp_path, _GOOD)
    result = _sync(tmp_path, root, "-DryRun")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Would create issue" in result.stdout
