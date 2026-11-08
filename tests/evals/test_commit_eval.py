"""Eval: the commit-message generator (src/tools/commit.py) — the product-side example.

Each golden is a staged diff. The generator writes a message with its real prompt and
Claude; the judge scores it against the conventional-commit rules the prompt states
(G-Eval) and against the diff itself (Answer Relevancy). The canary proves the gate has
teeth: a degraded prompt must fail the same rubric.
"""

import pytest
from deepeval.metrics import AnswerRelevancyMetric, GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams
from eval_goldens import load_goldens

from src.tools import commit

pytestmark = pytest.mark.eval

GOLDENS = load_goldens("commit")


def conventional_commit(judge) -> GEval:
    return GEval(
        name="Conventional commit",
        evaluation_steps=[
            (
                "The first line is `<type>(<scope>): <description>` or "
                "`<type>: <description>`, with type one of feat, fix, refactor, test, "
                "docs, chore, perf, ci, build, revert."
            ),
            (
                "The type fits the diff: a bug fix is fix, new behaviour is feat, a "
                "documentation-only change is docs. Do not deduct for a "
                "borderline-but-valid type choice (e.g. `refactor` vs `feat` when the "
                "change both refactors and adds behaviour); only a clear mismatch (e.g. "
                "`fix` for a purely new feature) should deduct."
            ),
            (
                "The description is in the imperative mood, at most 72 characters, "
                "and has no trailing period."
            ),
            (
                "The output holds nothing but the commit message — no explanation "
                "addressed to the reader, no preamble, no markdown fences. A body after "
                "a blank line is part of the message. Do not deduct for leading or "
                "trailing whitespace — treat the message as if it were stripped."
            ),
        ],
        evaluation_params=[SingleTurnParams.INPUT, SingleTurnParams.ACTUAL_OUTPUT],
        model=judge,
        threshold=0.6,
    )


@pytest.mark.parametrize("golden", GOLDENS, ids=["fix", "feat", "docs"])
def test_commit_message(golden, judge, evaluate) -> None:
    case = LLMTestCase(
        input=golden["input"],
        actual_output=commit.generate_commit_message(golden["input"]),
        context=golden.get("context"),
    )
    evaluate(
        case,
        [conventional_commit(judge), AnswerRelevancyMetric(model=judge, threshold=0.7)],
    )


def test_a_degraded_prompt_fails_the_eval(judge, monkeypatch) -> None:
    monkeypatch.setattr(
        commit,
        "_PROMPT_TEMPLATE",
        "Tell a colleague, in a friendly paragraph with emoji, what this diff does:\n{diff}",
    )
    golden = GOLDENS[0]
    case = LLMTestCase(
        input=golden["input"],
        actual_output=commit.generate_commit_message(golden["input"]),
    )
    metric = conventional_commit(judge)
    metric.measure(case)
    assert not metric.success, (
        f"degraded prompt passed: {metric.score} — {metric.reason}"
    )
