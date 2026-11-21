"""A refused edit ends the implement round (#346) — stages/Implement.ps1, lib/Util.ps1.

The engine (Claude Code) refuses writes to its protected paths in an unattended run,
whatever the allow rules say. A retry cannot help, so the round ends after one attempt:
the record of the attempt lists the files git says changed (not the edits the agent
asked for), the other work is pushed without a PR, and the owner is told which files
are theirs to change.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

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


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "t@example.com")
    _git(repo, "config", "user.name", "t")
    _git(repo, "config", "commit.gpgsign", "false")
    (repo / "keep.py").write_text("x = 1\n")
    (repo / "old.py").write_text("y = 2\n")
    (repo / "move_me.py").write_text("z = 3\n")
    (repo / ".devcontainer").mkdir()
    (repo / ".devcontainer" / "devcontainer.json").write_text("{}\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "init")
    return repo


# ── The tracer bullet: one refused edit, one shell deletion ───────────────────


def _stream(repo: Path) -> list[dict]:
    refused = str(repo / ".devcontainer" / "devcontainer.json")
    edit_input = {"file_path": refused, "old_string": "{}", "new_string": '{"a":1}'}
    return [
        {
            "type": "assistant",
            "message": {
                "content": [
                    {
                        "type": "tool_use",
                        "id": "t1",
                        "name": "Edit",
                        "input": edit_input,
                    },
                    {
                        "type": "tool_use",
                        "id": "t2",
                        "name": "Bash",
                        "input": {"command": "rm old.py"},
                    },
                    {
                        "type": "text",
                        "text": "\n- old.py removed\n- Left undone: none\n",
                    },
                ]
            },
        },
        {
            "type": "result",
            "subtype": "success",
            "permission_denials": [
                {"tool_name": "Edit", "tool_use_id": "t1", "tool_input": edit_input}
            ],
        },
    ]


_CONDUCTOR = r"""
$script:Log      = [System.Collections.Generic.List[string]]::new()
$script:Comments = [System.Collections.Generic.List[string]]::new()
$script:State    = [pscustomobject]@{ attempts = @(); attempt_count = 0 }
$script:Stream   = Get-Content -Raw stream.json | ConvertFrom-Json
$script:RealGit  = (Get-Command git -CommandType Application | Select-Object -First 1).Source
function script:Assert-EngineReady {}
function script:Resume-PausedIssues {}
function script:Test-TrustedAuthor { param($IssueNumber) $true }
function script:Acquire-OrchestratorLock { param($IssueNumber) $true }
function script:Release-OrchestratorLock {}
function script:Test-EngineUsageLimit { $null }
function script:Get-IssueState { param($IssueNumber) $script:State }
function script:Test-Readiness { param($State) $true }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Set-AgentFailedState { param($IssueNumber, $FailedAt, $Reason) $script:Log.Add("failed:$FailedAt") }
function script:Add-FailedAttempt { $script:Log.Add('failed-attempt') }
function script:Add-ImplementAttempt { param($IssueNumber, $Stage, $Reason, $Attempt, $Max, $Implemented, $LeftUndone, $IssuesDiscovered, $Commands, $Procedure)
    $script:Log.Add("attempt:${Stage}:$Attempt") ; $script:AttemptReason = $Reason }
function script:Add-Comment { param($Number, $Body) $script:Comments.Add($Body) }
function script:Format-ErrorBlock { param($Raw) $Raw }
function script:Move-ToLane {}
function script:Get-SignalComments { param($IssueNumber, $Prefix) @() }
function script:Format-OwnerComments { param($IssueNumber) '' }
function script:Get-IssueEstimate { param($IssueNumber) 2 }
function script:Get-CommitMessage { param($Diff, $FallbackMessage) $FallbackMessage }
function script:Test-RemoteBranch { param($Branch) $false }
function script:Update-Branch { $script:Log.Add('update'); [pscustomobject]@{ UpToDate = $true; Merged = $false; Conflicts = @() } }
function script:Invoke-Review { $script:Log.Add('review'); $true }
function script:Invoke-Ship { $script:Log.Add('ship'); $true }
function script:New-FeatureBranch { param($Number, $Title)
    $b = Get-BranchName -Number $Number -Title $Title; & $script:RealGit checkout -q -b $b; $b }
function script:uv { $global:LASTEXITCODE = 0; '1 passed' }
function script:gh {
    $global:LASTEXITCODE = 0
    $a = "$args"
    if ($a -like 'issue view*') { return '{"title":"Use protected files","labels":[],"state":"OPEN","body":"b"}' }
    if ($a -like 'pr list*')    { return '[]' }
    if ($a -like 'pr create*')  { $script:Log.Add('pr-create'); return 'https://x/pr/1' }
    return ''
}
function script:git {
    if ($args[0] -eq 'push')  { $script:Log.Add('push'); $global:LASTEXITCODE = 0; return }
    if ($args[0] -in @('fetch', 'reset', 'stash')) { $global:LASTEXITCODE = 0; return }
    & $script:RealGit @args
}
function script:claude {
    $script:Log.Add('engine')
    Remove-Item old.py        # the Bash `rm` the agent ran
    $script:Stream | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }
    $global:LASTEXITCODE = 0
}
"""


def test_a_refused_edit_ends_the_round_after_one_attempt(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "stream.json").write_text(json.dumps(_stream(repo)))
    _git(repo, "add", "stream.json")
    _git(repo, "commit", "-q", "-m", "fixture")

    out = _run(
        _CONDUCTOR
        + r"""
Invoke-Orchestration -IssueNumber 346 -MaxRetries 3
$pushed = & $script:RealGit log -1 --name-status --format=%s feature/346-use-protected-files
[pscustomobject]@{
    log      = @($script:Log)
    comments = @($script:Comments)
    reason   = $script:AttemptReason
    pushed   = ($pushed -join "`n")
} | ConvertTo-Json -Compress -Depth 5
""",
        cwd=repo,
    )

    record = next(c for c in out["comments"] if c.startswith("🤖 Implementation"))
    assert "`old.py` — deleted" in record
    assert "devcontainer" not in record
    assert "**Files changed (1):**" in record

    log = out["log"]
    assert log.count("engine") == 1, log
    assert log.count("attempt:implement:1") == 1, log
    assert "failed:implement" in log
    assert "failed-attempt" not in log
    assert "review" not in log and "pr-create" not in log and "ship" not in log
    assert "push" in log
    assert "\nD\told.py" in out["pushed"]
    assert ".devcontainer/devcontainer.json" in out["reason"]

    refusal = next(c for c in out["comments"] if "Engine refused an edit" in c)
    assert refusal.startswith("🤖")
    assert (
        "`.devcontainer/devcontainer.json` — the engine protects this path" in refusal
    )
    assert "feature/346-use-protected-files" in refusal
    assert "SECURITY.md#protected-paths" in refusal
    # Not the generic failure or retry comments.
    assert not any("Implement Failed" in c or "🤖🔁" in c for c in out["comments"])


# ── A merge conflict at the start of an attempt (#367) ────────────────────────


def _conflicted_repo(tmp_path: Path) -> Path:
    """On the issue's branch; origin/main changed keep.py's line and added a file."""
    repo = _repo(tmp_path)
    _git(repo, "checkout", "-q", "-b", "feature/346-use-protected-files")
    (repo / "keep.py").write_text("x = 'branch'\n")
    _git(repo, "commit", "-qam", "feat(#346): branch work")
    _git(repo, "checkout", "-q", "main")
    (repo / "keep.py").write_text("x = 'main'\n")
    (repo / "main_only.py").write_text("m = 1\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "chore: main moves on")
    _git(repo, "update-ref", "refs/remotes/origin/main", "main")
    _git(repo, "checkout", "-q", "feature/346-use-protected-files")
    return repo


# Real Update-Branch against the local origin/main; the agent's turn is $AgentTurn.
_MERGE_CONDUCTOR = (
    "\n".join(
        line
        for line in _CONDUCTOR.splitlines()
        if not line.startswith(("function script:Update-Branch", "$script:Stream"))
    )
    + r"""
function script:Test-RemoteBranch { param($Branch) $true }
function script:gh {
    $global:LASTEXITCODE = 0
    $a = "$args"
    if ($a -like 'issue view*') { return '{"title":"Use protected files","labels":[],"state":"OPEN","body":"b"}' }
    if ($a -like 'pr list*')    { if ($script:Log -contains 'pr-create') { return '[{"number":1,"url":"https://x/pr/1"}]' }; return '[]' }
    if ($a -like 'pr create*')  { $script:Log.Add('pr-create'); return 'https://x/pr/1' }
    return ''
}
$script:Pushes = [System.Collections.Generic.List[string]]::new()
function script:git {
    if ($args[0] -eq 'push')  { $script:Log.Add('push'); $script:Pushes.Add("$args"); $global:LASTEXITCODE = 0; return }
    if ($args[0] -in @('fetch', 'reset', 'stash')) { $global:LASTEXITCODE = 0; return }
    & $script:RealGit @args
}
function script:claude {
    $script:Log.Add('engine')
    $script:Prompt = "$input"
    & $script:AgentTurn
    @{ type = 'result'; subtype = 'success' } | ConvertTo-Json -Compress
    $global:LASTEXITCODE = 0
}
"""
)

_MERGE_REPORT = r"""
Invoke-Orchestration -IssueNumber 346 -MaxRetries 3
& $script:RealGit checkout -q feature/346-use-protected-files
[pscustomobject]@{
    log      = @($script:Log)
    comments = @($script:Comments)
    reason   = $script:AttemptReason
    prompt   = $script:Prompt
    pushes   = @($script:Pushes)
    merging  = (Test-Path .git/MERGE_HEAD)
    subjects = @(& $script:RealGit log --format=%s -3)
} | ConvertTo-Json -Compress -Depth 5
"""


def test_conflict_markers_left_end_the_round_after_one_attempt(tmp_path: Path) -> None:
    repo = _conflicted_repo(tmp_path)
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    out = _run(
        _MERGE_CONDUCTOR
        + "$script:AgentTurn = { }   # the agent leaves the markers\n"
        + _MERGE_REPORT,
        cwd=repo,
    )

    log = out["log"]
    assert log.count("engine") == 1, log
    assert log.count("attempt:implement:1") == 1, log
    assert "failed:implement" in log
    assert "failed-attempt" not in log  # recorded once, by implement
    assert "push" not in log and "review" not in log and "pr-create" not in log
    assert out["reason"] == "Conflict markers left in: keep.py"
    assert out["merging"] is False  # the merge was aborted
    head_after = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    assert head_after == head

    assert "MERGE CONFLICT" in out["prompt"] and "- keep.py" in out["prompt"]
    assert out["prompt"].index("MERGE CONFLICT") < out["prompt"].index("INSTRUCTIONS:")
    assert any(c.startswith("🤖⚠️ Merge conflict with main") for c in out["comments"])
    left = next(c for c in out["comments"] if "Conflict markers left" in c)
    assert left.startswith("🤖❌") and "`keep.py`" in left
    assert not any("Implement Failed" in c or "🤖🔁" in c for c in out["comments"])


def test_an_attempt_that_merged_main_lists_only_its_own_files(tmp_path: Path) -> None:
    repo = _conflicted_repo(tmp_path)

    out = _run(
        _MERGE_CONDUCTOR
        + r"""
$script:AgentTurn = {
    Set-Content -Path keep.py -Value "x = ('branch', 'main')"
    Set-Content -Path agent_own.py -Value 'a = 1'
}
"""
        + _MERGE_REPORT,
        cwd=repo,
    )

    record = next(c for c in out["comments"] if c.startswith("🤖 Implementation"))
    assert "`keep.py` — changed" in record
    assert "`agent_own.py` — added" in record
    assert "main_only.py" not in record
    assert "**Files changed (2):**" in record

    assert (
        out["subjects"][1]
        == "chore(#346): merge main into feature/346-use-protected-files"
    )
    assert out["merging"] is False
    assert "review" in out["log"] and "ship" in out["log"]
    assert "failed-attempt" not in out["log"]
    assert out["pushes"] and not any("force" in p for p in out["pushes"])


# ── Invoke-CommitAndPR -NoPR: the attempt's work reaches the branch ───────────


_NOPR = r"""
$script:Log      = [System.Collections.Generic.List[string]]::new()
$script:Comments = [System.Collections.Generic.List[string]]::new()
$script:RealGit  = (Get-Command git -CommandType Application | Select-Object -First 1).Source
function script:uv { $global:LASTEXITCODE = 0; '' }
function script:Add-Comment { param($Number, $Body) $script:Comments.Add($Body) }
function script:Test-RemoteBranch { param($Branch) $false }
function script:gh { if ($args[0] -eq 'pr') { $script:Log.Add('gh') }; $global:LASTEXITCODE = 0; '[]' }
function script:git {
    if ($args[0] -eq 'push')  { $script:Log.Add('push'); $global:LASTEXITCODE = 0; return }
    if ($args[0] -eq 'fetch') { $global:LASTEXITCODE = 0; return }
    & $script:RealGit @args
}
$r = Invoke-CommitAndPR -Number 346 -Title 't' -Branch 'feature/346-t' -NoPR
[pscustomobject]@{
    pushed   = [bool]$r.Pushed
    log      = @($script:Log)
    comments = @($script:Comments)
} | ConvertTo-Json -Compress
"""


@pytest.mark.parametrize("agent_committed", [True, False])
def test_no_pr_pushes_commits_the_agent_made_during_the_run(
    tmp_path: Path, agent_committed: bool
) -> None:
    repo = _repo(tmp_path)
    _git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    if agent_committed:
        # Nothing is staged after the run, but HEAD is ahead of the default branch.
        (repo / "keep.py").write_text("x = 2\n")
        _git(repo, "commit", "-qam", "agent committed by mistake")

    out = _run(_NOPR, cwd=repo)

    assert out["pushed"] is agent_committed
    assert ("push" in out["log"]) is agent_committed
    assert "gh" not in out["log"]  # no PR lookup or creation
    assert not any("Already Implemented" in c for c in out["comments"])


# ── Get-RefusedFiles: what the engine reports, nothing else ───────────────────


def _refused(events: list, root: str, cwd: Path) -> list:
    (cwd / "ev.json").write_text(json.dumps(events))
    out = _run(
        f"""
$ev = Get-Content -Raw ev.json | ConvertFrom-Json
[pscustomobject]@{{ files = @(Get-RefusedFiles -StreamEvents $ev -RepoRoot '{root}') }} | ConvertTo-Json -Compress
""",
        cwd=cwd,
    )
    return out["files"]


def _result(*denials: dict) -> dict:
    return {"type": "result", "permission_denials": list(denials)}


def test_only_refused_edits_count_and_paths_become_repo_relative(
    tmp_path: Path,
) -> None:
    events = [
        _result(
            {"tool_name": "Bash", "tool_input": {"command": "rm -rf .claude"}},
            {
                "tool_name": "Write",
                "tool_input": {"file_path": "/r/.vscode/settings.json"},
            },
            {
                "tool_name": "Edit",
                "tool_input": {"file_path": "/r/.vscode/settings.json"},
            },
            {
                "tool_name": "NotebookEdit",
                "tool_input": {"notebook_path": "/r/nb.ipynb"},
            },
            {"tool_name": "Edit", "tool_input": {"file_path": ".mcp.json"}},
        )
    ]
    assert _refused(events, "/r", tmp_path) == [
        ".vscode/settings.json",
        "nb.ipynb",
        ".mcp.json",
    ]


def test_no_result_event_or_no_denials_is_no_refusal(tmp_path: Path) -> None:
    prose = {
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": "The edit was refused."}]},
    }
    assert _refused([prose], "/r", tmp_path) == []
    assert _refused([prose, {"type": "result"}], "/r", tmp_path) == []
    assert _refused([_result()], "/r", tmp_path) == []


# ── Get-AttemptChangedFiles: the record comes from git ────────────────────────


def test_changed_files_come_from_git(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    base = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    # A commit made during the run, then uncommitted and untracked changes.
    (repo / "keep.py").write_text("x = 2\n")
    _git(repo, "commit", "-qam", "agent committed by mistake")
    _git(repo, "mv", "move_me.py", "moved.py")
    (repo / "old.py").unlink()
    (repo / "new.py").write_text("n = 1\n")

    out = _run(
        f"""
$files = @(Get-AttemptChangedFiles -BaseCommit '{base}')
[pscustomobject]@{{
    files   = @($files | ForEach-Object {{ "$($_.path)=$($_.change)" }})
    section = (Format-ChangedFiles -ChangedFiles $files)
}} | ConvertTo-Json -Compress
""",
        cwd=repo,
    )
    assert sorted(out["files"]) == [
        "keep.py=changed",
        "move_me.py=deleted",
        "moved.py=added",
        "new.py=added",
        "old.py=deleted",
    ]
    assert "**Files changed (5):**" in out["section"]
    assert "- `keep.py` — changed" in out["section"]


def test_nothing_changed_gives_no_section(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    out = _run(
        r"""
$base = git rev-parse HEAD
[pscustomobject]@{ section = (Format-ChangedFiles -ChangedFiles @(Get-AttemptChangedFiles -BaseCommit $base)) } | ConvertTo-Json -Compress
""",
        cwd=repo,
    )
    assert out["section"] == ""
