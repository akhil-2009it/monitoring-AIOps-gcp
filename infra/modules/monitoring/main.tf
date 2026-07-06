###############################################################################
# monitoring — Cloud Scheduler retrain triggers + alert policy.
###############################################################################

variable "region"        { type = string }
variable "prefix"        { type = string }
variable "labels"        { type = map(string) }
variable "retrain_topic" { type = string }

resource "google_cloud_scheduler_job" "rcf_metrics_daily" {
  name        = "${var.prefix}-rcf-metrics-daily"
  description = "Trigger RCF metrics retrain daily 02:00 UTC"
  schedule    = "0 2 * * *"
  region      = var.region

  pubsub_target {
    topic_name = var.retrain_topic
    data       = base64encode(jsonencode({ detector = "rcf-metrics", trigger = "daily" }))
  }
}

resource "google_cloud_scheduler_job" "iforest_logs_daily" {
  name     = "${var.prefix}-iforest-logs-daily"
  schedule = "30 2 * * *"
  region   = var.region

  pubsub_target {
    topic_name = var.retrain_topic
    data       = base64encode(jsonencode({ detector = "iforest-logs", trigger = "daily" }))
  }
}

resource "google_cloud_scheduler_job" "lstm_ae_weekly" {
  name     = "${var.prefix}-lstm-ae-weekly"
  schedule = "30 20 * * SAT"
  region   = var.region

  pubsub_target {
    topic_name = var.retrain_topic
    data       = base64encode(jsonencode({ detector = "lstm-ae-traces", trigger = "weekly" }))
  }
}

resource "google_cloud_scheduler_job" "logbert_weekly" {
  name     = "${var.prefix}-log-embedding-weekly"
  schedule = "0 21 * * SAT"
  region   = var.region

  pubsub_target {
    topic_name = var.retrain_topic
    data       = base64encode(jsonencode({ detector = "log-embedding-anomaly", trigger = "weekly" }))
  }
}

resource "google_monitoring_metric_descriptor" "anomalies" {
  description  = "Anomalies metric recorded by scoring API"
  display_name = "Scoring Anomalies"
  type         = "custom.googleapis.com/aiops/scoring/anomalies"
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
}

resource "google_monitoring_alert_policy" "precision_drop" {
  display_name = "${var.prefix}-detector-precision-drop"
  combiner     = "OR"
  depends_on   = [google_monitoring_metric_descriptor.anomalies]
  conditions {
    display_name = "scoring precision low (rolling 1h)"
    condition_threshold {
      filter          = "resource.type=\"global\" AND metric.type=\"custom.googleapis.com/aiops/scoring/anomalies\""
      comparison      = "COMPARISON_LT"
      threshold_value = 0.75
      duration        = "3600s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  user_labels = var.labels
}
