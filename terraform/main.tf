terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider — point at Minikube's kubeconfig
# -----------------------------------------------------------------------------
provider "kubernetes" {
  # Reads your local ~/.kube/config automatically.
  # Make sure `minikube start` has been run before `terraform apply`.
  config_path    = "~/.kube/config"
  config_context = "minikube"
}

# -----------------------------------------------------------------------------
# Staging namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "staging" {
  metadata {
    name = var.staging_namespace

    # Labels let kubectl and other tooling filter by environment
    labels = {
      environment = "staging"
      managed-by  = "terraform"
      project     = "orflow-api"
    }

    annotations = {
      description = "OrFlow API staging environment — automated deploys, smoke tested"
    }
  }
}

# -----------------------------------------------------------------------------
# Production namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "production" {
  metadata {
    name = var.production_namespace

    labels = {
      environment = "production"
      managed-by  = "terraform"
      project     = "orflow-api"
    }

    annotations = {
      description = "OrFlow API production environment — approval-gated deploys only"
    }
  }
}

# -----------------------------------------------------------------------------
# Resource quotas
# -----------------------------------------------------------------------------
# Quotas enforce isolation: a runaway staging deployment cannot consume
# resources that production needs. This is a production-grade pattern
# even at small scale.

resource "kubernetes_resource_quota" "staging" {
  metadata {
    name      = "orflow-staging-quota"
    namespace = kubernetes_namespace.staging.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = "500m"
      "requests.memory" = "256Mi"
      "limits.cpu"      = "1"
      "limits.memory"   = "512Mi"
      "pods"            = "5"
    }
  }
}

resource "kubernetes_resource_quota" "production" {
  metadata {
    name      = "orflow-production-quota"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = "1"
      "requests.memory" = "512Mi"
      "limits.cpu"      = "2"
      "limits.memory"   = "1Gi"
      "pods"            = "10"
    }
  }
}