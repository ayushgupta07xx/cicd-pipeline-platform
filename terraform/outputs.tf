output "environments" {
  description = "Provisioned environments and the least-privilege identity Jenkins uses in each."
  value = {
    staging = {
      cluster      = module.staging.cluster_name
      namespace    = module.staging.namespace
      deployer_sa  = module.staging.deployer_service_account
      token_secret = module.staging.deployer_token_secret
    }
    prod = {
      cluster      = module.prod.cluster_name
      namespace    = module.prod.namespace
      deployer_sa  = module.prod.deployer_service_account
      token_secret = module.prod.deployer_token_secret
    }
  }
}
