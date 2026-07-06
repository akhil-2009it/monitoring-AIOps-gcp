"""Shared config for all four anomaly detector pipelines."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Mapping


@dataclass
class DetectorConfig:
    detector_name: str                         # rcf-metrics | iforest-logs | lstm-ae-traces | log-bert
    model_display_name: str
    project_id: str = os.environ.get("GCP_PROJECT_ID", "")
    region: str = os.environ.get("GCP_REGION", "asia-south1")
    environment: str = os.environ.get("ENV", "dev")
    bucket: str = os.environ.get("MONITORING_BUCKET", "")
    service_account: str = os.environ.get("VERTEX_SERVICE_ACCOUNT", "")
    artifact_registry: str = os.environ.get("MONITORING_AR", "monitoring-mlops")

    metric_gate: Mapping[str, float] = field(default_factory=dict)

    train_machine: str = "n1-standard-4"
    train_gpu_type: str | None = None
    train_gpu_count: int = 0
    serve_machine: str = "n1-standard-2"
    serve_gpu_type: str | None = None
    serve_gpu_count: int = 0

    @property
    def pipeline_name(self) -> str:
        return f"{self.detector_name}-{self.environment}-pipeline"

    @property
    def endpoint_name(self) -> str:
        return f"{self.detector_name}-{self.environment}"

    @property
    def gcs_input_uri(self) -> str:
        return f"gs://{self.bucket}/{self.environment}/features/"

    @property
    def gcs_eval_uri(self) -> str:
        return f"gs://{self.bucket}/{self.environment}/eval/"

    @property
    def gcs_model_uri(self) -> str:
        return f"gs://{self.bucket}/{self.environment}/models/{self.detector_name}/"

    @property
    def staging_uri(self) -> str:
        return f"gs://{self.bucket}/{self.environment}/pipeline-staging/"

    @property
    def container_uri_train(self) -> str:
        return (f"{self.region}-docker.pkg.dev/{self.project_id}/"
                f"{self.artifact_registry}/{self.detector_name}-train:latest")

    @property
    def container_uri_serve(self) -> str:
        return (f"{self.region}-docker.pkg.dev/{self.project_id}/"
                f"{self.artifact_registry}/{self.detector_name}-serve:latest")


COMMON_LABELS = {
    "project": "monitoring-mlops-gcp",
    "owner": "team",
    "managed-by": "terraform",
}
