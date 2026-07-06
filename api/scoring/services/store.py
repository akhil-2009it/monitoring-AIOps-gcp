"""Alerts / feedback store — Firestore.

Collections:
    alerts   — emitted by streaming detector + /score
    feedback — analyst labels
    sources  — last-seen timestamps per source
"""
from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone

from google.cloud import firestore

_db = firestore.Client(project=os.environ["GCP_PROJECT_ID"])
ALERTS = "alerts"
FEEDBACK = "feedback"
SOURCES = "sources"


def record_alert(payload: dict) -> str:
    aid = payload.get("id") or str(uuid.uuid4())
    payload = {**payload, "id": aid, "ts": payload.get("ts") or datetime.now(timezone.utc).isoformat()}
    _db.collection(ALERTS).document(aid).set(payload)
    return aid


def list_alerts(since: str | None = None, source: str | None = None,
                severity: str | None = None, limit: int = 100) -> list[dict]:
    q = _db.collection(ALERTS).order_by("ts", direction=firestore.Query.DESCENDING).limit(limit)
    docs = list(q.stream())
    out = [{**d.to_dict(), "id": d.id} for d in docs]
    if since:
        out = [a for a in out if a["ts"] >= since]
    if source:
        out = [a for a in out if a.get("source") == source]
    if severity:
        out = [a for a in out if a.get("severity") == severity]
    return out


def get_alert(alert_id: str) -> dict | None:
    snap = _db.collection(ALERTS).document(alert_id).get()
    return ({**snap.to_dict(), "id": snap.id}) if snap.exists else None


def write_feedback(alert_id: str, label: str) -> None:
    _db.collection(FEEDBACK).document(str(uuid.uuid4())).set({
        "alert_id": alert_id, "label": label,
        "ts": datetime.now(timezone.utc).isoformat(),
    })


def heartbeat(source: str) -> None:
    _db.collection(SOURCES).document(source).set({
        "last_seen": datetime.now(timezone.utc).isoformat(),
    }, merge=True)


def sources_health() -> list[dict]:
    return [{**d.to_dict(), "source": d.id} for d in _db.collection(SOURCES).stream()]
