"""Anomaly Scoring API — GCP port.

Routes:
    POST /api/v1/score
    GET  /api/v1/alerts
    GET  /api/v1/alerts/{id}/explain
    POST /api/v1/feedback
    GET  /api/v1/sources
    GET  /health
    GET  /metrics             — Prom-format for GMP scrape
"""
from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from starlette.responses import Response

from api.scoring.schemas import (
    Alert,
    CommonEvent,
    FeedbackIn,
    ScoreResponse,
)
from api.scoring.services import store, telemetry, vertex_client

app = FastAPI(title="Anomaly Scoring API (GCP)", version="1.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

REQ = Counter("scoring_requests_total", "Total /score calls", ["source", "is_anomaly"])
LAT = Histogram("scoring_latency_seconds", "Scoring latency", ["source"])

ANOMALY_THRESHOLD = float(os.environ.get("ANOMALY_THRESHOLD", "3.0"))


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/api/v1/score", response_model=ScoreResponse)
def score(event: CommonEvent) -> ScoreResponse:
    tracer = telemetry.tracer()
    with tracer.start_as_current_span("score") as span:
        span.set_attribute("source", event.source)
        with LAT.labels(source=event.source).time():
            result = vertex_client.predict(event.source, event.model_dump())

        is_anom = result["is_anomaly"] or result["score"] >= ANOMALY_THRESHOLD
        REQ.labels(source=event.source, is_anomaly=str(is_anom).lower()).inc()
        telemetry.record_score(result["detector"], event.source, result["score"], is_anom)
        store.heartbeat(event.source)

        if is_anom:
            store.record_alert({
                "id": str(uuid.uuid4()),
                "ts": event.ts,
                "detector": result["detector"],
                "severity": "HIGH" if result["score"] >= 5.0 else "MEDIUM",
                "score": result["score"],
                "source": event.source,
                "host": event.host,
                "explanation": result.get("explanation", {}),
            })

        return ScoreResponse(
            score=result["score"], is_anomaly=is_anom,
            detector=result["detector"], explanation=result.get("explanation", {}),
        )


@app.get("/api/v1/alerts")
def alerts(
    since: str | None = Query(None),
    source: str | None = Query(None),
    severity: str | None = Query(None),
    limit: int = Query(100, le=1000),
):
    return {"items": store.list_alerts(since=since, source=source, severity=severity, limit=limit)}


@app.get("/api/v1/alerts/{alert_id}/explain")
def explain(alert_id: str):
    a = store.get_alert(alert_id)
    if not a:
        raise HTTPException(404, "alert not found")
    return {
        "alert": a,
        "top_features": a.get("explanation", {}).get("top_features", []),
        "baseline": a.get("explanation", {}).get("baseline", {}),
        "observed": a.get("explanation", {}).get("observed", {}),
        "similar_past_alerts": store.list_alerts(source=a["source"], limit=5),
    }


@app.post("/api/v1/feedback")
def feedback(body: FeedbackIn):
    store.write_feedback(body.alert_id, body.label)
    telemetry.log({"event": "feedback", "alert_id": body.alert_id, "label": body.label})
    return {"ok": True}


@app.get("/api/v1/sources")
def sources_health():
    return {"items": store.sources_health()}
