
from kfp import dsl
from kfp.dsl import Metrics, Output

from ml.pipelines._shared.builder import build_pipeline, submit
from ml.pipelines._shared.config import DetectorConfig


CFG = DetectorConfig(
    detector_name="rcf-metrics",
    model_display_name="rcf-metrics-detector",
    metric_gate={"f1": 0.70},
    train_machine="n1-standard-4",
    serve_machine="n1-standard-2",
)


@dsl.component(
    base_image="python:3.11-slim",
    packages_to_install=["google-cloud-aiplatform==1.49.0", "google-cloud-storage==2.16.0",
                          "scikit-learn==1.3.2", "pandas==2.2.0", "pyarrow==15.0.0"],
)
def evaluate(model_uri: str, eval_uri: str, project_id: str, region: str) -> str:
    """Evaluate RCF on injected-attack labelled set; emit F1."""
    import io
    import json
    import pandas as pd
    from google.cloud import storage
    from sklearn.metrics import f1_score, precision_score, recall_score

    cli = storage.Client()
    bkt, _, prefix = eval_uri.replace("gs://", "").partition("/")
    bucket = cli.bucket(bkt)

    frames = []
    for blob in cli.list_blobs(bucket, prefix=prefix):
        if blob.name.endswith(".parquet"):
            frames.append(pd.read_parquet(io.BytesIO(blob.download_as_bytes())))
    df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()

    if df.empty:
        out = {"metrics": {"f1": 0.0, "n": 0, "note": "no eval data"}}
    else:
        # Score is column `anomaly_score` (predicted by inference container) vs `is_anomaly`.
        y_true = df["is_anomaly"].astype(int)
        y_pred = (df["anomaly_score"] > df["anomaly_score"].quantile(0.99)).astype(int)
        out = {"metrics": {
            "f1": float(f1_score(y_true, y_pred, zero_division=0)),
            "precision": float(precision_score(y_true, y_pred, zero_division=0)),
            "recall": float(recall_score(y_true, y_pred, zero_division=0)),
            "n": int(len(df)),
        }}

    bkt2, _, key = model_uri.replace("gs://", "").partition("/")
    cli.bucket(bkt2).blob(f"{key}eval/evaluation.json").upload_from_string(json.dumps(out))
    return json.dumps(out)


def main() -> None:
    pkg = build_pipeline(CFG, evaluate, primary_metric="f1", op=">=")
    submit(CFG, pkg, trigger="manual")


if __name__ == "__main__":
    main()
