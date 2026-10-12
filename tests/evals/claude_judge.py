"""ClaudeJudge — the model DeepEval metrics use to score an eval.

DeepEval defaults to OpenAI; its custom-model interface (DeepEvalBaseLLM) is the seam
that keeps the judge Claude-first. The Claude CLI goes first because it authenticates
with the same subscription token the pipeline uses in the cloud
(CLAUDE_CODE_OAUTH_TOKEN); the Anthropic SDK is the fallback when ANTHROPIC_API_KEY is
set. There is no non-Claude fallback by design.
"""

import asyncio
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

    def load_model(self, *args: Any, **kwargs: Any) -> "ClaudeJudge":
        return self

    def get_model_name(self, *args: Any, **kwargs: Any) -> str:
        return f"claude ({self.model_id})"

    def generate(  # pyright: ignore[reportIncompatibleMethodOverride]
        self, prompt: str, schema: type[BaseModel] | None = None
    ) -> Any:
        """The judge's answer; validated into `schema` when DeepEval asks for one."""
        answer = self._cli(prompt) or self._sdk(prompt)
        if answer is None:
            raise RuntimeError(
                "No Claude judge available: install the Claude CLI (authenticated, "
                "e.g. CLAUDE_CODE_OAUTH_TOKEN) or set ANTHROPIC_API_KEY."
            )
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

    def _cli(self, prompt: str) -> str | None:
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
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return None
        answer = result.stdout.strip()
        return answer if result.returncode == 0 and answer else None

    def _sdk(self, prompt: str) -> str | None:
        try:
            import anthropic
            from anthropic.types import TextBlock

            response = anthropic.Anthropic().messages.create(
                model=self.model_id,
                max_tokens=4096,
                messages=[{"role": "user", "content": prompt}],
            )
        except Exception:  # noqa: BLE001 — no key, no network: the judge is unavailable
            return None
        text = "".join(b.text for b in response.content if isinstance(b, TextBlock))
        return text.strip() or None
