"""The orchestrator module, read from the evals in one pwsh call.

An eval runs a stage's instructions on the model that stage uses, so the model comes from
the orchestrator module and never from a literal in `tests/evals/`. The commit eval calls
the orchestrator's commit-message generator the same way (`run_in_orchestrator`).
"""

import functools
import json
import os
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
ORCHESTRATOR = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
STAGES = ("review", "implement")

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

# Both models come from Get-TaskModel on the engine the orchestrator runs (its Engine
# setting): review is the Review task, and implement the ImplementLarge task (#341).
_MODELS = """
    @{
        review    = Get-TaskModel -Task 'Review'
        implement = Get-TaskModel -Task 'ImplementLarge'
    } | ConvertTo-Json -Compress
"""


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


@functools.cache
def stage_models() -> dict[str, str]:
    """The models the pipeline's stages use: keys `review` and `implement`.

    Read from the orchestrator module in one pwsh call, once per process.
    """
    models = run_in_orchestrator(_MODELS)
    if not all(isinstance(models.get(k), str) and models[k] for k in STAGES):
        raise RuntimeError(f"stage model lookup gave no models: {models}")
    return {k: models[k] for k in STAGES}
