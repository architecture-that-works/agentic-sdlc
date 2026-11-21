"""Eval: the review skill's report — the shape `review` must produce.

Each golden is an issue's criterion plus a diff. Claude reviews it with the skill's
SKILL.md as its system prompt and no tools, on the model the review stage uses. The
exact parts of § Step 4 — Report are checked in code first (`check_review_format`):
the verdict line the pipeline reads, and no severity label. Only what needs judgement
goes to the judge (G-Eval): the verdict agrees with the expected one, and a named
defect is a three-part finding with a concrete case. The format check is proven by a
model-free test over stored bad reports, which runs in the default suite.
"""

import re
import subprocess
from pathlib import Path

import pytest
from claude_judge import orchestrator_models
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams
from eval_goldens import load_goldens

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL = (REPO_ROOT / ".agents/skills/review/SKILL.md").read_text(encoding="utf-8")
GOLDENS = load_goldens("review")

# review/SKILL.md § Step 4 — Report: `APPROVED`, or `REJECTED — fix 1`, `fix 1 and 3`,
# `fix 1, 2 and 4`. The review stage reads this line; anything else is a rejection.
VERDICT_LINE = re.compile(r"APPROVED|REJECTED — fix \d+(?:(?:, | and )\d+)*")
# The skill's internal severities are never printed (§ Quick Reference).
SEVERITY_LABEL = re.compile(r"\b(?:BLOCK|WARN|INFO)\b|\b(?i:severity):")


def check_review_format(report: str) -> list[str]:
    """The exact-format violations in a review report; empty when it passes."""
    violations = []
    first = next((line.strip() for line in report.splitlines() if line.strip()), "")
    if not VERDICT_LINE.fullmatch(first):
        violations.append(
            f"first line is not `APPROVED` or `REJECTED — fix <numbers>`: {first!r}"
        )
    labels = sorted(set(SEVERITY_LABEL.findall(report)))
    if labels:
        violations.append(f"severity label printed: {', '.join(labels)}")
    return violations


def review(change: str, skill: str = SKILL) -> str:
    out = subprocess.run(
        [
            "claude",
            "-p",
            "--model",
            orchestrator_models()["review"],
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
        # Mirrors review/SKILL.md § Step 4 — Report; the exact format is checked in code.
        evaluation_steps=[
            (
                "The report's verdict — APPROVED or REJECTED — is the verdict the "
                "expected output gives."
            ),
            (
                "When the expected output names a defect, the report has it as a numbered "
                "finding with three labelled parts — Defect, Case, Fix — and the Case is a "
                "concrete input with the wrong result it produces. An approved report "
                "with no findings needs no parts. Do not deduct for formatting."
            ),
            (
                "Only the findings the verdict line names block. A numbered finding the "
                "verdict line does not name, or a proposed follow-up issue, is a "
                "recommendation the skill allows for points the issue did not ask for: "
                "it never deducts, even when the expected output says `no findings`."
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


@pytest.mark.eval
@pytest.mark.parametrize(
    "golden", GOLDENS, ids=[g["additional_metadata"]["id"] for g in GOLDENS]
)
def test_review_report(golden, judge, evaluate) -> None:
    report = review(golden["input"])
    violations = check_review_format(report)
    assert violations == [], f"{violations}\n--- report ---\n{report}"
    evaluate(_case(golden, report), [review_report(judge)])


FINDING = """
What this change does: adds paginate(), which slices one page out of a list.

1. **The first page is skipped** (`src/orders.py:L6`)
   - **Defect:** `start = page * size` treats `page` as 0-based.
   - **Case:** paginate(list(range(10)), 1, 3) returns [3, 4, 5] instead of [0, 1, 2].
   - **Fix:** `start = (page - 1) * size`.
"""

# The first lines reviews really produced with § Step 4 — Report removed (#341).
STORED_REPORTS = {
    "decorated-rejected": ("## Verdict: REJECTED (BLOCK)\n" + FINDING, False),
    "severity-as-verdict": ("## Verdict: BLOCK\n" + FINDING, False),
    "count-not-numbers": ("REJECTED — 1 BLOCK finding\n" + FINDING, False),
    "severity-on-finding": (
        "REJECTED — fix 1\n" + FINDING.replace("**Defect:**", "**Defect (WARN):**"),
        False,
    ),
    "severity-label": ("REJECTED — fix 1\n" + FINDING + "   - Severity: high\n", False),
    "decorated-approved": ("**APPROVED**\n\nLooks good.\n", False),
    "correct-rejected": ("REJECTED — fix 1\n" + FINDING, True),
    "correct-rejected-list": (
        "\nREJECTED — fix 1, 2 and 3\n" + FINDING + FINDING.replace("1.", "2."),
        True,
    ),
    "correct-approved": (
        (
            "APPROVED\nWhat this change does: adds paginate().\nLooks good.\n"
            "Checked page 1 and page 2 against the criterion; the info in the "
            "docstring matches.\n"
        ),
        True,
    ),
}


@pytest.mark.parametrize(
    ("report", "passes"), STORED_REPORTS.values(), ids=STORED_REPORTS.keys()
)
def test_review_format_check(report: str, passes: bool) -> None:
    violations = check_review_format(report)
    assert (violations == []) is passes, violations
