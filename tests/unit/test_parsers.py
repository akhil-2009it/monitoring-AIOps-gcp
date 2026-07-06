"""Unit tests — parsers + CommonEvent invariants."""
from __future__ import annotations

import pytest

from ml.parsers import (
    CommonEvent,
    hmac_pii,
    parse_app_json,
    parse_lb,
    parse_nginx,
)


def test_common_event_rejects_unknown_source():
    with pytest.raises(ValueError):
        CommonEvent(ts="t", ingest_ts="t", source="not-a-source", host="h", message="m")


def test_hmac_pii_stable_and_anonymised():
    assert hmac_pii("alice") == hmac_pii("alice")
    assert hmac_pii("alice") != "alice"
    assert hmac_pii(None) is None


def test_nginx_line_parses():
    line = ('1.2.3.4 - - [19/Jun/2026:10:00:00 +0000] '
            '"GET /api/x HTTP/1.1" 200 532 "-" "curl/7.0"')
    ev = parse_nginx(line)
    assert ev is not None and ev.status == 200 and ev.path == "/api/x"


def test_lb_parses_status_and_latency():
    rec = {
        "timestamp": "2026-06-19T10:00:00Z",
        "httpRequest": {"requestUrl": "/x", "status": 200, "latency": "0.250s",
                         "remoteIp": "1.1.1.1", "userAgent": "ua", "responseSize": 1234},
        "resource": {"labels": {"backend_service_name": "bs-1"}},
    }
    ev = parse_lb(rec)
    assert ev.latency_ms == 250.0 and ev.status == 200


def test_app_json_parses_severity():
    rec = {"ts": "2026-06-19T10:00:00Z", "host": "p", "message": "x", "severity": "warn"}
    ev = parse_app_json(rec)
    assert ev.severity == "WARN"
