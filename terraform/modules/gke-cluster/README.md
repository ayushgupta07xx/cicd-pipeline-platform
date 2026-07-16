# gke-cluster

Provisions a GKE cluster suitable for hosting the delivery pipeline's target
environments, as a cloud-portable equivalent of the local `kind` clusters.

**This module is not applied in the submitted demonstration.** No GCP project or
billing account is attached, so it is provided validated (`terraform validate`)
rather than applied. It exists to show the platform design does not depend on
`kind`: the `environment` module — namespaces, quotas, least-privilege RBAC —
applies unchanged against the cluster this module creates.

## What changes when moving to GCP

| Local (kind)                      | GKE                                                |
|-----------------------------------|----------------------------------------------------|
| kubeconfig with a long-lived SA token | Workload Identity — short-lived, auto-rotated  |
| Local registry on `localhost:5001`   | Artifact Registry, with IAM-scoped pull access  |
| Single node, no autoscaling          | Node pool with autoscaling and surge upgrades   |
| No network policy                    | Private nodes, authorized networks, NetworkPolicy |

The delivery pipeline itself is unaffected: `deploy-config.yaml` names a
`credentialId` and a `cluster`, and neither the shared library nor the
application repositories know or care which infrastructure sits behind them.

## Usage

```hcl
module "gke" {
  source       = "./modules/gke-cluster"
  project_id   = "my-project"
  region       = "asia-south1"
  cluster_name = "delivery-staging"
}
```
