# Signal flow — demo-app to monitoring-mlops-gcp

This is the end-to-end picture of how each of the ingestion paths wires up when the demo-app is deployed alongside the AIOps platform on GCP.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  demo-app (this directory)                                                   │
│                                                                              │
│   ┌──────────┐   ┌──────────┐   ┌──────────┐                               │
│   │ web      │   │ api      │   │ worker   │                               │
│   │ (NGINX)  │   │ (FastAPI)│   │ (Python) │                               │
│   └────┬─────┘   └────┬─────┘   └────┬─────┘                               │
│        │              │              │                                      │
│        │              ▼              ▼                                      │
│        │         ┌─────────┐    ┌─────────┐                                │
│        │         │ MySQL   │    │ Redis   │                                │
│        │         │(CloudSQL)│   │(Memory  │                                │
│        │         └────┬────┘    │  store) │                                │
│        │              │         └─────────┘                                │
│        │              ▼                                                     │
│        │         mysql-slow.log (Cloud Logging)                             │
│        │              │                                                     │
│        │              ▼                                                     │
│        │         Cloud Logging Sink (defined in demo-app/infra)             │
│        │              │                                                     │
└────────┼──────────────┼─────────────────────────────────────────────────────┘
         │              │
         │              ├──► Pub/Sub events topic: `monitoring-mlops-{env}-events`
         │              │
         │ stdout/stderr│
         ▼              ▼
    GKE default Cloud Logging (captured by Autopilot)
         │
         ├──► Logging Sink (defined in platform) ──► Pub/Sub `events` topic
         │
         ▼
    Pub/Sub events topic ──► Dataflow job ──► GCS raw: `gs://{bucket}/{env}/raw/`
                           └──► Cloud Function (streaming-statistical-detector)
                                   └──► Pub/Sub anomalies topic

    Google Managed Prometheus (GMP via PodMonitoring CR)
         │  scrapes /metrics from api/worker
         ▼
    Managed Grafana

    OpenTelemetry SDK (integrated in api/worker)
         │  via OTLP http exporter
         ▼
    OTEL collector ──► Google Cloud Trace
```

## Per-source mapping

| Source | Producer in demo | Path to platform |
|---|---|---|
| **app**           | api / worker container stdout (JSON) | Cloud Logging → Sink → Pub/Sub `events` → Dataflow → GCS |
| **nginx**         | web container access log              | Cloud Logging → Sink → Pub/Sub `events` → Dataflow → GCS |
| **cloudsql**      | Cloud SQL MySQL slow-query log       | Cloud Logging → Sink → Pub/Sub `events` → Dataflow → GCS |
| **lb**            | GCE Ingress HTTP load balancer logs   | Cloud Logging → Sink → Pub/Sub `events` → Dataflow → GCS |
| **cloud_armor**   | Cloud Armor security policy logs      | Cloud Logging → Sink → Pub/Sub `events` → Dataflow → GCS |
| **prom_app**      | api `/metrics`                        | PodMonitoring → Google Managed Prometheus (GMP) |
| **node_metrics**  | GKE Node exporter metrics             | Managed Prometheus auto-collection |
| **container_metrics**| GKE cAdvisor metrics               | Managed Prometheus auto-collection |
| **otel_traces**   | api / worker OTEL SDK                 | OTEL Collector Sidecar → Cloud Trace |

## How to verify each path

After 10 minutes of traffic from `traffic-gen/`:

```bash
# 1. Cloud SQL slow query logs / App logs in GCS raw partitions
gsutil ls gs://monitoring-mlops-dev-raw/dev/raw/source=cloudsql/ --recursive | tail
gsutil ls gs://monitoring-mlops-dev-raw/dev/raw/source=app/ --recursive | tail

# 2. Query logs via BigQuery external tables
bq query --use_legacy_sql=false \
  'SELECT source, COUNT(*) as n FROM `monitoring-mlops-gcp.monitoring.raw_events` GROUP BY 1'

# 3. Verify metrics in Google Managed Prometheus / Grafana
# Query the custom metrics endpoint or check Managed Grafana dashboard for:
# demo_api_requests_total

# 4. Verify traces in Google Cloud Trace
gcloud trace list-traces --filter="resource.type=k8s_container AND resource.labels.container_name=demo-api"
# Or open the Cloud Trace UI: https://console.cloud.google.com/traces/list

# 5. Anomalies arriving in the Pub/Sub anomalies topic
gcloud pubsub subscriptions pull monitoring-mlops-dev-anomalies-sub --limit=10
```
