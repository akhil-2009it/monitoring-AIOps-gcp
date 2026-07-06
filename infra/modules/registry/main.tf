###############################################################################
# registry — Artifact Registry for all docker images.
###############################################################################

variable "region" { type = string }
variable "labels" { type = map(string) }

resource "google_artifact_registry_repository" "ar" {
  location      = var.region
  repository_id = "monitoring-mlops"
  format        = "DOCKER"
  labels        = var.labels
}

output "name" { value = google_artifact_registry_repository.ar.name }
