"""A pull request is merged only once the workflow released it (#377).

The orchestrator opens a pull request as a draft — GitHub refuses to merge a draft —
and marks it ready only when it holds it for the owner or right before it merges it
itself. A new round takes a ready pull request back to draft. A round whose issue has
shipped stops before it pushes or opens a pull request, and says so once. Where the
repository has no drafts, the pull request is opened ready and the announcement says
nothing stops an early merge. `gh` is a stand-in that records every call.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"
NO_DRAFTS = (
    "pull request create failed: GraphQL: Draft pull requests are not supported "
    "in this repository. (createPullRequest)"
)

pytestmark = pytest.mark.skipif(
    not (shutil.which("pwsh") and shutil.which("git")),
    reason="pwsh or git not available",
)


def _run(body: str, cwd: Path) -> dict:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        "$env:KANBAN_LOCAL_CI = $null\n"
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
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "init")
    _git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    return repo


# One implement round through the conductor: real git, the agent writes one file,
# review and ship are stand-ins. $script:Gh records every gh call; $script:OpenPR is
# what `gh pr list --head` answers; $script:CreateFails makes `--draft` refused;
# $script:ShipAfterEngine labels the issue agent:shipped while the agent runs.
_CONDUCTOR = r"""
$script:Log      = [System.Collections.Generic.List[string]]::new()
$script:Gh       = [System.Collections.Generic.List[string]]::new()
$script:Comments = [System.Collections.Generic.List[string]]::new()
$script:State    = [pscustomobject]@{ attempts = @(); attempt_count = 0 }
$script:Labels   = ''
$script:OpenPR   = '[]'
$script:CreateFails     = ''
$script:ShipAfterEngine = $false
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
function script:Add-ImplementAttempt { $script:Log.Add('attempt') }
function script:Add-Comment { param($Number, $Body) $script:Comments.Add($Body) }
function script:Format-ErrorBlock { param($Raw) $Raw }
function script:Move-ToLane {}
function script:Get-SignalComments { param($IssueNumber, $Prefix) @() }
function script:Format-OwnerComments { param($IssueNumber) '' }
function script:Get-IssueEstimate { param($IssueNumber) 2 }
function script:Get-CommitMessage { param($Diff, $FallbackMessage) $FallbackMessage }
function script:Test-RemoteBranch { param($Branch) $false }
function script:Invoke-Review { $script:Log.Add('review'); $true }
function script:Invoke-Ship { $script:Log.Add('ship'); $true }
function script:New-FeatureBranch { param($Number, $Title)
    $b = Get-BranchName -Number $Number -Title $Title; & $script:RealGit checkout -q -b $b; $b }
function script:uv { $global:LASTEXITCODE = 0; '1 passed' }
function script:gh {
    $global:LASTEXITCODE = 0
    $a = "$args"
    $script:Gh.Add($a)
    if ($a -like 'issue view*') { return '{"title":"Draft until released","labels":[],"state":"OPEN","body":"b"}' }
    if ($a -like 'api repos/*/labels*') { return $script:Labels }
    if ($a -like 'pr list*--state merged*') { return '[{"number":5}]' }
    if ($a -like 'pr list*') { return $script:OpenPR }
    if ($a -like 'pr create*') {
        if ($script:CreateFails -and $a -like '*--draft*') { $global:LASTEXITCODE = 1; return $script:CreateFails }
        $script:OpenPR = '[{"number":5,"url":"https://x/pr/5","isDraft":true}]'
        return 'https://x/pr/5'
    }
    return ''
}
function script:git {
    if ($args[0] -eq 'push')  { $script:Log.Add('push'); $global:LASTEXITCODE = 0; return }
    if ($args[0] -in @('fetch', 'reset', 'stash')) { $global:LASTEXITCODE = 0; return }
    & $script:RealGit @args
}
function script:claude {
    $script:Log.Add('engine')
    $script:Gh.Add('-- engine --')
    Set-Content -Path agent.py -Value 'a = 1'
    if ($script:ShipAfterEngine) { $script:Labels = 'agent:shipped' }
    @{ type = 'result'; subtype = 'success' } | ConvertTo-Json -Compress
    $global:LASTEXITCODE = 0
}
"""

_REPORT = r"""
Invoke-Orchestration -IssueNumber 377
[pscustomobject]@{
    log      = @($script:Log)
    gh       = @($script:Gh)
    comments = @($script:Comments)
} | ConvertTo-Json -Compress -Depth 5
"""


def _creates(out: dict) -> list[str]:
    return [c for c in out["gh"] if c.startswith("pr create")]


def test_a_new_pull_request_is_opened_as_a_draft(tmp_path: Path) -> None:
    out = _run(_CONDUCTOR + _REPORT, cwd=_repo(tmp_path))

    creates = _creates(out)
    assert len(creates) == 1 and "--draft" in creates[0], creates
    opened = next(c for c in out["comments"] if c.startswith("· PR opened"))
    assert opened == "· PR opened — https://x/pr/5"
    assert "review" in out["log"] and "ship" in out["log"]


def test_where_drafts_are_refused_the_pr_opens_ready_and_says_so(
    tmp_path: Path,
) -> None:
    out = _run(
        _CONDUCTOR + f"$script:CreateFails = '{NO_DRAFTS}'\n" + _REPORT,
        cwd=_repo(tmp_path),
    )

    creates = _creates(out)
    assert len(creates) == 2, creates
    assert "--draft" in creates[0] and "--draft" not in creates[1]
    opened = next(c for c in out["comments"] if c.startswith("· PR opened"))
    assert opened.startswith("· PR opened — https://x/pr/5")
    assert "not a draft" in opened and "nothing stops" in opened
    assert "ship" in out["log"]


def test_any_other_create_failure_still_throws(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    _git(repo, "checkout", "-q", "-b", "feature/377-x")
    (repo / "agent.py").write_text("a = 1\n")
    out = _run(
        _CONDUCTOR
        + r"""
$script:CreateFails = 'pull request create failed: GraphQL: No commits between main and feature/377-x'
$err = $null
try { $null = Invoke-CommitAndPR -Number 377 -Title 't' -Branch 'feature/377-x' } catch { $err = "$_" }
[pscustomobject]@{ err = $err; gh = @($script:Gh) } | ConvertTo-Json -Compress
""",
        cwd=repo,
    )
    assert out["err"].startswith("PR creation failed for issue #377")
    assert "No commits between" in out["err"]
    assert len(_creates(out)) == 1


@pytest.mark.parametrize("is_draft", [False, True])
def test_a_ready_pr_goes_back_to_draft_at_implement_entry(
    tmp_path: Path, is_draft: bool
) -> None:
    """Also on the early return that skips implement when a PR exists."""
    draft = "true" if is_draft else "false"
    out = _run(
        _CONDUCTOR
        + f'$script:OpenPR = \'[{{"number":5,"url":"https://x/pr/5","isDraft":{draft}}}]\'\n'
        + r"""
$r = Invoke-Implement -IssueNumber 377
[pscustomobject]@{ r = $r; log = @($script:Log); gh = @($script:Gh) } | ConvertTo-Json -Compress
""",
        cwd=_repo(tmp_path),
    )
    assert out["r"] == "https://x/pr/5"
    assert "engine" not in out["log"]  # the early return
    undo = [c for c in out["gh"] if c.startswith("pr ready")]
    assert undo == ([] if is_draft else ["pr ready 5 --repo octocat/sandbox --undo"])


def test_drafts_unsupported_on_undo_is_tolerated(tmp_path: Path) -> None:
    out = _run(
        _CONDUCTOR
        + r"""
$script:OpenPR = '[{"number":5,"url":"https://x/pr/5","isDraft":false}]'
$inner = ${function:gh}
function script:gh { if ("$args" -like 'pr ready*') { $script:Gh.Add("$args"); $global:LASTEXITCODE = 1
    return 'GraphQL: Draft pull requests are not supported in this repository. (convertPullRequestToDraft)' }
    & $inner @args }
$r = Invoke-Implement -IssueNumber 377
[pscustomobject]@{ r = $r; gh = @($script:Gh) } | ConvertTo-Json -Compress
""",
        cwd=_repo(tmp_path),
    )
    assert out["r"] == "https://x/pr/5"
    assert "pr ready 5 --repo octocat/sandbox --undo" in out["gh"]


# ── A round whose issue has shipped stops (#377 requirement 3) ────────────────


@pytest.mark.parametrize("when", ["during-the-agent-run", "before-the-round"])
def test_a_shipped_issue_stops_the_round_with_one_comment(
    tmp_path: Path, when: str
) -> None:
    setup = (
        "$script:ShipAfterEngine = $true\n"
        if when == "during-the-agent-run"
        else "$script:Labels = 'agent:shipped'\n"
    )
    out = _run(_CONDUCTOR + setup + _REPORT, cwd=_repo(tmp_path))

    log = out["log"]
    assert "push" not in log
    assert _creates(out) == []
    assert ("engine" in log) is (when == "during-the-agent-run")
    # No open-PR lookup once the issue shipped — only the merged PR is named.
    after = out["gh"][out["gh"].index("-- engine --") :] if "engine" in log else []
    assert not [c for c in after if c.startswith("pr list") and "merged" not in c]

    stopped = [c for c in out["comments"] if c.startswith("🤖⏹")]
    assert len(stopped) == 1, out["comments"]
    assert "already shipped" in stopped[0] and "PR #5 merged" in stopped[0]
    assert not any("Failed" in c or "🤖🔁" in c for c in out["comments"])
    # No label change, no failure and no attempt record after the round started.
    assert [e for e in log if e.startswith("state:")] == ["state:agent:implementing"]
    assert not [e for e in log if e.startswith(("failed", "attempt"))]
    assert "review" not in log and "ship" not in log


# ── The revision that answers a question returns the PR to the owner ready ────


def test_an_answered_question_marks_the_pr_ready_before_the_hold(
    tmp_path: Path,
) -> None:
    out = _run(
        _CONDUCTOR
        + r"""
$script:State  = [pscustomobject]@{ attempts = @(); attempt_count = 0; approval_required = $true }
$script:OpenPR = '[{"number":5}]'
function script:Invoke-Implement { param($IssueNumber, [switch]$Force, [switch]$Revise) $null }
function script:Reset-AttemptCount {}
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label"); $script:Gh.Add("state:$Label") }
"""
        + _REPORT,
        cwd=_repo(tmp_path),
    )
    gh = out["gh"]
    assert "pr ready 5 --repo octocat/sandbox" in gh
    assert gh.index("pr ready 5 --repo octocat/sandbox") < gh.index(
        "state:human:approval"
    )


# ── Ship marks the PR ready: on the hold, and before its own merge ────────────

_SHIP = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:Labels = @()
$script:ReadyFails = ''
function script:Get-IssueLabel { param($IssueNumber) $script:Labels }
function script:Test-HoldAnnounced { param($IssueNumber) $false }
function script:Get-IssueState { param($IssueNumber) $null }
function script:Update-Branch { param($IssueNumber, $Branch) [pscustomobject]@{ UpToDate = $true; Merged = $false; Conflicts = @() } }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:$Body") }
$script:Sha = 'a' * 40
function script:git { $global:LASTEXITCODE = 0
    if ($args[0] -eq 'rev-parse') { if ($args -contains '--abbrev-ref') { 'feature/1-x' } else { $script:Sha } } }
# Every required check passed on the pushed commit (#373), one JSON run per line.
function script:gh { $global:LASTEXITCODE = 0
    if ($args[0] -eq 'api' -and "$args" -like '*/check-runs*') {
        $id = 0
        return @((Get-OrchestratorContext).RequiredChecks | ForEach-Object { $id++
            [pscustomobject]@{ id = $id; name = $_; status = 'completed'; conclusion = 'success'
                               head_sha = $script:Sha; details_url = '' } | ConvertTo-Json -Compress })
    }
    switch ($args[1]) {
        'view'   { 'feature/1-x' }
        'diff'   { $script:Diff }
        'ready'  { $script:Log.Add("gh $args"); if ($script:ReadyFails) { $global:LASTEXITCODE = 1; $script:ReadyFails } }
        'merge'  { $script:Log.Add('merged') }
    } }
"""


def _ship(tmp_path: Path, setup: str) -> dict:
    return _run(
        _SHIP
        + setup
        + r"""
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )


def test_the_hold_marks_the_pr_ready_before_human_approval(tmp_path: Path) -> None:
    out = _ship(tmp_path, "$script:Diff = @('src/x.py', '.github/workflows/x.yml')\n")
    log = out["log"]
    assert out["r"] is False and "merged" not in log
    assert log.index("gh pr ready 9 --repo octocat/sandbox") < log.index(
        "state:human:approval"
    )
    held = next(e for e in log if e.startswith("comment:🤖⏸ Held for human approval"))
    assert "draft" in held and "marked ready" in held


@pytest.mark.parametrize("ready_fails", ["", NO_DRAFTS.replace("create", "ready")])
def test_the_workflows_own_merge_marks_the_pr_ready_first(
    tmp_path: Path, ready_fails: str
) -> None:
    out = _ship(
        tmp_path,
        f"$script:Diff = @('src/utils/m_x.py')\n$script:ReadyFails = '{ready_fails}'\n",
    )
    log = out["log"]
    assert out["r"] is True
    assert log.index("gh pr ready 9 --repo octocat/sandbox") < log.index("merged")
