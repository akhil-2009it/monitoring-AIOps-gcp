# End-to-End MLOps on GCP — Learning Guide
**Project**: `monitoring-mlops-gcp` | **Region**: `asia-south1` (Mumbai) | **Owner**: Akhil

This guide walks every layer of the platform from raw log ingestion to a live anomaly scoring API, covering what each piece does, why it exists, and how to operate it.

---

## Table of Contents

1. [Mental Model — What This Platform Does](#1-mental-model)
2. [Architecture Overview](#2-architecture-overview)
3. [GCP Service Map](#3-gcp-service-map)
4. [Layer 1–2: Sources and Ingestion](#4-sources-and-ingestion)
5. [Layer 3: Data Lake](#5-data-lake)
6. [Layer 4: Feature Engineering](#6-feature-engineering)
7. [Layer 5: Detection — Four Detectors](#7-detection)
8. [Layer 6: Model Registry and Endpoints](#8-model-registry-and-endpoints)
9. [Layer 7: Monitoring and Retraining](#9-monitoring-and-retraining)
10. [Scoring API (FastAPI on GKE)](#10-scoring-api)
11. [Infrastructure as Code (Terraform)](#11-infrastructure-as-code)
12. [Kubernetes and Helm](#12-kubernetes-and-helm)
13. [Security Model](#13-security-model)
14. [End-to-End Deployment Walkthrough](#14-end-to-end-deployment)
15. [Operating the Platform](#15-operating-the-platform)
16. [Cost Management](#16-cost-management)
17. [Key Concepts Glossary](#17-glossary)

---

## 1. Mental Model

The platform answers one question continuously: **"Is this event anomalous?"**

It does this across four detection tiers, because no single approach can cover all timescales:

```
EVENT ARRIVES
     │
     ├─► [Tier 0] GCP-managed (SCC, Cloud Armor, Event Threat Detection)
     │   Fires in seconds. No code required. Covers GCP-side threats.
     │
     ├─► [Tier 1] Streaming statistical detector (Cloud Function + rules.yaml)
     │   Fires in seconds. No training required. Works from minute one.
     │   Needs ~30 min of history for z-score rules.
     │
     ├─► [Tier 2] BigQuery ML / Elastic AD
     │   Fires in minutes. Statistical model on indexed data.
     │   Needs detector initialisation period.
     │
     └─► [Tier 3] Vertex AI Endpoints (4 trained detectors)
         Fires in milliseconds (inference). Training takes hours.
         Needs 1–7 days of labelled or unlabelled history.
```

Why tiers? Because on day one you have no trained model and no labelled data. The streaming statistical detector catches obvious attacks immediately. As data accumulates, the trained detectors come online and catch subtler, slower anomalies that rules miss.

---

## 2. Architecture Overview

```
L1  Sources
    CDN · LB · Cloud Armor · App · GKE · NGINX · Cloud SQL · MongoDB ·
    Memorystore · Prometheus metrics · OTEL traces
         │
         │ Cloud Logging export
         ▼
L2  Ingestion
    Cloud Logging sinks ──► Pub/Sub `events` topic ──► Dataflow ──► GCS (raw NDJSON)
                                    │
                                    │ direct subscription
                                    ▼
                            Cloud Function Gen2
                            (streaming-statistical-detector)
                                    │
                                    ▼
                            Pub/Sub `anomalies` topic
         │
         │ GCS batch
         ▼
L3  Data Lake
    GCS:  gs://<bucket>/<env>/raw/<source>/year=.../month=.../day=.../*.jsonl
    BigQuery: external tables over GCS (query without loading)
         │
         │ Vertex Processing / Custom Job
         ▼
L4  Feature Engineering
    security_features.py  →  gs://<bucket>/<env>/features/security/*.parquet
    (5-min sliding windows per source+host)
         │
         ▼
L5  Detection
    ┌─────────────────────────────────────────────────────────┐
    │  Vertex AI Pipelines (KFP v2 DAG per detector)          │
    │  DataValidate → FeatureExtract → Train → Evaluate       │
    │  → GateOnMetric → Register                              │
    │                                                         │
    │  Detector 1: RCF Metrics       (IsolationForest proxy)  │
    │  Detector 2: IForest Logs      (IsolationForest on logs) │
    │  Detector 3: LSTM-AE Traces    (LSTM autoencoder)        │
    │  Detector 4: Log-BERT Anomaly  (TF-IDF + IForest embed) │
    └─────────────────────────────────────────────────────────┘
         │
         │ model registration
         ▼
L6  Model Registry + Endpoints
    Vertex Model Registry  ──►  4× Vertex Endpoints
    (gated by quality metric before promotion)
         │
         │ online prediction
         ▼
APP Scoring API (FastAPI on GKE Autopilot)
    POST /api/v1/score   ──► routes to the right Vertex Endpoint by source
    GET  /api/v1/alerts  ──► anomaly log from Firestore
    GET  /api/v1/alerts/{id}/explain
    POST /api/v1/feedback
         │
         ▼
L7  Monitoring
    Drift on detector inputs · Cloud Monitoring alerts ·
    Managed Grafana · Looker Studio · Cloud Scheduler retrain triggers
```

---

## 3. GCP Service Map

Understanding why each GCP service was chosen helps you debug and extend it.

| Concern | GCP Service | Why This One |
|---|---|---|
| Object store / data lake | Cloud Storage (GCS) | Cheap, durable, Vertex-native |
| Streaming ingest | Cloud Logging → Pub/Sub → Dataflow | Cloud Logging already captures GKE/LB logs; Pub/Sub is the fan-out bus |
| Event bus | Pub/Sub | Managed, at-least-once, scales to millions/sec |
| Streaming compute | Cloud Function Gen2 | Sub-second cold start, Pub/Sub trigger built-in, no cluster to manage |
| Search + batch AD | BigQuery + `ML.DETECT_ANOMALIES` | Serverless, integrates with GCS external tables |
| ML training orchestration | Vertex AI Pipelines (KFP v2) | Native GCP: uses Artifact Registry, GCS, Vertex Training/Endpoints as first-class resources |
| Model registry | Vertex AI Model Registry | Version control + metric gate before promotion |
| Online inference | Vertex AI Endpoints | Managed autoscaling, GPU support, integrates with IAM |
| Container orchestration | GKE Autopilot | No node management; Workload Identity for secretless auth |
| Metrics scraping | Google Managed Prometheus (GMP) | No Prometheus server to operate; scrapes via `PodMonitoring` CR |
| Dashboards | Managed Grafana | GMP-native; no infra to manage |
| Container images | Artifact Registry | Regional, IAM-integrated, vulnerability scanning |
| Secrets | Secret Manager | Audit-logged, IAM-controlled, Workload Identity compatible |
| Database (alert metadata) | Cloud SQL Postgres 15 | Familiar SQL; private IP via PSA |
| WAF / DDoS | Cloud Armor | Attached to the HTTPS LB; byte-level rules |
| Threat detection | Security Command Center (SCC) | Native GCP threat Intel: VM anomaly, IAM abuse, data exfil |
| Scheduled jobs | Cloud Scheduler → Pub/Sub | Cron-like, emits a Pub/Sub message that triggers a Cloud Function |
| Observability | Cloud Monitoring + Cloud Trace (OTLP) | OpenTelemetry SDK → Cloud Trace; Prometheus → GMP |
| IaC | Terraform (google provider ~5.20) | Declarative, state-managed, team-reviewable |

---

## 4. Sources and Ingestion

### 4.1 What are "sources"?

Every event in the system carries a `source` field. The `CommonEvent` schema (in `ml/parsers/__init__.py`) defines a fixed allowed set:

```python
ALLOWED_SOURCES = {
    "cdn", "lb", "cloud_armor", "app", "gke", "nginx", "kafka",
    "cloudsql", "mongo", "redis", "node_metrics", "container_metrics",
    "prom_app", "otel_traces",
    # AWS aliases kept for cross-cloud migration windows:
    "cloudfront", "alb", "waf", "eks", "mysql",
}
```

Enforcing this at parse time means the Vertex Endpoint routing table (which maps `source → endpoint_id`) can never receive an unknown key.

### 4.2 The CommonEvent schema

Every parser normalises into this shape before anything is emitted to Pub/Sub:

```python
@dataclass
class CommonEvent:
    ts: str           # ISO-8601 event time
    ingest_ts: str    # ISO-8601 when we saw it
    source: str       # from ALLOWED_SOURCES
    host: str         # GKE pod, LB backend, VM name, etc.
    message: str      # raw log line or JSON-stringified payload
    severity: str     # DEBUG / INFO / WARN / ERROR / CRITICAL
    status: int       # HTTP status (or None)
    latency_ms: float # request latency (or None)
    bytes: int        # response size (or None)
    src_ip: str       # HMAC-hashed — never raw PII
    user: str         # HMAC-hashed — never raw PII
    path: str         # URL path
    user_agent: str
    attrs: dict       # source-specific extras
```

**PII rule**: `src_ip` and `user` are always passed through `hmac_pii()` before leaving the parser. This truncates the HMAC to 16 hex chars — enough to detect IP-burst patterns (same IP hashes the same way) without ever storing the real IP.

```python
def hmac_pii(value: str | None) -> str | None:
    if not value:
        return value
    return hmac.new(PII_HMAC_KEY, value.encode("utf-8"), hashlib.sha256).hexdigest()[:16]
```

`PII_HMAC_KEY` is loaded from the environment (set via Secret Manager in prod).

### 4.3 Per-source parsers

Each source has a parser function that returns a `CommonEvent`:

- `parse_nginx(line)` — regex on the combined log format
- `parse_cloud_armor(record)` — JSON payload from Cloud Logging export
- `parse_lb(record)` — GCP HTTPS LB request log
- `parse_app_json(record)` — structured app logs (supports both `ts`/`timestamp`, `message`/`msg`)
- `parse_cloudsql_slow(record)` — Cloud SQL slow query log

The dict `PARSERS = {"nginx": parse_nginx, ...}` is the dispatch table used by the Dataflow pipeline and the seeding script.

### 4.4 Ingestion path

```
App / GKE / LB / Cloud Armor
         │
         │  (auto-captured)
         ▼
Cloud Logging
         │
         │  log sink (Terraform-managed)
         ▼
Pub/Sub topic: monitoring-mlops-{env}-events
         │
         ├──► Subscription: events-streaming
         │    └──► Cloud Function (streaming detector — real-time path)
         │
         └──► Dataflow job (batch path)
              └──► GCS: gs://{bucket}/{env}/raw/{source}/year=…/month=…/day=…/*.jsonl
```

The `events` topic has **two consumers**: the Cloud Function (immediate) and Dataflow (archival). The Cloud Function ACKs its subscription independently; messages are not lost if the Function is slow.

### 4.5 Synthetic data seeding

`scripts/seed_logs.py` publishes fake `CommonEvent` dicts directly to the `events` topic, letting you fill the lake and trigger the streaming detector without real traffic:

```bash
python scripts/seed_logs.py \
    --project $GCP_PROJECT_ID \
    --topic monitoring-mlops-${ENV}-events \
    --n 5000 --rate 100
```

`scripts/inject_attack.py` sends a high-rate burst with `status=503` and elevated `latency_ms` to trigger the `error_rate_spike` and `latency_z_spike` streaming rules.

---

## 5. Data Lake

### 5.1 GCS layout

```
gs://{bucket}/{env}/
├── raw/
│   ├── lb/year=2026/month=06/day=20/*.jsonl
│   ├── nginx/…
│   └── app/…
├── features/
│   └── security/*.parquet     ← output of security_features.py
├── eval/                      ← labelled holdout sets per detector
│   ├── rcf-metrics/*.parquet
│   └── …
├── models/
│   ├── rcf-metrics/           ← model.joblib + feature_cols.json
│   ├── iforest-logs/
│   └── …
└── pipeline-staging/          ← Vertex Pipeline compiled JSONs + intermediate artifacts
```

The bucket has uniform bucket-level access (no per-object ACLs) and versioning enabled so you can roll back a bad model artifact.

### 5.2 BigQuery external tables

BigQuery can query the GCS NDJSON files directly via external tables, so an analyst can run:

```sql
SELECT source, COUNT(*) as n, AVG(latency_ms) as avg_lat
FROM `project.monitoring.raw_events`
WHERE DATE(ts) = CURRENT_DATE()
GROUP BY 1
```

...without a load job. The Terraform `search/` module creates these table definitions.

---

## 6. Feature Engineering

`ml/feature_engineering/security_features.py` is a Python script run as a **Vertex Custom Job** (or locally). It reads raw CommonEvent NDJSON from GCS, aggregates into 5-minute tumbling windows per `(source, host)`, and writes Parquet to the features prefix.

### 6.1 What features are computed?

For every `(source, host, window_end)` tuple:

| Feature | What it captures | Threat signal |
|---|---|---|
| `request_rate` | requests per second in the window | DDoS / traffic spike |
| `rate_4xx` | fraction of 4xx responses | scanning / path bruteforce |
| `rate_5xx` | fraction of 5xx responses | service degradation / attack impact |
| `auth_failure_rate` | fraction of 401/403 responses | credential stuffing |
| `distinct_ips` | unique HMAC'd source IPs | distributed attack |
| `distinct_paths` | unique URL paths | path enumeration / fuzzing |
| `p99_latency` | 99th percentile latency ms | slowloris / resource exhaustion |
| `bytes_p99` | 99th percentile response size | data exfiltration |
| `entropy_path` | Shannon entropy of path distribution | abnormal access pattern diversity |

### 6.2 Why these features?

The feature set was designed to be **detector-agnostic**. The same Parquet files feed the IsolationForest (Detector 1 & 2), the LSTM-AE (Detector 3, after reshaping into sequences), and the streaming statistical rules. Changing a feature definition requires retraining *all* detectors — this is a sensitive area.

### 6.3 Running feature engineering

```bash
python ml/feature_engineering/security_features.py \
  --input-uri  gs://$BUCKET/$ENV/raw/ \
  --output-uri gs://$BUCKET/$ENV/features/security/ \
  --window-minutes 5
```

In production this is triggered by a Vertex Pipeline step (`FeatureExtract`) before training.

---

## 7. Detection

### 7.1 Tier 1 — Streaming statistical detector

**File**: `ml/streaming/detector.py`  
**Runtime**: Cloud Function Gen2, triggered by Pub/Sub `events` subscription  
**Rules**: `ml/streaming/rules.yaml`

The function receives a base64-encoded `CommonEvent` JSON from Pub/Sub, deserialises it, and runs each rule from `rules.yaml` against the relevant metric field. No training required.

**Rule types** (all implemented in `_check()`):

- `threshold` — fire if `value op threshold` (e.g., `rate_5xx > 0.05`)
- `zscore` — fire if `|(value − rolling_mean) / rolling_std| > threshold`; needs 30 samples in history (≈ 2.5 min at 5-sec windows)
- `rate_of_change` — fire if `|Δvalue / prev| × 100 > threshold_pct`
- `ewma` — exponential weighted moving average; fire if deviation from EWMA exceeds `deviation_sigma` standard deviations

**In-process state**: `_HISTORY` (a deque of recent values per `(source, host, metric)`) and `_EWMA` (running EWMA state) are module-level dicts. This means state is **warm** as long as the function instance is alive, but **lost on cold start**. The `maxlen=360` deque holds 30 minutes of data at 5-second granularity.

**What happens when a rule fires**:

1. An anomaly dict is published to `Pub/Sub anomalies` topic
2. A structured log is written to Cloud Logging at the rule's severity level
3. A custom metric `custom.googleapis.com/aiops/streaming/anomalies` is emitted to Cloud Monitoring (labelled by `rule` and `source`)

**Current rules**:

```yaml
rules:
  - name: error_rate_spike       # rate_5xx > 5%         → HIGH
  - name: distinct_ip_burst      # distinct_ips > 10,000  → HIGH  (DDoS)
  - name: latency_z_spike        # p99_latency z-score > 4 → MEDIUM
  - name: auth_fail_burst        # auth_failure_rate ROC > 200% → HIGH
  - name: 4xx_creep              # rate_4xx EWMA drift 3σ  → LOW
```

> **Operator tip**: `rules.yaml` is the highest-false-positive risk file in the repo. Any threshold change must be validated on historical data before deploy. A too-sensitive rule drowns on-call in noise.

### 7.2 Tier 3 — Vertex AI Pipelines (trained detectors)

All four detectors share the same KFP v2 DAG, defined in `ml/pipelines/_shared/builder.py`:

```
DataValidate → Train (CustomJob) → Evaluate → GateOnMetric → Register
```

Per-detector files only declare:
- the Docker training image URI
- the `evaluate()` KFP component (how to compute the quality metric)
- the `metric_gate` (what score is required to register the model)

#### The shared DAG in detail

**Step 1 — `validate_features`**

Counts files and rows in the GCS features prefix. Raises `RuntimeError` if no files are found. This prevents a pipeline from training on an empty dataset, which would silently produce a useless model.

**Step 2 — `CustomTrainingJobOp`**

Launches a Vertex Custom Training Job with the detector's training Docker image. The image runs `train.py` (or equivalent), reads features from GCS, fits the model, and uploads `model.joblib` + metadata back to `gs://{bucket}/{env}/models/{detector}/`. Machine type is set per-detector:

- `n1-standard-4` Spot for RCF and IForest (CPU-only)
- `g2-standard-8` + 1× L4 GPU Spot for LSTM-AE and Log-BERT

Spot (preemptible) saves ~70% on training cost. The pipeline will retry if preempted.

**Step 3 — `evaluate()`** (per-detector KFP component)

Reads labelled eval Parquet from `gs://{bucket}/{env}/eval/`, computes the primary metric, uploads `evaluation.json` alongside the model artifacts, and returns the metrics payload as a JSON string.

**Step 4 — `gate_and_register`**

Parses the evaluation JSON. If `metric >= threshold` (or `<=` for loss-like metrics), it calls `aiplatform.Model.upload()` to register the model in Vertex Model Registry with the serving container URI. If the gate fails, the step returns `"GATE_FAILED ..."` instead of raising — the pipeline completes without registering, so the previous model stays live.

#### Detector 1: RCF Metrics

```python
CFG = DetectorConfig(
    detector_name="rcf-metrics",
    metric_gate={"f1": 0.70},          # must achieve F1 ≥ 0.70 on labelled eval set
    train_machine="n1-standard-4",
    serve_machine="n1-standard-2",
)
```

**Algorithm**: `sklearn.IsolationForest` (`n_estimators=100`, `contamination=0.01`). GCP has no managed RCF container, so IsolationForest is used — it has essentially the same behaviour (random partition trees, anomaly score = average path length).

**Trains on**: the 9 security feature columns from the Parquet files.

**Eval metric**: F1 score at the 99th percentile score threshold vs. `is_anomaly` labels from the injected-attack eval set. Gate: `f1 ≥ 0.70`.

**Serves**: `node_metrics`, `container_metrics`, `prom_app` sources.

#### Detector 2: IForest Logs

```python
CFG = DetectorConfig(
    detector_name="iforest-logs",
    metric_gate={"precision_top1pct": 0.80},
    train_machine="n1-standard-4",
    serve_machine="n1-standard-2",
)
```

Same IsolationForest algorithm but trained on log-derived features (`lb`, `cdn`, `cloudsql`, `nginx`). The eval metric is **Precision@1%**: of the top 1% highest-scored events, at least 80% must be true anomalies. This is more appropriate than F1 when anomalies are very rare (< 1% of traffic).

#### Detector 3: LSTM-AE Traces

```python
CFG = DetectorConfig(
    detector_name="lstm-ae-traces",
    metric_gate={"auc": 0.80},
    train_machine="g2-standard-8",
    train_gpu_type="NVIDIA_L4",
    train_gpu_count=1,
    serve_machine="n1-standard-4",
)
```

Trained on OTEL trace sequences (`otel_traces` source). An LSTM autoencoder learns to reconstruct normal trace latency/error sequences; high reconstruction error signals an anomaly. Eval metric: ROC-AUC ≥ 0.80. Needs a GPU for training (L4, not A100/H100).

#### Detector 4: Log-BERT Anomaly (Log Embedding)

```python
CFG = DetectorConfig(
    detector_name="log-embedding-anomaly",
    metric_gate={"precision_top1pct": 0.75},
    train_machine="g2-standard-8",
    train_gpu_type="NVIDIA_L4",
    train_gpu_count=1,
    serve_machine="n1-standard-4",
)
```

Embeds log messages via TF-IDF (or a fine-tuned BERT-lite, hence the name) and runs IsolationForest in embedding space. Catches semantic anomalies ("SQL injection in message body") that feature-space detectors miss. Serves `app` source logs. Gate: Precision@1% ≥ 0.75.

### 7.3 Naming conventions

```
Pipeline name: {detector_name}-{environment}-pipeline
              e.g. rcf-metrics-dev-pipeline

Endpoint name: {detector_name}-{environment}
              e.g. rcf-metrics-dev

Model artifact: gs://{bucket}/{env}/models/{detector_name}/
Container train: {region}-docker.pkg.dev/{project}/{ar_repo}/{detector_name}-train:latest
Container serve: {region}-docker.pkg.dev/{project}/{ar_repo}/{detector_name}-serve:latest
```

---

## 8. Model Registry and Endpoints

### 8.1 Vertex Model Registry

When `gate_and_register` succeeds, it calls:

```python
model = aiplatform.Model.upload(
    display_name=cfg.model_display_name,
    artifact_uri=model_uri,                     # gs://… path to model.joblib
    serving_container_image_uri=serving_uri,    # Artifact Registry image
    serving_container_predict_route="/predict",
    serving_container_health_route="/health",
    serving_container_ports=[8080],
)
```

The registry tracks every version with its evaluation metrics. You can compare versions in the Vertex console before promoting.

### 8.2 Vertex Endpoints

Each detector gets its own endpoint:

| Endpoint | Serves | Machine | GPU |
|---|---|---|---|
| `rcf-metrics-{env}` | node_metrics, container_metrics, prom_app | n1-standard-2 | — |
| `iforest-logs-{env}` | lb, cdn, cloudsql, nginx | n1-standard-2 | — |
| `lstm-ae-traces-{env}` | otel_traces | n1-standard-4 | 1× L4 |
| `log-embedding-anomaly-{env}` | app | n1-standard-4 | 1× L4 |

Endpoints are deployed with `min-replica-count=1`, `max-replica-count=2` and `traffic-split=0=100` (all traffic to the latest deployed model version).

### 8.3 Source → Endpoint routing

The Scoring API's `vertex_client.py` maps `source` strings to endpoint IDs:

```python
ENDPOINT_MAP = {
    "node_metrics":      ENDPOINT_RCF_METRICS,
    "container_metrics": ENDPOINT_RCF_METRICS,
    "prom_app":          ENDPOINT_RCF_METRICS,
    "lb":                ENDPOINT_IFOREST_LOGS,
    "cdn":               ENDPOINT_IFOREST_LOGS,
    "cloudsql":          ENDPOINT_IFOREST_LOGS,
    "nginx":             ENDPOINT_IFOREST_LOGS,
    "app":               ENDPOINT_LOG_BERT,
    "otel_traces":       ENDPOINT_LSTM_AE,
}
```

If a source has no entry (e.g., `kafka`, `redis`), the API returns `score=0.0, is_anomaly=False` with a `note` field — no exception, no 500.

---

## 9. Monitoring and Retraining

### 9.1 Drift monitoring

The platform monitors **detector inputs** (the feature vectors), not predictions. Why? Because input drift means the model is being asked to score data it was never trained on — its predictions become unreliable even if they look confident. Output drift (e.g., sudden spike in predicted anomalies) is a lagging indicator of the same problem.

The `ml/monitoring/` module (and `L7 Monitoring` in the Terraform) watches the feature distribution. When input features drift beyond a threshold, a Cloud Monitoring alert fires → retraining is triggered.

### 9.2 Retraining triggers

Retraining is driven by Cloud Scheduler → `retrain` Pub/Sub topic → Cloud Function → `ml.pipelines.<detector>.pipeline.main()`:

```
Cloud Scheduler (cron) ──► Pub/Sub `retrain` ──► Cloud Function `pipeline-trigger`
                                                       │
                                                       ▼
                                               Vertex Pipeline submitted
```

Schedules (set in Terraform):

- **RCF Metrics**: daily at 02:00 UTC (`0 2 * * *`) — metrics change quickly
- **LSTM-AE Traces**: weekly Sat 20:30 UTC / Sun 02:00 IST (`30 20 * * SAT`) — trace patterns change slowly

IForest Logs and Log-BERT can be added to the scheduler similarly.

### 9.3 Cloud Monitoring alert policies

A precision-drop alert fires if the custom metric `aiops/scoring/anomalies` falls below 0.75 over a 1-hour rolling window:

```hcl
resource "google_monitoring_alert_policy" "precision_drop" {
  conditions {
    condition_threshold {
      filter     = "metric.type=\"custom.googleapis.com/aiops/scoring/anomalies\""
      comparison = "COMPARISON_LT"
      threshold_value = 0.75
      duration   = "3600s"
    }
  }
}
```

The streaming detector emits `custom.googleapis.com/aiops/streaming/anomalies` per rule fire. The scoring API (FastAPI) emits `scoring_requests_total` and `scoring_latency_seconds` in Prometheus format on `/metrics`, scraped by GMP via the `PodMonitoring` CR.

### 9.4 Dashboards

- **Managed Grafana**: connected to GMP; shows per-source request rates, detector latency, anomaly rate, streaming rule fire counts
- **Looker Studio**: connected to BigQuery; shows longer-term trends over the raw event lake

---

## 10. Scoring API

**File**: `api/scoring/main.py`  
**Runtime**: FastAPI on GKE Autopilot, 2–8 replicas, HPA at 70% CPU

### 10.1 Routes

| Route | Purpose |
|---|---|
| `GET /health` | Liveness probe — returns `{"status": "ok"}` |
| `GET /metrics` | Prometheus-format metrics for GMP scrape |
| `POST /api/v1/score` | Score a single CommonEvent; returns `{score, is_anomaly, detector, explanation}` |
| `GET /api/v1/alerts` | Query stored anomaly alerts (filterable by `since`, `source`, `severity`, `limit`) |
| `GET /api/v1/alerts/{id}/explain` | Full explanation: top features, baseline vs observed, similar past alerts |
| `POST /api/v1/feedback` | Label an alert as true positive / false positive (written to Firestore) |
| `GET /api/v1/sources` | Per-source heartbeat / health status |

### 10.2 Scoring flow

```python
@app.post("/api/v1/score")
def score(event: CommonEvent) -> ScoreResponse:
    # 1. Start an OTEL trace span
    # 2. Route to the right Vertex Endpoint based on event.source
    result = vertex_client.predict(event.source, event.model_dump())
    # 3. Classify as anomaly if score >= ANOMALY_THRESHOLD (default 3.0)
    is_anom = result["is_anomaly"] or result["score"] >= ANOMALY_THRESHOLD
    # 4. Increment Prometheus counters
    # 5. If anomaly: write to Firestore alert store
    return ScoreResponse(score=..., is_anomaly=..., detector=..., explanation=...)
```

`ANOMALY_THRESHOLD` is configurable via environment variable, allowing you to tune sensitivity per-environment (e.g., lower threshold in prod to catch more, higher in dev to reduce noise).

### 10.3 Telemetry

The API emits three telemetry signals:

- **Traces**: every `/score` call is wrapped in an OTEL span (`score`), exported to Cloud Trace via the OTEL collector sidecar (configured in `helm/charts/otel-collector/`)
- **Metrics**: `scoring_requests_total{source, is_anomaly}` and `scoring_latency_seconds{source}` in Prometheus format, scraped by GMP
- **Logs**: structured JSON to Cloud Logging via the `store.heartbeat()` and `telemetry.log()` calls

### 10.4 Workload Identity (secretless auth)

The FastAPI pod never holds a credential file. Instead:

```
Kubernetes ServiceAccount: anomaly-scoring-api
      │  (annotated: iam.gke.io/gcp-service-account=aiops-runner@...)
      │
      ▼ Workload Identity Federation
GCP Service Account: aiops-runner
      │  (has: roles/aiplatform.user, roles/storage.objectAdmin, ...)
      │
      ▼
Vertex Endpoints / GCS / Firestore / Cloud SQL
```

Terraform provisions the `iam.workloadIdentityUser` binding. The Helm chart annotates the KSA. No `GOOGLE_APPLICATION_CREDENTIALS` file, no JSON key on disk.

---

## 11. Infrastructure as Code

All GCP resources are declared in `infra/main.tf` (monolithic for simplicity; the `modules/` subdirectories hold more granular configs).

### 11.1 APIs enabled by Terraform

Terraform's first action is enabling the required GCP APIs:

```hcl
resource "google_project_service" "apis" {
  for_each = toset([
    "aiplatform.googleapis.com",  "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com", "cloudscheduler.googleapis.com",
    "cloudtrace.googleapis.com",  "container.googleapis.com",
    "dataflow.googleapis.com",    "pubsub.googleapis.com",
    "secretmanager.googleapis.com", "securitycenter.googleapis.com",
    ...
  ])
}
```

This is idempotent — running `terraform apply` twice is safe.

### 11.2 Resource naming convention

All resources use a `local.prefix = "monitoring-mlops-${var.environment}"` prefix and carry the same label set:

```hcl
labels = {
  project     = "monitoring-mlops-gcp"
  owner       = "team"
  environment = var.environment
  managed-by  = "terraform"
}
```

Labels let you filter resources in the console, set billing budget alerts per project, and audit ownership.

### 11.3 Key Terraform resources

**GCS lake bucket** — versioned, uniform access, labelled. One bucket per environment (dev/prod).

**Artifact Registry** — Docker format, regional. All detector training and serving images live here.

**Pub/Sub topics** — three topics: `events` (raw stream), `anomalies` (detector output), `retrain` (cron trigger).

**Service account `aiops-runner`** with 12 IAM roles — this single SA is used by: GKE pods (via WLI), Cloud Functions, Vertex Training Jobs, and Vertex Endpoints. Minimum-privilege: only the roles needed for the platform's operations.

**GKE Autopilot** — `enable_autopilot = true`. No node pool config, no OS patching. Google manages node lifecycle. Workload Identity pool bound to the project.

**Cloud SQL Postgres 15** — private IP (no public endpoint), `db-custom-1-3840` (1 vCPU, 3840 MB RAM), 20 GB disk. Used by the Scoring API's `store.py` for alert persistence and analyst metadata.

**Cloud Armor** — default-deny policy with a placeholder allow rule (tighten to your CIDR in prod). Attached to the HTTPS LB via BackendConfig on the Scoring API ingress.

**Cloud Scheduler** — two jobs posting to `retrain` topic. Terraform manages the schedule; a Cloud Function subscribing to the topic actually launches the pipeline.

**Cloud Monitoring alert** — fires when `aiops/scoring/anomalies` metric drops below 0.75 for 1 hour (precision drop = model degradation signal).

---

## 12. Kubernetes and Helm

The Scoring API is deployed via the `helm/charts/anomaly-scoring-api/` chart.

### 12.1 What the chart creates

- `Deployment` — 2 replicas minimum, `requests: {cpu: 250m, memory: 512Mi}`, `limits: {cpu: 1, memory: 1Gi}`
- `Service` — ClusterIP on port 80, targets 8080
- `ServiceAccount` — annotated with the GCP SA for Workload Identity
- `Ingress` — GCE ingress class, points to static IP `aiops-scoring-ip`, managed TLS cert
- `PodMonitoring` — GMP custom resource; scrapes `/metrics` every 30s
- `HorizontalPodAutoscaler` — 2–8 replicas, CPU target 70%

### 12.2 Environment variables injected via Helm

```yaml
env:
  GCP_PROJECT_ID: ""         # set at helm upgrade time
  GCP_REGION: asia-south1
  ANOMALY_THRESHOLD: "3.0"
  ENDPOINT_RCF_METRICS: ""   # Vertex endpoint numeric ID
  ENDPOINT_IFOREST_LOGS: ""
  ENDPOINT_LSTM_AE: ""
  ENDPOINT_LOG_BERT: ""
  OTEL_EXPORTER_OTLP_ENDPOINT: otel-collector.observability.svc.cluster.local:4317
```

The four `ENDPOINT_*` vars link the API to the Vertex endpoints. These are captured from `gcloud ai endpoints list` output after step 6 of the deployment.

### 12.3 Fluent Bit

`helm/charts/fluent-bit/` runs as a DaemonSet, tailing `/var/log/containers/*.log` and shipping to Cloud Logging. This is how GKE pod logs become available in the `app` source for the pipeline.

---

## 13. Security Model

### 13.1 No credentials on disk

Every compute component authenticates via GCP's managed identity:
- GKE pods → Workload Identity → `aiops-runner` GSA
- Cloud Functions → `--service-account=aiops-runner@...`
- Vertex Training Jobs → `service_account=cfg.service_account`

No JSON key files. No `GOOGLE_APPLICATION_CREDENTIALS` env vars in prod.

### 13.2 PII handling

Raw IPs and usernames are HMAC'd in the parser before any storage, streaming, or training step. The HMAC key is in Secret Manager; pods read it at startup via the Secret Manager SDK (or Workload Identity + Secret Manager webhook).

### 13.3 Network security

- Cloud SQL has **no public IP**. Access is via Private Services Access (PSA) from within the VPC.
- GKE Autopilot nodes are not directly internet-accessible.
- The only internet ingress is the HTTPS LB, protected by Cloud Armor.
- The Cloud Armor policy (as committed) is a placeholder — in prod, restrict `src_ip_ranges` to your known consumers.

### 13.4 Security Command Center (SCC)

SCC is enabled in `infra/modules/scc/`. It provides:
- **Event Threat Detection** — detects IAM abuse, cryptocurrency mining, data exfiltration
- **Security Health Analytics** — checks for public GCS buckets, overly permissive IAM, unencrypted disks
- **Findings** → Cloud Pub/Sub → alert pipelines (configured in the SCC Terraform module)

**Do not disable SCC** — it is the platform's GCP-side threat Intel layer and works from day one with zero instrumentation.

---

## 14. End-to-End Deployment

### Prerequisites

```bash
gcloud --version   # >= 460
terraform --version  # >= 1.6
helm version       # >= 3.13
kubectl version    # >= 1.28
python --version   # 3.11
docker --version

export GCP_PROJECT_ID=<your-project>
export GCP_REGION=asia-south1
export ENV=dev

gcloud config set project $GCP_PROJECT_ID
gcloud auth login
gcloud auth application-default login
```

Quotas to raise before starting: 1 L4 GPU for Vertex training, 1 L4 GPU for Vertex serving, GKE Autopilot vCPU (at least 4).

### Step 1 — Terraform: bootstrap the platform

```bash
cd infra

cat > terraform.tfvars <<EOF
project_id  = "$GCP_PROJECT_ID"
region      = "$GCP_REGION"
environment = "$ENV"
domain      = "aiops.example.com"
EOF

terraform init
terraform apply -auto-approve

# Capture outputs for later steps
export BUCKET=$(terraform output -raw bucket)
export AR_REPO=$(terraform output -raw artifact_registry)
export RUNNER_SA=$(terraform output -raw service_account)
export GKE=$(terraform output -raw gke_cluster_name)
export EVENTS_TOPIC=$(terraform output -raw events_topic)
```

After this, you have: GCS bucket, Artifact Registry, 3 Pub/Sub topics, GKE cluster, Cloud SQL, Cloud Armor, Cloud Scheduler jobs, and Cloud Monitoring alert policy.

### Step 2 — Build and push containers

```bash
gcloud auth configure-docker $GCP_REGION-docker.pkg.dev
TAG="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/$AR_REPO"

# Scoring API
docker build -t $TAG/anomaly-scoring-api:latest -f api/scoring/Dockerfile .
docker push $TAG/anomaly-scoring-api:latest

# Detector training images
for d in rcf_metrics iforest_logs lstm_ae_traces log_embedding_anomaly; do
  docker build -t $TAG/${d//_/-}-train:latest -f ml/pipelines/$d/Dockerfile . || true
  docker push $TAG/${d//_/-}-train:latest || true
done

# Detector serving images (reuse sklearn prebuilt for IForest-based detectors)
docker pull us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest
docker tag  us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest $TAG/rcf-metrics-serve:latest
docker tag  us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest $TAG/iforest-logs-serve:latest
docker push $TAG/rcf-metrics-serve:latest && docker push $TAG/iforest-logs-serve:latest
```

### Step 3 — Seed synthetic data

```bash
export PYTHONPATH=$(pwd)
python scripts/seed_logs.py \
  --project $GCP_PROJECT_ID \
  --topic monitoring-mlops-${ENV}-events \
  --n 5000 --rate 100
```

This puts 5,000 events into the Pub/Sub `events` topic. The streaming detector fires immediately (threshold rules). Dataflow lands raw events in GCS for the batch pipeline.

### Step 4 — Deploy the streaming detector

```bash
gcloud functions deploy monitoring-mlops-${ENV}-streaming-detector \
  --gen2 --runtime=python311 --region=$GCP_REGION \
  --source=ml/streaming \
  --entry-point=handler \
  --trigger-topic=monitoring-mlops-${ENV}-events \
  --service-account=$RUNNER_SA \
  --memory=1Gi --timeout=120s \
  --set-env-vars="GCP_PROJECT_ID=$GCP_PROJECT_ID,ANOMALY_TOPIC=monitoring-mlops-${ENV}-anomalies"
```

Test immediately by injecting an attack:

```bash
python scripts/inject_attack.py --project $GCP_PROJECT_ID --kind ddos --duration-min 2 &
# Watch the anomalies topic
gcloud pubsub subscriptions pull monitoring-mlops-${ENV}-anomalies-sub --auto-ack --limit=10
```

### Step 5 — Feature engineering and train detectors

```bash
# Generate features from the raw GCS data
python ml/feature_engineering/security_features.py \
  --input-uri  gs://$BUCKET/$ENV/raw/ \
  --output-uri gs://$BUCKET/$ENV/features/security/ \
  --window-minutes 5

# Submit all four detector pipelines to Vertex
for d in rcf_metrics iforest_logs lstm_ae_traces log_embedding_anomaly; do
  python -m ml.pipelines.$d.pipeline
done
```

Each pipeline compiles a KFP JSON, uploads it, and submits a `PipelineJob`. You can monitor progress in the Vertex AI → Pipelines console. Pipelines take 10–30 minutes for CPU detectors, 1–3 hours for GPU detectors (LSTM-AE, Log-BERT).

### Step 6 — Deploy detectors to Vertex Endpoints

After pipelines complete and models are registered (check Vertex AI → Model Registry):

```bash
deploy_endpoint() {
  local NAME="$1" DISPLAY="$2" MACHINE="$3" GPU="${4:-}"
  gcloud ai endpoints create --display-name="$NAME" --region=$GCP_REGION || true
  EID=$(gcloud ai endpoints list --region=$GCP_REGION \
        --filter="displayName=$NAME" --format="value(name)" | awk -F/ '{print $NF}')
  MODEL=$(gcloud ai models list --region=$GCP_REGION \
          --filter="displayName=$DISPLAY" --sort-by="~createTime" --limit=1 \
          --format="value(name)")
  gcloud ai endpoints deploy-model "$EID" --region=$GCP_REGION \
    --model="$MODEL" --display-name="$DISPLAY-v1" \
    --machine-type="$MACHINE" ${GPU:+--accelerator=$GPU} \
    --min-replica-count=1 --max-replica-count=2 \
    --service-account=$RUNNER_SA --traffic-split=0=100
  echo "$NAME → endpoint id: $EID"
}

deploy_endpoint rcf-metrics-${ENV}      rcf-metrics-detector         n1-standard-2
deploy_endpoint iforest-logs-${ENV}     iforest-logs-detector        n1-standard-2
deploy_endpoint lstm-ae-traces-${ENV}   lstm-ae-traces-detector      n1-standard-4  "type=nvidia-l4,count=1"
deploy_endpoint log-embedding-${ENV}    log-embedding-anomaly-detector n1-standard-4 "type=nvidia-l4,count=1"
```

Note the numeric endpoint IDs — you'll need them for the Helm deploy.

### Step 7 — Deploy the Scoring API on GKE

```bash
gcloud container clusters get-credentials $GKE --region=$GCP_REGION

helm upgrade --install anomaly-scoring-api helm/charts/anomaly-scoring-api \
  --namespace default \
  --set image.repository=$TAG/anomaly-scoring-api \
  --set image.tag=latest \
  --set env.GCP_PROJECT_ID=$GCP_PROJECT_ID \
  --set env.GCP_REGION=$GCP_REGION \
  --set env.ENDPOINT_RCF_METRICS=<rcf-endpoint-id> \
  --set env.ENDPOINT_IFOREST_LOGS=<iforest-endpoint-id> \
  --set env.ENDPOINT_LSTM_AE=<lstm-endpoint-id> \
  --set env.ENDPOINT_LOG_BERT=<logbert-endpoint-id> \
  --set ingress.host=aiops.example.com \
  --set "serviceAccount.annotations.iam\.gke\.io/gcp-service-account=$RUNNER_SA"
```

Point DNS `aiops.example.com → aiops-scoring-ip` (the static IP output by Terraform).

### Step 8 — Wire the weekly retrain

```bash
gcloud functions deploy monitoring-mlops-${ENV}-pipeline-trigger \
  --gen2 --runtime=python311 --region=$GCP_REGION \
  --source=ml/pipelines/_shared \
  --entry-point=cloud_event_trigger \
  --trigger-topic=monitoring-mlops-${ENV}-retrain \
  --service-account=$RUNNER_SA \
  --set-env-vars="GCP_PROJECT_ID=$GCP_PROJECT_ID,GCP_REGION=$GCP_REGION,\
MONITORING_BUCKET=$BUCKET,MONITORING_AR=$AR_REPO,\
VERTEX_SERVICE_ACCOUNT=$RUNNER_SA,ENV=$ENV"
```

The Cloud Scheduler jobs (already created by Terraform in Step 1) will fire automatically at their scheduled times.

### Step 9 — Smoke test

```bash
SCORING_HOST=aiops.example.com bash scripts/smoke_test.sh
```

The smoke test calls: `/health` → `/api/v1/score` with a normal event → `/api/v1/score` with a DDoS event → `/api/v1/alerts`.

Expected success state:

| Check | Expected |
|---|---|
| `gcloud ai endpoints list --region=$GCP_REGION` | 4 endpoints, status `DEPLOYED` |
| `kubectl get pods -l app=anomaly-scoring-api` | All `Running` |
| `/api/v1/score` p99 latency | < 250 ms |
| `/api/v1/alerts` after attack inject | `items` array non-empty |
| Cloud Monitoring → Metrics Explorer | `aiops/streaming/anomalies` has datapoints |
| Cloud Trace | `score` spans visible |
| Cloud Scheduler → last run status | `SUCCESS` |

---

## 15. Operating the Platform

### 15.1 Checking detector health

```bash
# Are Vertex Endpoints up?
gcloud ai endpoints list --region=$GCP_REGION --format="table(displayName,deployedModels[0].dedicatedResources.machineSpec.machineType)"

# API pods healthy?
kubectl get pods -l app=anomaly-scoring-api
kubectl logs -l app=anomaly-scoring-api --tail=50

# Streaming detector firing?
gcloud logging read 'logName="projects/$GCP_PROJECT_ID/logs/aiops-streaming-detector"' --limit=20
```

### 15.2 Manual pipeline trigger

```bash
python -m ml.pipelines.rcf_metrics.pipeline   # triggers manually, ignores scheduler
```

### 15.3 Rolling back a bad model

Because every model version is in Vertex Model Registry, you can redeploy the previous version without retraining:

```bash
# List model versions
gcloud ai models list --region=$GCP_REGION --filter="displayName=rcf-metrics-detector"

# Deploy the previous version to the endpoint
gcloud ai endpoints deploy-model $ENDPOINT_ID --region=$GCP_REGION \
  --model=$PREVIOUS_MODEL_ID --traffic-split=0=100
```

### 15.4 Updating streaming rules

Edit `ml/streaming/rules.yaml`, then redeploy the Cloud Function:

```bash
gcloud functions deploy monitoring-mlops-${ENV}-streaming-detector \
  --gen2 --runtime=python311 --region=$GCP_REGION \
  --source=ml/streaming --entry-point=handler \
  --trigger-topic=monitoring-mlops-${ENV}-events \
  --service-account=$RUNNER_SA --memory=1Gi
```

The Function picks up the new `rules.yaml` from its source package. **No pipeline retraining needed** — rules are evaluated at runtime.

### 15.5 Teardown order

This order matters. Destroying in the wrong order leaves orphan resources or causes Terraform failures.

```bash
# 1. Scale down Vertex Endpoints (stop billing)
for NAME in rcf-metrics iforest-logs lstm-ae-traces log-embedding-anomaly; do
  EID=$(gcloud ai endpoints list --region=$GCP_REGION \
        --filter="displayName=${NAME}-${ENV}" --format="value(name)" | awk -F/ '{print $NF}')
  gcloud ai endpoints undeploy-model $EID --region=$GCP_REGION \
    --deployed-model-id=$(gcloud ai endpoints describe $EID --region=$GCP_REGION \
    --format="value(deployedModels[0].id)") --quiet || true
done

# 2. GKE — remove the Helm release
helm uninstall anomaly-scoring-api

# 3. Cloud Functions
gcloud functions delete monitoring-mlops-${ENV}-streaming-detector --region=$GCP_REGION --quiet
gcloud functions delete monitoring-mlops-${ENV}-pipeline-trigger   --region=$GCP_REGION --quiet

# 4. Terraform destroy (Pub/Sub, GCS, Cloud SQL, GKE, Scheduler, etc.)
cd infra && terraform destroy -auto-approve
```

Or run the convenience script:

```bash
bash scripts/teardown.sh dev
```

---

## 16. Cost Management

Training jobs use **Spot (preemptible)** VMs — about 70% cheaper than on-demand. Spot VMs can be preempted; Vertex Pipelines will retry the step automatically.

| Resource | Type | Approx. Cost | Cadence |
|---|---|---|---|
| RCF / IForest training | `n1-standard-4` Spot | ~$0.05/hr | Daily, 10–30 min |
| LSTM-AE / Log-BERT training | `g2-standard-8` Spot + 1× L4 | ~$0.30/hr | Weekly, 1–3 hr |
| RCF / IForest serving | `n1-standard-2` × 2 replicas | ~$0.10/hr | Continuous |
| LSTM-AE / Log-BERT serving | `n1-standard-4` + L4 × 2 replicas | ~$0.95/hr | Continuous |
| GKE Autopilot (Scoring API) | per-pod | ~$0.04/pod/hr | 2–8 replicas |
| Cloud SQL | `db-custom-1-3840` | ~$0.07/hr | Continuous |
| GCS + Pub/Sub + Logging | volume-based | < $5/day dev | Continuous |

**Rules to stay cost-safe** (from `CLAUDE.md`):
- Spot for all training jobs — never on-demand
- Max GPU: L4. Never A100 or H100 in this project
- `n1-standard-2` for CPU serving endpoints in dev; scale up only in prod
- Stop Cloud SQL during off-hours in dev: `gcloud sql instances patch $INSTANCE --activation-policy NEVER`

---

## 17. Key Concepts Glossary

**Vertex AI Pipeline (KFP v2)**: A directed acyclic graph (DAG) of containerised steps managed by Vertex AI. Each step runs in its own Docker container. The DAG is compiled to JSON and submitted; Vertex handles scheduling, retries, and artifact lineage.

**KFP component (`@dsl.component`)**: A Python function decorated to become a reusable DAG step. KFP serialises it, wraps it in a container, and manages its inputs/outputs as typed artifacts.

**Vertex Custom Training Job**: A one-off job that runs your Docker image on specified hardware. Used for the `Train` step in each pipeline. Returns when the container exits 0.

**Vertex Endpoint**: An HTTPS endpoint backed by one or more deployed model versions. Handles autoscaling, health checks, and traffic splitting between versions. Billed per replica-hour.

**Vertex Model Registry**: Version-controlled store of model artifacts + metadata. Each entry points to a GCS URI (model files) and a serving container image. The `gate_and_register` step uses it as the promotion gate.

**Workload Identity Federation (WIF)**: GCP mechanism that lets a Kubernetes Service Account impersonate a GCP Service Account without a key file. The binding is `{GCP_PROJECT}.svc.id.goog[{namespace}/{ksa}] → GSA`.

**GKE Autopilot**: GKE mode where Google manages node provisioning, sizing, and patching. You only define Pods/Deployments; the cluster scales nodes automatically.

**Google Managed Prometheus (GMP)**: A managed Prometheus-compatible backend. You deploy a `PodMonitoring` CRD in your cluster; GMP scrapes the pod's `/metrics` endpoint and stores data in Cloud Monitoring.

**Pub/Sub**: GCP's fully managed message bus. Topics receive messages; subscriptions pull or push them to consumers. At-least-once delivery. Multiple subscriptions on the same topic = fan-out.

**Cloud Function Gen2**: Serverless functions backed by Cloud Run. Gen2 has faster cold starts, larger memory, and better Pub/Sub integration than Gen1. The `@functions_framework.cloud_event` decorator handles the Pub/Sub envelope unwrapping.

**Cloud Armor**: GCP's managed WAF and DDoS protection, attached to HTTPS Load Balancers. Rules can match on IP ranges, geo, rate, or custom expressions. Findings flow into SCC.

**HMAC PII masking**: Computing `HMAC-SHA256(key, value)[:16]` over sensitive fields (IP, username) before storage. Preserves cardinality (same input → same output, so you can count distinct IPs) without storing the raw value.

**Isolation Forest**: Unsupervised anomaly detection algorithm. Randomly partitions the feature space; anomalies are isolated in fewer splits → shorter average path length → higher anomaly score. Used as the GCP proxy for AWS Random Cut Forest.

**LSTM Autoencoder**: A neural network that encodes a sequence into a compressed representation then decodes it back. Trained only on normal sequences. High reconstruction error on a new sequence = anomaly.

**KFP Metric Gate**: The `gate_and_register` component reads the evaluation JSON and compares the primary metric to a threshold. If it fails, the pipeline completes without registering the model — the existing endpoint keeps serving the previous version.
