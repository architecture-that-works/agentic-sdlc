"""Eval harness fixtures — how to write an eval is in docs/TESTING.md § Evals.

An eval is a pytest test marked `eval` that scores one model-facing component against
a golden dataset with DeepEval metrics, judged by Claude. Evals are deselected by
default; run them with `uv run pytest -m eval`.
"""

import os
from pathlib import Path

import pytest

# Forced, not defaulted: the harness never reports usage to DeepEval's servers.
os.environ["DEEPEVAL_TELEMETRY_OPT_OUT"] = "1"

from claude_judge import ClaudeJudge  # imported after the opt-out, on purpose
from eval_results import (
    EvalResult,
    assert_passed,
    export_spans,
    exporter_from_env,
    measure,
    write_jsonl,
)

RESULTS_DIR = Path("logs") / "evals"

_results: list[EvalResult] = []


@pytest.fixture(scope="session")
def judge() -> ClaudeJudge:
    return ClaudeJudge()


@pytest.fixture
def evaluate(request):
    """Score a test case with metrics, record every result, fail on any miss."""

    def _evaluate(test_case, metrics) -> list[EvalResult]:
        results = measure(test_case, metrics, case=request.node.name)
        _results.extend(results)
        assert_passed(results)
        return results

    return _evaluate


def pytest_sessionfinish(session: pytest.Session) -> None:
    if not _results:
        return
    path = write_jsonl(_results, RESULTS_DIR)
    exporter = exporter_from_env()
    if exporter is not None:
        export_spans(_results, exporter)
    print(f"\n{len(_results)} eval result(s) written to {path}")
