"""Vertex AI Endpoint client — invokes the appropriate detector based on source.

Each detector is registered in the env so the same FastAPI image can route
across all four endpoints.
"""
from __future__ import annotations

import os
from functools import lru_cache

from google.cloud import aiplatform


PROJECT_ID = os.environ["GCP_PROJECT_ID"]
REGION = os.environ.get("GCP_REGION", "asia-south1")

# Source → endpoint id mapping (numeric ids set in Helm values).
ENDPOINT_MAP: dict[str, str] = {
    "node_metrics":      os.environ.get("ENDPOINT_RCF_METRICS", ""),
    "container_metrics": os.environ.get("ENDPOINT_RCF_METRICS", ""),
    "prom_app":          os.environ.get("ENDPOINT_RCF_METRICS", ""),
    "lb":                os.environ.get("ENDPOINT_IFOREST_LOGS", ""),
    "cdn":               os.environ.get("ENDPOINT_IFOREST_LOGS", ""),
    "cloudsql":          os.environ.get("ENDPOINT_IFOREST_LOGS", ""),
    "nginx":             os.environ.get("ENDPOINT_IFOREST_LOGS", ""),
    "app":               os.environ.get("ENDPOINT_LOG_BERT", ""),
    "otel_traces":       os.environ.get("ENDPOINT_LSTM_AE", ""),
}


@lru_cache(maxsize=8)
def _endpoint(endpoint_id: str) -> aiplatform.Endpoint:
    aiplatform.init(project=PROJECT_ID, location=REGION)
    return aiplatform.Endpoint(endpoint_name=endpoint_id)


def predict(source: str, instance: dict) -> dict:
    endpoint_id = ENDPOINT_MAP.get(source)
    if not endpoint_id:
        return {"score": 0.0, "is_anomaly": False, "detector": "no-endpoint",
                "note": f"no detector configured for source={source}"}
    res = _endpoint(endpoint_id).predict(instances=[instance])
    pred = res.predictions[0] if res.predictions else {}
    return {
        "score": float(pred.get("anomaly_score", 0.0)),
        "is_anomaly": bool(pred.get("is_anomaly", False)),
        "detector": pred.get("detector", "vertex"),
        "explanation": pred.get("explanation", {}),
    }
