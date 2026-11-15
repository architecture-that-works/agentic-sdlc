"""ClaudeJudge — the model DeepEval metrics use to score an eval.

DeepEval defaults to OpenAI; its custom-model interface (DeepEvalBaseLLM) is the seam
that keeps the judge Claude-first. The Claude CLI goes first because it authenticates
with the same subscription token the pipeline uses in the cloud
(CLAUDE_CODE_OAUTH_TOKEN); the Anthropic SDK is the fallback when ANTHROPIC_API_KEY is
set. There is no non-Claude fallback by design.
"""

import asyncio
import os
import subprocess
from typing import Any

from deepeval.models import DeepEvalBaseLLM
from pydantic import BaseModel

DEFAULT_MODEL = "claude-sonnet-5"
# The longest one judgement may take; DeepEval's own timeouts are set from it.
JUDGE_TIMEOUT_SECONDS = 300


class ClaudeJudge(DeepEvalBaseLLM):
    # DeepEval's base declares generate(*args, **kwargs) -> str; its documented
    # custom-model pattern is generate(self, prompt) — hence the override ignores.

    def __init__(self, model: str = DEFAULT_MODEL) -> None:
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
