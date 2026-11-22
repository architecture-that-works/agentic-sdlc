"""Contract test for the settings table (#388).

- lib/Config.ps1 — $OrchestratorConfig is the one place every orchestrator setting
  has its value. A key nothing reads is a setting that changes nothing, so every
  top-level key must be read by name (`.Key` or `['Key']`) in a PowerShell file of
  the orchestrator module or its commands. The `Key =` line in the table that
  defines it does not count.
"""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parents[2]
PWSH = shutil.which("pwsh") or "pwsh"
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
SEARCH_ROOTS = (REPO_ROOT / ".github" / "orchestrator", REPO_ROOT / ".github" / "tasks")

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _config_keys() -> list[str]:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) { ConvertTo-Json -Compress "
        "-InputObject @($OrchestratorConfig.Keys | Sort-Object) }\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("[")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _sources() -> str:
    files = [
        p
        for root in SEARCH_ROOTS
        for p in root.rglob("*")
        if p.suffix in {".ps1", ".psm1"}
    ]
    assert files
    return "\n".join(p.read_text(encoding="utf-8") for p in files)


def test_every_setting_in_the_table_is_read() -> None:
    keys = _config_keys()
    assert "MaxRetries" in keys  # the table loaded, not an empty list
    text = _sources()
    unread = [
        key
        for key in keys
        if not re.search(rf"\.{re.escape(key)}\b|\[\s*'{re.escape(key)}'\s*\]", text)
    ]
    assert not unread, f"settings nothing reads: {unread}"


def test_the_new_settings_keep_their_values() -> None:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) { [pscustomobject]@{\n"
        "  pause = $OrchestratorConfig.MaxPauseHours\n"
        "  timeout = $OrchestratorConfig.RequiredChecksTimeoutSeconds\n"
        "  poll = $OrchestratorConfig.RequiredChecksPollSeconds\n"
        "  ctx = @((Get-OrchestratorContext).PSObject.Properties.Name)\n"
        "} | ConvertTo-Json -Compress }\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = json.loads(
        [ln for ln in result.stdout.splitlines() if ln.startswith("{")][-1]
    )
    assert (out["pause"], out["timeout"], out["poll"]) == (5, 900, 10)
    assert "MaxRetries" not in out["ctx"]
    assert "RequiredChecks" in out["ctx"]
