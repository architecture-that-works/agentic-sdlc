"""After a merge, start a round for a held pull request that now conflicts (#374).

Start-ConflictRounds (stages/Ship.ps1) runs after every merged feature-branch PR
(afk.yml, conflict-rounds job). It looks at every other open PR whose issue is at
human:approval, finds out with a read-only merge (Test-BranchConflict, `git
merge-tree`) whether the default branch still merges into its branch, and for each
one that conflicts moves the issue to agent:implementing, posts one signal comment
naming the merge, and dispatches the implement job. Git runs for real against a bare
`origin` in a temporary directory; gh and the label transition are in-memory fakes.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"
CONFLICTING = "feature/1-conflicts"
CLEAN = "feature/2-clean"

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


def _clone(tmp_path: Path, origin: Path, name: str) -> Path:
    work = tmp_path / name
    _git(tmp_path, "clone", "-q", str(origin), str(work))
    for k, v in (
        ("user.email", "t@example.com"),
        ("user.name", "t"),
        ("commit.gpgsign", "false"),
    ):
        _git(work, "config", k, v)
    return work


def _commit_to(work: Path, branch: str, files: dict[str, str], *, new: bool) -> None:
    _git(work, "checkout", "-q", *(["-b", branch, "main"] if new else [branch]))
    for name, text in files.items():
        (work / name).write_text(text)
    _git(work, "add", "-A")
    _git(work, "commit", "-q", "-m", f"work on {branch}")
    _git(work, "push", "-q", "origin", branch)


def _setup(tmp_path: Path) -> Path:
    """Two held branches, then a merge to main that touches the first one's lines.

    Returns a checkout of main that has fetched every branch, as the
    conflict-rounds job's `fetch-depth: 0` checkout has.
    """
    origin = tmp_path / "origin.git"
    _git(tmp_path, "init", "-q", "--bare", "-b", "main", str(origin))
    seed = _clone(tmp_path, origin, "seed")
    (seed / "README.md").write_text("Title\n=====\n\nline one\n")
    _git(seed, "add", "-A")
    _git(seed, "commit", "-q", "-m", "init")
    _git(seed, "push", "-q", "origin", "main")
    _commit_to(seed, CONFLICTING, {"README.md": "Title\n=====\n\nline A\n"}, new=True)
    _commit_to(seed, CLEAN, {"clean.py": "b = 1\n"}, new=True)
    # PR #9 merges: main changes the same line as the first branch.
    _git(seed, "checkout", "-q", "main")
    _commit_to(seed, "main", {"README.md": "Title\n=====\n\nline C\n"}, new=False)

    job = _clone(tmp_path, origin, "job")
    _git(job, "fetch", "-q", "origin")
    return job


def _snapshot(work: Path) -> dict[str, str]:
    return {
        "refs": _git(work, "for-each-ref"),
        "head": _git(work, "rev-parse", "HEAD"),
        "branch": _git(work, "rev-parse", "--abbrev-ref", "HEAD"),
        "status": _git(work, "status", "--porcelain"),
    }


def test_the_probe_reports_a_conflict_without_changing_any_branch(
    tmp_path: Path,
) -> None:
    job = _setup(tmp_path)
    before = _snapshot(job)
    out = _run(
        f"""
[pscustomobject]@{{
    conflicting = (Test-BranchConflict -Branch '{CONFLICTING}')
    clean       = (Test-BranchConflict -Branch '{CLEAN}')
}} | ConvertTo-Json -Compress
""",
        cwd=job,
    )
    assert out == {"conflicting": True, "clean": False}
    assert _snapshot(job) == before
    assert not (job / ".git" / "MERGE_HEAD").exists()


def test_the_probe_fails_loudly_on_a_branch_it_cannot_read(tmp_path: Path) -> None:
    job = _setup(tmp_path)
    out = _run(
        r"""
$err = $null
try { $null = Test-BranchConflict -Branch 'feature/3-missing' } catch { $err = "$_" }
[pscustomobject]@{ err = $err } | ConvertTo-Json -Compress
""",
        cwd=job,
    )
    assert out["err"] and "feature/3-missing" in out["err"]


# The open PRs, the issues' labels, and fakes for every gh call and the transition.
# Besides the two held PRs: the merged PR itself, a non-feature branch, a fork's PR
# and a PR whose issue is not held. None has a branch in the repo, so probing one
# would throw — they must be filtered out before the probe. PR 17 is held but its
# branch was never fetched: it is skipped, and the scan goes on to the next PR.
_FAKES = r"""
$script:Labels = @{
    1 = @('human:approval', 'size:S')
    2 = @('human:approval')
    7 = @('human:approval')
    4 = @('agent:failed')
    5 = @('human:approval')
    6 = @('human:approval')
    9 = @('human:approval')
}
$script:Prs = @(
    @{ number = 11; headRefName = 'feature/1-conflicts'; isCrossRepository = $false }
    @{ number = 17; headRefName = 'feature/7-unfetched'; isCrossRepository = $false }
    @{ number = 12; headRefName = 'feature/2-clean';     isCrossRepository = $false }
    @{ number = 14; headRefName = 'feature/4-failed';    isCrossRepository = $false }
    @{ number = 15; headRefName = 'feature/5-fork';      isCrossRepository = $true }
    @{ number = 16; headRefName = 'docs/6-not-feature';  isCrossRepository = $false }
    @{ number = 9;  headRefName = 'feature/9-merged';    isCrossRepository = $false }
) | ConvertTo-Json -Compress
$script:Log = [System.Collections.Generic.List[string]]::new()
function script:gh { $global:LASTEXITCODE = 0
    $a = $args -join ' '
    if ($a -like 'pr list*') { $script:Log.Add("gh:$a"); return $script:Prs }
    if ($a -match '^api repos/[^/]+/[^/]+/issues/(\d+)/labels') { return $script:Labels[[int]$Matches[1]] }
    if ($a -like 'workflow run*') { $script:Log.Add("dispatch:$a"); return }
    throw "unexpected gh call: $a" }
function script:Set-AgentState { param($IssueNumber, $Label)
    $script:Log.Add("state:${IssueNumber}:$Label")
    $script:Labels[[int]$IssueNumber] = @($Label) }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:${Number}:$Body") }
"""


def _rows(rows: str) -> str:
    return (
        f"$rows = @({rows} | ForEach-Object {{ [pscustomobject]@{{ "
        "IssueNumber = $_.IssueNumber; PRNumber = $_.PRNumber; "
        "Conflicts = $_.Conflicts; RoundStarted = $_.RoundStarted } })"
    )


def test_a_round_starts_only_for_the_held_pr_that_now_conflicts(
    tmp_path: Path,
) -> None:
    job = _setup(tmp_path)
    out = _run(
        _FAKES
        + _rows("Start-ConflictRounds -MergedPR 9")
        + "\n[pscustomobject]@{ rows = $rows; log = @($script:Log) } | ConvertTo-Json -Compress -Depth 4\n",
        cwd=job,
    )
    assert out["rows"] == [
        {"IssueNumber": 1, "PRNumber": 11, "Conflicts": True, "RoundStarted": True},
        {"IssueNumber": 2, "PRNumber": 12, "Conflicts": False, "RoundStarted": False},
    ]
    log = out["log"]
    assert sum(e.startswith("gh:pr list") for e in log) == 1  # one PR list call

    # Issue 1: label first, then one comment naming the merge, then one dispatch.
    events = [e for e in log if not e.startswith("gh:")]
    assert [e.split(":", 2)[0] for e in events] == ["state", "comment", "dispatch"]
    assert events[0] == "state:1:agent:implementing"
    comment = events[1]
    assert comment.startswith("comment:1:🤖⚠️ Merge conflict after PR #9 merged")
    assert "a round is starting" in comment
    dispatch = events[2]
    assert "afk.yml" in dispatch
    assert "stage=implement" in dispatch and "issue_number=1" in dispatch

    # Issue 2 (clean) and every non-candidate are untouched.
    assert not any(":2:" in e or "issue_number=2" in e for e in events)


def test_running_the_check_again_during_the_round_starts_nothing(
    tmp_path: Path,
) -> None:
    job = _setup(tmp_path)
    out = _run(
        _FAKES
        + "$null = Start-ConflictRounds -MergedPR 9\n"
        + "$script:Log.Clear()\n"
        + _rows("Start-ConflictRounds -MergedPR 9")
        + "\n[pscustomobject]@{ rows = $rows; log = @($script:Log) } | ConvertTo-Json -Compress -Depth 4\n",
        cwd=job,
    )
    # Issue 1 is at agent:implementing now, so it is no longer a candidate.
    assert out["rows"] == [
        {"IssueNumber": 2, "PRNumber": 12, "Conflicts": False, "RoundStarted": False},
    ]
    assert [e for e in out["log"] if not e.startswith("gh:")] == []
