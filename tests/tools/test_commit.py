from unittest.mock import MagicMock, patch

from src.tools.commit import generate_commit_message


def test_generate_commit_message_uses_cli_when_available() -> None:
    with patch("src.tools.commit._claude_cli", return_value="feat(utils): add helper"):
        result = generate_commit_message("diff --git a/file.py b/file.py\n+new line")

    assert result == "feat(utils): add helper"


def test_generate_commit_message_falls_back_to_sdk() -> None:
    with patch("src.tools.commit._claude_cli", return_value=None):
        with patch("src.tools.commit._claude_sdk", return_value="fix(config): correct env loading"):
            result = generate_commit_message("diff")

    assert result == "fix(config): correct env loading"


def test_generate_commit_message_cli_takes_priority_over_sdk() -> None:
    with patch("src.tools.commit._claude_cli", return_value="feat: from cli"):
        with patch("src.tools.commit._claude_sdk", return_value="feat: from sdk") as mock_sdk:
            result = generate_commit_message("diff")

    mock_sdk.assert_not_called()
    assert result == "feat: from cli"
