"""Eval: the review skill's report — the shape `review` must produce.

Each golden is an issue's criterion plus a diff. Claude reviews it with the skill's
SKILL.md as its system prompt and no tools; the judge scores the report against the
skill's § Report contract (G-Eval): the verdict line, three-part findings with a
concrete case, no severity tag. The canary proves the gate has teeth: with § Report
removed from the skill, the planted-bug review must fail the same rubric.
"""

import re
import subprocess
from pathlib import Path

import pytest
from claude_judge import DEFAULT_MODEL
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams
from eval_goldens import load_goldens

pytestmark = pytest.mark.eval

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL = (REPO_ROOT / ".agents/skills/review/SKILL.md").read_text(encoding="utf-8")
GOLDENS = load_goldens("review")


def review(change: str, skill: str = SKILL) -> str:
    out = subprocess.run(
        [
            "claude",
            "-p",
            "--model",
            DEFAULT_MODEL,
            "--tools",
            "",
            "--system-prompt",
            skill,
        ],
        input=f"Review this change. You have no tools: judge it from the text below.\n\n{change}",
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=REPO_ROOT,
        timeout=600,
        check=False,
    )
    assert out.returncode == 0, out.stderr or out.stdout
    return out.stdout


def review_report(judge) -> GEval:
    return GEval(
        name="Review report",
        # Mirrors review/SKILL.md § Step 4 — Report.
        evaluation_steps=[
            (
                "The first line is the verdict: `APPROVED`, or `REJECTED — fix <numbers>` "
                "naming the findings that must be fixed. It is the verdict the expected "
                "output gives."
            ),
            (
                "When the expected output names a defect, the report has it as a numbered "
                "finding with three labelled parts — Defect, Case, Fix — and the Case is a "
                "concrete input with the wrong result it produces. An approved report "
                "with no findings needs no parts."
            ),
            (
                "No finding carries a severity label such as BLOCK, WARN, INFO, critical "
                "or high; the verdict line alone says which findings block."
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


def _case(golden: dict, report: str) -> LLMTestCase:
    return LLMTestCase(
        input=golden["input"],
        actual_output=report,
        expected_output=golden["expected_output"],
    )


@pytest.mark.parametrize(
    "golden", GOLDENS, ids=[g["additional_metadata"]["id"] for g in GOLDENS]
)
def test_review_report(golden, judge, evaluate) -> None:
    evaluate(_case(golden, review(golden["input"])), [review_report(judge)])


def test_a_skill_without_its_report_section_fails_the_eval(judge) -> None:
    degraded = re.sub(
        r"### Step 4 — Report.*?(?=### Step 5)", "", SKILL, flags=re.DOTALL
    )
    assert degraded != SKILL, "§ Step 4 — Report not found in the review skill"
    golden = GOLDENS[1]  # planted-bug
    metric = review_report(judge)
    metric.measure(_case(golden, review(golden["input"], skill=degraded)))
    assert not metric.success, (
        f"degraded skill passed: {metric.score} — {metric.reason}"
    )
