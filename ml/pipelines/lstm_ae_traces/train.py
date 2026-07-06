"""Vertex CustomJob entrypoint — LSTM-AE traces placeholder.
"""
from __future__ import annotations

import argparse
import io
import json
import tempfile
from pathlib import Path

import joblib
import pandas as pd
from google.cloud import storage
from sklearn.ensemble import IsolationForest


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--input-uri", required=True)
    p.add_argument("--output-uri", required=True)
    p.add_argument("--n-estimators", type=int, default=100)
    p.add_argument("--contamination", type=float, default=0.01)
    return p.parse_args()


def _read_features(input_uri: str) -> pd.DataFrame:
    cli = storage.Client()
    bkt, _, prefix = input_uri.replace("gs://", "").partition("/")
    frames = []
    for blob in cli.list_blobs(cli.bucket(bkt), prefix=prefix):
        if blob.name.endswith(".parquet"):
            frames.append(pd.read_parquet(io.BytesIO(blob.download_as_bytes())))
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def _upload_dir(local: Path, uri: str) -> None:
    cli = storage.Client()
    bkt, _, key = uri.replace("gs://", "").partition("/")
    bucket = cli.bucket(bkt)
    for p in local.rglob("*"):
        if p.is_file():
            rel = p.relative_to(local).as_posix()
            bucket.blob(f"{key.rstrip('/')}/{rel}").upload_from_filename(str(p))


FEATURE_COLS = [
    "request_rate", "rate_4xx", "rate_5xx", "auth_failure_rate",
    "distinct_ips", "distinct_paths", "p99_latency", "bytes_p99", "entropy_path",
]


def main() -> None:
    args = parse_args()
    df = _read_features(args.input_uri)
    if df.empty:
        raise SystemExit("no features")

    X = df[FEATURE_COLS].fillna(0).values
    model = IsolationForest(
        n_estimators=args.n_estimators,
        contamination=args.contamination,
        random_state=42, n_jobs=-1,
    )
    model.fit(X)

    work = Path(tempfile.mkdtemp())
    joblib.dump(model, work / "model.joblib")
    (work / "feature_cols.json").write_text(json.dumps(FEATURE_COLS))
    _upload_dir(work, args.output_uri)
    print(f"wrote model → {args.output_uri}")


if __name__ == "__main__":
    main()
