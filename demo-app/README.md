# demo-app/ — A small e-commerce stack that emits everything `monitoring-mlops-gcp` ingests

This is the **producer side** for the AIOps platform. It exists so you can run an end-to-end demo without pointing the platform at a real production system.

It is a deliberately small stack:

```
Internet ──► GCE Ingress ──► GKE Autopilot
                                ├── web         (NGINX)
                                ├── api         (FastAPI)
                                └── worker      (background jobs)
                                    │
                                    ├──► Cloud SQL MySQL  (slow-query log enabled)
                                    └──► Memorystore Redis

Logs/metrics/traces flow:
  GKE containers → stdout/stderr → Cloud Logging (default) → sink → Pub/Sub ─► GCS raw / Dataflow
  Cloud SQL      → slow-query log → Cloud Logging           → sink → Pub/Sub ─► GCS raw / Dataflow
  App stdout     → Fluent Bit DaemonSet (tail)              → Cloud Logging   ─► Pub/Sub
  Metrics        → Google Managed Prometheus (GMP)
  Traces         → OTLP via OTEL collector                  → Cloud Trace
```

That covers all GCP sources documented in `../CLAUDE.md`.

## What's in this directory

```
demo-app/
├── README.md                ← this file
├── api/                     ← Python FastAPI service (the backend API)
│   ├── app/main.py
│   ├── app/...
│   ├── Dockerfile
│   └── requirements.txt
├── worker/                  ← Python background worker (job processor)
│   ├── app/worker.py
│   ├── Dockerfile
│   └── requirements.txt
├── web/                     ← NGINX-served static site (the frontend)
│   ├── site/index.html
│   └── nginx.conf
├── traffic-gen/             ← Locust-based traffic generator
│   ├── locustfile.py
│   └── README.md
├── infra/                   ← Terraform for Cloud SQL, Memorystore Redis, static global IP
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── helm/                    ← Helm charts for the services
│   └── demo-service/
│       ├── values-api.yaml
│       ├── values-worker.yaml
│       └── values-web.yaml
│       └── values.yaml
└── docs/                    ← Demo-specific documentation
    └── signal-flow.md
```

## Why each service exists

| Service | Drives | What anomalies it can simulate |
|---|---|---|
| `web` (NGINX) | GCE Ingress, NGINX combined log | DDoS, scanner, slow-loris |
| `api` (FastAPI) | App JSON logs, OTEL traces, Prom metrics, Cloud SQL slow-query | High latency, error storms, memory leaks (simulated), brute-force on /login |
| `worker` (Python) | App JSON logs, OTEL traces, Prom metrics | Queue depth anomalies, processing-time outliers |

## Deploying

This deploys *on top of* a running `monitoring-mlops-gcp` environment (the AIOps platform must already be applied). The demo app expects:

- A GKE cluster (`monitoring-mlops-{env}-gke`)
- The Artifact Registry repository `monitoring-mlops`
- The `events` Pub/Sub topic from the parent platform

### 1. Provision Infrastructure
**Apply the parent platform Terraform first** (`../infra`). It creates the VPC
PSA peering range, the Pub/Sub `events` topic, and the Artifact Registry repo
that this stack depends on. Skipping that step makes the Cloud SQL private-IP
attachment fail.

Then run Terraform here to provision Cloud SQL, Memorystore Redis,
Workload-Identity GSAs, and a static IP.

```bash
cd demo-app/infra

cat > terraform.tfvars <<EOF
project_id  = "$GCP_PROJECT_ID"
region      = "$GCP_REGION"
environment = "$ENV"
network     = "default"
EOF

terraform init
terraform apply -auto-approve

# Extract IP addresses needed for deployment
export MYSQL_IP=$(terraform output -raw mysql_ip)
export REDIS_IP=$(terraform output -raw redis_ip)
export DEMO_IP=$(terraform output -raw demo_ip)
```

### 2. Build + Push Containers
Build the container images and push them to the parent Artifact Registry repo:

```bash
cd ../

gcloud auth configure-docker $GCP_REGION-docker.pkg.dev
TAG="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/monitoring-mlops"

docker build -t $TAG/demo-api:latest -f api/Dockerfile api
docker build -t $TAG/demo-worker:latest -f worker/Dockerfile worker
docker build -t $TAG/demo-web:latest -f web/Dockerfile web

docker push $TAG/demo-api:latest
docker push $TAG/demo-worker:latest
docker push $TAG/demo-web:latest
```

### 3. Deploy Kubernetes Services (Helm)
Update the target IPs in your values files or pass them using `--set`:

```bash
cd helm

# Deploy MySQL-dependent API backend
helm upgrade --install demo-api ./demo-service \
  --namespace default \
  -f ./demo-service/values-api.yaml \
  --set image.repository=$TAG/demo-api \
  --set env.DB_HOST=$MYSQL_IP

# Deploy Redis-dependent background worker
helm upgrade --install demo-worker ./demo-service \
  --namespace default \
  -f ./demo-service/values-worker.yaml \
  --set image.repository=$TAG/demo-worker \
  --set env.REDIS_URL="redis://$REDIS_IP:6379/0"

# Deploy NGINX web frontend (fronted by GCE Ingress)
helm upgrade --install demo-web ./demo-service \
  --namespace default \
  -f ./demo-service/values-web.yaml \
  --set image.repository=$TAG/demo-web
```

### 4. Drive Traffic with Locust
Start generating mock requests to trigger metrics/traces:

```bash
cd ../traffic-gen
locust -f locustfile.py --host http://$DEMO_IP --headless --users 50 --spawn-rate 5 --run-time 30m
```

## Tearing down

```bash
helm uninstall demo-api demo-worker demo-web
cd demo-app/infra && terraform destroy -auto-approve
```
