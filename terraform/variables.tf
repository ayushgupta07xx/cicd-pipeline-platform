variable "clusters" {
  description = "Target clusters keyed by environment name. Adding an environment is an entry here — no module or resource changes."
  type = map(object({
    context   = string
    namespace = string
    cpu_quota = string
    mem_quota = string
  }))
  default = {
    staging = {
      context   = "kind-staging"
      namespace = "demo"
      cpu_quota = "4"
      mem_quota = "4Gi"
    }
    prod = {
      context   = "kind-prod"
      namespace = "demo"
      cpu_quota = "4"
      mem_quota = "4Gi"
    }
  }
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig holding the cluster contexts."
  type        = string
  default     = "~/.kube/config"
}
