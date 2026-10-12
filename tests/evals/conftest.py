"""Eval harness fixtures — how to write an eval is in docs/TESTING.md § Evals.

An eval is a pytest test marked `eval` that scores one model-facing component against
a golden dataset with DeepEval metrics, judged by Claude. Evals are deselected by
default; run them with `uv run pytest -m eval`.
"""

import os

import pytest

# Forced, not defaulted: the harness never reports usage to DeepEval's servers.
os.environ["DEEPEVAL_TELEMETRY_OPT_OUT"] = "1"

from claude_judge import (  # imported after the opt-out, on purpose
    JUDGE_TIMEOUT_SECONDS,
    ClaudeJudge,
)

# DeepEval's default per-attempt timeout (~88 s) suits an HTTP API; the CLI judge
# cold-starts and may take up to JUDGE_TIMEOUT_SECONDS. Defaulted, so the environment
# can still override; DeepEval re-reads its settings when the environment changes.
os.environ.setdefault(
    "DEEPEVAL_PER_ATTEMPT_TIMEOUT_SECONDS_OVERRIDE", str(JUDGE_TIMEOUT_SECONDS)
)
os.environ.setdefault(
    "DEEPEVAL_PER_TASK_TIMEOUT_SECONDS_OVERRIDE", str(2 * JUDGE_TIMEOUT_SECONDS + 60)
)
from eval_results import (
    EvalResult,
    assert_passed,
    exporter_from_env,
    measure,
    publish,
)

from src.config import settings

# ADR-003 egress: JSONL under Settings.log_dir, or OTLP instead when an endpoint is set.
RESULTS_DIR = settings.log_dir / "evals"
RESULTS = pytest.StashKey[list[EvalResult]]()


def _session_results(config: pytest.Config) -> list[EvalResult]:
    return config.stash.setdefault(RESULTS, [])


@pytest.fixture(scope="session")
def judge() -> ClaudeJudge:
    return ClaudeJudge()


@pytest.fixture
def evaluate(request):
    """Score a test case with metrics, record every result, fail on any miss."""

    def _evaluate(test_case, metrics) -> list[EvalResult]:
        results = measure(test_case, metrics, case=request.node.name)
        _session_results(request.config).extend(results)
        assert_passed(results)
        return results

    return _evaluate


def pytest_sessionfinish(session: pytest.Session) -> None:
    results = _session_results(session.config)
    if not results:
        return
    path = publish(results, RESULTS_DIR, exporter_from_env())
    where = path or "the OTLP endpoint"
    print(f"\n{len(results)} eval result(s) sent to {where}")
