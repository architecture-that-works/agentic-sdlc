"""eval_results — scoring an eval, recording each metric, exporting the records.

Unit tests only: metrics are stand-ins with DeepEval's metric surface, and spans go to
the OTel SDK's in-memory exporter, so nothing calls a model or the network.
"""

import json
from dataclasses import dataclass

import pytest
from eval_results import (
    EvalResult,
    assert_passed,
    export_spans,
    exporter_from_env,
    measure,
    publish,
    to_record,
    write_jsonl,
)
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter


@dataclass
class FakeMetric:
    """DeepEval's metric surface: measure() sets score, success and reason."""

    fixed_score: float
    threshold: float = 0.5
    __name__: str = "Conventional commit [GEval]"
    score: float | None = None
    success: bool | None = None
    reason: str | None = None

    def measure(self, test_case: object) -> float:
        self.score = self.fixed_score
        self.success = self.fixed_score >= self.threshold
        self.reason = f"scored {self.fixed_score}"
        return self.fixed_score


def _result(passed: bool = True, case: str = "test_commit[fix]") -> EvalResult:
    return EvalResult(
        case=case,
        metric="Conventional commit [GEval]",
        score=0.9 if passed else 0.2,
        threshold=0.5,
        passed=passed,
        reason="clear" if passed else "no type prefix",
    )


def test_measure_scores_every_metric_against_the_case() -> None:
    results = measure("case-input", [FakeMetric(0.9), FakeMetric(0.2)], case="c1")
    assert [(r.case, r.score, r.passed) for r in results] == [
        ("c1", 0.9, True),
        ("c1", 0.2, False),
    ]
    assert results[1].reason == "scored 0.2"


def test_record_follows_the_otel_genai_evaluation_event() -> None:
    record = to_record(_result(passed=False))
    assert record["name"] == "gen_ai.evaluation.result"
    assert record["attributes"] == {
        "gen_ai.evaluation.name": "Conventional commit [GEval]",
        "gen_ai.evaluation.score.value": 0.2,
        "gen_ai.evaluation.score.label": "fail",
        "gen_ai.evaluation.explanation": "no type prefix",
        "test.case.name": "test_commit[fix]",
    }
    assert record["timestamp"].endswith("Z")


def test_write_jsonl_writes_one_record_per_result(tmp_path) -> None:
    path = write_jsonl([_result(), _result(passed=False)], tmp_path)
    lines = path.read_text(encoding="utf-8").splitlines()
    assert path.parent == tmp_path and path.suffix == ".jsonl"
    assert [
        json.loads(line)["attributes"]["gen_ai.evaluation.score.label"]
        for line in lines
    ] == [
        "pass",
        "fail",
    ]


def test_export_spans_emits_one_span_per_case_with_an_event_per_metric() -> None:
    exporter = InMemorySpanExporter()
    export_spans(
        [_result(case="a"), _result(passed=False, case="a"), _result(case="b")],
        exporter,
    )
    spans = sorted(exporter.get_finished_spans(), key=lambda s: s.name)
    assert [s.name for s in spans] == ["evaluate a", "evaluate b"]
    events = spans[0].events
    assert [e.name for e in events] == ["gen_ai.evaluation.result"] * 2
    assert (events[1].attributes or {})["gen_ai.evaluation.score.label"] == "fail"


def test_publish_writes_jsonl_when_no_exporter_is_configured(tmp_path) -> None:
    """ADR-003 egress: the local JSONL file is the default."""
    path = publish([_result()], tmp_path, exporter=None)
    assert path is not None and path.exists()


def test_publish_exports_instead_of_writing_when_an_exporter_is_configured(
    tmp_path,
) -> None:
    """ADR-003 egress: with an OTLP endpoint, records go there *instead* of the file."""
    exporter = InMemorySpanExporter()
    assert publish([_result()], tmp_path, exporter=exporter) is None
    assert len(exporter.get_finished_spans()) == 1
    assert list(tmp_path.iterdir()) == []


def test_exporter_from_env_is_none_without_an_endpoint(monkeypatch) -> None:
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_ENDPOINT", raising=False)
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", raising=False)
    assert exporter_from_env() is None


def test_exporter_from_env_uses_otlp_when_an_endpoint_is_set(monkeypatch) -> None:
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:5000")
    assert isinstance(exporter_from_env(), OTLPSpanExporter)


def test_assert_passed_names_each_failing_metric_with_score_and_reason() -> None:
    assert_passed([_result()])
    with pytest.raises(AssertionError) as err:
        assert_passed([_result(), _result(passed=False)])
    assert "Conventional commit [GEval]" in str(err.value)
    assert "0.2" in str(err.value) and "no type prefix" in str(err.value)
