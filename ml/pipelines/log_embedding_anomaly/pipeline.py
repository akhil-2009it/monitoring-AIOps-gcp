
from kfp import dsl

from ml.pipelines._shared.builder import build_pipeline, submit
from ml.pipelines._shared.config import DetectorConfig

CFG = DetectorConfig(
    detector_name="log-embedding-anomaly",
    model_display_name="log-embedding-anomaly-detector",
    metric_gate={"precision_top1pct": 0.75},
    train_machine="g2-standard-8",
    train_gpu_type="NVIDIA_L4",
    train_gpu_count=1,
    serve_machine="n1-standard-4",
)


@dsl.component(
    base_image="python:3.11-slim",
    packages_to_install=["google-cloud-storage==2.16.0", "pandas==2.2.0",
                          "pyarrow==15.0.0", "scikit-learn==1.3.2"],
)
def evaluate(model_uri: str, eval_uri: str, project_id: str, region: str) -> str:
    import io
    import json
    import pandas as pd
    from google.cloud import storage

    cli = storage.Client()
    bkt, _, prefix = eval_uri.replace("gs://", "").partition("/")
    frames = []
    for blob in cli.list_blobs(cli.bucket(bkt), prefix=prefix):
        if blob.name.endswith(".parquet"):
            frames.append(pd.read_parquet(io.BytesIO(blob.download_as_bytes())))
    df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()

    if df.empty:
        out = {"metrics": {"precision_top1pct": 0.0, "n": 0}}
    else:
        thr = df["anomaly_score"].quantile(0.99)
        top = df[df["anomaly_score"] >= thr]
        out = {"metrics": {
            "precision_top1pct": float((top["is_anomaly"] == 1).mean()) if len(top) else 0.0,
            "n": int(len(df)),
        }}

    bkt2, _, key = model_uri.replace("gs://", "").partition("/")
    cli.bucket(bkt2).blob(f"{key}eval/evaluation.json").upload_from_string(json.dumps(out))
    return json.dumps(out)


def main() -> None:
    pkg = build_pipeline(CFG, evaluate, primary_metric="precision_top1pct", op=">=")
    submit(CFG, pkg, trigger="manual")


if __name__ == "__main__":
    main()
