output "mysql_ip" {
  description = "Private IP address of the MySQL Cloud SQL instance"
  value       = google_sql_database_instance.demo.private_ip_address
}

output "redis_ip" {
  description = "Host IP address of the Memorystore Redis instance"
  value       = google_redis_instance.redis.host
}

output "demo_ip" {
  description = "Global external static IP address for the demo-app ingress"
  value       = google_compute_global_address.demo_ip.address
}

output "mysql_secret_id" {
  description = "GCP Secret Manager secret ID containing database credentials JSON"
  value       = google_secret_manager_secret.mysql_secret.secret_id
}

output "mysql_pass_secret_id" {
  description = "GCP Secret Manager secret ID for the raw mysql password"
  value       = google_secret_manager_secret.mysql_pass.secret_id
}

output "demo_api_gsa" {
  description = "Email of the api GSA (annotate KSA default/demo-api with this)"
  value       = google_service_account.demo_api.email
}

output "demo_worker_gsa" {
  description = "Email of the worker GSA (annotate KSA default/demo-worker with this)"
  value       = google_service_account.demo_worker.email
}
