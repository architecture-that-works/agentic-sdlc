"""Eval: the review skill's verdict — the one thing the orchestrator reads from a review.

Each stored case is an issue's criterion plus a change. Claude reviews it with the
skill's SKILL.md as its system prompt and no tools, on the model the review stage uses,
and the verdict is read the way `stages/Review.ps1` reads it: a line that starts with
`APPROVED` approves, anything else rejects.

The two cases are twins: the same issue, tests and change, differing only in one planted
line. Approving `clean` and rejecting `planted-bug` can only be explained by that line, so
a reviewer that rejects for another reason fails `clean`. Each case runs three times and
every verdict must be right, so a reviewer that is right only some of the time fails.
"""

import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from eval_goldens import load_goldens
from stage_models import stage_models

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL = (REPO_ROOT / ".agents/skills/review/SKILL.md").read_text(encoding="utf-8")
GOLDENS = load_goldens("review")
RUNS = 3

# stages/Review.ps1: `$review -match '(?im)^APPROVED'`; anything else is a rejection.
_APPROVED = re.compile(r"^APPROVED", re.IGNORECASE | re.MULTILINE)


def approves(report: str) -> bool:
    """The verdict the review stage reads from a report: True approves."""
    return _APPROVED.search(report) is not None


def review(change: str) -> str:
    out = subprocess.run(
        [
            "claude",
            "-p",
            "--model",
            stage_models()["review"],
            "--tools",
            "",
            "--system-prompt",
            SKILL,
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


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_review_verdict(case) -> None:
    stage_models()  # one lookup before the threads, not one per thread
    with ThreadPoolExecutor(max_workers=RUNS) as pool:
        reports = list(pool.map(review, [case["input"]] * RUNS))
    wrong = [r for r in reports if approves(r) is not case["approve"]]
    expected = "approve" if case["approve"] else "reject"
    assert not wrong, (
        f"{len(wrong)} of {RUNS} reviews did not {expected}:\n\n"
        + "\n\n--- next report ---\n\n".join(wrong)
    )


def test_approves_reads_the_verdict_the_way_the_review_stage_does() -> None:
    assert approves("APPROVED\nWhat this change does: adds paginate().\n")
    assert not approves(
        "## Verdict: APPROVED\n1. **The first page is skipped**\n"
        "   - **Case:** paginate(list(range(10)), 1, 3) returns [3, 4, 5].\n"
    )


def test_the_review_cases_are_twins() -> None:
    # The twin rule (tests/README.md § Evals): only the planted line may differ.
    clean, planted = (
        next(g["input"].splitlines() for g in GOLDENS if g["id"] == name)
        for name in ("clean", "planted-bug")
    )
    assert len(clean) == len(planted)
    assert sum(a != b for a, b in zip(clean, planted, strict=True)) == 1
