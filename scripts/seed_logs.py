"""Seed synthetic CommonEvent stream → Pub/Sub `events` topic."""
from __future__ import annotations

import argparse
import json
import random
import time
from datetime import datetime, timezone

from google.cloud import pubsub_v1

SOURCES = ["lb", "cdn", "app", "gke", "nginx", "cloudsql", "node_metrics"]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--project", required=True)
    p.add_argument("--topic", default="monitoring-mlops-dev-events")
    p.add_argument("--n", type=int, default=2000)
    p.add_argument("--rate", type=float, default=50.0, help="events/sec")
    args = p.parse_args()

    pub = pubsub_v1.PublisherClient()
    topic = pub.topic_path(args.project, args.topic)

    rng = random.Random(7)
    for i in range(args.n):
        ev = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "ingest_ts": datetime.now(timezone.utc).isoformat(),
            "source": rng.choice(SOURCES),
            "host": f"host-{rng.randint(1, 50)}",
            "message": f"event-{i}",
            "status": rng.choice([200, 200, 200, 200, 301, 404, 500]),
            "latency_ms": max(1.0, rng.gauss(80, 30)),
            "bytes": rng.randint(200, 50000),
            "src_ip": f"10.0.{rng.randint(1, 255)}.{rng.randint(1, 255)}",
            "path": rng.choice(["/", "/api/v1/order", "/login", "/health"]),
        }
        pub.publish(topic, json.dumps(ev).encode("utf-8"))
        if args.rate > 0:
            time.sleep(1.0 / args.rate)
    print(f"published {args.n} events")


if __name__ == "__main__":
    main()
