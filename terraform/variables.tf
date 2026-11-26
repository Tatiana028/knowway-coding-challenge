variable "postgres_image" {
  description = "Docker image for Postgres"
  type        = string
  default     = "postgres:18.7-trixie"
}

variable "db_password" {
  description = "Database password"
  type        = string
  default     = "app"
  sensitive   = true
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "runs"
}

variable "proxy_external_port" {
  description = "Host port the proxy listens on"
  type        = number
  default     = 8080
}
