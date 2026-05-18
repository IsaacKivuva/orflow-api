variable "staging_namespace" {
  description = "Name of the Kubernetes namespace for the staging environment"
  type        = string
  default     = "orflow-staging"
}

variable "production_namespace" {
  description = "Name of the Kubernetes namespace for the production environment"
  type        = string
  default     = "orflow-production"
}