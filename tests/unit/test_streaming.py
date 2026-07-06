"""Unit tests — streaming detector rule logic (no Pub/Sub network calls)."""
from __future__ import annotations

import os
import sys

# Stub GCP clients to avoid creds requirement during pytest.
import types
fake = types.ModuleType("google.cloud.pubsub_v1")
class _Pub:
    def topic_path(self, *_): return "x"
    def publish(self, *_a, **_k): return None
fake.PublisherClient = _Pub
sys.modules.setdefault("google.cloud.pubsub_v1", fake)
fake_log = types.ModuleType("google.cloud.logging")
class _LogClient:
    def __init__(self, **_k): pass
    def logger(self, *_a):
        class L:
            def log_struct(self, *_a, **_k): pass
        return L()
fake_log.Client = _LogClient
sys.modules.setdefault("google.cloud.logging", fake_log)
fake_mon = types.ModuleType("google.cloud.monitoring_v3")
class _MetricClient:
    def create_time_series(self, *_a, **_k): pass
class _TS:
    def __init__(self): self.metric=type("M",(),{"labels":{},"type":""})(); self.resource=type("R",(),{"type":""})(); self.points=[]
    def add(self): p=type("P",(),{"value":type("V",(),{"int64_value":0,"double_value":0.0})(),"interval":type("I",(),{"end_time":type("E",(),{"seconds":0})()})()})(); self.points.append(p); return p
fake_mon.MetricServiceClient = _MetricClient
fake_mon.TimeSeries = _TS
sys.modules.setdefault("google.cloud.monitoring_v3", fake_mon)

os.environ.setdefault("GCP_PROJECT_ID", "test")
os.environ.setdefault("RULES_PATH", os.path.join(os.path.dirname(__file__), "..", "..",
                                                  "ml", "streaming", "rules.yaml"))

from ml.streaming.detector import _check  # noqa: E402


def test_threshold_rule_fires():
    rule = {"type": "threshold", "metric": "rate_5xx", "op": ">", "value": 0.05}
    assert _check(rule, "lb", "h1", 0.10) is True
    assert _check(rule, "lb", "h1", 0.01) is False


def test_zscore_needs_history():
    rule = {"type": "zscore", "metric": "p99_latency", "threshold": 4.0}
    for v in [80] * 50:
        _check(rule, "lb", "h2", float(v))
    assert _check(rule, "lb", "h2", 5000.0) is True


def test_rate_of_change():
    rule = {"type": "rate_of_change", "metric": "auth_failure_rate", "threshold_pct": 200}
    _check(rule, "app", "h3", 0.01)
    assert _check(rule, "app", "h3", 0.05) is True
