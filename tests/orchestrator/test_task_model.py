"""Tests for Get-TaskModel and Get-ImplementTask — model selection in lib/Config.ps1.

Every model call is a named task; TaskTiers gives each task a tier and each Engines
row gives that engine's model per tier (issue #359). The tests read the table from the
module and never write a model ID, so changing a model is a one-line edit in Engines.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
REPO_ROOT = Path(__file__).parent.parent.parent
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _in_module(body: str) -> object:
    """Run `body` inside the orchestrator module's scope; return its JSON output."""
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
        [PWSH, "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [ln for ln in result.stdout.splitlines() if ln.startswith(("{", "["))]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _error_of(call: str, setup: str = "") -> str:
    """The message `call` throws inside the module, or '' when it returns."""
    data = _in_module(
        f"{setup}\n"
        f"try {{ {call} | Out-Null; @{{ err = '' }} | ConvertTo-Json -Compress }}\n"
        "catch { @{ err = $_.Exception.Message } | ConvertTo-Json -Compress }"
    )
    assert isinstance(data, dict)
    return data["err"]


def test_every_task_resolves_on_every_engine_row() -> None:
    """For every Engines row, every task in TaskTiers resolves to a model."""
    data = _in_module(
        "$r = @{}\n"
        "foreach ($e in $OrchestratorConfig.Engines.Keys) {\n"
        "  foreach ($t in $OrchestratorConfig.TaskTiers.Keys) {\n"
        '    $r["$e/$t"] = Get-TaskModel -Task $t -Engine $e\n'
        "  }\n"
        "}\n"
        "$r | ConvertTo-Json -Compress"
    )
    assert isinstance(data, dict)
    engines = {key.split("/")[0] for key in data}
    assert engines == {"claude"}
    assert {
        "Refine",
        "Plan",
        "ImplementLarge",
        "ImplementSmall",
        "Review",
        "CommitMessage",
        "EngineCheck",
    } <= {key.split("/")[1] for key in data}
    empty = [
        key for key, model in data.items() if not isinstance(model, str) or not model
    ]
    assert not empty, f"tasks without a model: {empty}"


def test_the_default_engine_is_the_engine_setting() -> None:
    """Without -Engine, the task resolves on the Engine setting's row."""
    data = _in_module(
        "@{ default = Get-TaskModel -Task 'Review';"
        " explicit = Get-TaskModel -Task 'Review' -Engine $OrchestratorConfig.Engine;"
        " ctx = (Get-OrchestratorContext).Engine; setting = $OrchestratorConfig.Engine }"
        " | ConvertTo-Json -Compress"
    )
    assert isinstance(data, dict)
    assert data["default"] == data["explicit"]
    assert data["ctx"] == data["setting"]


@pytest.mark.parametrize(
    ("estimate", "task"),
    [
        (0, "ImplementSmall"),
        (1, "ImplementSmall"),
        (2, "ImplementSmall"),
        (3, "ImplementLarge"),
        (5, "ImplementLarge"),
        (8, "ImplementLarge"),
    ],
)
def test_implement_task_is_chosen_by_the_estimate(estimate: int, task: str) -> None:
    """0 (no estimate), 1 and 2 points are ImplementSmall; 3, 5 and 8 ImplementLarge."""
    data = _in_module(
        f"@{{ task = Get-ImplementTask -Estimate {estimate} }} | ConvertTo-Json -Compress"
    )
    assert isinstance(data, dict)
    assert data["task"] == task


def test_an_engine_without_a_row_stops_naming_the_row() -> None:
    err = _error_of("Get-TaskModel -Task 'Review' -Engine 'nosuchengine'")
    assert "Engines.nosuchengine" in err
    assert "'Review'" in err
    assert "lib/Config.ps1" in err


def test_an_unknown_task_stops_naming_the_task_row() -> None:
    err = _error_of("Get-TaskModel -Task 'NoSuchTask'")
    assert "TaskTiers.NoSuchTask" in err
    assert "lib/Config.ps1" in err


def test_a_tier_without_a_model_stops_naming_the_engine_tier() -> None:
    """An engine row missing the task's tier stops; it never falls back to a model."""
    err = _error_of(
        "Get-TaskModel -Task 'Probe' -Engine 'probe'",
        setup=(
            "$OrchestratorConfig.TaskTiers['Probe'] = 'complex'\n"
            "$OrchestratorConfig.Engines['probe'] = @{ routine = 'x' }"
        ),
    )
    assert "Engines.probe.complex" in err
    assert "'Probe'" in err
    assert "lib/Config.ps1" in err
