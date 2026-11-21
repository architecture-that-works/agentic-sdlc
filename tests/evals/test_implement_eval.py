"""Eval: the implement skill's closing note — the two lines the orchestrator reads.

Each stored case is a finished mini-task: what was done, skipped and noticed. Claude
writes the closing note with the skill's SKILL.md as its system prompt and no tools, on
the model the implement stage uses. The note must hold a line starting `Left undone:` and
one starting `Issues discovered:`, which `stages/Implement.ps1` lifts into the issue.
"""

import re
import subprocess
from pathlib import Path

import pytest
from eval_goldens import load_goldens
from stage_models import stage_models

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL = (REPO_ROOT / ".agents/skills/implement/SKILL.md").read_text(encoding="utf-8")
GOLDENS = load_goldens("implement")

# A bullet prefix is optional: stages/Implement.ps1 reads `- Left undone:` from the
# agent's bullets, and the skill's note writes the same line.
REQUIRED_LINES = ("Left undone:", "Issues discovered:")


def missing_lines(note: str) -> list[str]:
    """The closing-note lines the note lacks; empty when it passes."""
    return [
        label
        for label in REQUIRED_LINES
        if not re.search(rf"^\s*(?:[-*•]\s+)?{re.escape(label)}", note, re.MULTILINE)
    ]


def closing_note(task: str) -> str:
    out = subprocess.run(
        [
            "claude",
            "-p",
            "--model",
            stage_models()["implement"],
            "--tools",
            "",
            "--system-prompt",
            SKILL,
        ],
        input=(
            "The task below is finished. Write the closing note your skill asks for "
            f"at the end of a task — output only the note.\n\n{task}"
        ),
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=REPO_ROOT,
        timeout=600,
        check=False,
    )
    assert out.returncode == 0, out.stderr or out.stdout
    return out.stdout


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_closing_note(case) -> None:
    note = closing_note(case["input"])
    assert missing_lines(note) == [], f"{missing_lines(note)} missing from:\n{note}"


def test_missing_lines() -> None:
    assert (
        missing_lines(
            "- Left undone: lo > hi is not handled.\n"
            "- Issues discovered: README.md documents clamp_value.\n"
        )
        == []
    )
    assert missing_lines(
        "Added clamp with tests; nothing was skipped.\n"
        "Note: README.md documents clamp_value.\n"
    ) == ["Left undone:", "Issues discovered:"]
