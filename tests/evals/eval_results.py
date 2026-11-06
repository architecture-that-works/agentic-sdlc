"""Scoring an eval and exporting its results over open specifications.

Every metric score becomes one `gen_ai.evaluation.result` record (OpenTelemetry GenAI
semantic conventions), local-first and OTLP-opt-in: records land in
a local JSONL file by default; when OTEL_EXPORTER_OTLP_ENDPOINT is set they are exported
over OTLP instead — one span per eval case, one event per metric — which MLflow (>= 3.6)
or any OTel backend ingests. No vendor SDK in the export path.
"""

import json
import os
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol

from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor, SpanExporter

EVENT_NAME = "gen_ai.evaluation.result"


class Metric(Protocol):
    """The surface of a DeepEval metric the harness relies on."""

    threshold: float
    score: float | None
    success: bool | None
    reason: str | None

    @property
    def __name__(self) -> str: ...

    def measure(self, test_case: Any) -> float: ...


@dataclass(frozen=True)
class EvalResult:
    case: str
    metric: str
    score: float
    threshold: float
    passed: bool
    reason: str


def measure(test_case: Any, metrics: Sequence[Metric], case: str) -> list[EvalResult]:
    """Score one eval case with every metric (each call may reach the judge)."""
    results = []
    for metric in metrics:
        metric.measure(test_case)
        results.append(
            EvalResult(
                case=case,
                metric=metric.__name__,
                score=float(metric.score or 0.0),
                threshold=metric.threshold,
                passed=bool(metric.success),
                reason=metric.reason or "",
            )
        )
    return results


def assert_passed(results: Iterable[EvalResult]) -> None:
    failed = [r for r in results if not r.passed]
    assert not failed, "\n".join(
        f"{r.metric}: {r.score:.2f} < {r.threshold} — {r.reason}" for r in failed
    )


def _attributes(result: EvalResult) -> dict[str, Any]:
    return {
        "gen_ai.evaluation.name": result.metric,
        "gen_ai.evaluation.score.value": result.score,
        "gen_ai.evaluation.score.label": "pass" if result.passed else "fail",
        "gen_ai.evaluation.explanation": result.reason,
        "test.case.name": result.case,
    }


def to_record(result: EvalResult) -> dict[str, Any]:
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    return {"name": EVENT_NAME, "timestamp": now, "attributes": _attributes(result)}


def write_jsonl(results: Iterable[EvalResult], directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"evals-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}.jsonl"
    with path.open("w", encoding="utf-8") as f:
        for result in results:
            f.write(json.dumps(to_record(result)) + "\n")
    return path


def exporter_from_env() -> SpanExporter | None:
    """OTLP/HTTP when an endpoint is configured; headers come from the standard env vars."""
    if not (
        os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
        or os.environ.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
    ):
        return None
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

    return OTLPSpanExporter()


def publish(
    results: Sequence[EvalResult], directory: Path, exporter: SpanExporter | None
) -> Path | None:
    """OTLP *instead of* the file when an exporter is configured.

    Returns the JSONL path, or None when the records went to the OTLP endpoint.
    """
    if exporter is not None:
        export_spans(results, exporter)
        return None
    return write_jsonl(results, directory)


def export_spans(results: Iterable[EvalResult], exporter: SpanExporter) -> None:
    provider = TracerProvider(resource=Resource.create({"service.name": "evals"}))
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    tracer = provider.get_tracer("evals")
    by_case: dict[str, list[EvalResult]] = {}
    for result in results:
        by_case.setdefault(result.case, []).append(result)
    for case, case_results in by_case.items():
        with tracer.start_as_current_span(
            f"evaluate {case}", attributes={"test.case.name": case}
        ) as span:
            for result in case_results:
                span.add_event(EVENT_NAME, attributes=_attributes(result))
    provider.shutdown()
