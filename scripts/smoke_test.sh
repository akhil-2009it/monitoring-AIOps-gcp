#!/usr/bin/env bash
set -euo pipefail
ENV="${1:-dev}"
HOST="${SCORING_HOST:-aiops.example.com}"

echo "1. health"
curl -fsSL "https://$HOST/health" | jq

echo "2. score happy"
curl -fsSL "https://$HOST/api/v1/score" -H 'content-type: application/json' \
  -d '{"ts":"2026-06-19T10:00:00Z","source":"lb","host":"edge-1",
       "message":"GET /","status":200,"latency_ms":80,"bytes":1024}' | jq

echo "3. score attack"
curl -fsSL "https://$HOST/api/v1/score" -H 'content-type: application/json' \
  -d '{"ts":"2026-06-19T10:00:00Z","source":"lb","host":"edge-1",
       "message":"DDoS burst","status":503,"latency_ms":2}' | jq

echo "4. alerts"
curl -fsSL "https://$HOST/api/v1/alerts?limit=5" | jq '.items | length'
