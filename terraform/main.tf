# Platform layer for the delivery pipeline.
#
# Scope boundary — deliberate:
#   Terraform owns  : namespaces, RBAC, quotas, limit ranges  (slow-moving, reviewed)
#   Jenkins owns    : Deployments, Services                    (per-commit, pipeline-driven)
#
# Placing Deployments here would force `terraform apply` on every commit and put
# Terraform in conflict with the pipeline over image tags. The split follows
# lifecycle, not tooling preference.

provider "kubernetes" {
  alias          = "staging"
  config_path    = var.kubeconfig_path
  config_context = var.clusters["staging"].context
}

provider "kubernetes" {
  alias          = "prod"
  config_path    = var.kubeconfig_path
  config_context = var.clusters["prod"].context
}

module "staging" {
  source = "./modules/environment"
  providers = {
    kubernetes = kubernetes.staging
  }
  environment  = "staging"
  cluster_name = var.clusters["staging"].context
  namespace    = var.clusters["staging"].namespace
  cpu_quota    = var.clusters["staging"].cpu_quota
  mem_quota    = var.clusters["staging"].mem_quota
}

module "prod" {
  source = "./modules/environment"
  providers = {
    kubernetes = kubernetes.prod
  }
  environment  = "prod"
  cluster_name = var.clusters["prod"].context
  namespace    = var.clusters["prod"].namespace
  cpu_quota    = var.clusters["prod"].cpu_quota
  mem_quota    = var.clusters["prod"].mem_quota
}
