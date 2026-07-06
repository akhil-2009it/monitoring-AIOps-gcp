"""Telemetry helpers — Cloud Logging, Cloud Monitoring custom metrics, OTEL traces.

Imported once at app startup; provides:
    - structured_logger: dict-payload logger with trace_id correlation
    - record_score: Cloud Monitoring custom metric for /score outcomes
    - tracer: OpenTelemetry tracer wired to Cloud Trace via OTLP
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from functools import lru_cache

from google.cloud import logging as gcl
from google.cloud import monitoring_v3
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

PROJECT_ID = os.environ["GCP_PROJECT_ID"]
SERVICE = os.environ.get("OTEL_SERVICE_NAME", "anomaly-scoring-api")


# ─────────── Cloud Logging structured ──────────────────────────────────────
_LOGGER = gcl.Client(project=PROJECT_ID).logger(SERVICE)


def log(payload: dict, severity: str = "INFO") -> None:
    payload = {**payload, "service": SERVICE, "ts": datetime.now(timezone.utc).isoformat()}
    _LOGGER.log_struct(payload, severity=severity)


# ─────────── Cloud Monitoring custom metric ────────────────────────────────
_MON = monitoring_v3.MetricServiceClient()
_PROJECT_PATH = f"projects/{PROJECT_ID}"


def record_score(detector: str, source: str, score: float, is_anomaly: bool) -> None:
    series = monitoring_v3.TimeSeries()
    series.metric.type = "custom.googleapis.com/aiops/scoring/anomalies"
    series.metric.labels["detector"] = detector
    series.metric.labels["source"] = source
    series.metric.labels["is_anomaly"] = str(is_anomaly).lower()
    series.resource.type = "global"

    p = series.points.add()
    p.value.double_value = float(score)
    now = datetime.now(timezone.utc)
    p.interval.end_time.seconds = int(now.timestamp())
    try:
        _MON.create_time_series(name=_PROJECT_PATH, time_series=[series])
    except Exception as e:    # noqa: BLE001
        log({"event": "metric_write_failed", "error": str(e)}, severity="WARNING")


# ─────────── OpenTelemetry → Cloud Trace ───────────────────────────────────
@lru_cache(maxsize=1)
def tracer():
    resource = Resource.create({"service.name": SERVICE, "gcp.project_id": PROJECT_ID})
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(
        endpoint=os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
        insecure=True,
    )
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    return trace.get_tracer(SERVICE)
