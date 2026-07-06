###############################################################################
# database — Cloud SQL Postgres for analyst metadata + PSA peering.
###############################################################################

variable "project_id"  { type = string }
variable "region"      { type = string }
variable "prefix"      { type = string }
variable "labels"      { type = map(string) }
variable "network"     { type = string }

resource "google_compute_global_address" "psa" {
  name          = "${var.prefix}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = var.network
}

resource "google_service_networking_connection" "psa" {
  network                 = "projects/${var.project_id}/global/networks/${var.network}"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

resource "google_sql_database_instance" "pg" {
  name             = "${var.prefix}-pg"
  database_version = "POSTGRES_15"
  region           = var.region
  depends_on       = [google_service_networking_connection.psa]

  settings {
    tier              = "db-custom-1-3840"
    availability_type = "ZONAL"
    disk_size         = 20
    user_labels       = var.labels
    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.project_id}/global/networks/${var.network}"
    }
  }
  deletion_protection = false
}

output "connection_name" { value = google_sql_database_instance.pg.connection_name }
output "private_ip"      { value = google_sql_database_instance.pg.private_ip_address }
