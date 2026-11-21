"""Eval: the review skill's verdict — the one thing the orchestrator reads from a review.

Each stored case is an issue's criterion plus a change. Claude reviews it with the
skill's SKILL.md as its system prompt and no tools, on the model the review stage uses,
and answers in the shape of the skill's `answer.schema.json` — the schema the review
stage passes too. The verdict is read the way `stages/Review.ps1` reads it: the checked
`verdict` field of the result's `structured_output`.

The two cases are twins: the same issue, tests and change, differing only in one planted
line. Approving `clean` and rejecting `planted-bug` can only be explained by that line, so
a reviewer that rejects for another reason fails `clean`. Each case runs three times and
every verdict must be right, so a reviewer that is right only some of the time fails.
"""

import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from eval_goldens import load_goldens
from stage_models import stage_models

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / ".agents/skills/review"
SKILL = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
SCHEMA = (SKILL_DIR / "answer.schema.json").read_text(encoding="utf-8")
GOLDENS = load_goldens("review")
RUNS = 3


def verdict_of(result: dict) -> str | None:
    """The verdict the review stage reads from a result: `structured_output.verdict`."""
    answer = result.get("structured_output")
    return answer.get("verdict") if isinstance(answer, dict) else None


def review(change: str) -> dict:
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
            "--json-schema",
            SCHEMA,
            "--output-format",
            "json",
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
    return json.loads(out.stdout)


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_review_verdict(case) -> None:
    stage_models()  # one lookup before the threads, not one per thread
    with ThreadPoolExecutor(max_workers=RUNS) as pool:
        reports = list(pool.map(review, [case["input"]] * RUNS))
    wrong = [r for r in reports if (verdict_of(r) == "approved") is not case["approve"]]
    expected = "approve" if case["approve"] else "reject"
    assert not wrong, (
        f"{len(wrong)} of {RUNS} reviews did not {expected}:\n\n"
        + "\n\n--- next result ---\n\n".join(json.dumps(r, indent=2) for r in wrong)
    )


def test_verdict_of_reads_the_checked_field_the_review_stage_reads() -> None:
    approved = {
        "type": "result",
        "subtype": "success",
        "structured_output": {"verdict": "approved", "report": "Looks good."},
    }
    rejected = {
        "type": "result",
        "subtype": "success",
        "structured_output": {
            "verdict": "rejected",
            "report": "Fix 1.\n\nAPPROVED would not count here.\n\n1. **The first page is skipped**",
        },
    }
    assert verdict_of(approved) == "approved"
    assert verdict_of(rejected) == "rejected"
    assert (
        verdict_of({"type": "result", "subtype": "error_max_structured_output_retries"})
        is None
    )


def test_the_review_cases_are_twins() -> None:
    # The twin rule (tests/README.md § Evals): only the planted line may differ.
    clean, planted = (
        next(g["input"].splitlines() for g in GOLDENS if g["id"] == name)
        for name in ("clean", "planted-bug")
    )
    assert len(clean) == len(planted)
    assert sum(a != b for a, b in zip(clean, planted, strict=True)) == 1
