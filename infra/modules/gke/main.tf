###############################################################################
# gke — Autopilot cluster + Workload Identity bindings.
###############################################################################

variable "project_id"  { type = string }
variable "region"      { type = string }
variable "prefix"      { type = string }
variable "labels"      { type = map(string) }
variable "runner_sa"   { type = string }

resource "google_container_cluster" "gke" {
  provider            = google-beta
  name                = "${var.prefix}-gke"
  location            = var.region
  enable_autopilot    = true
  deletion_protection = false
  resource_labels     = var.labels

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

# Workload Identity bindings for KSAs that consume the runner GSA.
resource "google_service_account_iam_member" "wli_scoring" {
  service_account_id = var.runner_sa
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/anomaly-scoring-api]"
}

resource "google_service_account_iam_member" "wli_otel" {
  service_account_id = var.runner_sa
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[observability/otel-collector]"
}

resource "google_service_account_iam_member" "wli_ui" {
  service_account_id = var.runner_sa
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/aiops-ui]"
}

output "cluster_name"     { value = google_container_cluster.gke.name }
output "cluster_endpoint" { value = google_container_cluster.gke.endpoint }
