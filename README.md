# monitoring-mlops-gcp

AIOps + MLOps + Security Analytics platform — **GCP** sibling of `../monitoring-mlops/` (AWS).

End-to-end ingest → detect → alert pipeline backed by Vertex AI, Pub/Sub,
Dataflow, GKE Autopilot, Cloud Logging, Cloud Monitoring, BigQuery, and
Security Command Center.

```
monitoring-mlops-gcp/
├── CLAUDE.md                ← architecture, layers, sources, detectors
├── infra/                   ← Terraform for the whole platform
├── ml/
│   ├── parsers/             ← log → CommonEvent
│   ├── feature_engineering/ ← sliding-window security features (Vertex CustomJob)
│   ├── pipelines/           ← 4 detectors as Vertex Pipelines (KFP v2)
│   │   ├── rcf_metrics
│   │   ├── iforest_logs
│   │   ├── lstm_ae_traces
│   │   └── log_embedding_anomaly
│   ├── streaming/           ← cold-start Cloud Function (z-score / EWMA / threshold)
│   └── monitoring/          ← drift on detector inputs
├── api/scoring/             ← FastAPI: /score /alerts /explain /feedback /sources
├── helm/charts/anomaly-scoring-api  ← GKE chart with PodMonitoring + Cloud Armor
├── scripts/                 ← seed_logs · inject_attack · teardown · smoke
├── tests/                   ← unit + integration + load
└── docs/DEPLOY.md           ← full runbook
```

Pipeline shape (per detector — same as AWS port):

```
DataValidate → FeatureExtract → Train (Vertex CustomJob)
            → Evaluate → GateOnMetric → RegisterModel
```

Tiered detection (matches AWS port):

| Tier | Latency | Mechanism |
|---|---|---|
| GCP-managed       | seconds | SCC + Cloud Armor + Event Threat Detection |
| Streaming-stat    | seconds | Cloud Function on `events` Pub/Sub |
| BigQuery / Elastic AD | minutes | `ML.DETECT_ANOMALIES` over feature tables |
| Vertex Pipeline + Endpoint | hours train, ms inference | RCF, IForest, LSTM-AE, Log-BERT |

See `docs/DEPLOY.md` for install + connect instructions.
