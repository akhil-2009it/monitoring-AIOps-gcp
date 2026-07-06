###############################################################################
# identity — runner GSA + IAM project roles.
###############################################################################

variable "project_id" { type = string }
variable "labels"     { type = map(string) }

resource "google_service_account" "runner" {
  account_id   = "aiops-runner"
  display_name = "monitoring-mlops-gcp runner"
}

resource "google_project_iam_member" "runner_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/storage.objectAdmin",
    "roles/secretmanager.secretAccessor",
    "roles/cloudsql.client",
    "roles/datastore.user",
    "roles/pubsub.publisher",
    "roles/pubsub.subscriber",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/cloudtrace.agent",
    "roles/artifactregistry.reader",
    "roles/bigquery.dataEditor",
    "roles/dataflow.worker",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.runner.email}"
}

output "email"      { value = google_service_account.runner.email }
output "name"       { value = google_service_account.runner.name }
