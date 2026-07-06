###############################################################################
# lb — Cloud Armor policy + static IP for the AIOps API + UI.
###############################################################################

variable "labels" { type = map(string) }

resource "google_compute_security_policy" "armor" {
  name = "aiops-scoring-armor"

  rule {
    action   = "allow"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    description = "Default allow (placeholder — restrict in prod)"
  }

  rule {
    action   = "rate_based_ban"
    priority = 500
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }
      ban_duration_sec = 300
    }
    description = "DDoS rate-limit: 600 req/min/IP"
  }

  rule {
    action   = "deny(403)"
    priority = 600
    match {
      expr { expression = "evaluatePreconfiguredExpr('sqli-v33-stable')" }
    }
    description = "Cloud Armor SQLi WAF"
  }

  rule {
    action   = "deny(403)"
    priority = 601
    match {
      expr { expression = "evaluatePreconfiguredExpr('xss-v33-stable')" }
    }
    description = "Cloud Armor XSS WAF"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default rule"
  }
}

resource "google_compute_global_address" "api_ip" { name = "aiops-scoring-ip" }
resource "google_compute_global_address" "ui_ip"  { name = "aiops-ui-ip" }

output "armor_policy"  { value = google_compute_security_policy.armor.name }
output "api_static_ip" { value = google_compute_global_address.api_ip.address }
output "ui_static_ip"  { value = google_compute_global_address.ui_ip.address }
