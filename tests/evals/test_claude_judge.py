"""ClaudeJudge — DeepEval's judge model, backed by Claude (CLI first, SDK fallback).

Unit tests only: the subprocess and the Anthropic client are the system boundaries
and are faked, so these run in the default suite without any model call.
"""

import asyncio
import os
import subprocess
from unittest.mock import MagicMock, patch

import pytest
from claude_judge import ClaudeJudge
from pydantic import BaseModel


class Verdict(BaseModel):
    score: float
    reason: str


def _cli(stdout: str, returncode: int = 0, stderr: str = "") -> MagicMock:
    return MagicMock(returncode=returncode, stdout=stdout, stderr=stderr)


def test_generate_returns_the_cli_answer() -> None:
    with patch("claude_judge.subprocess.run", return_value=_cli("  judged  \n")) as run:
        assert ClaudeJudge("test-model").generate("rate this") == "judged"
    args, kwargs = run.call_args
    assert args[0][:2] == ["claude", "-p"]
    assert kwargs["input"] == "rate this"


def test_generate_falls_back_to_the_sdk_when_the_cli_is_missing() -> None:
    from anthropic.types import TextBlock

    client = MagicMock()
    client.messages.create.return_value.content = [
        TextBlock(text="from sdk", type="text")
    ]
    with (
        patch("claude_judge.subprocess.run", side_effect=FileNotFoundError),
        patch("anthropic.Anthropic", return_value=client),
        patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}),
    ):
        assert ClaudeJudge("test-model").generate("rate this") == "from sdk"


def test_generate_falls_back_to_the_sdk_when_the_cli_fails() -> None:
    from anthropic.types import TextBlock

    client = MagicMock()
    client.messages.create.return_value.content = [
        TextBlock(text="from sdk", type="text")
    ]
    with (
        patch("claude_judge.subprocess.run", return_value=_cli("", returncode=1)),
        patch("anthropic.Anthropic", return_value=client),
        patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}),
    ):
        assert ClaudeJudge("test-model").generate("rate this") == "from sdk"


def test_generate_raises_when_no_claude_is_available() -> None:
    with (
        patch("claude_judge.subprocess.run", side_effect=FileNotFoundError),
        patch("anthropic.Anthropic", side_effect=Exception("no key")),
        patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}),
        pytest.raises(RuntimeError, match="Claude"),
    ):
        ClaudeJudge("test-model").generate("rate this")


def test_generate_with_a_schema_returns_the_validated_model() -> None:
    answer = 'Here you go:\n```json\n{"score": 0.8, "reason": "clear"}\n```'
    with patch("claude_judge.subprocess.run", return_value=_cli(answer)):
        verdict = ClaudeJudge("test-model").generate("rate this", schema=Verdict)
    assert verdict == Verdict(score=0.8, reason="clear")


def test_generate_with_a_schema_raises_on_an_answer_without_json() -> None:
    with (
        patch("claude_judge.subprocess.run", return_value=_cli("no idea")),
        pytest.raises(ValueError, match="no idea"),
    ):
        ClaudeJudge("test-model").generate("rate this", schema=Verdict)


def test_a_generate_matches_generate() -> None:
    with patch("claude_judge.subprocess.run", return_value=_cli("judged")):
        assert (
            asyncio.run(ClaudeJudge("test-model").a_generate("rate this")) == "judged"
        )


def test_cli_timeout_counts_as_unavailable() -> None:
    from anthropic.types import TextBlock

    client = MagicMock()
    client.messages.create.return_value.content = [
        TextBlock(text="from sdk", type="text")
    ]
    with (
        patch(
            "claude_judge.subprocess.run",
            side_effect=subprocess.TimeoutExpired("claude", 1),
        ),
        patch("anthropic.Anthropic", return_value=client),
        patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}),
    ):
        assert ClaudeJudge("test-model").generate("rate this") == "from sdk"


def test_model_name_names_claude() -> None:
    assert "claude" in ClaudeJudge(model="test-model").get_model_name()


def test_deepeval_waits_as_long_as_the_judge_may_take() -> None:
    """DeepEval's default per-attempt timeout (~88 s) suits an HTTP API, not a CLI
    judge that cold-starts; in CI it cancelled a grill eval mid-judgement (#155)."""
    from claude_judge import JUDGE_TIMEOUT_SECONDS
    from deepeval.config.settings import get_settings

    assert get_settings().DEEPEVAL_PER_ATTEMPT_TIMEOUT_SECONDS >= JUDGE_TIMEOUT_SECONDS


def test_non_zero_exit_with_usage_limit_names_the_line() -> None:
    with (
        patch(
            "claude_judge.subprocess.run",
            return_value=_cli("", returncode=1, stderr="usage limit reached"),
        ),
        patch("anthropic.Anthropic", side_effect=Exception("quota")),
        patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}),
        pytest.raises(RuntimeError) as exc_info,
    ):
        ClaudeJudge("test-model").generate("rate this")
    msg = str(exc_info.value)
    assert "usage limit reached" in msg
    assert "install the Claude CLI" not in msg


def test_missing_cli_raises_install_hint() -> None:
    with (
        patch("claude_judge.subprocess.run", side_effect=FileNotFoundError),
        patch("anthropic.Anthropic", side_effect=Exception("quota")),
        patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}),
        pytest.raises(RuntimeError) as exc_info,
    ):
        ClaudeJudge("test-model").generate("rate this")
    assert "install the Claude CLI" in str(exc_info.value)


def test_timeout_names_the_duration() -> None:
    with (
        patch(
            "claude_judge.subprocess.run",
            side_effect=subprocess.TimeoutExpired("claude", 1),
        ),
        patch("anthropic.Anthropic", side_effect=Exception("quota")),
        patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}),
        pytest.raises(RuntimeError) as exc_info,
    ):
        ClaudeJudge("test-model").generate("rate this")
    assert "timeout after" in str(exc_info.value)
