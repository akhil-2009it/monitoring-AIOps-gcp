#!/usr/bin/env bash
###############################################################################
# deploy_all.sh — interactive end-to-end deploy for monitoring-mlops-gcp.
#
# Drives the full stack in 9 stages. Each stage prints its plan, asks
# [Y/n/s/q] (yes / no-skip / shell-into-stage-dir / quit), then runs.
#
# Usage:
#   scripts/deploy_all.sh
#
# Required env (or it will prompt):
#   GCP_PROJECT_ID, GCP_REGION (default asia-south1), ENV (default dev),
#   DOMAIN_AIOPS (default aiops.example.com), DOMAIN_DEMO (default demo.example.com)
###############################################################################
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; CYA=$'\033[36m'; CLR=$'\033[0m'

log()   { printf '%s[deploy]%s %s\n' "$CYA" "$CLR" "$*"; }
ok()    { printf '%s[ ok  ]%s %s\n' "$GRN" "$CLR" "$*"; }
warn()  { printf '%s[warn ]%s %s\n' "$YEL" "$CLR" "$*"; }
die()   { printf '%s[fail ]%s %s\n' "$RED" "$CLR" "$*" >&2; exit 1; }

confirm() {
  # $1 = stage label, $2 = stage dir (optional)
  local label="$1" dir="${2:-$ROOT}"
  echo
  printf '%s━━ %s ━━%s\n' "$CYA" "$label" "$CLR"
  if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
    ok "non-interactive auto-confirm: $label"
    return 0
  fi
  while true; do
    read -r -p "Run this step? [Y]es / [n]o-skip / [s]hell / [q]uit: " ans </dev/tty
    case "${ans:-Y}" in
      Y|y|"") return 0 ;;
      N|n)    warn "skipping: $label"; return 1 ;;
      S|s)    ( cd "$dir" && "${SHELL:-bash}" -i ) ;;
      Q|q)    die "user quit at: $label" ;;
      *)      echo "  pick one of Y / n / s / q" ;;
    esac
  done
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# ── Pre-flight ─────────────────────────────────────────────────────────────
require_cmd gcloud
require_cmd terraform
require_cmd kubectl
require_cmd helm
require_cmd docker
require_cmd python3

: "${GCP_PROJECT_ID:=$(gcloud config get-value project 2>/dev/null || true)}"
: "${GCP_REGION:=asia-south1}"
: "${ENV:=dev}"
: "${DOMAIN_AIOPS:=aiops.example.com}"
: "${DOMAIN_DEMO:=demo.example.com}"

if [[ -z "${GCP_PROJECT_ID}" ]]; then
  read -r -p "GCP_PROJECT_ID: " GCP_PROJECT_ID </dev/tty
fi
[[ -n "$GCP_PROJECT_ID" ]] || die "GCP_PROJECT_ID is required"

export GCP_PROJECT_ID GCP_REGION ENV DOMAIN_AIOPS DOMAIN_DEMO

PREFIX="monitoring-mlops-${ENV}"
TAG="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/monitoring-mlops"

cat <<EOF
$CYA┌─ monitoring-mlops-gcp deploy ─┐$CLR
  Project   : $GCP_PROJECT_ID
  Region    : $GCP_REGION
  Env       : $ENV
  Prefix    : $PREFIX
  AR repo   : $TAG
  AIOps UI  : https://$DOMAIN_AIOPS
  Demo URL  : http://$DOMAIN_DEMO
$CYA└──────────────────────────────────────────────────────────────$CLR
EOF

if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
  read -r -p "Looks right? [Y/q]: " a </dev/tty
  [[ "${a:-Y}" =~ ^[Yy]?$ ]] || die "abort"
fi

gcloud config set project "$GCP_PROJECT_ID" >/dev/null
gcloud config set compute/region "$GCP_REGION" >/dev/null

# ── Stage 1 — Platform Terraform ───────────────────────────────────────────
if confirm "Stage 1/9 — Terraform: provision platform (GKE/GCS/Pub-Sub/BQ/Vertex/...)" "$ROOT/infra"; then
  pushd infra >/dev/null
  cat > terraform.tfvars <<EOF
project_id  = "$GCP_PROJECT_ID"
region      = "$GCP_REGION"
environment = "$ENV"
domain      = "$DOMAIN_AIOPS"
EOF
  terraform init -upgrade
  terraform apply -auto-approve

  BUCKET=$(terraform output -raw bucket)
  AR_REPO=$(terraform output -raw artifact_registry)
  RUNNER_SA=$(terraform output -raw service_account)
  GKE=$(terraform output -raw gke_cluster_name)
  EVENTS_TOPIC=$(terraform output -raw events_topic)
  ANOMALY_TOPIC=$(terraform output -raw anomalies_topic)
  RETRAIN_TOPIC=$(terraform output -raw retrain_topic)
  ANOMALY_SUB=$(terraform output -raw anomalies_sub)
  API_IP=$(terraform output -raw api_static_ip)
  UI_IP=$(terraform output -raw ui_static_ip)
  BQ_DATASET=$(terraform output -raw bigquery_dataset)
  popd >/dev/null

  cat > "$ROOT/.deploy.env" <<EOF
BUCKET=$BUCKET
AR_REPO=$AR_REPO
RUNNER_SA=$RUNNER_SA
GKE=$GKE
EVENTS_TOPIC=$EVENTS_TOPIC
ANOMALY_TOPIC=$ANOMALY_TOPIC
RETRAIN_TOPIC=$RETRAIN_TOPIC
ANOMALY_SUB=$ANOMALY_SUB
API_IP=$API_IP
UI_IP=$UI_IP
BQ_DATASET=$BQ_DATASET
EOF
  ok "platform up · outputs cached in .deploy.env"
fi

# Reload outputs (so re-runs / skipped stages still have them)
[[ -f "$ROOT/.deploy.env" ]] && source "$ROOT/.deploy.env" || warn "no .deploy.env — Stage 1 must run at least once"

# ── Stage 2 — Build + push images (Cloud Build; no local docker) ───────────
if confirm "Stage 2/9 — Cloud Build & push images (scoring-api · ui · 4 trainers · demo-app · sklearn-serve mirror)"; then
  # All builds run in GCP via Cloud Build. No local docker required.
  gcb() {
    # $1 = image name (short); $2 = Dockerfile path (relative to $ROOT); $3 = build context dir
    local IMG="$1" DF="$2" CTX="$3"
    # Compute Dockerfile path relative to CTX (Cloud Build uploads CTX as source)
    local DF_ABS="$ROOT/$DF"
    local DF_REL
    DF_REL=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$DF_ABS" "$CTX")
    log "cloud-build → $IMG (dockerfile: $DF_REL, context: $CTX)"
    local CFG
    CFG=$(mktemp)
    cat > "$CFG" <<YAML
steps:
- name: gcr.io/cloud-builders/docker
  args: ['build','-t','$TAG/$IMG:latest','-f','$DF_REL','.']
images:
- '$TAG/$IMG:latest'
timeout: 1800s
options:
  machineType: E2_HIGHCPU_8
YAML
    gcloud builds submit "$CTX" \
      --project="$GCP_PROJECT_ID" \
      --config="$CFG"
    rm -f "$CFG"
  }

  # Scoring API and UI (context = repo root for scoring so it can COPY ml/)
  gcb "anomaly-scoring-api" "api/scoring/Dockerfile" "$ROOT"
  gcb "aiops-ui"            "api/ui/Dockerfile"      "$ROOT/api/ui"

  # 4 trainer images — Dockerfiles live inside ml/pipelines/<d>/, context = repo root
  for d in rcf_metrics iforest_logs lstm_ae_traces log_embedding_anomaly; do
    if [[ -f "$ROOT/ml/pipelines/$d/Dockerfile" ]]; then
      gcb "${d//_/-}-train" "ml/pipelines/$d/Dockerfile" "$ROOT"
    else
      warn "no Dockerfile for ml/pipelines/$d — skipping trainer image"
    fi
  done

  # Demo-app trio
  gcb "demo-api"    "demo-app/api/Dockerfile"    "$ROOT/demo-app/api"
  gcb "demo-worker" "demo-app/worker/Dockerfile" "$ROOT/demo-app/worker"
  gcb "demo-web"    "demo-app/web/Dockerfile"    "$ROOT/demo-app/web"

  # Mirror Vertex pre-built sklearn image into our AR as serve images.
  # Uses a tiny Cloud Build inline job (no docker on laptop).
  MIRROR_DIR=$(mktemp -d)
  cat > "$MIRROR_DIR/cloudbuild.yaml" <<YAML
steps:
- name: gcr.io/cloud-builders/docker
  entrypoint: bash
  args:
  - -c
  - |
    set -e
    docker pull us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest
    for s in rcf-metrics iforest-logs lstm-ae-traces log-embedding-anomaly; do
      docker tag  us-docker.pkg.dev/vertex-ai/prediction/sklearn-cpu.1-3:latest ${TAG}/\$\${s}-serve:latest
      docker push ${TAG}/\$\${s}-serve:latest
    done
timeout: 1200s
options:
  machineType: E2_HIGHCPU_8
YAML
  gcloud builds submit --project="$GCP_PROJECT_ID" --config="$MIRROR_DIR/cloudbuild.yaml" --no-source
  rm -rf "$MIRROR_DIR"

  ok "images built + pushed via Cloud Build"
fi

# ── Stage 3 — Demo-app Terraform (Cloud SQL + Memorystore + GSAs) ──────────
if confirm "Stage 3/9 — Terraform: demo-app infra (Cloud SQL MySQL · Memorystore · WLI GSAs)" "$ROOT/demo-app/infra"; then
  pushd demo-app/infra >/dev/null
  cat > terraform.tfvars <<EOF
project_id  = "$GCP_PROJECT_ID"
region      = "$GCP_REGION"
environment = "$ENV"
network     = "default"
EOF
  terraform init -upgrade
  terraform apply -auto-approve

  MYSQL_IP=$(terraform output -raw mysql_ip)
  REDIS_IP=$(terraform output -raw redis_ip)
  DEMO_IP=$(terraform output -raw demo_ip)
  MYSQL_PASS_SECRET=$(terraform output -raw mysql_pass_secret_id)
  DEMO_API_GSA=$(terraform output -raw demo_api_gsa)
  DEMO_WORKER_GSA=$(terraform output -raw demo_worker_gsa)
  popd >/dev/null

  cat >> "$ROOT/.deploy.env" <<EOF
MYSQL_IP=$MYSQL_IP
REDIS_IP=$REDIS_IP
DEMO_IP=$DEMO_IP
MYSQL_PASS_SECRET=$MYSQL_PASS_SECRET
DEMO_API_GSA=$DEMO_API_GSA
DEMO_WORKER_GSA=$DEMO_WORKER_GSA
EOF
  source "$ROOT/.deploy.env"
  ok "demo-app infra up"
fi

# ── Stage 4 — Streaming Cloud Function ─────────────────────────────────────
if confirm "Stage 4/9 — Deploy streaming Cloud Function (Pub/Sub → rules → anomalies)"; then
  gcloud functions deploy "${PREFIX}-streaming-detector" \
    --gen2 --runtime=python311 --region="$GCP_REGION" \
    --source="$ROOT/ml/streaming" \
    --entry-point=handler \
    --trigger-topic="${PREFIX}-events" \
    --service-account="$RUNNER_SA" \
    --memory=1Gi --timeout=120s \
    --set-env-vars="GCP_PROJECT_ID=$GCP_PROJECT_ID,ANOMALY_TOPIC=${PREFIX}-anomalies,RULES_PATH=/workspace/rules.yaml"
  ok "streaming detector deployed"
fi

# ── Stage 5 — Feature engineering + 4 Vertex pipelines ─────────────────────
if confirm "Stage 5/9 — Feature engineering + submit 4 Vertex pipelines (RCF/IForest/LSTM-AE/LogBERT)"; then
  export PYTHONPATH="$ROOT"
  log "seeding synthetic events to Pub/Sub for cold-start"
  python3 "$ROOT/scripts/seed_logs.py" \
      --project "$GCP_PROJECT_ID" \
      --topic "${PREFIX}-events" \
      --n 5000 --rate 200 || warn "seed script failed (non-fatal)"

  log "running feature_engineering/security_features.py"
  python3 "$ROOT/ml/feature_engineering/security_features.py" \
      --input-uri  "gs://$BUCKET/$ENV/raw/" \
      --output-uri "gs://$BUCKET/$ENV/features/security/" \
      --window-minutes 5 || warn "feature build failed (non-fatal first run)"

  for d in rcf_metrics iforest_logs lstm_ae_traces log_embedding_anomaly; do
    log "submitting Vertex Pipeline: $d"
    python3 -m "ml.pipelines.${d}.pipeline" || warn "pipeline $d failed (continuing)"
  done
  ok "pipelines submitted (watch in Vertex Console)"
fi

# ── Stage 6 — Deploy 4 Vertex Endpoints (model attach) ─────────────────────
if confirm "Stage 6/9 — Attach trained models to the 4 Vertex Endpoints (created by Terraform)"; then
  attach_model() {
    local NAME="$1" DISPLAY="$2" MACHINE="$3" GPU="${4:-}"
    local EID
    EID=$(gcloud ai endpoints list --region="$GCP_REGION" \
          --filter="displayName=$NAME" --format="value(name)" | awk -F/ '{print $NF}')
    [[ -n "$EID" ]] || { warn "endpoint $NAME not found (Stage 1 should have created it)"; return; }
    local MODEL
    MODEL=$(gcloud ai models list --region="$GCP_REGION" \
            --filter="displayName=$DISPLAY" --sort-by="~createTime" --limit=1 \
            --format="value(name)")
    [[ -n "$MODEL" ]] || { warn "no model found for $DISPLAY (Stage 5 must finish first)"; return; }

    gcloud ai endpoints deploy-model "$EID" --region="$GCP_REGION" \
      --model="$MODEL" --display-name="${DISPLAY}-v1" \
      --machine-type="$MACHINE" \
      ${GPU:+--accelerator=$GPU} \
      --min-replica-count=1 --max-replica-count=2 \
      --service-account="$RUNNER_SA" --traffic-split=0=100 || warn "deploy-model failed for $NAME"
  }
  attach_model "rcf-metrics-${ENV}"     rcf-metrics-detector            n1-standard-2
  attach_model "iforest-logs-${ENV}"    iforest-logs-detector           n1-standard-2
  attach_model "lstm-ae-traces-${ENV}"  lstm-ae-traces-detector         n1-standard-4 type=nvidia-l4,count=1
  attach_model "log-embedding-${ENV}"   log-embedding-anomaly-detector  n1-standard-4 type=nvidia-l4,count=1

  cat >> "$ROOT/.deploy.env" <<EOF
ENDPOINT_RCF=$(gcloud ai endpoints list --region="$GCP_REGION" --filter="displayName=rcf-metrics-${ENV}" --format="value(name)" | awk -F/ '{print $NF}')
ENDPOINT_IFOREST=$(gcloud ai endpoints list --region="$GCP_REGION" --filter="displayName=iforest-logs-${ENV}" --format="value(name)" | awk -F/ '{print $NF}')
ENDPOINT_LSTM=$(gcloud ai endpoints list --region="$GCP_REGION" --filter="displayName=lstm-ae-traces-${ENV}" --format="value(name)" | awk -F/ '{print $NF}')
ENDPOINT_LOGBERT=$(gcloud ai endpoints list --region="$GCP_REGION" --filter="displayName=log-embedding-${ENV}" --format="value(name)" | awk -F/ '{print $NF}')
EOF
  source "$ROOT/.deploy.env"
  ok "endpoints attached"
fi

# ── Stage 7 — Helm: scoring-api · ui · otel-collector ──────────────────────
if confirm "Stage 7/9 — Helm install: anomaly-scoring-api · aiops-ui · otel-collector"; then
  gcloud container clusters get-credentials "$GKE" --region="$GCP_REGION"

  helm upgrade --install otel-collector "$ROOT/helm/charts/otel-collector" \
    --namespace observability --create-namespace \
    --set projectId="$GCP_PROJECT_ID" \
    --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="$RUNNER_SA"

  helm upgrade --install anomaly-scoring-api "$ROOT/helm/charts/anomaly-scoring-api" \
    --namespace default \
    --set image.repository="$TAG/anomaly-scoring-api" \
    --set image.tag=latest \
    --set env.GCP_PROJECT_ID="$GCP_PROJECT_ID" \
    --set env.GCP_REGION="$GCP_REGION" \
    --set env.ENDPOINT_RCF_METRICS="${ENDPOINT_RCF:-}" \
    --set env.ENDPOINT_IFOREST_LOGS="${ENDPOINT_IFOREST:-}" \
    --set env.ENDPOINT_LSTM_AE="${ENDPOINT_LSTM:-}" \
    --set env.ENDPOINT_LOG_BERT="${ENDPOINT_LOGBERT:-}" \
    --set env.OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.observability.svc.cluster.local:4318" \
    --set ingress.host="$DOMAIN_AIOPS" \
    --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="$RUNNER_SA"

  helm upgrade --install aiops-ui "$ROOT/helm/charts/aiops-ui" \
    --namespace default \
    --set image.repository="$TAG/aiops-ui" \
    --set image.tag=latest \
    --set ingress.host="$DOMAIN_AIOPS"

  ok "scoring API + UI + OTEL collector installed"
fi

# ── Stage 8 — Demo-app Helm install ────────────────────────────────────────
if confirm "Stage 8/9 — Helm install: demo-api · demo-worker · demo-web (signal source)"; then
  # Sync the MySQL password into a k8s Secret consumed by demo-api.
  if [[ -n "${MYSQL_PASS_SECRET:-}" ]]; then
    DB_PASS=$(gcloud secrets versions access latest --secret="$MYSQL_PASS_SECRET")
    kubectl create secret generic demo-api-db \
      --from-literal=DB_PASSWORD="$DB_PASS" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    warn "MYSQL_PASS_SECRET not set — create k8s secret 'demo-api-db' manually"
  fi

  helm upgrade --install demo-api "$ROOT/demo-app/helm/demo-service" \
    --namespace default \
    -f "$ROOT/demo-app/helm/demo-service/values-api.yaml" \
    --set image.repository="$TAG/demo-api" \
    --set env.DB_HOST="${MYSQL_IP:-}" \
    --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="$DEMO_API_GSA"

  helm upgrade --install demo-worker "$ROOT/demo-app/helm/demo-service" \
    --namespace default \
    -f "$ROOT/demo-app/helm/demo-service/values-worker.yaml" \
    --set image.repository="$TAG/demo-worker" \
    --set env.REDIS_URL="redis://${REDIS_IP:-localhost}:6379/0" \
    --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"="$DEMO_WORKER_GSA"

  helm upgrade --install demo-web "$ROOT/demo-app/helm/demo-service" \
    --namespace default \
    -f "$ROOT/demo-app/helm/demo-service/values-web.yaml" \
    --set image.repository="$TAG/demo-web" \
    --set ingress.hosts[0].host="$DOMAIN_DEMO"

  ok "demo-app deployed"
fi

# ── Stage 9 — Traffic generator + verification ─────────────────────────────
if confirm "Stage 9/9 — kubectl apply traffic-gen cronjob + run smoke test"; then
  # Substitute project into the cronjob image ref before apply.
  sed "s|REPLACE_PROJECT|$GCP_PROJECT_ID|g" "$ROOT/demo-app/traffic-gen/k8s-cronjob.yaml" \
    | kubectl apply -f -

  log "kicking off one normal traffic Job immediately"
  kubectl -n demo create job --from=cronjob/demo-traffic-normal traffic-bootstrap-$(date +%s) || true

  if [[ -x "$ROOT/scripts/smoke_test.sh" ]]; then
    SCORING_HOST="$DOMAIN_AIOPS" bash "$ROOT/scripts/smoke_test.sh" || warn "smoke test failed (DNS may not be ready yet)"
  fi
  ok "traffic flowing"
fi

# Resolve LB IPs from the Ingress resources (placeholder DNS — no real records).
UI_LB_IP=$(kubectl get ingress aiops-ui -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
SCORING_LB_IP=$(kubectl get ingress anomaly-scoring-api -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
DEMO_LB_IP=$(kubectl get ingress demo-web -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

# Fall back to the static-IP outputs if Ingress hasn't reconciled yet.
UI_LB_IP=${UI_LB_IP:-$UI_IP}
SCORING_LB_IP=${SCORING_LB_IP:-$API_IP}
DEMO_LB_IP=${DEMO_LB_IP:-$DEMO_IP}

cat <<EOF

$GRN┌─ Done. End-state (placeholder DNS — hit by IP) ─┐$CLR
  AIOps Console (UI) : http://${UI_LB_IP:-<pending>}/
                       curl -H "Host: $DOMAIN_AIOPS" http://${UI_LB_IP:-<ip>}/

  Scoring API JSON   : http://${SCORING_LB_IP:-<pending>}/api/v1/alerts
                       curl -H "Host: $DOMAIN_AIOPS" http://${SCORING_LB_IP:-<ip>}/api/v1/alerts

  Demo app           : http://${DEMO_LB_IP:-<pending>}/
                       curl -H "Host: $DOMAIN_DEMO" http://${DEMO_LB_IP:-<ip>}/

  Cloud Logging      : https://console.cloud.google.com/logs?project=$GCP_PROJECT_ID
  Cloud Trace        : https://console.cloud.google.com/traces?project=$GCP_PROJECT_ID
  Vertex Endpoints   : https://console.cloud.google.com/vertex-ai/endpoints?project=$GCP_PROJECT_ID
  Dashboards (Mon)   : https://console.cloud.google.com/monitoring/dashboards?project=$GCP_PROJECT_ID
  BigQuery dataset   : ${BQ_DATASET:-monitoring}

  Pull anomalies from Pub/Sub:
    gcloud pubsub subscriptions pull ${PREFIX}-anomalies-fanout --auto-ack --limit=10

  Trigger an attack burst:
    kubectl -n demo patch cronjob demo-traffic-attack --patch '{"spec":{"suspend":false}}'
    kubectl -n demo create job --from=cronjob/demo-traffic-attack attack-now

  Note: with placeholder DNS, ManagedCertificate is disabled (tls=false).
  Ingress serves HTTP-only on the static IP; once you point real DNS, set
  ingress.tls=true in the values + helm upgrade to enable HTTPS.
$GRN└──────────────────────────────────────────────────────────────────$CLR
EOF
