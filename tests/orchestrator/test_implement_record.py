"""Procedure-derivation from agent stream events — lib/Util.ps1 Get-ProcedureRecord.

Each test calls Get-ProcedureRecord with a minimal stream-JSON fixture that
contains the one tool_use block needed to set (or leave unset) a single flag,
and asserts exactly that field. One test per Procedure: field, no more.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run_procedure(events: list) -> dict:
    events_json = json.dumps(events)
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        f"$events = '{events_json}' | ConvertFrom-Json\n"
        "$r = Get-ProcedureRecord -StreamEvents $events\n"
        "[pscustomobject]@{\n"
        "    agentsMdRead  = [bool]$r.agentsMdRead\n"
        "    contextMdRead = [bool]$r.contextMdRead\n"
        "    skillRead     = [bool]$r.skillRead\n"
        "    pytestRun     = [bool]$r.pytestRun\n"
        "} | ConvertTo-Json -Compress\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _read_event(file_path: str) -> dict:
    return {
        "content": [
            {"type": "tool_use", "name": "Read", "input": {"file_path": file_path}}
        ]
    }


def _bash_event(command: str) -> dict:
    return {
        "content": [{"type": "tool_use", "name": "Bash", "input": {"command": command}}]
    }


def test_agents_md_read_detected() -> None:
    out = _run_procedure([_read_event("AGENTS.md")])
    assert out["agentsMdRead"] is True
    assert out["contextMdRead"] is False


def test_context_md_read_detected() -> None:
    out = _run_procedure([_read_event("CONTEXT.md")])
    assert out["contextMdRead"] is True
    assert out["agentsMdRead"] is False


def test_skill_read_detected() -> None:
    out = _run_procedure([_read_event(".agents/skills/implement/SKILL.md")])
    assert out["skillRead"] is True
    assert out["pytestRun"] is False


def test_pytest_run_detected() -> None:
    out = _run_procedure([_bash_event("uv run pytest --tb=short -q")])
    assert out["pytestRun"] is True
    assert out["agentsMdRead"] is False
    assert out["contextMdRead"] is False
    assert out["skillRead"] is False
