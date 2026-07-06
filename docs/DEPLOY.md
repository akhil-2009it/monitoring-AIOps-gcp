# monitoring-mlops-gcp — Deploy on GCP

End-to-end runbook. Region `asia-south1` (Mumbai).

```
        Sources                          Detection                    Surface
   ┌────────────┐   Cloud Logging   ┌─────────────────┐           ┌──────────┐
   │ LB / CDN / │ ────► sinks ────► │ Pub/Sub events  │ ────────► │ Cloud    │
   │ App / GKE  │                   └────────┬────────┘   stream  │ Function │
   │ NGINX /    │                            │                    │ (rules)  │
   │ Cloud SQL  │                            │ batch              └────┬─────┘
   └────────────┘                            ▼                         │
                                  ┌─────────────────┐                   ▼
                                  │ Dataflow → GCS  │           ┌──────────────┐
                                  │  raw partitions │           │ Pub/Sub      │
                                  └────────┬────────┘           │ anomalies    │
                                           │                    └──────┬───────┘
                                           ▼                           │
                              ┌─────────────────────┐                  │
                              │ Vertex Processing   │                  │
                              │ security_features   │                  │
                              └────────┬────────────┘                  │
                                       │                               │
                                       ▼                               │
                              ┌─────────────────────┐                  │
                              │ 4 Vertex Pipelines  │                  │
                              │ (RCF/IForest/LSTM/  │                  │
                              │  LogBERT)           │                  │
                              └────────┬────────────┘                  │
                                       │ register                      │
                                       ▼                               ▼
                              ┌─────────────────────┐  predict  ┌──────────────┐
                              │ Vertex Endpoints    │ ◄─────── │ Scoring API  │
                              │ (n1-standard-2 /    │           │ (GKE +       │
                              │  L4 GPU)            │ ───────► │  Cloud Armor)│
                              └─────────────────────┘   alerts └──────────────┘
                                                                       │
                                                                       ▼
                                                              Firestore (alerts/feedback)
                                                              Cloud Logging / Monitoring
                                                              Managed Grafana / Looker
```

---

## 0. Prereqs

```bash
gcloud --version          # >= 460
terraform --version       # >= 1.6
helm version              # >= 3.13
kubectl version           # >= 1.28
python --version          # 3.11
docker --version

export GCP_PROJECT_ID=<your-project>
export GCP_REGION=asia-south1
export ENV=dev
gcloud config set project $GCP_PROJECT_ID
gcloud config set compute/region $GCP_REGION
gcloud auth login
gcloud auth application-default login
```

Quotas to raise: L4 GPUs for Vertex training (≥ 1), L4 GPUs for Vertex
serving (≥ 1), Cloud SQL instances, GKE Autopilot vCPU.

---

## 1. Terraform — bootstrap whole platform

```bash
cd monitoring-mlops-gcp/infra

cat > terraform.tfvars <<EOF
project_id  = "$GCP_PROJECT_ID"
region      = "$GCP_REGION"
environment = "$ENV"
domain      = "aiops.example.com"
EOF

terraform init
terraform apply -auto-approve

export BUCKET=$(terraform output -raw bucket)
export AR_REPO=$(terraform output -raw artifact_registry)
export RUNNER_SA=$(terraform output -raw service_account)
export GKE=$(terraform output -raw gke_cluster_name)
export EVENTS_TOPIC=$(terraform output -raw events_topic)
export ANOMALY_TOPIC=$(terraform output -raw anomalies_topic)
export RETRAIN_TOPIC=$(terraform output -raw retrain_topic)
echo $BUCKET / $RUNNER_SA / $GKE
```

What gets provisioned:
- GCS lake bucket (versioned)
- Artifact Registry Docker repo `monitoring-mlops`
- 3 Pub/Sub topics: events, anomalies, retrain
- Service account `aiops-runner` + 12 IAM roles (Vertex/Storage/Secret/Cloud SQL/Datastore/PubSub/Logging/Monitoring/Trace/AR/BigQuery)
- GKE Autopilot cluster + Workload Identity binding `default/anomaly-scoring-api → aiops-runner`
- Cloud SQL Postgres (private IP) + Private Services Access
- Cloud Armor security policy
- Static global IP for the API LB
- Cloud Scheduler jobs (daily RCF retrain · weekly LSTM-AE retrain) → Pub/Sub
- Cloud Monitoring alert policy on detector precision drop

---

## 2. Build + push containers

```bash
gcloud auth configure-docker $GCP_REGION-docker.pkg.dev
TAG="$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/$AR_REPO"

# 2.1 Scoring API
docker build -t $TAG/anomaly-scoring-api:latest -f api/scoring/Dockerfile .
docker push $TAG/anomaly-scoring-api:latest

# 2.2 Detector training images (one per detector)
for d in rcf_metrics iforest_logs lstm_ae_traces log_embedding_anomaly; do
  docker build -t $TAG/${d//_/-}-train:latest \
      -f ml/pipelines/$d/Dockerfile . 2>/dev/null || true
  docker push $TAG/${d//_/-}-train:latest 2>/dev/null || true
done

# 2.3 Detector serving images — vLLM/vertex-prebuilt for sklearn detectors
docker pull us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest
docker tag  us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest \
            $TAG/rcf-metrics-serve:latest
docker tag  us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest \
            $TAG/iforest-logs-serve:latest
docker push $TAG/rcf-metrics-serve:latest
docker push $TAG/iforest-logs-serve:latest
```

---

## 3. Seed synthetic data

```bash
export PYTHONPATH=$(pwd)
python scripts/seed_logs.py --project $GCP_PROJECT_ID \
       --topic monitoring-mlops-${ENV}-events --n 5000 --rate 100
```

This populates the `events` topic. The streaming Cloud Function (next step)
emits anomalies to the `anomalies` topic. Dataflow / Cloud Logging sinks
land raw events in GCS for the batch pipelines.

---

## 4. Deploy the streaming detector (Cloud Function Gen2)

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

---

## 5. Run feature engineering + train detectors

```bash
# 5.1 One-off: turn raw events in GCS into 5-min security features
python ml/feature_engineering/security_features.py \
  --input-uri  gs://$BUCKET/$ENV/raw/ \
  --output-uri gs://$BUCKET/$ENV/features/security/ \
  --window-minutes 5

# 5.2 Submit each detector pipeline
for d in rcf_metrics iforest_logs lstm_ae_traces log_embedding_anomaly; do
  python -m ml.pipelines.$d.pipeline
done

# 5.3 Approve the model in Vertex Model Registry (each detector)
gcloud ai models list --region=$GCP_REGION
```

---

## 6. Deploy detectors to Vertex Endpoints

```bash
deploy_endpoint() {
  local NAME="$1"; local DISPLAY="$2"; local MACHINE="$3"; local GPU="${4:-}"
  gcloud ai endpoints create --display-name="$NAME" --region=$GCP_REGION || true
  EID=$(gcloud ai endpoints list --region=$GCP_REGION \
        --filter="displayName=$NAME" --format="value(name)" | awk -F/ '{print $NF}')
  MODEL=$(gcloud ai models list --region=$GCP_REGION \
          --filter="displayName=$DISPLAY" --sort-by="~createTime" --limit=1 --format="value(name)")

  gcloud ai endpoints deploy-model "$EID" --region=$GCP_REGION \
    --model="$MODEL" --display-name="$DISPLAY-v1" \
    --machine-type="$MACHINE" \
    ${GPU:+--accelerator=$GPU} \
    --min-replica-count=1 --max-replica-count=2 \
    --service-account=$RUNNER_SA --traffic-split=0=100
  echo "$NAME → $EID"
}

deploy_endpoint rcf-metrics-${ENV}        rcf-metrics-detector        n1-standard-2
deploy_endpoint iforest-logs-${ENV}       iforest-logs-detector       n1-standard-2
deploy_endpoint lstm-ae-traces-${ENV}     lstm-ae-traces-detector     n1-standard-4 type=nvidia-l4,count=1
deploy_endpoint log-embedding-${ENV}      log-embedding-anomaly-detector n1-standard-4 type=nvidia-l4,count=1
```

Capture endpoint ids — they go into the Helm values.

---

## 7. Deploy the Scoring API on GKE

```bash
gcloud container clusters get-credentials $GKE --region=$GCP_REGION

helm upgrade --install anomaly-scoring-api helm/charts/anomaly-scoring-api \
  --namespace default \
  --set image.repository=$TAG/anomaly-scoring-api \
  --set image.tag=latest \
  --set env.GCP_PROJECT_ID=$GCP_PROJECT_ID \
  --set env.GCP_REGION=$GCP_REGION \
  --set env.ENDPOINT_RCF_METRICS=<rcf-id> \
  --set env.ENDPOINT_IFOREST_LOGS=<iforest-id> \
  --set env.ENDPOINT_LSTM_AE=<lstm-id> \
  --set env.ENDPOINT_LOG_BERT=<logbert-id> \
  --set ingress.host=aiops.example.com \
  --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"=$RUNNER_SA

# Workload Identity binding (if not already done by Terraform):
gcloud iam service-accounts add-iam-policy-binding $RUNNER_SA \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:$GCP_PROJECT_ID.svc.id.goog[default/anomaly-scoring-api]"
```

The chart provisions:
- `Deployment` + `Service` (ClusterIP)
- `ServiceAccount` annotated for Workload Identity → `aiops-runner` GSA
- `Ingress` (GCE) with managed TLS cert + Cloud Armor `BackendConfig`
- `PodMonitoring` (Google Managed Prometheus auto-scrape on `/metrics`)
- HPA (CPU 70%, 2-8 replicas)

Point your DNS at the static IP `aiops.example.com → aiops-scoring-ip`.

---

## 8. Wire weekly retrain (Cloud Scheduler → Pub/Sub → Function → Vertex Pipeline)

```bash
gcloud functions deploy monitoring-mlops-${ENV}-pipeline-trigger \
  --gen2 --runtime=python311 --region=$GCP_REGION \
  --source=ml/pipelines/_shared \
  --entry-point=cloud_event_trigger \
  --trigger-topic=monitoring-mlops-${ENV}-retrain \
  --service-account=$RUNNER_SA \
  --set-env-vars="GCP_PROJECT_ID=$GCP_PROJECT_ID,GCP_REGION=$GCP_REGION,MONITORING_BUCKET=$BUCKET,MONITORING_AR=$AR_REPO,VERTEX_SERVICE_ACCOUNT=$RUNNER_SA,ENV=$ENV"
```

(Add a small `cloud_event_trigger(event)` function that decodes the
detector name and calls `ml.pipelines.<detector>.pipeline.main()`.)

Cloud Scheduler is already configured by Terraform:
- `monitoring-mlops-dev-rcf-metrics-daily` — `0 2 * * *` UTC
- `monitoring-mlops-dev-lstm-ae-weekly` — `30 20 * * SAT` UTC (Sun 02:00 IST)

---

## 9. Verify end-to-end

```bash
# Inject attack — should fire streaming-statistical alert within 60 s
python scripts/inject_attack.py --project $GCP_PROJECT_ID --kind ddos --duration-min 2 &

# Watch the anomalies topic
gcloud pubsub subscriptions create alerts-watch \
  --topic=monitoring-mlops-${ENV}-anomalies --ack-deadline=10 || true
gcloud pubsub subscriptions pull alerts-watch --auto-ack --limit=10

# Confirm via the Scoring API
SCORING_HOST=aiops.example.com bash scripts/smoke_test.sh
```

Success table:
| Check | Expectation |
|---|---|
| `gcloud ai endpoints list` | 4 endpoints DEPLOYED |
| `kubectl get pods -l app=anomaly-scoring-api` | All `Running` |
| `/api/v1/score` p99 | < 250 ms |
| `/api/v1/alerts` after attack inject | items > 0 |
| Cloud Monitoring metric `aiops/scoring/anomalies` | datapoints visible |
| Cloud Trace | spans for `score` operation |
| Cloud Scheduler last-run | success in console |

---

## 10. Teardown

```bash
bash scripts/teardown.sh dev
```

Order: Vertex Endpoints → GKE Helm uninstall → Cloud Functions →
Pub/Sub subs → Cloud SQL stop → `terraform destroy`.

---

## 11. Cost notes (CLAUDE.md rule 2)

| Resource | Type | Hourly | Used |
|---|---|---|---|
| Train (RCF/IForest) | `n1-standard-4` Spot | ≈ $0.05 | daily, 10-30 min |
| Train (LSTM-AE / LogBERT) | `g2-standard-8` Spot, 1× L4 | ≈ $0.30 | weekly, 1-3 h |
| Serve (RCF/IForest) | `n1-standard-2` | ≈ $0.10 | continuous |
| Serve (LSTM-AE / LogBERT) | `n1-standard-4` + L4 | ≈ $0.95 | continuous |
| GKE Autopilot | per-pod | ~$0.04/pod | 2-8 replicas |
| Cloud SQL | `db-custom-1-3840` | ≈ $0.07 | continuous |
| GCS / Pub/Sub / Logging | volume-based | < $5 / day dev | continuous |

Spot for all training. L4 ceiling. No A100/H100. Stop Cloud SQL during off-hours.
