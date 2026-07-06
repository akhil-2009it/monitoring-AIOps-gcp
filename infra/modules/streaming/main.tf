###############################################################################
# streaming — Pub/Sub topics + Dataflow PubSub→GCS partitioned writer.
###############################################################################

variable "project_id"      { type = string }
variable "region"          { type = string }
variable "environment"     { type = string }
variable "prefix"          { type = string }
variable "bucket_name"     { type = string }
variable "service_account" { type = string }
variable "labels"          { type = map(string) }

resource "google_pubsub_topic" "events" {
  name   = "${var.prefix}-events"
  labels = var.labels
}

resource "google_pubsub_topic" "anomalies" {
  name   = "${var.prefix}-anomalies"
  labels = var.labels
}

resource "google_pubsub_topic" "retrain" {
  name   = "${var.prefix}-retrain"
  labels = var.labels
}

# Subscription consumed by the streaming Cloud Function.
resource "google_pubsub_subscription" "events_to_streaming" {
  name                 = "${var.prefix}-events-streaming"
  topic                = google_pubsub_topic.events.name
  ack_deadline_seconds = 60
  labels               = var.labels
}

# Subscription consumed by the Dataflow GCS-writer job.
resource "google_pubsub_subscription" "events_to_dataflow" {
  name                 = "${var.prefix}-events-dataflow"
  topic                = google_pubsub_topic.events.name
  ack_deadline_seconds = 600
  labels               = var.labels
}

# Subscription that the Scoring API + alerting consumers attach to.
resource "google_pubsub_subscription" "anomalies_fanout" {
  name                 = "${var.prefix}-anomalies-fanout"
  topic                = google_pubsub_topic.anomalies.name
  ack_deadline_seconds = 60
  labels               = var.labels
}

# Dataflow temp / staging locations.
resource "google_storage_bucket_object" "df_tmp" {
  name    = "${var.environment}/dataflow/tmp/.keep"
  bucket  = var.bucket_name
  content = " "
}

# Dataflow job — uses Google's PubSub-to-GCS streaming flex template.
# The template reads JSON messages from a Pub/Sub subscription and writes
# them to date-partitioned files in GCS. Hive partitioning by `source` is
# done by a downstream Dataflow user-defined function (UDF) referenced via
# `javascriptTextTransformGcsPath` — kept simple here: dump per-window file.
resource "google_dataflow_flex_template_job" "events_to_gcs" {
  provider                = google-beta
  name                    = "${var.prefix}-events-to-gcs"
  container_spec_gcs_path = "gs://dataflow-templates/latest/flex/Cloud_PubSub_to_GCS_Text_Flex"
  region                  = var.region
  service_account_email   = var.service_account
  labels                  = var.labels

  parameters = {
    inputSubscription   = google_pubsub_subscription.events_to_dataflow.id
    outputDirectory     = "gs://${var.bucket_name}/${var.environment}/raw/"
    outputFilenamePrefix = "events-"
    outputFilenameSuffix = ".json"
    windowDuration      = "5m"
    numShards           = "2"
  }

  on_delete = "cancel"
}

output "events_topic"     { value = google_pubsub_topic.events.id }
output "anomalies_topic"  { value = google_pubsub_topic.anomalies.id }
output "retrain_topic"    { value = google_pubsub_topic.retrain.id }
output "anomalies_sub"    { value = google_pubsub_subscription.anomalies_fanout.id }
