"""Procedure-derivation from the agent's tool calls — lib/Util.ps1 Get-ProcedureRecord.

Each test calls Get-ProcedureRecord with the one tool call ({ Name; Input }, as
Invoke-EngineTask hands it to its -OnToolCall callback) needed to set (or leave
unset) a single flag, and asserts exactly that field. One test per Procedure: field.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run_procedure(calls: list) -> dict:
    calls_json = json.dumps(calls)
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        f"$calls = '{calls_json}' | ConvertFrom-Json\n"
        "$r = Get-ProcedureRecord -ToolCalls $calls\n"
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
    return {"Name": "Read", "Input": {"file_path": file_path}}


def _bash_event(command: str) -> dict:
    return {"Name": "Bash", "Input": {"command": command}}


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


@pytest.mark.parametrize(
    "command",
    [
        "uv run pytest --tb=short -q",
        "uv run pytest tests/x/test_y.py",
        "uv run pytest tests/x/test_y.py::test_z",
        "uv run pytest -x tests/x",
    ],
)
def test_pytest_run_detected(command: str) -> None:
    out = _run_procedure([_bash_event(command)])
    assert out["pytestRun"] is True
    assert out["agentsMdRead"] is False
    assert out["contextMdRead"] is False
    assert out["skillRead"] is False
