###############################################################################
# monitoring-mlops-gcp — root Terraform.
# Orchestrates modules under infra/modules/* per CLAUDE.md.
###############################################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 5.20" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.20" }
  }
}

variable "project_id" {
  type = string
}
variable "region" {
  type    = string
  default = "asia-south1"
}
variable "environment" {
  type    = string
  default = "dev"
}
variable "bucket_name" {
  type    = string
  default = "monitoring-mlops-gcp"
}
variable "domain" {
  type    = string
  default = "aiops.example.com"
}
variable "network" {
  type    = string
  default = "default"
}

provider "google" {
  project = var.project_id
  region  = var.region
}
provider "google-beta" {
  project = var.project_id
  region  = var.region
}

locals {
  prefix = "monitoring-mlops-${var.environment}"
  labels = {
    project     = "monitoring-mlops-gcp"
    owner       = "team"
    environment = var.environment
    managed-by  = "terraform"
  }
  apis = [
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "containerscanning.googleapis.com",
    "dataflow.googleapis.com",
    "eventarc.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "securitycenter.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.key
  disable_on_destroy = false
}

module "identity" {
  source     = "./modules/identity"
  project_id = var.project_id
  labels     = local.labels
  depends_on = [google_project_service.apis]
}

module "registry" {
  source = "./modules/registry"
  region = var.region
  labels = local.labels
  depends_on = [google_project_service.apis]
}

module "datalake" {
  source      = "./modules/datalake"
  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  bucket_name = var.bucket_name
  labels      = local.labels
  depends_on  = [google_project_service.apis]
}

module "streaming" {
  source          = "./modules/streaming"
  project_id      = var.project_id
  region          = var.region
  environment     = var.environment
  prefix          = local.prefix
  bucket_name     = module.datalake.bucket_name
  service_account = module.identity.email
  labels          = local.labels
  depends_on      = [google_project_service.apis]
}

module "database" {
  source     = "./modules/database"
  project_id = var.project_id
  region     = var.region
  prefix     = local.prefix
  labels     = local.labels
  network    = var.network
  depends_on = [google_project_service.apis]
}

module "gke" {
  source     = "./modules/gke"
  project_id = var.project_id
  region     = var.region
  prefix     = local.prefix
  labels     = local.labels
  runner_sa  = module.identity.name
  depends_on = [google_project_service.apis]
}

module "lb" {
  source = "./modules/lb"
  labels = local.labels
  depends_on = [google_project_service.apis]
}

module "vertex" {
  source      = "./modules/vertex"
  region      = var.region
  environment = var.environment
  labels      = local.labels
  depends_on  = [google_project_service.apis]
}

module "monitoring" {
  source        = "./modules/monitoring"
  region        = var.region
  prefix        = local.prefix
  labels        = local.labels
  retrain_topic = module.streaming.retrain_topic
  depends_on    = [google_project_service.apis]
}

module "grafana" {
  source = "./modules/grafana"
  prefix = local.prefix
  labels = local.labels
  depends_on = [google_project_service.apis]
}

# ── Outputs ────────────────────────────────────────────────────────────────
output "bucket"            { value = module.datalake.bucket_name }
output "bigquery_dataset"  { value = module.datalake.dataset_id }
output "artifact_registry" { value = module.registry.name }
output "service_account"   { value = module.identity.email }
output "gke_cluster_name"  { value = module.gke.cluster_name }
output "events_topic"      { value = module.streaming.events_topic }
output "anomalies_topic"   { value = module.streaming.anomalies_topic }
output "retrain_topic"     { value = module.streaming.retrain_topic }
output "anomalies_sub"     { value = module.streaming.anomalies_sub }
output "armor_policy"      { value = module.lb.armor_policy }
output "api_static_ip"     { value = module.lb.api_static_ip }
output "ui_static_ip"      { value = module.lb.ui_static_ip }
output "sql_connection"    { value = module.database.connection_name }
output "vertex_endpoints"  { value = module.vertex.endpoint_ids }
