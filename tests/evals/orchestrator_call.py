"""The one pwsh call from an eval into the orchestrator module.

An eval starts its model the way its stage does: through the module — the engine
function `Invoke-EngineTask`, or a function that calls it such as the commit-message
generator. The model comes from the task's name inside the module, so no CLI name, flag
or model is written in `tests/evals/`.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
ORCHESTRATOR = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"

# Imports the module and runs {body} in its scope, with Write-Log silenced. The body's
# last output line is one JSON object.
_SCRIPT = """
$env:GITHUB_REPOSITORY = 'octocat/sandbox'
$env:GITHUB_DEFAULT_BRANCH = 'main'
Import-Module '{orchestrator}' -Force -DisableNameChecking
& (Get-Module Orchestrator) {{
    function script:Write-Log {{ param($Message, $Color) }}
{body}
}}
"""

# Starts the model on a checked answer: the task, the prompt and the schema come from
# the environment (EVAL_TASK, EVAL_PROMPT, EVAL_SCHEMA), never quoted into the script.
# The schema is normalised the way the stages pass it; the result is cut to what an
# eval reads, deep enough to keep nested lists.
_ENGINE_TASK = """
    $schema = $env:EVAL_SCHEMA | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
    $run = Invoke-EngineTask -Task $env:EVAL_TASK -Prompt $env:EVAL_PROMPT `
        -Label "$env:EVAL_TASK eval" -Schema $schema
    [pscustomobject]@{
        Outcome = $run.Outcome
        Answer  = $run.Answer
        Cause   = $run.Cause
    } | ConvertTo-Json -Depth 20 -Compress
"""

# Covers every attempt of the engine function, its 20s + 40s backoff and the import.
ENGINE_TASK_TIMEOUT = 900


def run_in_orchestrator(
    body: str, *, env: dict[str, str] | None = None, timeout: int = 120
) -> dict:
    """Runs `body` inside the orchestrator module in one pwsh call; its last JSON line.

    `env` is added to the call's environment — how a value such as a diff reaches the
    body without being quoted into it. Raises RuntimeError rather than fall back: an
    eval that cannot read the orchestrator must fail, not skip.
    """
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        raise RuntimeError("pwsh not found: the evals read the orchestrator")
    script = _SCRIPT.format(orchestrator=ORCHESTRATOR, body=body)
    try:
        result = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=timeout,
            check=False,
            cwd=REPO_ROOT,
            env={**os.environ, **(env or {})},
        )
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"orchestrator call timed out: {e}") from e
    if result.returncode != 0:
        raise RuntimeError(
            f"orchestrator call failed (exit {result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    if not lines:
        raise RuntimeError(f"orchestrator call gave no JSON object: {result.stdout}")
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError as e:
        raise RuntimeError(f"orchestrator call gave bad JSON: {e}") from e


def engine_task(task: str, prompt: str, schema: str) -> dict:
    """Starts `task`'s model through `Invoke-EngineTask`, one-shot, on a checked answer.

    Returns `{Outcome, Answer, Cause}` — the part of the engine function's result an eval
    reads. `Answer` is the checked answer, set only when `Outcome` is `finished`.
    """
    return run_in_orchestrator(
        _ENGINE_TASK,
        env={"EVAL_TASK": task, "EVAL_PROMPT": prompt, "EVAL_SCHEMA": schema},
        timeout=ENGINE_TASK_TIMEOUT,
    )
