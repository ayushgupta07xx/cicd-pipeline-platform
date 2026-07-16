# Setup

Reproduces the entire delivery platform on a single machine: two Kubernetes
clusters, a shared registry, a Jenkins controller configured as code, and a
monitoring stack.

Every step is scripted. Nothing below requires clicking through a UI.

## Prerequisites

| Tool     | Version tested | Purpose |
|----------|----------------|---------|
| Docker   | 29.3+          | Runs the clusters, the registry, Jenkins, and builds |
| kubectl  | 1.34+          | Cluster access |
| kind     | 0.29+          | Local Kubernetes clusters |
| Terraform| 1.15+          | Platform layer (namespaces, quotas, RBAC) |
| git, jq, envsubst | any   | Scripting |

Roughly 4 GB of free RAM and 15 GB of disk. Verified on WSL2 (Ubuntu 22.04).

```bash
docker version --format '{{.Server.Version}}'
kubectl version --client -o json | jq -r .clientVersion.gitVersion
kind version && terraform version | head -1
```

## 1. Clusters and registry

```bash
git clone https://github.com/ayushgupta07xx/cicd-pipeline-platform.git
cd cicd-pipeline-platform
./infra/bootstrap-clusters.sh
```

This creates:

- a `registry:2` container on `127.0.0.1:5001`, shared by both clusters
- kind clusters `staging` and `prod`
- a containerd `hosts.toml` on each node mapping `localhost:5001` to the
  registry container over the `kind` Docker network

The script is idempotent — re-running it is safe.

**Why one registry for two clusters.** An image is built once per commit and
promoted unchanged. Rebuilding per environment would mean production runs an
artifact that nothing verified.

Verify:

```bash
kubectl --context kind-staging get nodes
kubectl --context kind-prod get nodes
curl -s http://localhost:5001/v2/_catalog
```

## 2. Platform layer (Terraform)

Namespaces, resource quotas, limit ranges, and the least-privilege RBAC that
Jenkins authenticates as.

```bash
cd terraform
terraform init
terraform apply
```

If the namespaces already exist (for example, created by an earlier `kubectl`
run), adopt them instead of recreating:

```bash
./import.sh
terraform plan     # expect: no changes
```

**Scope boundary.** Terraform owns the platform layer — slow-moving, reviewed.
Jenkins owns Deployments and Services — per commit, pipeline-driven. Putting
Deployments in Terraform would force `terraform apply` on every commit and put
Terraform in conflict with the pipeline over image tags.

Verify the identity Jenkins will use is genuinely constrained:

```bash
kubectl --context kind-staging auth can-i --list -n demo \
  --as=system:serviceaccount:demo:jenkins-deployer
```

## 3. Jenkins controller

The controller image bakes in `docker`, `kubectl`, `trivy` and `envsubst`, so it
is reproducible from the Dockerfile rather than assembled by hand.

```bash
cd ../jenkins
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
docker build --build-arg DOCKER_GID="${DOCKER_GID}" -t finacplus/jenkins:local .
```

`DOCKER_GID` is a build argument because the Docker socket's group differs per
host; hardcoding the common default (999) silently breaks the socket mount
elsewhere.

Mint a kubeconfig per cluster. Each authenticates as `jenkins-deployer` — the
namespaced ServiceAccount created by Terraform — never as a cluster admin:

```bash
mkdir -p secrets && chmod 700 secrets
./gen-kubeconfig.sh staging demo secrets/kubeconfig-staging.yaml
./gen-kubeconfig.sh prod    demo secrets/kubeconfig-prod.yaml
```

The generated kubeconfig points at `https://<cluster>-control-plane:6443`, not
`localhost` — Jenkins runs on the `kind` Docker network and reaches the API
server by container DNS. The cluster CA is embedded; TLS verification is not
skipped.

Start the controller:

```bash
export SHARED_LIB_REPO="https://github.com/ayushgupta07xx/cicd-pipeline-shared-library.git"
export JENKINS_ADMIN_PASSWORD="choose-something"   # demo only; see security.md
./run-jenkins.sh
```

Jenkins comes up on <http://localhost:8090> with no setup wizard, both
kubeconfig credentials already loaded, and the shared library registered. All of
it comes from `casc.yaml`; the file contains `${ENV}` references, never secret
values.

Verify:

```bash
docker logs jenkins 2>&1 | grep -c SEVERE          # expect 0
curl -s -u admin:$JENKINS_ADMIN_PASSWORD \
  "http://localhost:8090/manage/credentials/store/system/domain/_/api/json?depth=1" | \
  jq -r '.credentials[].id'                        # expect both kubeconfigs
```

## 4. Jobs

```bash
J=http://localhost:8090
CRUMB=$(curl -s -c /tmp/jc -u admin:$JENKINS_ADMIN_PASSWORD "$J/crumbIssuer/api/json" \
        | jq -r '.crumbRequestField + ":" + .crumb')
for JOB in sample-app orders-api; do
  curl -s -b /tmp/jc -u admin:$JENKINS_ADMIN_PASSWORD -H "$CRUMB" \
    -H "Content-Type: application/xml" --data-binary @job-${JOB}.xml \
    -X POST "$J/createItem?name=${JOB}"
done
```

Jenkins requires a CSRF crumb on every POST; requests without one return 403.

## 5. Monitoring

```bash
cd ../monitoring
export CLUSTER_NAME=kind-staging
export CONFIG_CHECKSUM=$(cat 02-prometheus-config.yaml 03-prometheus-rules.yaml | sha256sum | cut -c1-12)
export DASHBOARD_CHECKSUM=$(sha256sum dashboard-delivery.json | cut -c1-12)

kubectl --context kind-staging apply -f 01-namespace-rbac.yaml
envsubst < 02-prometheus-config.yaml | kubectl --context kind-staging apply -f -
kubectl --context kind-staging apply -f 03-prometheus-rules.yaml
envsubst < 04-prometheus.yaml | kubectl --context kind-staging apply -f -

kubectl --context kind-staging -n monitoring create configmap grafana-dashboards \
  --from-file=dashboard-delivery.json --dry-run=client -o yaml | \
  kubectl --context kind-staging apply -f -
kubectl --context kind-staging apply -f 05-grafana-provisioning.yaml
envsubst < 06-grafana.yaml | kubectl --context kind-staging apply -f -
```

Access:

```bash
kubectl --context kind-staging -n monitoring port-forward svc/grafana 3000:3000 &
kubectl --context kind-staging -n monitoring port-forward svc/prometheus 9090:9090 &
```

Grafana on <http://localhost:3000> (admin/admin) → **Delivery → Delivery &
Service Health**. The dashboard and datasource are provisioned from files, so
they survive a pod restart and are reviewable in Git.

## Teardown

```bash
docker rm -f jenkins kind-registry
kind delete cluster --name staging
kind delete cluster --name prod
docker volume rm jenkins_home
```
