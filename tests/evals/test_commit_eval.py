"""Eval: the commit-message generator (src/tools/commit.py) — the product-side example.

Each stored case is a staged diff. The generator writes a message with its real prompt
and Claude, and the message is checked against the rules the prompt states: a
conventional first line of at most 72 characters with no trailing period, and nothing
but the message — no markdown fence, no trailer.
"""

import re

import pytest
from eval_goldens import load_goldens

from src.tools import commit

GOLDENS = load_goldens("commit")

TYPES = (
    "feat",
    "fix",
    "refactor",
    "test",
    "docs",
    "chore",
    "perf",
    "ci",
    "build",
    "revert",
)
FIRST_LINE = re.compile(rf"(?:{'|'.join(TYPES)})(?:\([^()\s]+\))?: \S.*")
TRAILER = re.compile(
    r"^\s*(?:Co-Authored-By|Signed-off-by):", re.IGNORECASE | re.MULTILINE
)


def commit_violations(message: str) -> list[str]:
    """The rules the message breaks; empty when it passes."""
    first = message.strip().splitlines()[0] if message.strip() else ""
    violations = []
    if not FIRST_LINE.fullmatch(first):
        violations.append(
            f"first line is not `<type>(<scope>): <description>`: {first!r}"
        )
    if len(first) > 72:
        violations.append(f"first line is {len(first)} characters, over 72")
    if first.endswith("."):
        violations.append("first line ends with a period")
    if "```" in message:
        violations.append("markdown fence")
    if TRAILER.search(message):
        violations.append("Co-Authored-By or Signed-off-by trailer")
    return violations


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_commit_message(case) -> None:
    message = commit.generate_commit_message(case["input"])
    assert commit_violations(message) == [], message


def test_commit_violations() -> None:
    assert (
        commit_violations(
            'fix(config): ignore unknown .env variables\n\nSettings() raised on "X".\n'
        )
        == []
    )
    assert (
        len(
            commit_violations(
                "```\nThis diff fixes the config so unknown variables are ignored.\n```\n"
                "Co-Authored-By: Someone <someone@example.com>\n"
            )
        )
        == 3
    )
