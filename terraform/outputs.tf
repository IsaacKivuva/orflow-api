output "staging_namespace" {
  description = "Name of the provisioned staging namespace"
  value       = kubernetes_namespace.staging.metadata[0].name
}

output "production_namespace" {
  description = "Name of the provisioned production namespace"
  value       = kubernetes_namespace.production.metadata[0].name
}

output "staging_quota_pods" {
  description = "Maximum pods allowed in the staging namespace"
  value       = kubernetes_resource_quota.staging.spec[0].hard["pods"]
}

output "production_quota_pods" {
  description = "Maximum pods allowed in the production namespace"
  value       = kubernetes_resource_quota.production.spec[0].hard["pods"]
}