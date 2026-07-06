variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region to deploy resource in"
  type        = string
  default     = "asia-south1"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "network" {
  description = "The VPC network to attach Cloud SQL and Redis to"
  type        = string
  default     = "default"
}
