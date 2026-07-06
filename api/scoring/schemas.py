"""Schemas for Scoring API."""
from __future__ import annotations

from typing import Any, Optional

from pydantic import BaseModel, Field


class CommonEvent(BaseModel):
    ts: str
    ingest_ts: Optional[str] = None
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
    attrs: dict[str, Any] = Field(default_factory=dict)


class ScoreResponse(BaseModel):
    score: float
    is_anomaly: bool
    detector: str
    explanation: dict[str, Any]


class Alert(BaseModel):
    id: str
    ts: str
    rule: Optional[str]
    detector: str
    severity: str
    score: float
    source: str
    host: str
    metric: Optional[str] = None
    explanation: dict[str, Any] = Field(default_factory=dict)


class FeedbackIn(BaseModel):
    alert_id: str
    label: str = Field(pattern="^(true_positive|false_positive|ignored)$")
