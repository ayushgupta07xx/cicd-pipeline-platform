# Monitoring and logging strategy

*Assessment deliverable (optional): "Recommendations for monitoring and logging
strategies to track the performance and health of the CI/CD pipeline."*

This is implemented, not only recommended: Prometheus and Grafana run in the
staging cluster, both services are instrumented, and the dashboard is
provisioned from a file in Git.

---

## 1. Principle: monitoring onboarding is declaration, not configuration

The pipeline's design claim is that adding a service should not require editing
pipeline code. Observability follows the same rule.

Prometheus discovers targets from pod annotations:

```yaml
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
```

A service carrying those three lines is scraped from the moment it deploys. No
Prometheus reload, no scrape config change, no ticket to a platform team.

**Verified:** `orders-api` and `sample-app` were instrumented independently and
both appeared as active targets with zero monitoring configuration changes.

---

## 2. What is measured

### Build identity as a metric

The most valuable metric in the stack is not latency — it is which artifact is
serving:
app_build_info{service="sample-app", build_number="15", commit="2189b06",
            branch="main", version="1.0.0", environment="staging",
               cluster="kind-staging"} 1
This closes the loop between delivery and observability. A latency regression is
attributable to a commit, not merely to a time. The Grafana dashboard renders
deploy annotations from this series, so every graph shows an orange marker at
each rollout — "did that deploy cause this?" is answered by looking.

Both services emit identical label sets deliberately. Inconsistent
instrumentation is what makes cross-service dashboards impossible.

### The four signals, per service

| Signal | Metric | Why |
|---|---|---|
| Traffic | `rate(http_requests_total[2m])` | Load context for everything else |
| Errors | `rate(http_requests_total{status=~"5.."}[5m])` ratio | User-visible failure |
| Latency | `histogram_quantile(0.95, ...)` | Tail latency is what users feel; averages hide it |
| Saturation | `process_resident_memory_bytes` vs the 192Mi limit | Predicts OOM kills before they happen |

Histograms rather than averages, and p95/p99 rather than p50, because a mean
latency of 40ms can hide a 2s tail affecting 2% of requests.

---

## 3. Alert rules

Alerts are committed as code (`monitoring/03-prometheus-rules.yaml`) and each
carries a runbook annotation — an alert without a next action is noise.

| Alert | Condition | Severity | Action |
|---|---|---|---|
| `ServiceHasUnreachableInstances` | no reachable instances for 2m | critical | Check pods and rollout history |
| `TargetDown` | a scrape target down 1m | warning | Verify pod Running and `/metrics` responds |
| `HighErrorRate` | >5% 5xx over 5m | critical | Correlate `app_build_info`, consider `rollout undo` |
| `LatencyP95Degraded` | p95 >500ms for 5m | warning | Check limits and recent deploys |
| `NewBuildDeployed` | build series changes | info | Timeline event, not a page |

**Alert on symptoms, not causes.** "p95 above 500ms" is a user-visible symptom.
"CPU above 80%" is a cause that may or may not matter — paging on it produces
alert fatigue, which is how real incidents get missed.

`NewBuildDeployed` is deliberately `info`. Deploys are not incidents; they are
context. Placing them on the same timeline as the metrics they may have changed
is what makes correlation possible.

---

## 4. Monitoring the pipeline itself

Currently implemented: the pipeline's *outcome* is observable through
`app_build_info` — what is deployed where, and when it changed.

Recommended additions, in priority order:

1. **Prometheus metrics plugin for Jenkins** — exposes `/prometheus` with build
   duration, queue depth, success/failure counts per job. Enables DORA metrics
   directly: deployment frequency from `changes(app_build_info)`, lead time from
   commit timestamp to deploy timestamp, change failure rate from failed builds
   over total, MTTR from the gap between a failed rollout and its rollback.
2. **Alert on pipeline health, not just application health** — a queue that
   never drains or a build duration doubling week over week is an incident for
   the platform team before it is one for anyone else.
3. **Scrape both clusters.** Prometheus currently runs in staging only. A
   production deployment runs one Prometheus per cluster with a federation or
   remote-write endpoint aggregating both, so a single query spans environments.

---

## 5. Logging strategy

**Currently:** container stdout, retrieved on demand — and, importantly, printed
automatically into the build log when a rollout fails:
--- pods ---
--- recent events ---
--- logs (most recent pod) ---
Failure diagnostics that require someone to go looking are diagnostics that
arrive too late. The engineer reading a failed build already has pod status,
Kubernetes events, and application logs in front of them.

**Recommended for production:**

| Concern | Recommendation |
|---|---|
| Aggregation | Promtail → Loki, or Fluent Bit → Elasticsearch. Loki pairs naturally with Grafana and indexes labels rather than full text, which keeps cost proportional to metadata |
| Correlation | Log the same labels the metrics carry — `service`, `environment`, `commit`, `build_number`. A dashboard panel can then link a latency spike to the exact log lines from the same build |
| Format | Structured JSON. `gunicorn --access-logfile -` and Express both support it; grep-friendly text stops scaling the moment there are three services |
| Retention | Hot 7 days, warm 30, archive to object storage. Most incidents are diagnosed within hours; compliance drives the long tail |
| What not to log | Request bodies and headers by default — for a mortgage platform, that is where PII lives. Log identifiers, not payloads |

---

## 6. Tracing

Not implemented; scope for two services is limited. Worth stating the trigger:
tracing earns its cost when a request crosses three or more services and
"which hop is slow" stops being answerable from per-service latency. OpenTelemetry
instrumentation with the same `service`/`commit` labels would slot into the
existing model without changing it.

---

## 7. Constraints in this environment

| Here | Why | Production |
|---|---|---|
| One Prometheus, staging only | 11 GB workstation | One per cluster, federated or remote-write |
| `emptyDir` storage, 6h retention | No persistent volumes locally | PVC with 15–30 day retention, or Thanos/Mimir for long-term |
| No Alertmanager | Nowhere to route to on a laptop | Alertmanager → PagerDuty/Slack, with severity-based routing and inhibition |
| Grafana admin/admin | Demo | SSO, viewer-by-default, dashboards as code (already true here) |
| No log aggregation | Memory | Loki or Elasticsearch per the table above |

The dashboard and datasource are provisioned from files rather than clicked into
Grafana's database. They survive a pod restart, are reviewable in a pull request,
and can be recreated from an empty cluster — which is the same standard the rest
of the platform is held to.
