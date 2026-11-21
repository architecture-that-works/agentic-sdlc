"""Eval: the implement skill's closing note — the lines `review` and the owner read.

Each golden is a finished mini-task: what was done, skipped and noticed. Claude writes
the closing note with the skill's SKILL.md as its system prompt and no tools; the judge
scores it against the skill's closing-note contract (G-Eval). The canary proves the gate
has teeth: with every mention of the two lines removed from the skill, the note must
fail the same rubric.
"""

import subprocess
from pathlib import Path

import pytest
from claude_judge import orchestrator_models
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams
from eval_goldens import load_goldens

pytestmark = pytest.mark.eval

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL = (REPO_ROOT / ".agents/skills/implement/SKILL.md").read_text(encoding="utf-8")
GOLDENS = load_goldens("implement")


def closing_note(task: str, skill: str = SKILL) -> str:
    out = subprocess.run(
        [
            "claude",
            "-p",
            "--model",
            orchestrator_models()["implement"],
            "--tools",
            "",
            "--system-prompt",
            skill,
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


def closing_note_format(judge) -> GEval:
    return GEval(
        name="Closing note",
        # Mirrors implement/SKILL.md § Primary Outputs — the closing note.
        evaluation_steps=[
            (
                "The output has a line starting `Left undone:` that names what the task "
                "skipped — the same point the expected output makes."
            ),
            (
                "The output has a line starting `Issues discovered:` that names what the "
                "owner must know — the same point the expected output makes."
            ),
            (
                "The output is the note and nothing else: no summary of the work, no "
                "preamble, no headings. Judge content, not formatting: a `- ` bullet "
                "prefix or its absence, inline code backticks, blank lines and "
                "whitespace never deduct."
            ),
        ],
        evaluation_params=[
            SingleTurnParams.INPUT,
            SingleTurnParams.ACTUAL_OUTPUT,
            SingleTurnParams.EXPECTED_OUTPUT,
        ],
        model=judge,
        threshold=0.6,
    )


def _case(golden: dict, note: str) -> LLMTestCase:
    return LLMTestCase(
        input=golden["input"],
        actual_output=note,
        expected_output=golden["expected_output"],
    )


@pytest.mark.parametrize(
    "golden", GOLDENS, ids=[g["additional_metadata"]["id"] for g in GOLDENS]
)
def test_closing_note(golden, judge, evaluate) -> None:
    evaluate(_case(golden, closing_note(golden["input"])), [closing_note_format(judge)])


def test_a_skill_without_the_closing_note_fails_the_eval(judge) -> None:
    lines = SKILL.splitlines(keepends=True)
    degraded = "".join(
        line
        for line in lines
        if "Left undone" not in line and "Issues discovered" not in line
    )
    assert degraded != SKILL, "the closing-note contract was not found in the skill"
    golden = GOLDENS[0]
    metric = closing_note_format(judge)
    metric.measure(_case(golden, closing_note(golden["input"], skill=degraded)))
    assert not metric.success, (
        f"degraded skill passed: {metric.score} — {metric.reason}"
    )
