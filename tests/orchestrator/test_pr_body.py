"""A pull request's text comes from the pull request template (#375).

- lib/Util.ps1 — Format-PullRequestBody fills the template's sections with the round's
  facts, drops every comment and ends on `Closes #<N>`; Get-PullRequestTemplate and
  Format-PullRequestBody stop on a missing template, a section they cannot fill and a
  missing `Closes #` line.
- stages/Implement.ps1 — Invoke-CommitAndPR checks the template before anything is
  committed, and a later round rewrites the description of the open pull request.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
ROOT = Path(__file__).parents[2]
MODULE = ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
TEMPLATE = ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md"
SECTIONS = ["Summary", "Left undone", "Issues discovered", "Validation"]

pytestmark = pytest.mark.skipif(
    not (shutil.which("pwsh") and shutil.which("git")),
    reason="pwsh or git not available",
)


def _pwsh(body: str, cwd: Path) -> subprocess.CompletedProcess:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        f"{body}\n"
        "}\n"
    )
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
        cwd=cwd,
    )


def _run(body: str, cwd: Path) -> dict:
    result = _pwsh(body, cwd)
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _build(template: str, tmp_path: Path, commands: str) -> dict:
    (tmp_path / "template.md").write_text(template, encoding="utf-8")
    return _run(
        rf"""
try {{
    $body = Format-PullRequestBody -Template (Get-Content -Raw template.md) -Number 375 `
        -Implemented 'Added the template' -LeftUndone 'the eval' `
        -IssuesDiscovered 'delete the variable FOO' -Commands @({commands})
    [pscustomobject]@{{ body = $body; error = '' }} | ConvertTo-Json -Compress
}} catch {{
    [pscustomobject]@{{ body = ''; error = "$_" }} | ConvertTo-Json -Compress
}}
""",
        cwd=tmp_path,
    )


_TWO_COMMANDS = (
    "[pscustomobject]@{ Name = 'pytest'; Exit = 0 }, "
    "[pscustomobject]@{ Name = 'git push'; Exit = 0 }"
)


def _section(body: str, name: str) -> str:
    """The text under `## <name>`, up to the next heading or the Closes line."""
    lines = body.splitlines()
    start = lines.index(f"## {name}") + 1
    out = []
    for line in lines[start:]:
        if line.startswith(("## ", "Closes #")):
            break
        out.append(line)
    return "\n".join(out).strip()


# ── The tracer bullet: the real template, a closing note, two commands ────────


def test_each_fact_sits_under_its_section_in_template_order(tmp_path: Path) -> None:
    out = _build(TEMPLATE.read_text(encoding="utf-8"), tmp_path, _TWO_COMMANDS)
    assert out["error"] == ""
    body = out["body"]

    headings = [line[3:] for line in body.splitlines() if line.startswith("## ")]
    assert headings == SECTIONS
    assert _section(body, "Summary") == "Added the template"
    assert _section(body, "Left undone") == "the eval"
    assert _section(body, "Issues discovered") == "delete the variable FOO"
    assert _section(body, "Validation") == "- `pytest` → 0\n- `git push` → 0"
    assert "<!--" not in body and "-->" not in body
    assert body.rstrip().splitlines()[-1] == "Closes #375"
    assert body.count("Closes #") == 1


def test_empty_facts_become_none(tmp_path: Path) -> None:
    (tmp_path / "template.md").write_text(TEMPLATE.read_text(encoding="utf-8"))
    out = _run(
        r"""
$body = Format-PullRequestBody -Template (Get-Content -Raw template.md) -Number 7
[pscustomobject]@{ body = $body } | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    for name in SECTIONS:
        assert _section(out["body"], name) == "none"


def test_a_multi_line_comment_is_left_out(tmp_path: Path) -> None:
    template = (
        "<!--\nline one\nline two\n-->\n\n## Summary\n<!-- a\nb -->\n\nCloses #\n"
    )
    out = _build(template, tmp_path, "")
    assert out["error"] == ""
    assert out["body"] == "## Summary\n\nAdded the template\n\nCloses #375"


# ── The stops ─────────────────────────────────────────────────────────────────


def test_a_missing_template_stops_naming_the_file(tmp_path: Path) -> None:
    out = _run(
        rf"""
try {{ $null = Get-PullRequestTemplate -Root '{tmp_path}'; $e = '' }} catch {{ $e = "$_" }}
[pscustomobject]@{{ error = $e }} | ConvertTo-Json -Compress
""",
        cwd=tmp_path,
    )
    assert ".github/PULL_REQUEST_TEMPLATE.md" in out["error"]
    assert "missing" in out["error"]


def test_a_section_it_cannot_fill_stops_naming_the_section(tmp_path: Path) -> None:
    template = TEMPLATE.read_text(encoding="utf-8").replace(
        "## Validation", "## Extra\n<!-- x -->\n\n## Validation"
    )
    out = _build(template, tmp_path, _TWO_COMMANDS)
    assert out["body"] == ""
    assert "'Extra'" in out["error"]
    assert ".github/PULL_REQUEST_TEMPLATE.md" in out["error"]


def test_a_template_without_a_closes_line_stops(tmp_path: Path) -> None:
    template = TEMPLATE.read_text(encoding="utf-8").replace("Closes #", "")
    out = _build(template, tmp_path, _TWO_COMMANDS)
    assert out["body"] == ""
    assert "Closes #" in out["error"]


# ── Invoke-CommitAndPR: the description on every round ────────────────────────


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
    _git(repo, "checkout", "-q", "-b", "feature/375-t")
    return repo


# $script:PrExists says whether `gh pr list` finds an open pull request.
_COMMIT = r"""
$script:Log      = [System.Collections.Generic.List[string]]::new()
$script:Bodies   = [System.Collections.Generic.List[string]]::new()
$script:RealGit  = (Get-Command git -CommandType Application | Select-Object -First 1).Source
function script:uv { $global:LASTEXITCODE = 0; '' }
function script:Add-Comment { param($Number, $Body) }
function script:Get-CommitMessage { param($Diff, $FallbackMessage) $FallbackMessage }
function script:gh {
    $global:LASTEXITCODE = 0
    $a = "$args"
    $i = [array]::IndexOf($args, '--body-file')
    if ($i -ge 0) { $script:Bodies.Add((Get-Content -Raw $args[$i + 1])) }
    if ($a -like 'pr list*')   { if ($script:PrExists) { return '[{"url":"https://x/pr/1"}]' }; return '[]' }
    if ($a -like 'pr create*') { $script:Log.Add('pr-create'); return 'https://x/pr/1' }
    if ($a -like 'pr edit*')   { $script:Log.Add("pr-edit:$($args[2])"); return '' }
    return ''
}
function script:git {
    if ($args[0] -eq 'push')   { $script:Log.Add('push'); $global:LASTEXITCODE = 0; return }
    if ($args[0] -eq 'commit') { $script:Log.Add('commit') }
    if ($args[0] -eq 'fetch')  { $global:LASTEXITCODE = 0; return }
    & $script:RealGit @args
}
function Invoke-Round { param($Implemented, $Exit)
    Invoke-CommitAndPR -Number 375 -Title 't' -Branch 'feature/375-t' `
        -Implemented $Implemented -LeftUndone 'none' -IssuesDiscovered 'none' `
        -PriorCommands @([pscustomobject]@{ Name = 'pytest'; Exit = $Exit })
}
"""


def test_a_second_round_rewrites_the_description(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    out = _run(
        _COMMIT
        + r"""
$script:PrExists = $false
Set-Content keep.py 'x = 2'
$first = Invoke-Round -Implemented 'first round' -Exit 0
$script:PrExists = $true
Set-Content keep.py 'x = 3'
$second = Invoke-Round -Implemented 'second round' -Exit 5
[pscustomobject]@{
    log    = @($script:Log)
    bodies = @($script:Bodies)
    urls   = @($first.PrUrl, $second.PrUrl)
} | ConvertTo-Json -Compress
""",
        cwd=repo,
    )
    log = out["log"]
    assert log.count("pr-create") == 1, log
    assert "pr-edit:https://x/pr/1" in log, log
    assert log.index("pr-create") < log.index("pr-edit:https://x/pr/1")
    assert out["urls"] == ["https://x/pr/1", "https://x/pr/1"]

    first, second = out["bodies"]
    assert _section(first, "Summary") == "first round"
    assert _section(second, "Summary") == "second round"
    validation = _section(second, "Validation").splitlines()
    assert validation == [
        "- `pytest` → 5",
        "- `ruff` → 0",
        "- `git commit` → 0",
        "- `git push` → 0",
    ]
    assert second.rstrip().splitlines()[-1] == "Closes #375"


def test_a_broken_template_stops_before_any_commit_or_push(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    out = _run(
        _COMMIT
        + r"""
function script:Get-PullRequestTemplate { "## Summary`n## Extra`nCloses #" }
Set-Content keep.py 'x = 2'
try { $null = Invoke-Round -Implemented 'x' -Exit 0; $e = '' } catch { $e = "$_" }
[pscustomobject]@{
    log    = @($script:Log)
    error  = $e
    staged = "$(& $script:RealGit diff --cached --name-only)"
} | ConvertTo-Json -Compress
""",
        cwd=repo,
    )
    assert "'Extra'" in out["error"]
    assert out["log"] == []  # no commit, no push, no PR
    assert out["staged"] == ""


def test_no_pr_does_not_read_the_template(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    out = _run(
        _COMMIT
        + r"""
function script:Get-PullRequestTemplate { throw 'read' }
Set-Content keep.py 'x = 2'
$r = Invoke-CommitAndPR -Number 375 -Title 't' -Branch 'feature/375-t' -NoPR
[pscustomobject]@{ log = @($script:Log); pushed = [bool]$r.Pushed } | ConvertTo-Json -Compress
""",
        cwd=repo,
    )
    assert out["pushed"] is True
    assert out["log"] == ["commit", "push"]
