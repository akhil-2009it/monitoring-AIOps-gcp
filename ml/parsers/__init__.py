"""Common event schema + per-source parsers — GCP port.

Source values map 1:1 to GCP-native log providers. AWS sources also accepted
so the same parser library can be used cross-cloud during migration windows.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any, Optional

PII_HMAC_KEY = os.environ.get("PII_HMAC_KEY", "change-me-in-prod").encode("utf-8")

ALLOWED_SOURCES = {
    "cdn", "lb", "cloud_armor", "app", "gke", "nginx", "kafka",
    "cloudsql", "mongo", "redis", "node_metrics", "container_metrics",
    "prom_app", "otel_traces",
    # AWS aliases — kept for cross-cloud parsers.
    "cloudfront", "alb", "waf", "eks", "mysql",
}


@dataclass
class CommonEvent:
    ts: str
    ingest_ts: str
    source: str
    host: str
    message: str
    severity: Optional[str] = None
    status: Optional[int] = None
    latency_ms: Optional[float] = None
    bytes: Optional[int] = None
    src_ip: Optional[str] = None
    user: Optional[str] = None
    path: Optional[str] = None
    user_agent: Optional[str] = None
    attrs: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.source not in ALLOWED_SOURCES:
            raise ValueError(f"unknown source: {self.source}")

    def to_dict(self) -> dict:
        return asdict(self)


def hmac_pii(value: str | None) -> str | None:
    if not value:
        return value
    return hmac.new(PII_HMAC_KEY, value.encode("utf-8"), hashlib.sha256).hexdigest()[:16]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ─────────── Per-source parsers ───────────────────────────────────────────
_NGINX_RE = re.compile(
    r'(?P<ip>\S+)\s+\S+\s+\S+\s+\[(?P<ts>[^\]]+)\]\s+"(?P<method>\S+)\s+(?P<path>\S+)\s+\S+"\s+'
    r'(?P<status>\d+)\s+(?P<bytes>\d+|-)\s+"[^"]*"\s+"(?P<ua>[^"]*)"'
)


def parse_nginx(line: str) -> CommonEvent | None:
    m = _NGINX_RE.search(line)
    if not m:
        return None
    return CommonEvent(
        ts=now_iso(), ingest_ts=now_iso(),
        source="nginx", host=os.environ.get("HOSTNAME", "unknown"),
        message=line, status=int(m["status"]),
        bytes=None if m["bytes"] == "-" else int(m["bytes"]),
        src_ip=hmac_pii(m["ip"]),
        path=m["path"], user_agent=m["ua"],
    )


def parse_cloud_armor(record: dict) -> CommonEvent:
    """Cloud Armor logs surfaced via Cloud Logging payload."""
    p = record.get("jsonPayload") or {}
    return CommonEvent(
        ts=record.get("timestamp", now_iso()),
        ingest_ts=now_iso(),
        source="cloud_armor",
        host=p.get("enforcedSecurityPolicy", {}).get("name", "unknown"),
        message=str(p.get("statusDetails", "")),
        status=int(record.get("httpRequest", {}).get("status", 0) or 0),
        src_ip=hmac_pii(record.get("httpRequest", {}).get("remoteIp")),
        path=record.get("httpRequest", {}).get("requestUrl"),
        user_agent=record.get("httpRequest", {}).get("userAgent"),
        attrs={"action": p.get("enforcedSecurityPolicy", {}).get("outcome")},
    )


def parse_lb(record: dict) -> CommonEvent:
    """GCP HTTPS LB request log."""
    h = record.get("httpRequest", {})
    return CommonEvent(
        ts=record.get("timestamp", now_iso()),
        ingest_ts=now_iso(),
        source="lb",
        host=record.get("resource", {}).get("labels", {}).get("backend_service_name", "unknown"),
        message=h.get("requestUrl", ""),
        status=int(h.get("status", 0) or 0),
        latency_ms=float(h.get("latency", "0s").replace("s", "")) * 1000.0
            if h.get("latency") else None,
        bytes=int(h.get("responseSize", 0) or 0),
        src_ip=hmac_pii(h.get("remoteIp")),
        path=h.get("requestUrl"),
        user_agent=h.get("userAgent"),
    )


def parse_app_json(record: dict) -> CommonEvent:
    return CommonEvent(
        ts=record.get("ts") or record.get("timestamp", now_iso()),
        ingest_ts=now_iso(),
        source="app",
        host=record.get("host") or record.get("pod", "unknown"),
        message=record.get("message") or record.get("msg", ""),
        severity=(record.get("severity") or record.get("level") or "INFO").upper(),
        latency_ms=record.get("latency_ms"),
        status=record.get("status"),
        user=hmac_pii(record.get("user")),
        path=record.get("path"),
        attrs=record.get("attrs") or {},
    )


def parse_cloudsql_slow(record: dict) -> CommonEvent:
    p = record.get("textPayload") or record.get("message") or ""
    return CommonEvent(
        ts=record.get("timestamp", now_iso()),
        ingest_ts=now_iso(),
        source="cloudsql",
        host=record.get("resource", {}).get("labels", {}).get("database_id", "unknown"),
        message=p, severity="WARN", attrs={"slow_query": True},
    )


PARSERS = {
    "nginx": parse_nginx,
    "cloud_armor": parse_cloud_armor,
    "lb": parse_lb,
    "app": parse_app_json,
    "cloudsql": parse_cloudsql_slow,
}
