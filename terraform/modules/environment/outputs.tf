output "cluster_name" { value = var.cluster_name }
output "namespace" { value = kubernetes_namespace.this.metadata[0].name }
output "deployer_service_account" { value = kubernetes_service_account.deployer.metadata[0].name }
output "deployer_token_secret" { value = kubernetes_secret.deployer_token.metadata[0].name }
