#!/usr/bin/env bash
# Teardown order — sacred. CLAUDE.md rule 3.
#
# Usage: scripts/teardown.sh --env dev
set -euo pipefail
ENV="${1:-dev}"
PREFIX="monitoring-mlops-${ENV}"
REGION="${GCP_REGION:-asia-south1}"

echo "1. Undeploy all Vertex Endpoints"
for ep in $(gcloud ai endpoints list --region="$REGION" --format='value(name)' || true); do
  for dm in $(gcloud ai endpoints describe "$ep" --region="$REGION" --format='value(deployedModels[].id)' || true); do
    gcloud ai endpoints undeploy-model "$ep" --region="$REGION" --deployed-model-id="$dm" --quiet || true
  done
  gcloud ai endpoints delete "$ep" --region="$REGION" --quiet || true
done

echo "2. Scale GKE Autopilot — Helm uninstall"
helm uninstall anomaly-scoring-api -n default --ignore-not-found || true

echo "3. Delete Cloud Functions"
gcloud functions delete "${PREFIX}-streaming-detector" --region="$REGION" --gen2 --quiet || true
gcloud functions delete "${PREFIX}-pipeline-trigger" --region="$REGION" --gen2 --quiet || true

echo "4. Delete Pub/Sub subs (topics live with terraform)"
for s in $(gcloud pubsub subscriptions list --format='value(name)' --filter="name~$PREFIX"); do
  gcloud pubsub subscriptions delete "$s" --quiet || true
done

echo "5. Stop Cloud SQL (preserve data)"
gcloud sql instances patch "${PREFIX}-pg" --activation-policy=NEVER --quiet || true

echo "6. Terraform destroy"
( cd infra && terraform destroy -auto-approve -var "environment=${ENV}" )

echo "Done. Verify Billing console 24 h later."
