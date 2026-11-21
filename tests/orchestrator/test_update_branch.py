"""Bringing a branch up to date by merging (#367) — stages/Ship.ps1.

Update-Branch merges the default branch into the issue's branch, as GitHub's
"Update branch" button does. A clean merge is committed and pushed without force; a
conflict is left in place for the agent. Complete-BranchUpdate finishes that merge
once the conflicted files are resolved, or names the files that still hold markers.
Every test runs real git against a bare `origin` in a temporary directory.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"
BRANCH = "feature/7-thing"

pytestmark = pytest.mark.skipif(
    not (shutil.which("pwsh") and shutil.which("git")),
    reason="pwsh or git not available",
)


def _run(body: str, cwd: Path) -> dict:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        "$script:Comments = [System.Collections.Generic.List[string]]::new()\n"
        "function script:Add-Comment { param($Number, $Body) $script:Comments.Add($Body) }\n"
        f"{body}\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
        cwd=cwd,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def _setup(tmp_path: Path, *, conflict: bool) -> tuple[Path, Path]:
    """A clone on BRANCH, pushed, with main moved on at origin since."""
    origin = tmp_path / "origin.git"
    _git(tmp_path, "init", "-q", "--bare", "-b", "main", str(origin))
    work = tmp_path / "work"
    _git(tmp_path, "clone", "-q", str(origin), str(work))
    for k, v in (
        ("user.email", "t@example.com"),
        ("user.name", "t"),
        ("commit.gpgsign", "false"),
    ):
        _git(work, "config", k, v)
    (work / "README.md").write_text("Title\n=====\n\nline one\n")
    _git(work, "add", "-A")
    _git(work, "commit", "-q", "-m", "init")
    _git(work, "push", "-q", "origin", "main")

    _git(work, "checkout", "-q", "-b", BRANCH)
    if conflict:
        (work / "README.md").write_text("Title\n=====\n\nline one (branch)\n")
    (work / "feature.py").write_text("f = 1\n")
    _git(work, "add", "-A")
    _git(work, "commit", "-q", "-m", "feat(#7): branch work")
    _git(work, "push", "-q", "origin", BRANCH)

    # main moves on in another clone.
    other = tmp_path / "other"
    _git(tmp_path, "clone", "-q", str(origin), str(other))
    _git(other, "config", "user.email", "o@example.com")
    _git(other, "config", "user.name", "o")
    if conflict:
        (other / "README.md").write_text("Title\n=====\n\nline one (main)\n")
    (other / "main_only.py").write_text("m = 1\n")
    _git(other, "add", "-A")
    _git(other, "commit", "-q", "-m", "chore: main moves on")
    _git(other, "push", "-q", "origin", "main")
    return work, origin


_UPDATE = r"""
$r = Update-Branch -IssueNumber 7 -Branch 'feature/7-thing'
[pscustomobject]@{
    upToDate  = [bool]$r.UpToDate
    merged    = [bool]$r.Merged
    conflicts = @($r.Conflicts)
    merging   = (Test-MergeInProgress)
    comments  = @($script:Comments)
} | ConvertTo-Json -Compress
"""


def test_a_conflict_is_left_in_place_and_named_then_completed_and_pushed(
    tmp_path: Path,
) -> None:
    work, origin = _setup(tmp_path, conflict=True)
    remote_before = _git(origin, "rev-parse", BRANCH)

    out = _run(_UPDATE, cwd=work)
    assert out["conflicts"] == ["README.md"]
    assert out["merged"] is False and out["merging"] is True
    assert (work / ".git" / "MERGE_HEAD").exists()
    assert _git(origin, "rev-parse", BRANCH) == remote_before  # nothing pushed
    assert any(
        c.startswith("· merging main into feature/7-thing") for c in out["comments"]
    )

    # The agent resolves the file, keeping both sides, and edits one file of its own.
    (work / "README.md").write_text(
        "Title\n=====\n\nline one (branch)\nline one (main)\n"
    )
    (work / "agent.py").write_text("a = 1\n")
    out = _run(
        r"""
$r = Complete-BranchUpdate -IssueNumber 7 -Branch 'feature/7-thing' -Conflicts @('README.md')
[pscustomobject]@{ markers = @($r.MarkerFiles); merging = (Test-MergeInProgress) } | ConvertTo-Json -Compress
""",
        cwd=work,
    )
    assert out["markers"] == [] and out["merging"] is False
    assert _git(work, "log", "-1", "--format=%s") == (
        "chore(#7): merge main into feature/7-thing"
    )
    assert len(_git(work, "log", "-1", "--format=%P").split()) == 2
    # The merge commit holds the resolution, not the agent's other edit.
    assert "agent.py" not in _git(work, "show", "--name-only", "--format=", "HEAD")
    assert (work / "agent.py").exists()

    # A plain push fast-forwards the remote: nothing was rewritten.
    _git(work, "push", "-q", "origin", f"HEAD:refs/heads/{BRANCH}")
    assert _git(origin, "rev-parse", BRANCH) == _git(work, "rev-parse", "HEAD")
    _git(work, "merge-base", "--is-ancestor", remote_before, "HEAD")


def test_markers_left_name_the_file_and_commit_nothing(tmp_path: Path) -> None:
    work, _ = _setup(tmp_path, conflict=True)
    _run(_UPDATE, cwd=work)
    head = _git(work, "rev-parse", "HEAD")

    out = _run(
        r"""
$r = Complete-BranchUpdate -IssueNumber 7 -Branch 'feature/7-thing' -Conflicts @('README.md')
[pscustomobject]@{ markers = @($r.MarkerFiles); merging = (Test-MergeInProgress) } | ConvertTo-Json -Compress
""",
        cwd=work,
    )
    assert out["markers"] == ["README.md"]
    assert out["merging"] is True
    assert _git(work, "rev-parse", "HEAD") == head


def test_a_setext_heading_underline_is_not_a_marker(tmp_path: Path) -> None:
    work, _ = _setup(tmp_path, conflict=True)
    _run(_UPDATE, cwd=work)
    # '=====' underlines remain (README's 'Title' heading) — still resolved.
    (work / "README.md").write_text("Title\n=======\n\nboth\n")
    out = _run(
        r"""
$r = Complete-BranchUpdate -IssueNumber 7 -Branch 'feature/7-thing' -Conflicts @('README.md')
[pscustomobject]@{ markers = @($r.MarkerFiles) } | ConvertTo-Json -Compress
""",
        cwd=work,
    )
    assert out["markers"] == []


def test_a_clean_merge_is_committed_and_pushed_without_force(tmp_path: Path) -> None:
    work, origin = _setup(tmp_path, conflict=False)
    remote_before = _git(origin, "rev-parse", BRANCH)
    # A forced push would be the only way to land a rewritten branch; refuse it.
    _git(origin, "config", "receive.denyNonFastForwards", "true")

    out = _run(_UPDATE, cwd=work)
    assert out["merged"] is True and out["conflicts"] == []
    assert out["merging"] is False
    assert _git(origin, "rev-parse", BRANCH) == _git(work, "rev-parse", "HEAD")
    _git(work, "merge-base", "--is-ancestor", remote_before, "HEAD")
    assert _git(work, "log", "-1", "--format=%s") == (
        "chore(#7): merge main into feature/7-thing"
    )


def test_an_up_to_date_branch_is_left_alone(tmp_path: Path) -> None:
    work, _ = _setup(tmp_path, conflict=False)
    _run(_UPDATE, cwd=work)  # first merge brings it up to date
    head = _git(work, "rev-parse", "HEAD")

    out = _run(_UPDATE, cwd=work)
    assert out["upToDate"] is True and out["merged"] is False
    assert out["comments"] == []
    assert _git(work, "rev-parse", "HEAD") == head
