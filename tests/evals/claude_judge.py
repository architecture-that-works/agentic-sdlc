"""ClaudeJudge — the model DeepEval metrics use to score an eval.

DeepEval defaults to OpenAI; its custom-model interface (DeepEvalBaseLLM) is the seam
that keeps the judge Claude-first. The Claude CLI goes first because it authenticates
with the same subscription token the pipeline uses in the cloud
(CLAUDE_CODE_OAUTH_TOKEN); the Anthropic SDK is the fallback when ANTHROPIC_API_KEY is
set. There is no non-Claude fallback by design.

The models come from the orchestrator (`orchestrator_models`), never from a literal
here: the judge runs on the Sonnet tier, each skill under test on its stage's model.
"""

import asyncio
import functools
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from deepeval.models import DeepEvalBaseLLM
from pydantic import BaseModel

REPO_ROOT = Path(__file__).resolve().parents[2]
ORCHESTRATOR = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
# The longest one judgement may take; DeepEval's own timeouts are set from it.
JUDGE_TIMEOUT_SECONDS = 300

# Loads the module the way tests/orchestrator/test_phase_model.py does. Review and
# implement come from the stage selector (implement above OpusImplementThreshold, the
# Opus tier); the judge is the Sonnet tier. KANBAN_MODEL_* overrides pass through.
_MODELS_SCRIPT = f"""
$env:GITHUB_REPOSITORY = 'octocat/sandbox'
$env:GITHUB_DEFAULT_BRANCH = 'main'
Import-Module '{ORCHESTRATOR}' -Force -DisableNameChecking
& (Get-Module Orchestrator) {{
    function script:Write-Log {{ param($Message, $Color) }}
    $above = $OrchestratorConfig.OpusImplementThreshold + 1
    @{{
        review    = Get-PhaseModel -Estimate 0 -Phase 'review'
        implement = Get-PhaseModel -Estimate $above -Phase 'implement'
        judge     = $KanbanModel_Sonnet
    }} | ConvertTo-Json -Compress
}}
"""


@functools.cache
def orchestrator_models() -> dict[str, str]:
    """The models the pipeline uses: keys `review`, `implement` and `judge`.

    Read from the orchestrator module in one pwsh call, once per process, with the
    Claude engine forced. Raises RuntimeError rather than fall back to a literal: a
    gate that cannot tell which model it tests must fail, not skip.
    """
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        raise RuntimeError("pwsh not found: the eval models come from the orchestrator")
    try:
        result = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-Command", _MODELS_SCRIPT],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env={**os.environ, "KANBAN_ENGINE": "claude"},
            timeout=120,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"orchestrator model lookup timed out: {e}") from e
    if result.returncode != 0:
        raise RuntimeError(
            f"orchestrator import failed (exit {result.returncode}): "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    try:
        models = json.loads(lines[-1]) if lines else None
    except json.JSONDecodeError as e:
        raise RuntimeError(f"orchestrator model lookup gave bad JSON: {e}") from e
    keys = ("review", "implement", "judge")
    if not isinstance(models, dict) or not all(
        isinstance(models.get(k), str) and models[k] for k in keys
    ):
        raise RuntimeError(f"orchestrator model lookup gave no models: {result.stdout}")
    return {k: models[k] for k in keys}


class ClaudeJudge(DeepEvalBaseLLM):
    # DeepEval's base declares generate(*args, **kwargs) -> str; its documented
    # custom-model pattern is generate(self, prompt) — hence the override ignores.

    def __init__(self, model: str) -> None:
        self.model_id = model  # set first: the base __init__ calls load_model()
        super().__init__(model)

    def load_model(self, *args: Any, **kwargs: Any) -> ClaudeJudge:
        return self

    def get_model_name(self, *args: Any, **kwargs: Any) -> str:
        return f"claude ({self.model_id})"

    def generate(  # pyright: ignore[reportIncompatibleMethodOverride]
        self, prompt: str, schema: type[BaseModel] | None = None
    ) -> Any:
        """The judge's answer; validated into `schema` when DeepEval asks for one."""
        cli_answer, cli_reason = self._cli(prompt)
        if cli_answer is not None:
            answer = cli_answer
        else:
            sdk_answer, sdk_reason = self._sdk(prompt)
            if sdk_answer is not None:
                answer = sdk_answer
            else:
                msg = f"Claude CLI: {cli_reason}; Anthropic SDK: {sdk_reason}"
                if cli_reason == "not installed":
                    msg += (
                        " — install the Claude CLI"
                        " (authenticated, e.g. CLAUDE_CODE_OAUTH_TOKEN)"
                    )
                raise RuntimeError(msg)
        if schema is None:
            return answer
        start, end = answer.find("{"), answer.rfind("}")
        if start < 0 or end < start:
            raise ValueError(f"Judge answer holds no JSON object: {answer}")
        return schema.model_validate_json(answer[start : end + 1])

    async def a_generate(  # pyright: ignore[reportIncompatibleMethodOverride]
        self, prompt: str, schema: type[BaseModel] | None = None
    ) -> Any:
        return await asyncio.to_thread(self.generate, prompt, schema)

    def _cli(self, prompt: str) -> tuple[str | None, str]:
        try:
            result = subprocess.run(
                ["claude", "-p", "--model", self.model_id],
                input=prompt,
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=JUDGE_TIMEOUT_SECONDS,
                check=False,
            )
        except FileNotFoundError:
            return None, "not installed"
        except subprocess.TimeoutExpired:
            return None, f"timeout after {JUDGE_TIMEOUT_SECONDS}s"
        answer = result.stdout.strip()
        if result.returncode == 0 and answer:
            return answer, ""
        for line in result.stderr.splitlines():
            if line.strip():
                return None, f"exit {result.returncode}: {line.strip()}"
        for line in result.stdout.splitlines():
            if line.strip():
                return None, f"exit {result.returncode}: {line.strip()}"
        return None, f"exit {result.returncode}"

    def _sdk(self, prompt: str) -> tuple[str | None, str]:
        if not os.environ.get("ANTHROPIC_API_KEY"):
            return None, "ANTHROPIC_API_KEY not set"
        try:
            import anthropic
            from anthropic.types import TextBlock

            response = anthropic.Anthropic().messages.create(
                model=self.model_id,
                max_tokens=4096,
                messages=[{"role": "user", "content": prompt}],
            )
        except Exception as e:  # noqa: BLE001 — any exception means the SDK cannot score
            return None, f"{type(e).__name__}: {e}"
        text = "".join(b.text for b in response.content if isinstance(b, TextBlock))
        stripped = text.strip()
        return (stripped, "") if stripped else (None, "empty response")
