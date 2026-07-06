terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 5.20" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.20" }
    random      = { source = "hashicorp/random",      version = "~> 3.6" }
  }
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
  prefix = "monitoring-mlops-${var.environment}-demo"
  labels = {
    project     = "monitoring-mlops-gcp"
    owner       = "team"
    environment = var.environment
    component   = "demo-app"
    managed-by  = "terraform"
  }
  main_prefix = "monitoring-mlops-${var.environment}"
}

# ─── Cloud SQL MySQL (equivalent to RDS MySQL) ──────────────────────────────
resource "random_password" "mysql" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_secret_manager_secret" "mysql_pass" {
  secret_id = "${local.prefix}-mysql-pass"
  labels    = local.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "mysql_pass" {
  secret      = google_secret_manager_secret.mysql_pass.id
  secret_data = random_password.mysql.result
}

# Secret storing the full connection details JSON (equivalent to AWS secretsmanager_secret_version)
resource "google_secret_manager_secret" "mysql_secret" {
  secret_id = "${local.prefix}-mysql-conn"
  labels    = local.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "mysql_secret" {
  secret = google_secret_manager_secret.mysql_secret.id
  secret_data = jsonencode({
    username = "demo"
    password = random_password.mysql.result
    engine   = "mysql"
    host     = google_sql_database_instance.demo.private_ip_address
    port     = 3306
    dbname   = "demoapp"
  })
}

# PSA peering must already exist before the private-IP Cloud SQL instance can
# attach. The parent platform Terraform (../../infra) creates this peering on
# the `default` network. Apply parent infra first; this data lookup will fail
# loudly if the connection is missing.
data "google_compute_network" "default" {
  name = var.network
}

resource "google_sql_database_instance" "demo" {
  name             = "${local.prefix}-mysql"
  database_version = "MYSQL_8_0"
  region           = var.region

  depends_on = [data.google_compute_network.default]

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = 20
    user_labels       = local.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.project_id}/global/networks/${var.network}"
    }

    # Enable slow query logging
    database_flags {
      name  = "slow_query_log"
      value = "on"
    }
    database_flags {
      name  = "long_query_time"
      value = "0.5"
    }
    database_flags {
      name  = "log_output"
      value = "FILE"
    }
  }
  deletion_protection = false
}

resource "google_sql_user" "demo" {
  name     = "demo"
  instance = google_sql_database_instance.demo.name
  password = random_password.mysql.result
}

resource "google_sql_database" "demo" {
  name     = "demoapp"
  instance = google_sql_database_instance.demo.name
}

# ─── Cloud Logging Sink for SQL slow query logs to Pub/Sub events ────────────
resource "google_logging_project_sink" "mysql_slow_sink" {
  name        = "${local.prefix}-mysql-slow-sink"
  destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${local.main_prefix}-events"
  filter      = "resource.type=\"cloudsql_database\" AND logName=\"projects/${var.project_id}/logs/cloudsql.googleapis.com%2Fmysql-slow.log\""
  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "mysql_slow_sink_publisher" {
  topic  = "projects/${var.project_id}/topics/${local.main_prefix}-events"
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.mysql_slow_sink.writer_identity
}

# ─── GCP Memorystore for Redis (equivalent to AWS ElastiCache Redis) ─────────
resource "google_redis_instance" "redis" {
  name               = "${local.prefix}-redis"
  tier               = "BASIC"
  memory_size_gb     = 1
  region             = var.region
  authorized_network = "projects/${var.project_id}/global/networks/${var.network}"
  connect_mode       = "DIRECT_PEERING"
  redis_version      = "REDIS_7_0"
  labels             = local.labels
}

# ─── Static external IP for the Demo Ingress ───────────────────────────────
resource "google_compute_global_address" "demo_ip" {
  name = "demo-app-ip"
}

# ─── Workload Identity GSAs for api / worker ────────────────────────────────
# Each KSA in the `default` namespace binds to a GSA. Bind in helm values via
# annotation `iam.gke.io/gcp-service-account`.
resource "google_service_account" "demo_api" {
  account_id   = "mlops-${var.environment}-demo-api"
  display_name = "demo-app api"
}

resource "google_service_account" "demo_worker" {
  account_id   = "mlops-${var.environment}-demo-worker"
  display_name = "demo-app worker"
}

# api needs Cloud SQL client + Secret Accessor on the mysql secret.
resource "google_project_iam_member" "demo_api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.demo_api.email}"
}

resource "google_secret_manager_secret_iam_member" "demo_api_secret" {
  secret_id = google_secret_manager_secret.mysql_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.demo_api.email}"
}

resource "google_secret_manager_secret_iam_member" "demo_api_pass" {
  secret_id = google_secret_manager_secret.mysql_pass.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.demo_api.email}"
}

# Workload Identity bindings: KSA(default/demo-api) -> GSA(demo_api)
resource "google_service_account_iam_member" "demo_api_wi" {
  service_account_id = google_service_account.demo_api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/demo-api]"
}

resource "google_service_account_iam_member" "demo_worker_wi" {
  service_account_id = google_service_account.demo_worker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/demo-worker]"
}
