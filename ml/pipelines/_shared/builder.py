"""Shared Vertex Pipeline builder — all 4 detectors share this DAG shape.

    DataValidate → FeatureExtract → Train (CustomJob) → Evaluate → GateOnMetric → Register

Per-detector files only declare:
  - the training image
  - the evaluation script
  - the metric gate
"""

from typing import Callable

from kfp import compiler, dsl
from kfp.dsl import Artifact, Input, Metrics, Output

from .config import DetectorConfig, COMMON_LABELS


@dsl.component(
    base_image="python:3.11-slim",
    packages_to_install=["google-cloud-storage==2.16.0"],
)
def validate_features(
    input_uri: str,
    min_rows: int,
    report: Output[Metrics],
):
    from google.cloud import storage
    client = storage.Client()
    bkt, _, prefix = input_uri.replace("gs://", "").partition("/")
    bucket = client.bucket(bkt)
    n_files = n_rows = 0
    for blob in client.list_blobs(bucket, prefix=prefix):
        if not (blob.name.endswith(".parquet") or blob.name.endswith(".jsonl")):
            continue
        n_files += 1
        if blob.name.endswith(".jsonl"):
            n_rows += sum(1 for _ in blob.download_as_text().splitlines() if _)
    report.log_metric("n_files", n_files)
    report.log_metric("n_rows_jsonl", n_rows)
    if n_files == 0:
        raise RuntimeError("no input feature files found")


@dsl.component(
    base_image="python:3.11-slim",
    packages_to_install=["google-cloud-aiplatform==1.49.0", "google-cloud-storage==2.16.0"],
)
def gate_and_register(
    model_uri: str,
    eval_payload: str,
    project_id: str,
    region: str,
    display_name: str,
    serving_container_uri: str,
    primary_metric: str,
    threshold: float,
    op: str,
) -> str:
    import json
    from google.cloud import aiplatform

    metrics = json.loads(eval_payload).get("metrics", {})
    val = float(metrics.get(primary_metric, 0.0))
    passed = val >= threshold if op == ">=" else val <= threshold
    if not passed:
        return f"GATE_FAILED {primary_metric}={val} op={op} thr={threshold}"

    aiplatform.init(project=project_id, location=region)
    model = aiplatform.Model.upload(
        display_name=display_name,
        artifact_uri=model_uri,
        serving_container_image_uri=serving_container_uri,
        serving_container_predict_route="/predict",
        serving_container_health_route="/health",
        serving_container_ports=[8080],
        serving_container_environment_variables={
            "GOOGLE_CLOUD_PROJECT": project_id
        }
    )
    return f"REGISTERED {model.resource_name}"


def build_pipeline(
    cfg: DetectorConfig,
    eval_component: Callable,
    primary_metric: str,
    op: str,
):
    """Returns a compiled Vertex Pipeline JSON path."""

    machine_spec = {"machine_type": cfg.train_machine}
    if cfg.train_gpu_count > 0 and cfg.train_gpu_type:
        machine_spec["accelerator_type"] = cfg.train_gpu_type
        machine_spec["accelerator_count"] = cfg.train_gpu_count

    @dsl.pipeline(name=cfg.pipeline_name, description=f"{cfg.detector_name} weekly retrain")
    def _dag(
        project_id: str = cfg.project_id,
        region: str = cfg.region,
        input_uri: str = cfg.gcs_input_uri,
        eval_uri: str = cfg.gcs_eval_uri,
        model_uri: str = cfg.gcs_model_uri,
        train_container_uri: str = cfg.container_uri_train,
        serving_container_uri: str = cfg.container_uri_serve,
        train_service_account: str = cfg.service_account,
        threshold: float = list(cfg.metric_gate.values())[0] if cfg.metric_gate else 0.0,
    ):
        from google_cloud_pipeline_components.v1.custom_job import CustomTrainingJobOp

        validate_features(input_uri=input_uri, min_rows=100)

        train = CustomTrainingJobOp(
            project=project_id, location=region,
            display_name=f"{cfg.detector_name}-train",
            worker_pool_specs=[{
                "machine_spec": machine_spec, "replica_count": 1,
                "container_spec": {
                    "image_uri": train_container_uri,
                    "args": [
                        f"--input-uri={input_uri}",
                        f"--output-uri={model_uri}",
                    ],
                },
            }],
            service_account=train_service_account,
        )

        ev = eval_component(
            model_uri=model_uri,
            eval_uri=eval_uri,
            project_id=project_id,
            region=region,
        ).after(train)

        gate_and_register(
            model_uri=model_uri,
            eval_payload=ev.output,
            project_id=project_id,
            region=region,
            display_name=cfg.model_display_name,
            serving_container_uri=serving_container_uri,
            primary_metric=primary_metric,
            threshold=threshold,
            op=op,
        ).after(ev)

    out = f"{cfg.detector_name}_pipeline.json"
    compiler.Compiler().compile(pipeline_func=_dag, package_path=out)
    return out


def submit(cfg: DetectorConfig, package_path: str, trigger: str = "manual"):
    from google.cloud import aiplatform
    aiplatform.init(project=cfg.project_id, location=cfg.region, staging_bucket=cfg.staging_uri)
    job = aiplatform.PipelineJob(
        display_name=f"{cfg.pipeline_name}-{trigger}",
        template_path=package_path,
        pipeline_root=cfg.staging_uri,
        enable_caching=False,
        labels={**COMMON_LABELS, "detector": cfg.detector_name, "environment": cfg.environment},
    )
    job.submit(service_account=cfg.service_account)
    return job
