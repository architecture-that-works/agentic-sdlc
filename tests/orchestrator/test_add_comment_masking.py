"""Add-Comment replaces secret values with *** before posting — lib/GitHub.ps1.

Tokens scoped to individual workflow steps still reach Add-Comment at runtime;
this gate ensures that even if a token value ends up in a comment body (e.g. in
a failure tail) it is never posted to GitHub in plain text.
"""

import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")

SENTINEL = "ghp_SENTINEL_VALUE_FOR_TESTING"


def _run_add_comment(body: str, env_vars: dict[str, str] | None = None) -> str:
    """Call Add-Comment via a pwsh stub and return what it would have posted."""
    env_setup = "\n".join(f"$env:{k} = '{v}'" for k, v in (env_vars or {}).items())
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as tmp:
        capture_path = tmp.name

    script = (
        f"{env_setup}\n"
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        f"    $captureFile = '{capture_path.replace(chr(92), '/')}'\n"
        "    function script:gh {\n"
        "        param([Parameter(ValueFromRemainingArguments)]$args)\n"
        "        $bodyIdx = [array]::IndexOf([string[]]$args, '--body-file')\n"
        "        if ($bodyIdx -ge 0) {\n"
        "            $f = $args[$bodyIdx + 1]\n"
        "            Get-Content $f -Raw | Set-Content $captureFile -NoNewline\n"
        "        }\n"
        "        $global:LASTEXITCODE = 0\n"
        "    }\n"
        f"    Add-Comment -Number 1 -Body '🤖 {body}'\n"
        "}\n"
    )
    out = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    assert out.returncode == 0, out.stderr + out.stdout
    posted = (
        Path(capture_path).read_text(encoding="utf-8")
        if Path(capture_path).exists()
        else ""
    )
    Path(capture_path).unlink(missing_ok=True)
    return posted


def test_add_comment_masks_gh_token() -> None:
    posted = _run_add_comment(
        f"token is {SENTINEL} here",
        env_vars={"GH_TOKEN": SENTINEL},
    )
    assert SENTINEL not in posted, f"sentinel was not masked: {posted!r}"
    assert "***" in posted


def test_add_comment_skips_masking_when_token_empty() -> None:
    body = "🤖 no token in this body"
    posted = _run_add_comment(body, env_vars={"GH_TOKEN": ""})
    assert "no token in this body" in posted
    assert "***" not in posted
