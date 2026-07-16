# cicd-pipeline-platform

**[▶ Watch the walkthrough](https://youtu.be/8HLydMg_BCg)** — 9 minutes, recorded from live output.

Everything required to reproduce the delivery platform this case study runs on:
two Kubernetes clusters, a shared registry, a Jenkins controller configured as
code, least-privilege RBAC provisioned with Terraform, and a Prometheus/Grafana
monitoring stack.

Application code lives elsewhere — this repository builds the ground it runs on.

| Directory     | Contents |
|---------------|----------|
| `infra/`      | `bootstrap-clusters.sh` — creates the kind clusters and shared registry |
| `jenkins/`    | Controller image, plugin manifest, JCasC config, job definitions, kubeconfig minting |
| `terraform/`  | Platform layer: namespaces, quotas, limit ranges, least-privilege RBAC. Plus a validated GKE module showing cloud portability |
| `monitoring/` | Prometheus (annotation-based discovery + alert rules) and Grafana (provisioned dashboard) |

## Scope boundary

Terraform owns the **platform** layer — slow-moving, reviewed, rarely changed.
Jenkins owns the **application** layer — Deployments and Services, per commit.
The split follows lifecycle rather than tooling preference: placing Deployments
in Terraform would force `terraform apply` on every commit and put Terraform in
conflict with the pipeline over image tags.

Full setup instructions: [`docs/setup.md`](docs/setup.md).
