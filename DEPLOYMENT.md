# DEPLOYMENT.md — end-to-end deploy walkthrough

Companion to `PROJECT_GUIDE.md`. Explains **what happens when you run
`scripts/deploy_all.sh` on a fresh GCP project**, why each stage exists, and
how the pieces glue together at runtime.

---

## Why this exists

Reading Terraform + Helm + KFP + gcloud invocations end-to-end is slow. New
engineers  need one page that answers:

- What resources exist on GCP after deploy?
- Which stage owns which resource — where do I look when it breaks?
- How does a synthetic HTTP request from `demo-app` end up as an anomaly on
  the AIOps Console?

If a stage fails, you want to be able to say "that's Stage N, it owns X" in
under 30 seconds. This doc is that lookup.

---

## Prerequisites

| Tool          | Purpose                                        |
|---------------|------------------------------------------------|
| `gcloud`      | Auth + APIs + CF/Vertex/Endpoints              |
| `terraform`   | Platform + demo-app IaC                        |
| `kubectl`     | GKE Autopilot workloads                        |
| `helm`        | Chart deploy (scoring/UI/otel/demo)            |
| `python3`     | Seed events + submit KFP pipelines             |
| `jq`, `curl`  | Smoke test                                     |

**No local Docker required** — Stage 2 runs entirely on **Cloud Build**.

**Auth**: `gcloud auth login` (or `gcloud auth activate-service-account
--key-file=...`). Terraform reads a bearer token via `GOOGLE_OAUTH_ACCESS_TOKEN`
so ADC is not required for `terraform` itself. Python SDKs (KFP submit,
seed_logs) need `GOOGLE_APPLICATION_CREDENTIALS` pointed at a service-account
key JSON with roles `roles/aiplatform.user`, `roles/pubsub.publisher`,
`roles/storage.admin`.

**Environment placeholders** used throughout this doc — replace with your
values:

| Placeholder            | Meaning                                      |
|------------------------|----------------------------------------------|
| `<PROJECT_ID>`         | GCP project ID                               |
| `<REGION>`             | GCP region (default `asia-south1`)           |
| `<ENV>`                | Environment tag (default `dev`)              |
| `<DOMAIN_AIOPS>`       | AIOps Console DNS (default `aiops.example.com`) |
| `<DOMAIN_DEMO>`        | Demo app DNS (default `demo.example.com`)    |
| `<AR_HOST>`            | `<REGION>-docker.pkg.dev/<PROJECT_ID>/monitoring-mlops` |
| `<RUNNER_SA>`          | Runner GSA (`aiops-runner@<PROJECT_ID>.iam.gserviceaccount.com`) |

---

## End-to-end flow (diagram)

```
                    ┌──────────────────────────────────────────────────────────┐
                    │  developer laptop  ──► scripts/deploy_all.sh (interactive) │
                    └──────────────┬───────────────────────────────────────────┘
                                   │
     ┌─────────────────────────────┴─────────────────────────────────────────┐
     │                                                                         │
     ▼ Stage 1: infra/ terraform apply                                          ▼
┌─────────────────┐                                            Stage 2: Cloud Build
│  ~82 resources  │                                            ┌────────────────────────┐
│─────────────────│                                            │  gcloud builds submit  │
│  GCS bucket     │                                            │  ────────────────────  │
│  BigQuery       │                                            │  10 images built on    │
│  Pub/Sub topics │                                            │  GCP e2-highcpu-8      │
│  Dataflow flex  │                                            │  workers, pushed to    │
│  Vertex 4×EP    │                                            │  Artifact Registry.    │
│  GKE Autopilot  │                                            │  No local Docker.      │
│  Cloud Armor    │                                            └────────────────────────┘
│  Runner GSA     │
│  AR repo        │  outputs cached in .deploy.env
└────────┬────────┘  (BUCKET, GKE, RUNNER_SA, IPs, topics, ...)
         │
         │
         ▼ Stage 3: demo-app/infra/ terraform apply
┌───────────────────┐
│ Cloud SQL MySQL   │  private VPC peering, ~10-14 min to provision
│ Memorystore Redis │  same VPC
│ demo-{api,worker} │
│ GSAs + IAM        │
└─────────┬─────────┘
          │
          ▼ Stage 4: gcloud functions deploy (Gen2)
┌────────────────────────────────────────────────────┐
│ monitoring-mlops-<ENV>-streaming-detector           │
│ trigger: Pub/Sub monitoring-mlops-<ENV>-events      │
│ code:    ml/streaming/{detector.py, rules.yaml}     │
│ purpose: statistical z-score / EWMA / rate rules on │
│          every incoming event; emits anomalies to   │
│          Pub/Sub anomalies topic + Cloud Monitoring │
│          custom metric.                             │
└────────────────────────────────────────────────────┘
          │
          ▼ Stage 5: seed events + KFP pipelines
┌────────────────────────────────────────────────────┐
│ scripts/seed_logs.py     → 5000 CommonEvents        │
│                            published to             │
│                            Pub/Sub events topic     │
│ ml/feature_engineering/  → parquet features on GCS  │
│                            (best-effort first run)  │
│ ml/pipelines/*/pipeline.py                          │
│    (RCF metrics, IForest logs, LSTM-AE traces,      │
│     Log-BERT anomaly)                               │
│    → each compiles KFP JSON, submits to Vertex,     │
│      trains on Spot (n1-standard-4/g2-standard-8)   │
│      then EVAL → GATE → Model Registry              │
│    Runtime: ~30-60 min per detector                 │
└──────────────────────────┬─────────────────────────┘
                           │
                           ▼ Stage 6: attach models
                   ┌───────────────────────┐
                   │ deploy-model on the 4 │  Only runs if the
                   │ Vertex Endpoints      │  metric gate passed.
                   │ (traffic-split=100%)  │  Cold-start deploys
                   │                       │  can skip this and
                   │ machine: n1-standard  │  run in "endpoints
                   │ GPU: L4 for LSTM +    │  exist but empty"
                   │      Log-BERT         │  mode until enough
                   └───────────────────────┘  data exists.

Stage 7: Helm workloads on GKE
┌────────────────────────────────────────────────────────────────────┐
│  ns=observability                                                   │
│    otel-collector — OTLP-in → Cloud Trace + GMP                     │
│                                                                     │
│  ns=default                                                          │
│    anomaly-scoring-api      Ingress (static IP) + Cloud Armor       │
│      env: ENDPOINT_{RCF,IFOREST,LSTM,LOGBERT}                       │
│      routes: /health /score /alerts /explain /feedback /sources     │
│    aiops-ui                 Ingress (static IP)                     │
│      nginx proxies /api/* → anomaly-scoring-api Service             │
└────────────────────────────────────────────────────────────────────┘

Stage 8: demo-app Helm
┌────────────────────────────────────────────────────────────────────┐
│  ns=default                                                          │
│    demo-api      → Cloud SQL MySQL (private IP) + Redis             │
│                    WLI = demo-api GSA                               │
│    demo-worker   → Redis queue consumer                             │
│                    WLI = demo-worker GSA                            │
│    demo-web      Ingress (static IP)                                │
│                                                                     │
│  Secret demo-api-db pulled from Secret Manager at deploy time.      │
└────────────────────────────────────────────────────────────────────┘

Stage 9: traffic-gen CronJob
┌────────────────────────────────────────────────────────────────────┐
│  ns=demo                                                             │
│    demo-traffic-normal   (default suspend=false)                    │
│    demo-traffic-attack   (default suspend=true; unsuspend to fire)  │
│                                                                     │
│  Locust hits demo-web, generating logs → Cloud Logging → sink →     │
│  Pub/Sub events topic → both:                                       │
│    (a) Cloud Function detector → immediate anomalies                │
│    (b) Dataflow flex job → GCS raw/ (partitioned by source)         │
│                                                                     │
│  Cold-start streaming rules fire in ~30 min once enough data lands. │
└────────────────────────────────────────────────────────────────────┘
```

---

## Runtime request flow (after deploy)

```
Locust in demo → demo-web (nginx) → demo-api (FastAPI) → MySQL / Redis
                                                             │
                                                             ▼
        Access logs, DB slow logs, errors ─────────► Cloud Logging
                                                             │  log sink
                                                             ▼
                                    Pub/Sub monitoring-mlops-<ENV>-events
                                                             │
                                    ┌────────────────────────┼───────────────────┐
                                    ▼                        ▼                   ▼
                       Cloud Function detector       Dataflow flex job     (fanout to
                       ─────────────────────────      ──────────────────    Elastic /
                       yaml rules → Pub/Sub           writes NDJSON to      external
                       monitoring-mlops-<ENV>-        GCS /raw/ partitioned  consumers)
                       anomalies topic                by source
                                    │
                                    ▼
                       Pub/Sub monitoring-mlops-<ENV>-
                       anomalies-fanout subscription
                                    │
                                    ▼
                          anomaly-scoring-api
                       (subscribes / pulls, or
                        UI polls /api/v1/alerts)
                                    │                 (Vertex /score → predict)
                                    ▼                 ────────────────────────►
                                   UI                 4 Vertex Endpoints
                                aiops-ui               (RCF / IForest / LSTM-AE
                              /api/v1/alerts            / Log-BERT)
```

---

## What's on GCP after a green deploy

| Where to look                           | What you'll find                                                  |
|-----------------------------------------|-------------------------------------------------------------------|
| Cloud Monitoring → Dashboards           | **AIOps Overview** + **Detector Health** (from `modules/grafana`) |
| Vertex AI → Endpoints                   | 4 endpoints (empty until Stage 6 attaches a gated model)          |
| Vertex AI → Pipelines                   | 4 runs per Stage-5 submit (`{detector}-<ENV>-pipeline-*`)         |
| BigQuery → dataset `monitoring`         | `raw_events`, `features_security` (external), `anomalies` (native)|
| Pub/Sub                                 | 3 topics, 3 subscriptions inc. `-anomalies-fanout`                |
| Cloud Functions Gen2                    | `monitoring-mlops-<ENV>-streaming-detector`                       |
| Cloud Storage `monitoring-mlops-gcp-<ENV>` | `<ENV>/raw/` (Dataflow), `<ENV>/features/`, `<ENV>/models/`     |
| GKE Autopilot cluster                   | Ingresses: `aiops-ui`, `anomaly-scoring-api`, `demo-web`          |
| Artifact Registry `monitoring-mlops`    | 10 images: 1 scoring, 1 UI, 4 trainers, 4 sklearn-serve mirrors, 3 demo, 1 traffic-gen |
| Cloud Armor                             | `aiops-scoring-armor` (rate limit + SQLi/XSS)                     |

---

## Stage-by-stage failure map

| Stage | Owns                    | Common failure                                              | Where to look             |
|-------|-------------------------|-------------------------------------------------------------|---------------------------|
| 1     | infra/                  | BQ external table needs seed file at GCS features prefix    | GCS `<ENV>/features/security/` |
| 2     | Cloud Build images      | Slow context upload → add `.gcloudignore`                    | GCB console               |
| 3     | demo-app/infra/         | Cloud SQL takes 10-14 min; peering must exist               | Cloud SQL console         |
| 4     | Cloud Function          | Missing IAM on runner SA (Pub/Sub subscriber)               | CF logs                   |
| 5     | KFP pipelines           | Trainer OOM / no eval data → gate fails                     | Vertex Pipelines UI       |
| 6     | Endpoint attach         | GATE_FAILED means model was never registered                | `gcloud ai models list`   |
| 7     | Helm scoring/UI/otel    | ImagePullBackOff — mismatched image.tag                     | `kubectl describe pod`    |
| 8     | Helm demo trio          | Secret `demo-api-db` missing / stale                         | `kubectl get secret`      |
| 9     | Traffic-gen CronJob     | Cronjob image ref uses old `demo-traffic-gen` name          | `kubectl -n demo get pods`|

---

## How this project is useful

1. **Cold-start observability.** Streaming statistical detectors + SCC catch
   incidents immediately, before ML detectors have enough data. The tiered
   architecture means you don't wait 7 days for signal.
2. **Portable detectors.** `CommonEvent` schema shared with the AWS port —
   train once, deploy to either cloud.
3. **Self-driving retrain.** Cloud Scheduler → Pub/Sub → Vertex Pipelines
   retrain weekly (`{detector}-<ENV>-pipeline`); gated by `metric_gate` before
   Model Registry upload; endpoints roll new versions atomically.
4. **Reference stack.** GKE Autopilot + Workload Identity + Cloud Armor +
   OTEL → Cloud Trace + GMP is the "boring GCP prod" recipe. Copy it into
   any new service.
5. **Signal source built-in.** `demo-app` (web/api/worker + Locust) gives
   you real logs/metrics/traces on day zero, so detectors + dashboards
   can be validated before you migrate real workloads.

---

## Teardown

`scripts/teardown.sh` in reverse Stage order:
1. `helm uninstall` all releases
2. `kubectl delete` cronjobs, secrets, ns=demo
3. `gcloud ai endpoints undeploy-model` for each endpoint
4. `gcloud functions delete` streaming detector
5. `terraform destroy` in `demo-app/infra/`
6. `terraform destroy` in `infra/`

**Order matters** — endpoint pool first (billing), Cloud SQL stop before
`terraform destroy` avoids the 24h retention charge, GCS bucket must be
empty (`gsutil rm -r gs://.../*`) before Terraform can drop it.
