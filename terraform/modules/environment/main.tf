terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

# Guardrail: a runaway pipeline cannot exhaust the cluster.
resource "kubernetes_resource_quota" "this" {
  metadata {
    name      = "compute-quota"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = var.cpu_quota
      "requests.memory" = var.mem_quota
      "limits.cpu"      = var.cpu_quota
      "limits.memory"   = var.mem_quota
      "pods"            = "20"
    }
  }
}

# Defaults so a workload that forgets to declare resources still cannot run unbounded.
resource "kubernetes_limit_range" "this" {
  metadata {
    name      = "default-limits"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "250m"
        memory = "192Mi"
      }
      default_request = {
        cpu    = "25m"
        memory = "64Mi"
      }
    }
  }
}

resource "kubernetes_service_account" "deployer" {
  metadata {
    name      = "jenkins-deployer"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

# Least privilege, as code. Namespaced Role — never a ClusterRole. Every verb
# here is required by an actual pipeline operation; nothing is speculative.
resource "kubernetes_role" "deployer" {
  metadata {
    name      = "jenkins-deployer"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"] # watch: rollout status
  }
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"] # rollout undo reads these
  }
  rule {
    api_groups = [""]
    resources  = ["services", "serviceaccounts"]
    verbs      = ["get", "list", "create", "update", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"] # failure diagnostics
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"] # smoke test only; NOT `create pods`
  }
}

resource "kubernetes_role_binding" "deployer" {
  metadata {
    name      = "jenkins-deployer"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.deployer.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.deployer.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_secret" "deployer_token" {
  metadata {
    name      = "jenkins-deployer-token"
    namespace = kubernetes_namespace.this.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.deployer.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
