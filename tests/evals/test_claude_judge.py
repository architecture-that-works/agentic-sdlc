"""ClaudeJudge — DeepEval's judge model, backed by Claude (CLI first, SDK fallback).

Unit tests only: the subprocess and the Anthropic client are the system boundaries
and are faked, so these run in the default suite without any model call.
"""

import asyncio
import subprocess
from unittest.mock import MagicMock, patch

import pytest
from claude_judge import ClaudeJudge
from pydantic import BaseModel


class Verdict(BaseModel):
    score: float
    reason: str


def _cli(stdout: str, returncode: int = 0) -> MagicMock:
    return MagicMock(returncode=returncode, stdout=stdout, stderr="")


def test_generate_returns_the_cli_answer() -> None:
    with patch("claude_judge.subprocess.run", return_value=_cli("  judged  \n")) as run:
        assert ClaudeJudge().generate("rate this") == "judged"
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
    ):
        assert ClaudeJudge().generate("rate this") == "from sdk"


def test_generate_falls_back_to_the_sdk_when_the_cli_fails() -> None:
    from anthropic.types import TextBlock

    client = MagicMock()
    client.messages.create.return_value.content = [
        TextBlock(text="from sdk", type="text")
    ]
    with (
        patch("claude_judge.subprocess.run", return_value=_cli("", returncode=1)),
        patch("anthropic.Anthropic", return_value=client),
    ):
        assert ClaudeJudge().generate("rate this") == "from sdk"


def test_generate_raises_when_no_claude_is_available() -> None:
    with (
        patch("claude_judge.subprocess.run", side_effect=FileNotFoundError),
        patch("anthropic.Anthropic", side_effect=Exception("no key")),
        pytest.raises(RuntimeError, match="Claude"),
    ):
        ClaudeJudge().generate("rate this")


def test_generate_with_a_schema_returns_the_validated_model() -> None:
    answer = 'Here you go:\n```json\n{"score": 0.8, "reason": "clear"}\n```'
    with patch("claude_judge.subprocess.run", return_value=_cli(answer)):
        verdict = ClaudeJudge().generate("rate this", schema=Verdict)
    assert verdict == Verdict(score=0.8, reason="clear")


def test_generate_with_a_schema_raises_on_an_answer_without_json() -> None:
    with (
        patch("claude_judge.subprocess.run", return_value=_cli("no idea")),
        pytest.raises(ValueError, match="no idea"),
    ):
        ClaudeJudge().generate("rate this", schema=Verdict)


def test_a_generate_matches_generate() -> None:
    with patch("claude_judge.subprocess.run", return_value=_cli("judged")):
        assert asyncio.run(ClaudeJudge().a_generate("rate this")) == "judged"


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
    ):
        assert ClaudeJudge().generate("rate this") == "from sdk"


def test_model_name_names_claude() -> None:
    assert "claude" in ClaudeJudge(model="claude-sonnet-5").get_model_name()
