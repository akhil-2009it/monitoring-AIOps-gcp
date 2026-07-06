
from kfp import dsl

from ml.pipelines._shared.builder import build_pipeline, submit
from ml.pipelines._shared.config import DetectorConfig

CFG = DetectorConfig(
    detector_name="lstm-ae-traces",
    model_display_name="lstm-ae-traces-detector",
    metric_gate={"auc": 0.80},
    train_machine="g2-standard-8",
    train_gpu_type="NVIDIA_L4",
    train_gpu_count=1,
    serve_machine="n1-standard-4",
)


@dsl.component(
    base_image="python:3.11-slim",
    packages_to_install=["google-cloud-storage==2.16.0", "scikit-learn==1.3.2",
                          "pandas==2.2.0", "pyarrow==15.0.0"],
)
def evaluate(model_uri: str, eval_uri: str, project_id: str, region: str) -> str:
    import io
    import json
    import pandas as pd
    from google.cloud import storage
    from sklearn.metrics import roc_auc_score

    cli = storage.Client()
    bkt, _, prefix = eval_uri.replace("gs://", "").partition("/")
    frames = []
    for blob in cli.list_blobs(cli.bucket(bkt), prefix=prefix):
        if blob.name.endswith(".parquet"):
            frames.append(pd.read_parquet(io.BytesIO(blob.download_as_bytes())))
    df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()

    if df.empty or "is_anomaly" not in df.columns:
        out = {"metrics": {"auc": 0.0, "n": 0}}
    else:
        try:
            auc = float(roc_auc_score(df["is_anomaly"], df["recon_error"]))
        except ValueError:
            auc = 0.0
        out = {"metrics": {"auc": auc, "n": int(len(df))}}

    bkt2, _, key = model_uri.replace("gs://", "").partition("/")
    cli.bucket(bkt2).blob(f"{key}eval/evaluation.json").upload_from_string(json.dumps(out))
    return json.dumps(out)


def main() -> None:
    pkg = build_pipeline(CFG, evaluate, primary_metric="auc", op=">=")
    submit(CFG, pkg, trigger="manual")


if __name__ == "__main__":
    main()
