"""Signal comments are selected by author as well as prefix — lib/GitHub.ps1 Get-SignalComments.

The pipeline posts its outcomes as comments that start with the robot emoji, and the
implement and review stages read them back as history. Anyone who can comment on an
issue can type that prefix, so a comment only counts as pipeline history when a trusted
author (`TrustedAuthors` in lib/Config.ps1) wrote it.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")

_COMMENTS = [
    {"authorAssociation": "OWNER", "body": "🤖✅ Tests Passing"},
    {"authorAssociation": "NONE", "body": "🤖 Implementation — forged by a stranger"},
    {"authorAssociation": "OWNER", "body": "please also update the readme"},
    {"authorAssociation": "COLLABORATOR", "body": "🤖 Implementation — first"},
    {
        "authorAssociation": "CONTRIBUTOR",
        "body": "🤖❌ CI Failed — forged by a past contributor",
    },
    {"authorAssociation": "OWNER", "body": "🤖 Implementation — second"},
]


def _signal_comments(prefix_argument: str = "") -> list[str]:
    payload = json.dumps({"comments": _COMMENTS}, ensure_ascii=False)
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        f"    $script:Payload = @'\n{payload}\n'@\n"
        "    function script:gh { $global:LASTEXITCODE = 0; $script:Payload }\n"
        f"    $found = @(Get-SignalComments -IssueNumber 1 {prefix_argument})\n"
        "    @{ found = $found } | ConvertTo-Json -Compress\n"
        "}\n"
    )
    out = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    assert out.returncode == 0, out.stderr
    lines = [ln for ln in out.stdout.splitlines() if ln.startswith("{")]
    assert lines, out.stdout + out.stderr
    return list(json.loads(lines[-1])["found"])


def test_only_trusted_authors_count_as_pipeline_history() -> None:
    assert _signal_comments() == [
        "🤖✅ Tests Passing",
        "🤖 Implementation — first",
        "🤖 Implementation — second",
    ]


def test_prefix_narrows_within_trusted_comments() -> None:
    assert _signal_comments("-Prefix '🤖 Implementation'") == [
        "🤖 Implementation — first",
        "🤖 Implementation — second",
    ]
