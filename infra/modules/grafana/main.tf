###############################################################################
# grafana — Cloud Monitoring dashboards (the "Managed Grafana for GCP" surface).
# Two dashboards: AIOps overview + detector health.
###############################################################################

variable "prefix" { type = string }
variable "labels" { type = map(string) }

resource "google_monitoring_dashboard" "aiops_overview" {
  dashboard_json = jsonencode({
    displayName = "AIOps Overview (${var.prefix})"
    gridLayout = {
      columns = "2"
      widgets = [
        {
          title = "Anomalies / minute (by detector)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter             = "metric.type=\"custom.googleapis.com/aiops/scoring/anomalies\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_RATE"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["metric.label.detector"]
                  }
                }
              }
            }]
          }
        },
        {
          title = "Scoring API p95 latency"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter      = "metric.type=\"prometheus.googleapis.com/scoring_latency_seconds/histogram\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_DELTA"
                    crossSeriesReducer = "REDUCE_PERCENTILE_95"
                  }
                }
              }
            }]
          }
        },
        {
          title = "Streaming Cloud Function executions"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter             = "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_RATE"
                    crossSeriesReducer = "REDUCE_SUM"
                  }
                }
              }
            }]
          }
        },
        {
          title = "Pub/Sub events backlog"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter      = "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_MEAN"
                    crossSeriesReducer = "REDUCE_MAX"
                    groupByFields      = ["resource.label.subscription_id"]
                  }
                }
              }
            }]
          }
        },
      ]
    }
  })
}

resource "google_monitoring_dashboard" "detector_health" {
  dashboard_json = jsonencode({
    displayName = "Detector Health (${var.prefix})"
    gridLayout = {
      columns = "2"
      widgets = [
        {
          title = "Vertex Endpoint prediction count"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter             = "metric.type=\"aiplatform.googleapis.com/prediction/online/prediction_count\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_RATE"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["resource.label.endpoint_id"]
                  }
                }
              }
            }]
          }
        },
        {
          title = "Vertex Endpoint p95 latency"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter             = "metric.type=\"aiplatform.googleapis.com/prediction/online/response_count\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_RATE"
                    crossSeriesReducer = "REDUCE_PERCENTILE_95"
                  }
                }
              }
            }]
          }
        },
      ]
    }
  })
}
