"""Statistical streaming detector — runs inside Cloud Function Gen2.

Triggered by Pub/Sub `events` subscription. Loads rules from rules.yaml,
applies each rule on the incoming feature record (or rolling window),
and emits anomalies to:
    - Pub/Sub `anomalies` topic (consumed by Scoring API + alerting)
    - Cloud Logging (severity from rule)
    - Cloud Monitoring custom metric `aiops/streaming/anomalies`
"""
from __future__ import annotations

import base64
import collections
import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import functions_framework
import yaml
from google.cloud import logging as gcl
from google.cloud import monitoring_v3
from google.cloud import pubsub_v1

PROJECT_ID = os.environ["GCP_PROJECT_ID"]
ANOMALY_TOPIC = os.environ.get("ANOMALY_TOPIC", "anomalies")
RULES_PATH = Path(os.environ.get("RULES_PATH", "/workspace/ml/streaming/rules.yaml"))

_publisher = pubsub_v1.PublisherClient()
_topic_path = _publisher.topic_path(PROJECT_ID, ANOMALY_TOPIC)
_logger = gcl.Client(project=PROJECT_ID).logger("aiops-streaming-detector")
_monitoring = monitoring_v3.MetricServiceClient()

# Rolling windows kept in-process per-key (best-effort; cold start drops state).
_HISTORY: dict[tuple[str, str, str], collections.deque[float]] = collections.defaultdict(
    lambda: collections.deque(maxlen=360)   # 30 min @ 5s windows
)
_EWMA: dict[tuple[str, str, str], dict[str, float]] = collections.defaultdict(dict)


def _rules() -> list[dict]:
    return yaml.safe_load(RULES_PATH.read_text())["rules"]


def _emit(anomaly: dict) -> None:
    _publisher.publish(_topic_path, json.dumps(anomaly).encode("utf-8"))
    _logger.log_struct(anomaly, severity=anomaly.get("severity", "INFO"))

    series = monitoring_v3.TimeSeries()
    series.metric.type = "custom.googleapis.com/aiops/streaming/anomalies"
    series.metric.labels["rule"] = anomaly["rule"]
    series.metric.labels["source"] = anomaly.get("source", "unknown")
    series.resource.type = "global"
    point = series.points.add()
    point.value.int64_value = 1
    now = datetime.now(timezone.utc)
    point.interval.end_time.seconds = int(now.timestamp())
    _monitoring.create_time_series(name=f"projects/{PROJECT_ID}", time_series=[series])


def _check(rule: dict, source: str, host: str, value: float) -> bool:
    key = (source, host, rule["metric"])
    history = _HISTORY[key]
    history.append(value)

    op = rule.get("op", ">")
    rtype = rule["type"]

    if rtype == "threshold":
        thr = float(rule["value"])
        return (value > thr) if op == ">" else (value < thr)

    if rtype == "zscore":
        if len(history) < 30:
            return False
        mean = sum(history) / len(history)
        var = sum((x - mean) ** 2 for x in history) / len(history)
        std = math.sqrt(var) or 1e-9
        return abs((value - mean) / std) > float(rule["threshold"])

    if rtype == "rate_of_change":
        if len(history) < 2:
            return False
        prev = history[-2] or 1e-9
        return abs(value - prev) / abs(prev) * 100 > float(rule["threshold_pct"])

    if rtype == "ewma":
        st = _EWMA[key]
        alpha = float(rule.get("alpha", 0.3))
        st["mean"] = alpha * value + (1 - alpha) * st.get("mean", value)
        diff = value - st["mean"]
        st["var"] = alpha * (diff ** 2) + (1 - alpha) * st.get("var", 0.0)
        std = math.sqrt(st["var"]) or 1e-9
        return abs(diff / std) > float(rule.get("deviation_sigma", 3))

    return False


@functions_framework.cloud_event
def handler(event):
    """Pub/Sub Gen2 trigger — `event.data['message']['data']` base64-encoded."""
    payload = base64.b64decode(event.data["message"]["data"]).decode("utf-8")
    record = json.loads(payload)

    source = record.get("source", "unknown")
    host = record.get("host", "unknown")
    fired: list[dict] = []
    for rule in _rules():
        metric = rule["metric"]
        val = record.get(metric)
        if val is None:
            continue
        if _check(rule, source, host, float(val)):
            anomaly = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "rule": rule["name"],
                "metric": metric,
                "value": val,
                "source": source,
                "host": host,
                "severity": rule.get("severity", "MEDIUM"),
                "detector": "streaming-statistical",
            }
            _emit(anomaly)
            fired.append(anomaly)

    return {"fired": fired, "n": len(fired)}
