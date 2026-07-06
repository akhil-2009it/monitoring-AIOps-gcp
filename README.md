# monitoring-AIOps-gcp

End-to-end **AIOps + MLOps + Security Analytics platform on Google Cloud**.

Ingests logs, metrics, and traces from across an application stack, then runs
**tiered anomaly and threat detection** — starting with cold-start streaming
rules that fire in seconds and grading up to trained ML detectors on Vertex
AI Endpoints. Fully IaC-driven, deployable to a fresh GCP project in one
interactive script (`scripts/deploy_all.sh`).

> **Companion docs**
> - [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md) — architecture, sensitive areas, detector specs
> - [`DEPLOYMENT.md`](DEPLOYMENT.md) — end-to-end deploy walkthrough with diagrams
> - [`MLOPS_GUIDE.md`](MLOPS_GUIDE.md) — ML-lifecycle notes (features, training, retrain)

---

## Table of contents

1. [Why this project exists](#why-this-project-exists)
2. [Architecture at a glance](#architecture-at-a-glance)
3. [Detection tiers](#detection-tiers)
4. [Repository layout](#repository-layout)
5. [Prerequisites](#prerequisites)
6. [Quick start (fresh GCP project)](#quick-start-fresh-gcp-project)
7. [What the deploy creates](#what-the-deploy-creates)
8. [Screenshots](#screenshots)
9. [Local development](#local-development)
10. [Cost & teardown](#cost--teardown)
11. [Design principles](#design-principles)
12. [Troubleshooting](#troubleshooting)
13. [License](#license)

---

## Why this project exists

Most anomaly-detection projects hit the same wall: **the ML detectors need
weeks of data before they trigger anything, but incidents happen on day one.**
This platform solves that by layering four detection tiers on top of the
same event stream, so useful signal is available at every stage of maturity —
from a fresh deploy through steady state to fully-trained models.

It also serves as a **reference stack** for a "boring GCP prod" runtime:
GKE Autopilot + Workload Identity, Cloud Armor at the edge, OpenTelemetry
into Cloud Trace, Google Managed Prometheus for metrics, and Vertex AI
for the ML lifecycle.

---

## Architecture at a glance

```
                       Cloud Armor  ──►  GCE Ingress  ──►  GKE Autopilot
                                                              │
                    ┌─────────────────────────────────────────┼──────────┐
                    ▼                                         ▼          ▼
             anomaly-scoring-api                        aiops-ui       demo-app
             (FastAPI, /score /alerts)                 (Anomaly      (web + api +
                    │                                   Console)      worker)
                    │  /predict                                          │
                    ▼                                                    │
             Vertex Endpoints × 4                                        │
             (RCF · IForest · LSTM-AE · Log-BERT)                        │
                    ▲                                                    │
                    │  Model Registry (gated by metric)                  │
                    │                                                    ▼
             Vertex AI Pipelines (KFP v2, weekly retrain)          Cloud Logging
                    ▲                                                    │
                    │                                                    ▼
                    │                                          Log Sink → Pub/Sub
                    │                                                    │
                    │                                    ┌───────────────┼──────────────┐
                    │                                    ▼               ▼              ▼
                    │                          Cloud Function     Dataflow flex     Fanout to
                    │                          (Gen2, streaming    (partitioned      external
                    │                           statistical rules)  GCS raw/)         consumers
                    │                                    │
                    │                                    ▼
                    │                          Pub/Sub anomalies topic
                    └────────────────────────────────────┘
                              (BigQuery `monitoring.anomalies` +
                               Cloud Monitoring dashboards +
                               UI polls /api/v1/alerts)
```

- **Object store / lake**: Cloud Storage (partitioned per source)
- **Search / index**: BigQuery (external + native tables)
- **Streaming ingest**: Cloud Logging → Pub/Sub → Dataflow → GCS
- **Streaming detection**: Cloud Function Gen2, YAML rules
- **ML orchestration**: Vertex AI Pipelines (KFP v2), Cloud Scheduler triggers
- **Model registry + serving**: Vertex Model Registry + 4 Endpoints
- **Metrics**: Google Managed Prometheus (GMP)
- **Traces**: Cloud Trace via OTEL collector on GKE
- **Secrets**: Secret Manager + Workload Identity
- **Container registry**: Artifact Registry

---

## Detection tiers

| Tier | Latency | What runs | Cold-start need |
|------|---------|-----------|-----------------|
| **GCP-managed** | seconds | Security Command Center, Cloud Armor, Event Threat Detection | works immediately |
| **Streaming statistical** | seconds | Cloud Function Gen2 — z-score, EWMA, rate-of-change, threshold | ~30 min of data |
| **BigQuery ML / Elastic AD** | minutes | `ML.DETECT_ANOMALIES` (RCF/ARIMA) on indexed metrics | after detector init |
| **Vertex ML detectors** | ms inference (hours to train) | RCF metrics, Isolation Forest logs, LSTM-AE traces, Log-BERT | needs 1–7 days |

Each detector has a metric gate on eval — models are only registered and
attached to an endpoint if they beat the gate (F1 ≥ 0.70 for RCF,
P@1% ≥ 0.80 for IForest, AUC > 0.80 for LSTM-AE, P@1% ≥ 0.75 for Log-BERT).

---

## Repository layout

```
monitoring-AIOps-gcp/
├── PROJECT_GUIDE.md            ← primary architecture guide
├── DEPLOYMENT.md               ← 9-stage deploy walkthrough with ASCII diagrams
├── MLOPS_GUIDE.md              ← ML lifecycle deep-dive
├── infra/                      ← platform Terraform
│   ├── main.tf
│   └── modules/
│       ├── datalake/           ← GCS + BigQuery dataset + external tables
│       ├── streaming/          ← Pub/Sub topics + Dataflow flex job
│       ├── vertex/             ← 4 Vertex AI Endpoints
│       ├── gke/                ← GKE Autopilot + Workload Identity
│       ├── database/           ← Cloud SQL Postgres + PSA peering
│       ├── identity/           ← runner GSA + IAM roles
│       ├── lb/                 ← Cloud Armor + static IPs
│       ├── monitoring/         ← Cloud Scheduler retrain + alert policy
│       ├── grafana/            ← Cloud Monitoring dashboards
│       └── registry/           ← Artifact Registry
├── ml/
│   ├── parsers/                ← per-source log parsers → CommonEvent
│   ├── feature_engineering/    ← sliding-window security features
│   ├── pipelines/              ← 4 Vertex Pipelines (KFP v2)
│   ├── streaming/              ← Cloud Function Gen2 (YAML rules)
│   ├── monitoring/             ← drift on detector inputs
│   └── inference/              ← local model loaders for tests
├── api/
│   ├── scoring/                ← FastAPI /score /alerts /explain /feedback /sources
│   └── ui/                     ← AIOps Anomaly Console (nginx static + proxy)
├── helm/charts/
│   ├── anomaly-scoring-api/    ← API on GKE + Ingress + Cloud Armor + PodMonitoring + HPA
│   ├── aiops-ui/               ← UI on GKE + Ingress + ManagedCertificate + Cloud Armor
│   └── otel-collector/         ← OTLP receivers → Cloud Trace + GMP exporters
├── demo-app/                   ← web + api + worker signal source
│   ├── infra/                  ← demo-app Terraform (Cloud SQL + Redis + GSAs)
│   ├── helm/                   ← demo-service chart with 3 values profiles
│   └── traffic-gen/            ← Locust CronJob (normal + attack profiles)
├── scripts/
│   ├── deploy_all.sh           ← 9-stage interactive deploy
│   ├── seed_logs.py            ← publish synthetic events to Pub/Sub
│   ├── inject_attack.py        ← simulated DDoS / brute-force
│   ├── smoke_test.sh           ← post-deploy verification
│   └── teardown.sh
├── tests/                      ← pytest for parsers / streaming rules
└── docs/
    ├── screenshots/
    ├── DEPLOY.md
    └── MLOPS_GUIDE.md
```

---

## Prerequisites

| Tool          | Version              | Why                                          |
|---------------|----------------------|----------------------------------------------|
| `gcloud`      | latest               | APIs, Cloud Function, Vertex, endpoints      |
| `terraform`   | ≥ 1.6.0              | Platform + demo-app IaC                      |
| `kubectl`     | ≥ 1.28               | GKE Autopilot workloads                      |
| `helm`        | ≥ 3.10               | Chart deploys                                |
| `python3`     | ≥ 3.11               | KFP submit + seed events                     |
| `jq`, `curl`  | any                  | Smoke test                                   |

**No local Docker required** — Stage 2 runs entirely on **Cloud Build**.

**Auth**:
- `gcloud auth login` (or `gcloud auth activate-service-account --key-file=...`)
- Terraform reads a bearer token via `GOOGLE_OAUTH_ACCESS_TOKEN`, so
  Application Default Credentials are optional for `terraform` itself
- Python SDKs (KFP submit, `seed_logs.py`) need
  `GOOGLE_APPLICATION_CREDENTIALS` set to a service-account key JSON with
  `roles/aiplatform.user`, `roles/pubsub.publisher`, `roles/storage.admin`

**GCP APIs enabled by the deploy**: aiplatform, artifactregistry, bigquery,
cloudbuild, cloudfunctions, cloudscheduler, compute, container, dataflow,
eventarc, iamcredentials, logging, monitoring, pubsub, redis, run,
secretmanager, servicenetworking, sqladmin, trace.

---

## Quick start (fresh GCP project)

```bash
# 1. Point gcloud at your project
gcloud auth login
gcloud config set project <YOUR_PROJECT_ID>

# 2. Copy tfvars templates
cp infra/terraform.tfvars.example          infra/terraform.tfvars
cp demo-app/infra/terraform.tfvars.example demo-app/infra/terraform.tfvars
# then edit both to set project_id, region, environment

# 3. Run the interactive deploy
./scripts/deploy_all.sh
```

The deploy asks `[Y/n/s/q]` before each stage, so any that are already
applied can be skipped. Terraform outputs are cached in `.deploy.env` so
re-runs are fast.

**Stage summary** (details in [`DEPLOYMENT.md`](DEPLOYMENT.md)):

| Stage | What it does                                                      | Runtime  |
|-------|-------------------------------------------------------------------|----------|
| 1     | Platform Terraform — GKE, GCS, BigQuery, Pub/Sub, Vertex, Armor   | ~15 min  |
| 2     | Cloud Build 10 images (scoring, UI, 4 trainers, demo trio, mirror)| ~5 min   |
| 3     | Demo-app Terraform — Cloud SQL MySQL + Memorystore + GSAs         | ~12 min  |
| 4     | `gcloud functions deploy` streaming detector (Gen2)               | ~2 min   |
| 5     | Seed 5k events + submit 4 Vertex Pipelines                        | ~30 min  |
| 6     | Attach trained models to the 4 Vertex Endpoints                   | ~10 min  |
| 7     | Helm — anomaly-scoring-api, aiops-ui, otel-collector              | ~2 min   |
| 8     | Helm — demo-api, demo-worker, demo-web                            | ~2 min   |
| 9     | Traffic-gen CronJob + smoke test                                  | ~1 min   |

---

## What the deploy creates

| Where                                    | What                                                                 |
|------------------------------------------|----------------------------------------------------------------------|
| Cloud Monitoring → Dashboards            | **AIOps Overview** + **Detector Health**                             |
| Vertex AI → Endpoints                    | 4 endpoints (empty until Stage 6 attaches gated models)              |
| Vertex AI → Pipelines                    | 4 runs per Stage-5 submit (`{detector}-<ENV>-pipeline-*`)            |
| BigQuery → dataset `monitoring`          | `raw_events`, `features_security` (external), `anomalies` (native)   |
| Pub/Sub                                  | 3 topics + 3 subscriptions inc. `-anomalies-fanout`                  |
| Cloud Functions Gen2                     | `monitoring-mlops-<ENV>-streaming-detector`                          |
| Cloud Storage `monitoring-mlops-gcp-<ENV>` | `<ENV>/raw/` (Dataflow), `<ENV>/features/`, `<ENV>/models/`        |
| GKE Autopilot cluster                    | Ingresses: `aiops-ui`, `anomaly-scoring-api`, `demo-web`             |
| Artifact Registry `monitoring-mlops`     | 10 images (scoring, UI, 4 trainers, 4 sklearn-serve mirrors, 3 demo) |
| Cloud Armor                              | `aiops-scoring-armor` (rate limit + SQLi/XSS)                        |

---

## Screenshots

**AIOps Anomaly Console** — dark UI on GKE, filtered alerts table with 1h
stat tiles, source-health strip, auto-refresh:

![AIOps Console](docs/screenshots/aiops-ui.png)

**Anomaly Scoring API** — FastAPI `/docs` (Swagger):

![Scoring API — Swagger](docs/screenshots/scoring-api-docs.png)

Scoring API routes:

| Method | Path                                | Purpose                                              |
|--------|-------------------------------------|------------------------------------------------------|
| GET    | `/health`                           | Liveness / readiness                                 |
| GET    | `/metrics`                          | Prometheus scrape (via GMP `PodMonitoring`)          |
| POST   | `/api/v1/score`                     | Fan out one CommonEvent to all 4 Vertex Endpoints    |
| GET    | `/api/v1/alerts?limit=`             | Recent anomalies (Firestore-backed)                  |
| GET    | `/api/v1/alerts/{id}/explain`       | Per-alert explanation payload                        |
| POST   | `/api/v1/feedback`                  | Analyst thumbs-up/down → labelling loop              |
| GET    | `/api/v1/sources`                   | Per-source health / event counts                     |

---

## Local development

Each service has its own dev workflow — pick the service, run its dev
command:

```bash
# Scoring API (FastAPI + uvicorn)
cd api/scoring
pip install -r requirements.txt
uvicorn main:app --reload --port 8080

# UI (nginx serves ./site — open api/ui/site/index.html directly for dev)
cd api/ui && python3 -m http.server 8000

# Demo API (FastAPI)
cd demo-app/api
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000

# Streaming detector (functions-framework local runner)
cd ml/streaming
pip install -r requirements.txt functions-framework
functions-framework --target=handler --port=8081

# Vertex Pipelines — compile only, don't submit
export MONITORING_BUCKET=your-bucket VERTEX_SERVICE_ACCOUNT=...
python3 -m ml.pipelines.rcf_metrics.pipeline
```

**Tests:**

```bash
pytest tests/ -v
pytest tests/unit/test_streaming.py -v
```

---

## Cost & teardown

**Rough monthly cost (dev, all four Vertex Endpoints attached with GPUs):**

| Component                                                    | ~USD / mo    |
|--------------------------------------------------------------|--------------|
| GKE Autopilot (baseline pods)                                | ~$70         |
| Cloud SQL MySQL (db-f1-micro, single-zone)                   | ~$10         |
| Memorystore Redis (M1)                                       | ~$40         |
| 2 × Vertex Endpoint n1-standard-2 (RCF, IForest)             | ~$140        |
| 2 × Vertex Endpoint n1-standard-4 + L4 GPU (LSTM, Log-BERT)  | ~$800        |
| Cloud Armor                                                  | ~$5          |
| Static IPs, Pub/Sub, BQ, GCS, dashboards                     | ~$10         |
| **Total (all detectors online)**                             | **~$1,000+** |
| **Endpoints undeployed / GKE scaled to 0**                   | **~$60**     |

**Teardown**:

```bash
./scripts/teardown.sh
```

Or manual reverse order:

1. `helm uninstall` all releases
2. `kubectl delete` cronjobs, secrets, `demo` and `observability` namespaces
3. `gcloud ai endpoints undeploy-model` on each of the 4 endpoints
4. `gcloud functions delete` streaming detector
5. `gcloud dataflow jobs cancel` running flex job
6. `gsutil -m rm -r gs://<bucket>/**`
7. `terraform destroy` in `demo-app/infra/`
8. `terraform destroy` in `infra/`

Cloud SQL takes ~5 min for its final snapshot; GKE Autopilot delete ~5–10 min;
each Vertex Endpoint ~2 min. Full teardown ≈ 20–30 min.

---

## Design principles

1. **No PII on the wire.** Usernames and IPs are HMAC-hashed in the parser
   before they leave the source. Detectors never see raw user identifiers.
2. **Cost-aware defaults.** `n1-standard-2` endpoints in dev, Spot for all
   training, no A100 / H100 anywhere. GPU only for LSTM-AE and Log-BERT.
3. **Metric gates before Model Registry.** A trained model that fails its
   gate never reaches an endpoint — no silent regressions.
4. **Drift on detector inputs, not predictions.** Predictions are noisy
   by design; input drift is the earlier signal.
5. **Portable schema.** All detectors run against a single `CommonEvent`
   shape (`ml/parsers/__init__.py`). A detector trained against this schema
   is portable across environments.
6. **Every Terraform resource labelled** `project=monitoring-mlops-gcp`.
7. **Everything reproducible.** No manual clicks in the Cloud Console
   are required.

---

## Troubleshooting

| Symptom                                                | Likely cause                                                  | Fix                                                                     |
|--------------------------------------------------------|---------------------------------------------------------------|-------------------------------------------------------------------------|
| Terraform fails on BQ external table                   | GCS features prefix has no files yet                          | Upload any parquet as placeholder to `gs://.../features/security/`      |
| Cloud Build hangs on TAR upload                        | Repo context too large                                        | Add / expand `.gcloudignore`; exclude `.terraform/` and `node_modules`  |
| Vertex Endpoint attach errors "no model"               | KFP metric gate failed                                        | Lower gate in `ml/pipelines/_shared/config.py` or supply real eval data |
| `demo-*` pods `ImagePullBackOff`                       | Chart default `image.tag=0.1.0`, but Cloud Build pushed `latest` | `helm upgrade --set image.tag=latest`                                 |
| Traffic-gen pod `ImagePullBackOff` (`demo-traffic-gen`)| CronJob image name doesn't match built image (`traffic-gen`)  | `kubectl -n demo patch cronjob ... image=traffic-gen:latest`            |
| `/api/v1/alerts` returns 500 (Firestore not found)     | Firestore native database not created                         | `gcloud firestore databases create --location=<REGION> --database=default --type=firestore-native` |
| `/api/v1/score` returns "traffic_split not set"        | Endpoint has no deployed model                                | Skip until Stage 6 succeeds, or attach a model manually                 |
| GCE Ingress backend 502 for ~5 min after pod ready     | Health-check propagation delay                                | Wait — GCE Ingress reconciles slowly                                    |

---

## License

MIT — see [`LICENSE`](LICENSE) if present, otherwise assume "use at your
own risk, no warranty".
