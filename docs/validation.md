# Test cases and validation procedures

*Assessment deliverable (optional): "Test cases and validation procedures to
ensure the correctness and reliability of the automation solution."*

The pipeline is itself software, and its failure modes are more expensive than
the applications it deploys: a broken pipeline either blocks every team or, far
worse, ships something broken while reporting success.

---

## 1. Verification layers

| Layer | Catches | Cost when it fires |
|---|---|---|
| Config validation | Malformed `deploy-config.yaml` | Seconds — before any work |
| Unit tests | Logic defects | ~30s — before an image exists |
| Image scan | Known CVEs in the artifact | ~10s — before the image is pushed |
| Rollout verification | Defects that only appear in a cluster | ~2min — auto-rolled back |
| Smoke test | Service starts but does not answer | ~10s — auto-rolled back |
| Approval gate | Unintended promotion | Human decision |

---

## 2. Application test cases

### sample-app (Python / pytest)

| Test | Asserts |
|---|---|
| `test_health_ok` | `/health` returns 200 and `{"status":"ok"}` |
| `test_ready_ok` | `/ready` returns 200 |
| `test_build_info_shape` | `/api/build-info` exposes every build and runtime key the UI and dashboards depend on |
| `test_index_renders` | The receipt page renders |
| `test_metrics_endpoint_exposes_prometheus_format` | `/metrics` serves exposition format including `app_build_info` |

### orders-api (Node / node:test)

| Test | Asserts |
|---|---|
| `health returns ok` | `/health` returns 200 |
| `ready returns ready` | `/ready` returns 200 |
| `build-info exposes artifact and runtime identity` | Contract shape holds |
| `metrics endpoint exposes prometheus exposition format` | `app_build_info` present |
| `orders endpoint returns a list` | Business endpoint responds |

Run locally in the exact image the pipeline uses:

```bash
docker run --rm -v "$(pwd)":/w -w /w python:3.12-slim \
  sh -c 'pip install -q -r requirements.txt pytest && python -m pytest -q'

docker run --rm -v "$(pwd)":/w -w /w node:22-slim \
  sh -c 'npm install --no-audit --no-fund && npm test'
```

Testing in the pipeline's own image removes the "works on my machine" gap.

---

## 3. Pipeline validation procedures

### P1 — Config validation rejects malformed input

Remove a required key from `deploy-config.yaml` and push.

**Expected:** build fails at *Load config* with
`Invalid deploy-config.yaml: - app.name is required`. No image is built.
**Proves:** errors surface precisely, before expensive work.

### P2 — Branch filtering prevents unintended deploys

```bash
git checkout -b feature/experiment && git push -u origin feature/experiment
```

**Expected:** build and test run; *Push image* and *Deploy* report
`NOT_EXECUTED`; log states `targets for branch 'feature/experiment': none`.
**Proves:** deployment targets are governed by declared policy.

### P3 — Unit tests block a broken artifact

**Expected:** *Test* fails; *Build image* onward skipped.
**Observed (builds #10, #12):** a readiness fault was caught by `test_ready_ok`
before any image existed.

### P4 — Rollout verification catches environment-only defects

Some defects depend on configuration injected at deploy time:

```python
if os.getenv("APP_ENV"):        # set only in-cluster
    return jsonify(status="not-ready"), 503
return jsonify(status="ready"), 200
```

**Expected:** tests pass, image builds and pushes, staging rollout stalls,
`rollout status` exits non-zero, diagnostics print, deployment reverts
automatically, build fails, production never reached.

**Observed (build #11):**
Rollout FAILED (exit 1) — collecting diagnostics
--- pods ---
sample-app-67b654cf7f-985nn   0/1   Running   2m20s
--- recent events ---
Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 503
Rolling back sample-app in staging to previous revision
Rollback complete — previous version restored
### P5 — Zero downtime through a failed deploy

```bash
kubectl --context kind-staging -n demo get pods -l app.kubernetes.io/name=sample-app
```

**Observed during P4:**
sample-app-67b654cf7f-985nn   0/1   Running   50s   ← new build, never Ready
sample-app-78499767c7-tpvhm   1/1   Running   12m   ← still serving
sample-app-78499767c7-v7r6q   1/1   Running   12m   ← still serving
**Proves:** `maxUnavailable: 0` — a broken build cannot displace a working one.

### P6 — Smoke test catches a started-but-broken service

**Proves:** *Ready* and *working* are different claims. A green rollout only
means containers started.

### P7 — Approval gate governs production

**Expected:** *Deploy → prod* holds at `PAUSED_PENDING_INPUT`; after
`timeoutMinutes: 15` the stage aborts.
**Observed (build #14):** staging advanced to build 14; production stayed on
build 13 because no approval was given in the window. Silence is refusal.

### P8 — Least privilege is real

```bash
kubectl --context kind-staging auth can-i --list -n demo \
  --as=system:serviceaccount:demo:jenkins-deployer

for CHECK in "create pods --subresource=portforward" "create pods" \
             "delete deployments" "get secrets"; do
  printf "  %-38s " "$CHECK"
  kubectl --context kind-staging auth can-i $CHECK -n demo \
    --as=system:serviceaccount:demo:jenkins-deployer
done
```

**Expected:** portforward yes; everything else no.

> **A note on the checker.** `kubectl auth can-i create pods/portforward`
> returns **no** even when granted — subresources require
> `--subresource=portforward`, and a malformed query silently answers about a
> resource that does not exist. A false negative when auditing permissions
> invites someone to "fix" something that was never broken. Verify the checker,
> not just the answer.

### P9 — Infrastructure matches its code

```bash
cd terraform && terraform plan
```

**Expected:** `No changes. Your infrastructure matches the configuration.`

### P10 — Monitoring discovers services without configuration

```bash
curl -s 'http://localhost:9090/api/v1/targets?state=active' | \
  jq -r '.data.activeTargets[] | "\(.labels.service // .labels.instance) → \(.health)"'
```

**Expected:** a newly deployed annotated service appears within one scrape
interval, with no Prometheus config change.

---

## 4. Regression checklist

Before changing the shared library, both services must pass end to end. Two
languages exercising one library is the regression suite for the library itself
— a change that only works for Python is caught immediately.

---

## 5. Library unit tests

`DeployConfig` receives the `CpsScript` object by constructor rather than
reaching for it globally, so it is testable with a stub and no Jenkins:

```bash
cd cicd-pipeline-shared-library
./test/run-tests.sh
```

12 tests covering config parsing, fail-fast validation, branch filtering, image
tag generation and security defaults. Two are regression tests for defects this
project actually hit:

| Test | Guards against |
|---|---|
| `test.image required when test.commands present` | The library once hardcoded a Python image, silently running `npm test` inside `python:3.12-slim` |
| `imageRef sanitises branch names into valid docker tags` | A branch named `feature/x` yields an invalid Docker tag and fails at push |

They run in a pinned container, so no local Groovy toolchain is needed and the
result does not depend on the machine.

## 6. Known gaps
- **`Deployer` is not unit tested.** Unlike `DeployConfig`, it is mostly shell
  orchestration, and testing it in isolation would mean asserting on generated
  command strings — which tests the assertion, not the behaviour. It is covered
  end-to-end instead: procedures P4–P6 exercise every path including rollback.
- **The smoke test checks status codes, not correctness.** It proves the service
  answers, not that the answer is right. Contract testing belongs in the
  application's own suite.
- **No load or soak testing.** Out of scope for a delivery-pipeline case study,
  though a real promotion gate might require a performance baseline.
