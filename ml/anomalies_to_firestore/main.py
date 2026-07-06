"""Cloud Function (gen2) — Pub/Sub `anomalies` -> Firestore `alerts`.

Consumes anomaly events emitted by the streaming detector (and any future
producer) and persists them so the AIOps Console can display them.
"""
from __future__ import annotations

import base64
import json
import os
import uuid
from datetime import datetime, timezone

import functions_framework
from google.cloud import firestore

PROJECT_ID = os.environ.get("GCP_PROJECT_ID") or os.environ["GOOGLE_CLOUD_PROJECT"]
_db = firestore.Client(project=PROJECT_ID)


def _severity(payload: dict) -> str:
    sev = payload.get("severity")
    if sev:
        return sev
    score = float(payload.get("score", payload.get("value", 0)) or 0)
    if score >= 5.0:
        return "HIGH"
    if score >= 3.0:
        return "MEDIUM"
    return "LOW"


@functions_framework.cloud_event
def handler(event):
    raw = base64.b64decode(event.data["message"]["data"]).decode("utf-8")
    payload = json.loads(raw)

    aid = payload.get("id") or str(uuid.uuid4())
    ts = payload.get("ts") or datetime.now(timezone.utc).isoformat()
    source = payload.get("source", "unknown")
    score = payload.get("score", payload.get("value"))
    try:
        score = float(score) if score is not None else 0.0
    except (TypeError, ValueError):
        score = 0.0

    doc = {
        "id": aid,
        "ts": ts,
        "detector": payload.get("detector", "streaming-statistical"),
        "severity": _severity(payload),
        "score": score,
        "source": source,
        "host": payload.get("host", "unknown"),
        "rule": payload.get("rule"),
        "metric": payload.get("metric"),
        "explanation": payload.get("explanation", {}),
    }
    _db.collection("alerts").document(aid).set(doc)
    _db.collection("sources").document(source).set(
        {"last_seen": ts}, merge=True
    )
    return {"ok": True, "id": aid}
