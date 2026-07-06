###############################################################################
# datalake — GCS bucket (raw + features + models) + BigQuery external tables.
###############################################################################

variable "project_id"  { type = string }
variable "region"      { type = string }
variable "environment" { type = string }
variable "bucket_name" { type = string }
variable "labels"      { type = map(string) }

resource "google_storage_bucket" "lake" {
  name                        = "${var.bucket_name}-${var.environment}"
  location                    = var.region
  uniform_bucket_level_access = true
  versioning { enabled = true }
  labels                      = var.labels

  lifecycle_rule {
    action    { type = "Delete" }
    condition { age = 90 }
  }
}

resource "google_storage_bucket_object" "raw_marker" {
  for_each = toset(["app", "lb", "cloud_armor", "cdn", "gke", "nginx", "cloudsql", "mongo", "redis"])
  name     = "${var.environment}/raw/source=${each.key}/placeholder.json"
  bucket   = google_storage_bucket.lake.name
  content  = jsonencode({
    ts         = "2026-06-20T10:00:00Z"
    ingest_ts  = "2026-06-20T10:00:00Z"
    source     = each.key
    host       = "placeholder"
    severity   = "INFO"
    status     = 200
    latency_ms = 0.0
    bytes      = 0
    src_ip     = "1.1.1.1"
    user       = "placeholder"
    path       = "/"
    user_agent = "placeholder"
    message    = "placeholder"
    attrs      = {}
  })
}

# BigQuery dataset + external tables over GCS raw partitions.
resource "google_bigquery_dataset" "monitoring" {
  dataset_id    = "monitoring"
  location      = var.region
  labels        = var.labels
  friendly_name = "AIOps raw + features"
}

resource "google_bigquery_table" "raw_events" {
  dataset_id = google_bigquery_dataset.monitoring.dataset_id
  table_id   = "raw_events"
  labels     = var.labels
  deletion_protection = false

  external_data_configuration {
    autodetect    = true
    source_format = "NEWLINE_DELIMITED_JSON"
    source_uris   = ["gs://${google_storage_bucket.lake.name}/${var.environment}/raw/*"]
    hive_partitioning_options {
      mode              = "AUTO"
      source_uri_prefix = "gs://${google_storage_bucket.lake.name}/${var.environment}/raw/"
    }
  }
}

resource "google_bigquery_table" "features_security" {
  dataset_id = google_bigquery_dataset.monitoring.dataset_id
  table_id   = "features_security"
  labels     = var.labels
  deletion_protection = false

  external_data_configuration {
    autodetect    = true
    source_format = "PARQUET"
    source_uris   = ["gs://${google_storage_bucket.lake.name}/${var.environment}/features/security/*"]
  }
}

# Native table for anomalies (loaded by Scoring API or Dataflow side-output).
resource "google_bigquery_table" "anomalies" {
  dataset_id = google_bigquery_dataset.monitoring.dataset_id
  table_id   = "anomalies"
  labels     = var.labels
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "ts"
  }

  schema = jsonencode([
    { name = "id",         type = "STRING",   mode = "REQUIRED" },
    { name = "ts",         type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "detector",   type = "STRING",   mode = "REQUIRED" },
    { name = "source",     type = "STRING",   mode = "REQUIRED" },
    { name = "host",       type = "STRING",   mode = "NULLABLE" },
    { name = "score",      type = "FLOAT",    mode = "REQUIRED" },
    { name = "severity",   type = "STRING",   mode = "REQUIRED" },
    { name = "explanation", type = "JSON",    mode = "NULLABLE" },
  ])
}

output "bucket_name"   { value = google_storage_bucket.lake.name }
output "dataset_id"    { value = google_bigquery_dataset.monitoring.dataset_id }
output "anomalies_table" { value = google_bigquery_table.anomalies.table_id }
