# Onboarding a repository or a cluster

The assessment asks for a solution *"scalable and adaptable to accommodate
different Git repositories and Kubernetes clusters."*

Neither operation touches pipeline code. This document is the proof of that
claim, and the procedure for doing it.

---

## Onboarding a new Git repository

A repository contributes **two files**. Everything else — build, test, scan,
push, deploy, verify, roll back — comes from the shared library.

### 1. `Jenkinsfile`

```groovy
@Library('finacplus-cicd@main') _

deliveryPipeline()
```

Three lines, identical in every repository. No stages, no credentials, no
cluster names, nothing to drift out of date.

### 2. `deploy-config.yaml`

```yaml
schemaVersion: 1

app:
  name: my-service              # also the Deployment/Service name
  version: "1.0.0"
  imageRepo: finacplus/my-service
  port: 8080

registry:
  host: localhost:5001

build:
  context: .
  dockerfile: Dockerfile

test:
  image: "python:3.12-slim"     # REQUIRED — the library assumes no runtime
  setup: "pip install -q -r requirements.txt pytest"
  commands:
    - "python -m pytest -q"

security:
  trivy:
    enabled: true
    severity: "HIGH,CRITICAL"
    ignoreUnfixed: true
    failOnFindings: false       # true blocks the build on findings

manifests:
  path: k8s
  files:
    - deployment.yaml

environments:
  - name: staging
    cluster: kind-staging
    namespace: demo
    replicas: 2
    credentialId: kubeconfig-staging
    branches: ["main"]          # [] means build+test only, never deploy
    autoDeploy: true
    smokeTest:
      path: /health
      expectStatus: 200

  - name: prod
    cluster: kind-prod
    namespace: demo
    replicas: 2
    credentialId: kubeconfig-prod
    branches: ["main"]
    autoDeploy: false
    approval:
      required: true
      timeoutMinutes: 15
    smokeTest:
      path: /health
      expectStatus: 200
```

### 3. Manifests

`k8s/deployment.yaml`, templated with `${VAR}` placeholders the library
substitutes at deploy time:

| Variable | Source | Meaning |
|---|---|---|
| `APP_NAME`, `NAMESPACE`, `REPLICAS` | `deploy-config.yaml` | Identity and scale |
| `IMAGE` | Built by the pipeline | Immutable tag: `<branch>-<build>-<sha>` |
| `APP_ENV`, `CLUSTER_NAME` | The environment being deployed to | Injected at **deploy** time |
| `BUILD_NUMBER`, `GIT_COMMIT`, `APP_VERSION`, `BUILD_TIME` | The build | Baked at **image build** time |

The build/deploy split matters: build metadata describes the *artifact*,
runtime metadata describes *where it landed*. The same image runs in staging and
production; only the runtime variables differ.

For the service to appear in monitoring, annotate the pod template — no
Prometheus configuration change is required:

```yaml
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
```

### 4. Create the job

```bash
sed 's|cicd-pipeline-sample-app|cicd-pipeline-my-service|' \
  jenkins/job-sample-app.xml > jenkins/job-my-service.xml

J=http://localhost:8090
CRUMB=$(curl -s -c /tmp/jc -u admin:$PASS "$J/crumbIssuer/api/json" \
        | jq -r '.crumbRequestField + ":" + .crumb')
curl -s -b /tmp/jc -u admin:$PASS -H "$CRUMB" -H "Content-Type: application/xml" \
  --data-binary @jenkins/job-my-service.xml -X POST "$J/createItem?name=my-service"
```

### Worked example

`orders-api` was onboarded as a deliberate stress test of this claim: Node
instead of Python, port 3000 instead of 8080, one replica instead of two, a
different image repository, and a smoke test against `/api/orders` rather than
`/health`.

It required **zero changes to the shared library** — with one instructive
exception, recorded honestly. The Test stage originally hardcoded a Python image
and `pip install`. Onboarding a Node service exposed that the library was not
actually language-agnostic; the fix moved the test runtime into
`deploy-config.yaml` as `test.image` and `test.setup`. The claim was only true
after a genuinely different second service tested it, which is why the second
repository exists.

---

## Onboarding a new Kubernetes cluster

### 1. Provision the platform layer

Add the cluster to `terraform/variables.tf`:

```hcl
variable "clusters" {
  default = {
    # ... existing ...
    uat = {
      context   = "kind-uat"
      namespace = "demo"
      cpu_quota = "4"
      mem_quota = "4Gi"
    }
  }
}
```

Add a provider alias and a module block in `terraform/main.tf`:

```hcl
provider "kubernetes" {
  alias          = "uat"
  config_path    = var.kubeconfig_path
  config_context = var.clusters["uat"].context
}

module "uat" {
  source    = "./modules/environment"
  providers = { kubernetes = kubernetes.uat }

  environment  = "uat"
  cluster_name = var.clusters["uat"].context
  namespace    = var.clusters["uat"].namespace
  cpu_quota    = var.clusters["uat"].cpu_quota
  mem_quota    = var.clusters["uat"].mem_quota
}
```

```bash
terraform apply
```

This creates the namespace, quota, limit range, and the least-privilege
`jenkins-deployer` ServiceAccount with an identical Role. The RBAC is defined
once in the module, so a new cluster cannot accidentally receive broader
permissions than the others.

### 2. Mint a credential

```bash
./jenkins/gen-kubeconfig.sh uat demo secrets/kubeconfig-uat.yaml
```

### 3. Register it with Jenkins

Add to `casc.yaml` under `credentials`:

```yaml
          - file:
              scope: GLOBAL
              id: "kubeconfig-uat"
              description: "kubeconfig — SA jenkins-deployer, ns demo, cluster uat"
              fileName: "kubeconfig-uat.yaml"
              secretBytes: "${KUBECONFIG_UAT_B64}"
```

and pass it in `run-jenkins.sh`:

```bash
  -e KUBECONFIG_UAT_B64="$(base64 -w0 secrets/kubeconfig-uat.yaml)" \
```

### 4. Target it from any repository

```yaml
environments:
  - name: uat
    cluster: kind-uat
    namespace: demo
    replicas: 1
    credentialId: kubeconfig-uat
    branches: ["main", "release/*"]
    autoDeploy: true
    smokeTest:
      path: /health
      expectStatus: 200
```

Environments deploy in the order declared. Placing `uat` before `prod` makes it
a promotion stage; the same immutable image flows through each.

---

## What is verified, and how

| Claim | Evidence |
|---|---|
| Repository-agnostic | `sample-app` (Python/Flask) and `orders-api` (Node/Express) run the identical library |
| Cluster-agnostic | The same image is promoted to `kind-staging` and `kind-prod` from one build |
| No pipeline code per repo | Both Jenkinsfiles are three identical lines |
| RBAC identical per cluster | Defined once in the Terraform `environment` module |
| Config errors caught early | `DeployConfig.validate()` aborts with a precise message before any build work |
