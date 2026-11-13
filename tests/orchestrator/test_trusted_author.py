"""The pipeline acts only on issues opened by a trusted author (#312).

It runs with the owner's tokens, so on a public repository a stranger's issue must
never reach refine or implement — whichever entry point the run came through. gh is
an in-memory fake at module script scope.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(association: str, exit_code: int = 0, from_: str = "refine") -> dict:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        "$script:engine = $false; $script:labels = @(); $script:comments = @()\n"
        "function script:Assert-EngineReady { $script:engine = $true; throw 'stop' }\n"
        "function script:Set-AgentState { param($IssueNumber, $Label) $script:labels += $Label }\n"
        "function script:Add-Comment { param($Number, $Body) $script:comments += $Body }\n"
        f"function script:gh {{ $global:LASTEXITCODE = {exit_code}; '{association}' }}\n"
        "$trusted = Test-TrustedAuthor -IssueNumber 7\n"
        f"try {{ $r = Invoke-Orchestration -From {from_} -IssueNumber 7 }} catch {{ $r = 'ran' }}\n"
        '[pscustomobject]@{ trusted = $trusted; result = "$r"; engine = $script:engine;\n'
        "  labels = @($script:labels); comments = @($script:comments) } | ConvertTo-Json -Compress\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def test_an_outsiders_issue_is_refused_before_the_engine_runs() -> None:
    out = _run("NONE")
    assert out["trusted"] is False
    assert out["result"] == "False"
    assert out["engine"] is False
    assert out["labels"] == []
    assert out["comments"] == []


def test_an_owner_comment_on_an_outsiders_issue_says_why_nothing_happens() -> None:
    out = _run("CONTRIBUTOR", from_="comment")
    assert out["engine"] is False
    assert out["comments"] == [
        "· not processed — opened by an outside contributor; open your own issue to adopt it"
    ]


def test_an_unreadable_author_is_untrusted() -> None:
    assert _run("OWNER", exit_code=1)["trusted"] is False


def test_the_owners_issue_goes_on_to_the_engine() -> None:
    out = _run("OWNER")
    assert out["trusted"] is True
    assert out["engine"] is True
