"""Tests for the ship stage's human-approval hold (.github/orchestrator/stages/Ship.ps1).

human:approval is a state the pipeline sets, like human:decision: ship decides it
from the PR's actual diff once CI is green. A PR touching a governance file is held
for the owner to merge; any other PR merges. The owner can still force a hold by
adding the label. Complete-HeldPR reconciles the issue on every feature-branch PR
close — a held PR the owner merged, or any other PR merged/closed outside the
pipeline entirely (e.g. a direct `gh pr merge`) — skipping only an issue already
agent:shipped. gh and git are in-memory fakes at module script scope.
"""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(body: str, cwd: Path | None = None) -> dict:
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
        cwd=str(cwd) if cwd else None,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def test_governance_files_are_matched_against_the_diff() -> None:
    out = _run(
        r"""
function script:gh { $global:LASTEXITCODE = 0
    'src/utils/m_version.py'; 'tests/utils/test_m_version.py'; '.github/workflows/stale.yml'; 'docs/adr/ADR-000-template-architecture-decision.md'; 'SECURITY.md' }
[pscustomobject]@{ files = @(Get-GovernanceFiles -PRNumber 9) } | ConvertTo-Json -Compress
"""
    )
    assert out["files"] == [
        ".github/workflows/stale.yml",
        "docs/adr/ADR-000-template-architecture-decision.md",
        "SECURITY.md",
    ]


# Invoke-Ship up to the merge: branch checkout, rebase and a green CI poll are faked.
_SHIP = r"""
$env:KANBAN_LOCAL_CI = $null
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:Labels = @()
function script:Get-IssueLabel { param($IssueNumber) $script:Labels }
function script:Test-HoldAnnounced { param($IssueNumber) $false }
$script:State = $null
function script:Get-IssueState { param($IssueNumber) $script:State }
function script:Invoke-RebaseOnMaster { param($IssueNumber, $Branch) }
function script:Set-IssueLabel { param($Number, $Add, $Remove) $script:Log.Add("label:+$Add") }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:" + ($Body -split "`n")[0]) }
function script:git { $global:LASTEXITCODE = 0; if ($args[0] -eq 'rev-parse') { 'feature/1-x' } }
function script:gh { $global:LASTEXITCODE = 0
    switch ($args[1]) {
        'view'   { 'feature/1-x' }
        'checks' { '[{"name":"test","bucket":"pass"}]' }
        'diff'   { $script:Diff }
        'merge'  { $script:Log.Add('merged') }
    } }
"""


def test_governance_change_is_held_after_green_ci(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/x.py', '.github/workflows/stale.yml')
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is False
    assert "merged" not in out["log"]
    # One pipeline label (#225): the hold replaces agent:reviewing.
    assert "state:human:approval" in out["log"]
    assert "state:agent:reviewing" not in out["log"]
    assert not any(e.startswith("label:") for e in out["log"])
    assert "comment:🤖⏸ Held for human approval" in out["log"]


def test_a_path_outside_the_allowlist_is_held_as_a_proposal(tmp_path: Path) -> None:
    """Taskfile.yml is outside WritablePaths and outside GovernancePaths. Before
    #285 that combination had no merge-time guard at all — staging blocked it, so
    the case never arose, but anything that did reach a PR would have auto-merged.
    Now the allowlist decides the merge, so it is held."""
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/x.py', 'Taskfile.yml')
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is False
    assert "merged" not in out["log"]
    assert "state:human:approval" in out["log"]
    assert "comment:🤖⏸ Held for human approval" in out["log"]


def test_the_hold_names_every_file_awaiting_approval(tmp_path: Path) -> None:
    """The owner is about to approve or reject these specific changes, so the
    comment has to list them — governance and out-of-allowlist alike."""
    out = _run(
        _SHIP
        + r"""
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:$Body") }
$script:Diff = @('src/x.py', 'Taskfile.yml', '.github/workflows/afk.yml')
$null = Invoke-Ship -IssueNumber 1 -PRNumber 9
$held = @($script:Log | Where-Object { $_ -like '*Held for human approval*' })[0]
[pscustomobject]@{
    taskfile = [bool]($held -match 'Taskfile\.yml')
    workflow = [bool]($held -match 'afk\.yml')
    boundary = [bool]($held -match "own boundary")
    src      = [bool]($held -match 'src/x\.py')
} | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["taskfile"] is True
    assert out["workflow"] is True
    # afk.yml redefines what the next PR may do — flagged, not just listed.
    assert out["boundary"] is True
    # src/x.py is inside the allowlist and not governed: not part of what is approved.
    assert out["src"] is False


def test_ordinary_change_merges(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/utils/m_version.py', 'tests/utils/test_m_version.py')
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is True
    assert "merged" in out["log"]
    assert "state:human:approval" not in out["log"]


def test_owner_label_still_forces_a_hold(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/x.py')
$script:Labels = @('human:approval')
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is False and "merged" not in out["log"]


def test_owner_hold_kept_in_the_carrier_still_forces_a_hold(tmp_path: Path) -> None:
    """The owner's label was replaced by a later state (#225); the carrier keeps it."""
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('src/x.py')
$script:State = [pscustomobject]@{ approval_required = $true }
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out["r"] is False and "merged" not in out["log"]
    assert "state:human:approval" in out["log"]


def test_announced_hold_is_not_repeated(tmp_path: Path) -> None:
    out = _run(
        _SHIP
        + r"""
$script:Diff = @('SECURITY.md')
$script:Labels = @('human:approval')
function script:Test-HoldAnnounced { param($IssueNumber) $true }
$r = Invoke-Ship -IssueNumber 1 -PRNumber 9
[pscustomobject]@{ r = $r; log = @($script:Log) } | ConvertTo-Json -Compress
""",
        tmp_path,
    )
    assert out == {"r": False, "log": []}


# Any feature-branch PR closes (afk.yml, pull_request closed).
_HELD = r"""
$script:Log = [System.Collections.Generic.List[string]]::new()
$script:Labels = @('human:approval')
function script:Get-IssueLabel { param($IssueNumber) $script:Log.Add("read:$IssueNumber"); $script:Labels }
function script:Set-IssueLabel { param($Number, $Add, $Remove) $script:Log.Add("label:-$Remove") }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Set-AgentFailedState { param($IssueNumber, $FailedAt, $Reason) $script:Log.Add("failed:$FailedAt") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:" + ($Body -split "`n")[0]) }
function script:git { $global:LASTEXITCODE = 0 }
"""


def _held(call: str, tmp_path: Path) -> list[str]:
    out = _run(
        _HELD
        + call
        + "\n[pscustomobject]@{ log = @($script:Log) } | ConvertTo-Json -Compress",
        tmp_path,
    )
    return out["log"]


def test_owner_merge_of_a_held_pr_ships_the_issue(tmp_path: Path) -> None:
    log = _held(
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $true", tmp_path
    )
    assert log == [
        "read:212",
        "state:agent:shipped",
        "comment:🤖✅ Merged",
    ]


def test_owner_close_of_a_held_pr_waits_for_their_comment(tmp_path: Path) -> None:
    log = _held(
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $false", tmp_path
    )
    assert "failed:review" in log
    assert "comment:🤖⏸ PR #9 closed without merging" in log
    assert "state:agent:shipped" not in log


def test_pr_merged_directly_without_going_through_ship_still_ships_the_issue(
    tmp_path: Path,
) -> None:
    """Regression: a PR merged by `gh pr merge` outside Invoke-Ship (no hold, issue
    still at agent:reviewing) must still reach agent:shipped — not be silently left
    at whatever label the review stage set (#252)."""
    log = _held(
        "$script:Labels = @('agent:reviewing')\n"
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $true",
        tmp_path,
    )
    assert log == [
        "read:212",
        "state:agent:shipped",
        "comment:🤖✅ Merged",
    ]


def test_already_shipped_issue_is_left_alone(tmp_path: Path) -> None:
    """Idempotency guard: Invoke-Ship's own in-process Complete-Ship almost always
    wins the race against this webhook handler — once the issue is shipped, the
    webhook handler is a no-op rather than double-shipping it."""
    shipped = _held(
        "$script:Labels = @('agent:shipped')\n"
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $true",
        tmp_path,
    )
    assert shipped == ["read:212"]
    foreign = _held(
        "Complete-HeldPR -PRNumber 9 -Branch 'dependabot/x' -Merged $true", tmp_path
    )
    assert foreign == []


def test_a_failed_issue_still_ships_when_its_pr_merges(tmp_path: Path) -> None:
    """Regression (#266): #223/#251/#256 all reached agent:failed from the
    pipeline's own blocked attempts, were fixed hands-on, and merged on the
    matching branch — agent:failed must NOT skip reconciliation, or the merge
    that should ship the issue leaves it stuck at agent:failed forever."""
    log = _held(
        "$script:Labels = @('agent:failed')\n"
        "Complete-HeldPR -PRNumber 9 -Branch 'feature/212-x' -Merged $true",
        tmp_path,
    )
    assert log == [
        "read:212",
        "state:agent:shipped",
        "comment:🤖✅ Merged",
    ]


# ── After the merge: no commit, no push, no model call (#349) ──────────────────
# Every change reaches the default branch through a PR. Complete-Ship sets
# agent:shipped and posts the signal comment, then returns — it never switches or
# syncs the default branch, commits, pushes, or asks a model to patch CONTEXT.md.
# git, gh and both engine CLIs are recorded, not faked into success-only no-ops.
_RECORDED = r"""
$script:Log   = [System.Collections.Generic.List[string]]::new()
$script:Calls = [System.Collections.Generic.List[string]]::new()
$env:KANBAN_LOCAL_CI = $null
$script:Labels = @('agent:reviewing')
function script:Get-IssueLabel { param($IssueNumber) $script:Labels }
function script:Test-HoldAnnounced { param($IssueNumber) $false }
function script:Get-IssueState { param($IssueNumber) $null }
function script:Invoke-RebaseOnMaster { param($IssueNumber, $Branch) }
function script:Set-AgentState { param($IssueNumber, $Label) $script:Log.Add("state:$Label") }
function script:Set-AgentFailedState { param($IssueNumber, $FailedAt, $Reason) $script:Log.Add("failed:$FailedAt") }
function script:Add-Comment { param($Number, $Body) $script:Log.Add("comment:" + ($Body -split "`n")[0]) }
function script:git    { $script:Calls.Add('git ' + ($args -join ' ')); $global:LASTEXITCODE = 0; if ($args[0] -eq 'rev-parse') { 'feature/1-x' } }
function script:claude { $script:Calls.Add('claude ' + ($args -join ' ')); $global:LASTEXITCODE = 0; 'NO_CHANGES' }
function script:agy    { $script:Calls.Add('agy ' + ($args -join ' '));    $global:LASTEXITCODE = 0; 'NO_CHANGES' }
function script:gemini { $script:Calls.Add('gemini ' + ($args -join ' ')); $global:LASTEXITCODE = 0; 'NO_CHANGES' }
function script:gh { $script:Calls.Add('gh ' + ($args -join ' ')); $global:LASTEXITCODE = 0
    switch ($args[1]) {
        'view'   { 'feature/1-x' }
        'checks' { '[{"name":"test","bucket":"pass"}]' }
        'diff'   { 'src/x.py' }
        'merge'  { $script:Log.Add('merged') }
    } }
"""


def _after_merge(call: str, tmp_path: Path) -> tuple[list[str], list[str], list[str]]:
    """Run `call`; return (log, git calls after the merge, model CLI calls)."""
    out = _run(
        _RECORDED
        + call
        + "\n[pscustomobject]@{ log = @($script:Log); calls = @($script:Calls) }"
        " | ConvertTo-Json -Compress",
        tmp_path,
    )
    calls = out["calls"]
    merge = next((i for i, c in enumerate(calls) if c.startswith("gh pr merge")), -1)
    after = calls[merge + 1 :]
    git_after = [c for c in after if c.startswith("git ")]
    models = [c for c in calls if c.split(" ", 1)[0] in {"claude", "agy", "gemini"}]
    return out["log"], git_after, models


_FORBIDDEN_GIT = ("commit", "push", "checkout", "switch", "pull", "reset", "fetch")


@pytest.mark.parametrize(
    "call",
    [
        pytest.param("Invoke-Ship -IssueNumber 1 -PRNumber 9 | Out-Null", id="ship"),
        pytest.param(
            "Complete-HeldPR -PRNumber 9 -Branch 'feature/1-x' -Merged $true",
            id="held-pr-merged",
        ),
    ],
)
def test_after_a_merge_ship_makes_no_commit_no_push_and_no_model_call(
    call: str, tmp_path: Path
) -> None:
    log, git_after, models = _after_merge(call, tmp_path)
    assert "state:agent:shipped" in log
    assert "comment:🤖✅ Merged" in log
    forbidden = [c for c in git_after if c.split(" ")[1] in _FORBIDDEN_GIT]
    assert forbidden == [], forbidden
    assert models == [], models


# ── Test-IssueShipped: the one rule, called by afk.yml's cheap pre-check AND by
# Complete-HeldPR itself (#275) — not two hand-synced copies of the same logic. ──


def test_issue_shipped_is_true_only_for_agent_shipped() -> None:
    def shipped(labels: list[str]) -> bool:
        array = ", ".join(f"'{label}'" for label in labels)
        out = _run(
            f"function script:Get-IssueLabel {{ param($IssueNumber) @({array}) }}\n"
            "[pscustomobject]@{ r = (Test-IssueShipped -IssueNumber 212) } | ConvertTo-Json -Compress"
        )
        return out["r"]

    assert shipped(["agent:shipped"]) is True
    assert shipped(["agent:failed"]) is False
    assert shipped(["agent:reviewing"]) is False
    assert shipped([]) is False


# ── Local CI (#314): when GitHub Actions cannot run, ship runs checks.yml's jobs
# itself and always leaves the merge to the owner. ──

_LOCAL_CI = r"""
$env:KANBAN_LOCAL_CI = '1'
$script:ChecksPolled = $false
function script:gh { $global:LASTEXITCODE = 0
    switch ($args[1]) {
        'view'   { 'feature/1-x' }
        'checks' { $script:ChecksPolled = $true; '[{"name":"test","bucket":"fail"}]' }
        'diff'   { $script:Diff }
        'merge'  { $script:Log.Add('merged') }
    } }
"""


def _local_ship(tmp_path: Path, jobs: str) -> dict:
    return _run(
        _SHIP
        + _LOCAL_CI
        + "function script:Invoke-LocalCI { "
        + jobs
        + " }\n"
        + r"""
$script:Diff = @('src/x.py', 'tests/test_x.py')
try { $r = Invoke-Ship -IssueNumber 1 -PRNumber 9 } catch { $r = "threw: $_" }
[pscustomobject]@{ r = "$r"; log = @($script:Log); polled = $script:ChecksPolled } | ConvertTo-Json -Compress
""",
        tmp_path,
    )


def test_local_ci_pass_holds_even_a_writable_only_pr(tmp_path: Path) -> None:
    out = _local_ship(
        tmp_path,
        "[pscustomobject]@{ Name = 'lint'; ExitCode = 0; Tail = '' };"
        " [pscustomobject]@{ Name = 'test'; ExitCode = 0; Tail = '' }",
    )
    assert out["r"] == "False"
    assert "merged" not in out["log"]
    assert "state:human:approval" in out["log"]
    assert "comment:🤖✅ Local CI passed" in out["log"]
    assert out["polled"] is False


def test_local_ci_failure_posts_ci_failed_and_throws(tmp_path: Path) -> None:
    out = _local_ship(
        tmp_path,
        "[pscustomobject]@{ Name = 'lint'; ExitCode = 0; Tail = '' };"
        " [pscustomobject]@{ Name = 'test'; ExitCode = 1; Tail = '1 failed' }",
    )
    assert out["r"].startswith("threw: CI checks failed for PR #9: test")
    assert "comment:🤖❌ CI Failed" in out["log"]
    assert "state:human:approval" not in out["log"]
    assert out["polled"] is False


def test_local_ci_runs_every_uv_command_checks_yml_runs() -> None:
    """The local job list mirrors checks.yml; a command added there must be added here."""
    workflow = (
        Path(__file__).parents[2] / ".github" / "workflows" / "checks.yml"
    ).read_text(encoding="utf-8")
    ci = set()
    for job in ("lint", "typecheck", "test", "audit"):
        body = re.search(
            rf"^  {job}:\n(.*?)(?=^  [\w-]+:\n|\Z)", workflow, re.MULTILINE | re.DOTALL
        )
        assert body, job
        ci |= {c.strip() for c in re.findall(r"run:\s*(uv run .+)", body.group(1))}
    out = _run(
        "[pscustomobject]@{ jobs = @($LocalCiJobs.Values | ForEach-Object { $_ -join ' ' }) }"
        " | ConvertTo-Json -Compress"
    )
    assert ci, "no uv run commands found in checks.yml"
    assert ci <= set(out["jobs"]), ci - set(out["jobs"])
