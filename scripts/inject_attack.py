"""Inject a fake attack — bursts 5xx + thousands of distinct src_ips.

Use:
    python scripts/inject_attack.py --project $PROJECT --duration-min 5 --kind ddos
"""
from __future__ import annotations

import argparse
import json
import random
import time
from datetime import datetime, timezone

from google.cloud import pubsub_v1

KINDS = ("ddos", "brute_force", "slow_loris")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--topic", default="monitoring-mlops-dev-events")
    p.add_argument("--duration-min", type=int, default=5)
    p.add_argument("--kind", choices=KINDS, default="ddos")
    args = p.parse_args()

    pub = pubsub_v1.PublisherClient()
    topic = pub.topic_path(args.project, args.topic)
    deadline = time.time() + args.duration_min * 60
    rng = random.Random()

    while time.time() < deadline:
        if args.kind == "ddos":
            ev = {"status": 503, "src_ip": f"203.0.113.{rng.randint(1, 254)}",
                  "path": "/", "latency_ms": 5.0, "bytes": 0}
        elif args.kind == "brute_force":
            ev = {"status": 401, "src_ip": "198.51.100.42",
                  "path": "/login", "user": "admin"}
        else:
            ev = {"status": 200, "src_ip": "192.0.2.7",
                  "path": "/upload", "latency_ms": 30000, "bytes": 100}

        ev.update({
            "ts": datetime.now(timezone.utc).isoformat(),
            "ingest_ts": datetime.now(timezone.utc).isoformat(),
            "source": "lb", "host": "edge-attack",
            "message": f"injected-{args.kind}",
        })
        pub.publish(topic, json.dumps(ev).encode("utf-8"))


if __name__ == "__main__":
    main()
