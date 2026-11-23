"""Eval: the review skill's verdict — the one thing the orchestrator reads from a review.

Each stored case is an issue's criterion plus a change. The model reviews it the way the
review stage starts it: through the engine function `Invoke-EngineTask`, on the `Review`
task, one-shot with no tools, with the skill's SKILL.md at the head of the prompt and the
skill's `answer.schema.json` as the schema — the schema the review stage passes too. The
verdict is read the way `stages/Review.ps1` reads it: the checked `verdict` field of the
result's `Answer`, only when its `Outcome` is `finished`.

The two cases are twins: the same issue, tests and change, differing only in one planted
line. Approving `clean` and rejecting `planted-bug` can only be explained by that line, so
a reviewer that rejects for another reason fails `clean`. Each case runs three times and
every verdict must be right, so a reviewer that is right only some of the time fails.
"""

import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from eval_goldens import load_goldens
from orchestrator_call import engine_task

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / ".agents/skills/review"
SKILL = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
SCHEMA = (SKILL_DIR / "answer.schema.json").read_text(encoding="utf-8")
GOLDENS = load_goldens("review")
RUNS = 3


def verdict_of(result: dict) -> str | None:
    """The verdict the review stage reads from a result: `Answer.verdict`.

    None unless the run finished with a checked answer.
    """
    if result.get("Outcome") != "finished":
        return None
    answer = result.get("Answer")
    return answer.get("verdict") if isinstance(answer, dict) else None


def wrong_results(results: list[dict], approve: bool) -> list[dict]:
    """The results whose verdict is not the expected one — a missing answer is always wrong.

    The review stage fails the attempt on a result without a checked answer; it never
    reads that as a rejection, so neither does the eval.
    """
    expected = "approved" if approve else "rejected"
    return [r for r in results if verdict_of(r) != expected]


def review(change: str) -> dict:
    prompt = (
        f"{SKILL}\n\n---\n\n"
        "Review this change. You have no tools: judge it from the text below.\n\n"
        f"{change}"
    )
    return engine_task("Review", prompt, SCHEMA)


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_review_verdict(case) -> None:
    with ThreadPoolExecutor(max_workers=RUNS) as pool:
        reports = list(pool.map(review, [case["input"]] * RUNS))
    wrong = wrong_results(reports, case["approve"])
    expected = "approve" if case["approve"] else "reject"
    assert not wrong, (
        f"{len(wrong)} of {RUNS} reviews did not {expected}:\n\n"
        + "\n\n--- next result ---\n\n".join(json.dumps(r, indent=2) for r in wrong)
    )


def test_verdict_of_reads_the_checked_field_the_review_stage_reads() -> None:
    approved = {
        "Outcome": "finished",
        "Answer": {"verdict": "approved", "report": "Looks good."},
        "Cause": None,
    }
    rejected = {
        "Outcome": "finished",
        "Answer": {
            "verdict": "rejected",
            "report": "Fix 1.\n\nAPPROVED would not count here.\n\n1. **The first page is skipped**",
        },
        "Cause": None,
    }
    assert verdict_of(approved) == "approved"
    assert verdict_of(rejected) == "rejected"
    assert verdict_of({"Outcome": "finished", "Answer": "approved"}) is None


def test_a_run_that_did_not_finish_has_no_verdict() -> None:
    for outcome in ("failed", "max_turns"):
        result = {
            "Outcome": outcome,
            "Answer": {"verdict": "approved", "report": "Looks good."},
            "Cause": "Review eval produced no checked answer",
        }
        assert verdict_of(result) is None


def test_a_result_without_a_checked_answer_fails_either_case() -> None:
    approved = {
        "Outcome": "finished",
        "Answer": {"verdict": "approved", "report": "Ok."},
    }
    rejected = {
        "Outcome": "finished",
        "Answer": {"verdict": "rejected", "report": "No."},
    }
    no_answer = {"Outcome": "failed", "Answer": None, "Cause": "no checked answer"}
    assert wrong_results([approved, rejected, no_answer], approve=True) == [
        rejected,
        no_answer,
    ]
    assert wrong_results([approved, rejected, no_answer], approve=False) == [
        approved,
        no_answer,
    ]


def test_the_review_cases_are_twins() -> None:
    # The twin rule (tests/README.md § Evals): only the planted line may differ.
    clean, planted = (
        next(g["input"].splitlines() for g in GOLDENS if g["id"] == name)
        for name in ("clean", "planted-bug")
    )
    assert len(clean) == len(planted)
    assert sum(a != b for a, b in zip(clean, planted, strict=True)) == 1
