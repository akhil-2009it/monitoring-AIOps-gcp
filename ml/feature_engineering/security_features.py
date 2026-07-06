"""Sliding-window security features over CommonEvent stream.

Mirrors the AWS port shape so any detector trained on AWS features can be
re-used here. Designed to run inside a Vertex AI Processing/Custom Job.

Inputs:  GCS prefix of NDJSON CommonEvent records (or BigQuery external table).
Outputs: GCS Parquet — one row per (source, host, window_end).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
from typing import Iterator

WINDOW = timedelta(minutes=5)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--input-uri", required=True)     # gs://bucket/raw/...
    p.add_argument("--output-uri", required=True)    # gs://bucket/features/...
    p.add_argument("--window-minutes", type=int, default=5)
    return p.parse_args()


def _iter_events(uri: str) -> Iterator[dict]:
    from google.cloud import storage
    bkt, _, prefix = uri.replace("gs://", "").partition("/")
    bucket = storage.Client().bucket(bkt)
    for blob in bucket.list_blobs(prefix=prefix):
        if not blob.name.endswith(".jsonl") and not blob.name.endswith(".json"):
            continue
        for line in blob.download_as_text().splitlines():
            line = line.strip()
            if not line:
                continue
            yield json.loads(line)


def _entropy(counter: dict[str, int]) -> float:
    n = sum(counter.values()) or 1
    return -sum((c / n) * math.log2(c / n) for c in counter.values() if c)


def aggregate(events: Iterator[dict], window: timedelta):
    """Yield (source, host, window_end, features dict)."""
    buckets: dict[tuple[str, str, datetime], dict] = defaultdict(lambda: {
        "n": 0, "n_4xx": 0, "n_5xx": 0, "auth_fail": 0,
        "ips": defaultdict(int), "paths": defaultdict(int),
        "latencies": [], "bytes": [],
    })

    for e in events:
        ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
        win_end = ts.replace(second=0, microsecond=0) + window
        key = (e.get("source", "unknown"), e.get("host", "unknown"), win_end)
        b = buckets[key]
        b["n"] += 1
        status = e.get("status") or 0
        if 400 <= status < 500:
            b["n_4xx"] += 1
        if 500 <= status < 600:
            b["n_5xx"] += 1
        if status in (401, 403):
            b["auth_fail"] += 1
        if e.get("src_ip"):
            b["ips"][e["src_ip"]] += 1
        if e.get("path"):
            b["paths"][e["path"]] += 1
        if e.get("latency_ms") is not None:
            b["latencies"].append(e["latency_ms"])
        if e.get("bytes") is not None:
            b["bytes"].append(e["bytes"])

    for (source, host, win_end), b in buckets.items():
        n = b["n"]
        latencies = sorted(b["latencies"])
        bytes_ = sorted(b["bytes"])
        yield {
            "source": source,
            "host": host,
            "window_end": win_end.isoformat(),
            "request_rate": n / window.total_seconds(),
            "rate_4xx": b["n_4xx"] / n if n else 0.0,
            "rate_5xx": b["n_5xx"] / n if n else 0.0,
            "auth_failure_rate": b["auth_fail"] / n if n else 0.0,
            "distinct_ips": len(b["ips"]),
            "distinct_paths": len(b["paths"]),
            "p99_latency": latencies[int(len(latencies) * 0.99) - 1] if latencies else 0.0,
            "bytes_p99": bytes_[int(len(bytes_) * 0.99) - 1] if bytes_ else 0.0,
            "entropy_path": _entropy(b["paths"]),
        }


def write_parquet(rows: list[dict], output_uri: str) -> None:
    import pandas as pd
    if not rows:
        print("no rows to write", file=sys.stderr)
        return
    df = pd.DataFrame(rows)
    bkt, _, key = output_uri.replace("gs://", "").partition("/")
    df.to_parquet(f"gs://{bkt}/{key}", index=False)


def main() -> int:
    args = parse_args()
    rows = list(aggregate(_iter_events(args.input_uri), timedelta(minutes=args.window_minutes)))
    write_parquet(rows, args.output_uri)
    print(f"wrote {len(rows)} feature rows → {args.output_uri}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
