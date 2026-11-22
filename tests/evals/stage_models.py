"""The model each pipeline stage runs on, read from the orchestrator.

An eval runs a stage's instructions on the model that stage uses, so the model comes from
the orchestrator module and never from a literal in `tests/evals/`.
"""

import functools
import json
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
ORCHESTRATOR = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
STAGES = ("review", "implement")

# Loads the module and asks Get-TaskModel, the one answer to which model a task runs on. Both models come
# from Get-TaskModel on the engine the orchestrator runs (its Engine setting): review is
# the Review task, and implement the ImplementLarge task (#341).
_SCRIPT = f"""
$env:GITHUB_REPOSITORY = 'octocat/sandbox'
$env:GITHUB_DEFAULT_BRANCH = 'main'
Import-Module '{ORCHESTRATOR}' -Force -DisableNameChecking
& (Get-Module Orchestrator) {{
    function script:Write-Log {{ param($Message, $Color) }}
    @{{
        review    = Get-TaskModel -Task 'Review'
        implement = Get-TaskModel -Task 'ImplementLarge'
    }} | ConvertTo-Json -Compress
}}
"""


@functools.cache
def stage_models() -> dict[str, str]:
    """The models the pipeline's stages use: keys `review` and `implement`.

    Read from the orchestrator module in one pwsh call, once per process. Raises RuntimeError rather than fall back to a literal: an
    eval that cannot tell which model it tests must fail, not skip.
    """
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        raise RuntimeError(
            "pwsh not found: the stage models come from the orchestrator"
        )
    try:
        result = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-Command", _SCRIPT],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=120,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"stage model lookup timed out: {e}") from e
    if result.returncode != 0:
        raise RuntimeError(
            f"orchestrator import failed (exit {result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    try:
        models = json.loads(lines[-1]) if lines else None
    except json.JSONDecodeError as e:
        raise RuntimeError(f"stage model lookup gave bad JSON: {e}") from e
    if not isinstance(models, dict) or not all(
        isinstance(models.get(k), str) and models[k] for k in STAGES
    ):
        raise RuntimeError(f"stage model lookup gave no models: {result.stdout}")
    return {k: models[k] for k in STAGES}
