# Security

*Assessment requirement: "Security best practices should be implemented
throughout the pipeline to safeguard code integrity and deployment
environments."*

Each control below is verifiable by running the command shown.

---

## 1. CI holds no cluster-admin

Every kubeconfig authenticates as a namespaced ServiceAccount bound to a
`Role` — never a `ClusterRole`.

```bash
kubectl --context kind-staging auth can-i --list -n demo \
  --as=system:serviceaccount:demo:jenkins-deployer
```
deployments.apps    [get list watch create update patch]
replicasets.apps    [get list watch]
services            [get list create update patch]
pods, pods/log      [get list watch]
events              [get list]
pods/portforward    [create]
Six rules. Every verb maps to an operation the pipeline actually performs:

| Verb | Used by |
|---|---|
| `patch deployments` | Applying a new image |
| `watch deployments` | `kubectl rollout status` opens a watch stream |
| `get replicasets` | `rollout undo` resolves the previous revision |
| `get pods/log` | Failure diagnostics |
| `create pods/portforward` | Smoke test reaching the Service |

And what is **refused**:

| Refused | Why it matters |
|---|---|
| `create pods` | Would let CI schedule arbitrary workloads |
| `delete deployments` | Deploying never requires deleting |
| `get secrets` | No reason to read them |
| anything in `kube-system` | The namespaced Role is a hard boundary |

> The discovery URLs and `selfsubject*` verbs that also appear in `can-i --list`
> are not granted here — they come from the `system:discovery` and
> `system:basic-user` ClusterRoles Kubernetes binds to `system:authenticated` by
> default. They permit asking "what may I do?" and reading API discovery
> documents; they grant no access to workloads or data.

---

## 2. Secrets never enter Groovy

Jenkins warns:

> A secret was passed to "withEnv" using Groovy String interpolation, which is
> insecure.

The library therefore exports the credential inside the shell script and lets
the **shell** dereference it:

```groovy
export KUBECONFIG="$KUBECONFIG_FILE"   // shell expands; Groovy never sees it
```

The kubeconfig is a Jenkins file credential, injected at boot from an
environment variable. `casc.yaml` — which is committed — contains
`secretBytes: "${KUBECONFIG_STAGING_B64}"`, a reference. No secret value exists
in any repository.

```bash
git grep -E "eyJhbGciOiJSUzI1NiI|BEGIN RSA PRIVATE KEY" HEAD   # expect: nothing
```

---

## 3. Container hardening

Both services run identically hardened:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  seccompProfile: { type: RuntimeDefault }
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
```

Verified, not asserted:

```bash
docker run --rm sample-app:latest id
# uid=10001(appuser) gid=10001(appuser)
```

The application's own ServiceAccount sets `automountServiceAccountToken: false`.
It never talks to the Kubernetes API, so it holds no credential to steal.

---

## 4. Supply chain

- **Trivy scans every image** before it can be pushed, at HIGH/CRITICAL.
- **Immutable tags**: `<branch>-<build>-<sha>`. A running pod is traceable to
  the exact source that produced it; no tag is ever overwritten.
- **Pinned base images and tools** — `python:3.12-slim`, `node:22-slim`,
  `jenkins/jenkins:lts-jdk17`, `trivy 0.72.0`, `kubectl v1.33.1`. A floating
  `:latest` in a controller means CI can change overnight without a commit.

`failOnFindings: false` is a deliberate, documented policy: base images carry
unfixed CVEs, and a demo that fails unpredictably teaches nothing. The switch
exists so a real team flips it to `true` on a maintained base image with an
exception process. **Observed:** `node:22-slim` reported 3 HIGH; the build was
marked UNSTABLE and continued, exactly as configured, while `python:3.12-slim`
scanned clean.

---

## 5. Change control

- Production requires explicit human approval, with a 15-minute timeout.
  Silence is refusal, and this is observed behaviour, not theory.
- The gate is a **control, not a safety net** — the evidence a release is safe
  comes from tests, scan, and staging verification of the identical artifact.
- All infrastructure is code: `terraform plan` reports no changes, meaning the
  RBAC and quotas running are the ones reviewed in Git.
- Resource quotas per namespace prevent a runaway pipeline from exhausting a
  cluster.

---

## 6. Known constraints

| Here | Why | Production |
|---|---|---|
| Docker socket mounted into Jenkins | Avoids `--privileged` that DinD requires | Kaniko or rootless BuildKit on ephemeral agents — socket access is effectively host root |
| Long-lived SA token | kind has no cloud IAM to federate with | Workload Identity / OIDC — short-lived, auto-rotated |
| Jenkins local auth, admin/admin | Demo only | SSO, RBAC, approval restricted to a release group |
| Grafana admin/admin | Demo only | SSO, viewer by default |
| No image signing | Scope | Cosign + admission policy refusing unsigned images |
| No NetworkPolicy | Scope | Default-deny egress; explicit allow to the registry and API server |

The socket mount deserves emphasis: it is the single largest compromise here.
Anything that can talk to the Docker socket can start a privileged container and
own the host. It is acceptable on an isolated workstation and unacceptable on a
shared build farm.
