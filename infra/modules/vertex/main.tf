###############################################################################
# vertex — 4 Vertex AI Endpoints (no model deployments — those happen
# after a pipeline run uploads a model and we attach via gcloud / pipeline).
###############################################################################

variable "region"      { type = string }
variable "environment" { type = string }
variable "labels"      { type = map(string) }

locals {
  detectors = ["rcf-metrics", "iforest-logs", "lstm-ae-traces", "log-embedding"]
}

resource "google_vertex_ai_endpoint" "endpoint" {
  for_each     = toset(local.detectors)
  name         = "${each.key}-${var.environment}"
  display_name = "${each.key}-${var.environment}"
  location     = var.region
  region       = var.region
  labels       = var.labels
  description  = "Endpoint for the ${each.key} detector"
}

output "endpoint_ids" {
  value = { for k, e in google_vertex_ai_endpoint.endpoint : k => e.name }
}
