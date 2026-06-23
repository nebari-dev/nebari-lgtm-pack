# LGTM pack end-to-end verification

Black-box checks that the lgtm-pack works when installed on a real Nebari
platform (NIC + foundational stack). These run in CI via
`.github/workflows/e2e-platform.yaml`, but each script is standalone and can be
run by hand against any platform cluster that already has the pack installed.

## What each script asserts

The signal checks all exercise the same contract — **telemetry sent to NIC's
collector reaches the LGTM backend** — which is the LGTM pack's actual
responsibility (it installs the collector override that wires the otlp receiver
to Loki/Tempo/Mimir). Logs, metrics, and traces each push a *synthetic* OTLP
payload through the collector and read it back, so the checks are deterministic
and independent of whatever the collector does or doesn't scrape organically.

| Script               | Asserts                                                                 |
|----------------------|-------------------------------------------------------------------------|
| `verify-grafana.sh`  | Grafana `/api/health` ok; Loki/Tempo/Mimir datasources provisioned & healthy |
| `verify-logs.sh`     | A synthetic OTLP log pushed through the collector is queryable in Loki (otlphttp/loki leg) |
| `verify-metrics.sh`  | A synthetic OTLP metric pushed through the collector is queryable in Mimir (otlphttp/mimir leg) |
| `verify-traces.sh`   | A synthetic OTLP span pushed through the collector is retrievable from Tempo (otlp/tempo leg) |

`run.sh` runs all four in order.

The collector is a serviceless DaemonSet, so the OTLP pushes port-forward to a
collector **pod** (discovered by `otel_pod` in `lib.sh`), not a Service.

## Running locally

You need a platform cluster with the pack installed. The fastest path mirrors
CI: install `nic`, create a k3d cluster, `nic deploy`, then register the chart
into the gitops repo (see the action-nebari-sandbox README). Once the
`nebari-lgtm-pack` ArgoCD Application is `Healthy`:

```bash
export KUBECONFIG=/path/to/kubeconfig
./tests/e2e/run.sh
```

Override names if your install differs:

```bash
LGTM_RELEASE=my-lgtm LGTM_NS=observability ./tests/e2e/run.sh
```

## Requirements

`kubectl`, `curl`, `jq` on PATH, and a `KUBECONFIG` pointing at the cluster.

## Why synthetic OTLP, and what does NOT work on a stock platform

These checks intentionally do **not** assert on organically-scraped metrics,
because on NIC `latest` the foundational collector cannot scrape:

- its ServiceAccount lacks pod `list`/`watch` RBAC (collector logs repeat
  `pods is forbidden`), and
- the released collector config ships only the `kubernetes-pods` scrape job
  (no cAdvisor/kubelet jobs).

As a result, kube-state-metrics / node-exporter / cAdvisor series never reach
Mimir, and the bundled **Kubernetes dashboards (k8s-views) and the
`nebari-gateway-traffic` dashboard stay empty** on a stock platform. That is an
upstream NIC gap, tracked separately — not a fault in the LGTM pack, whose
override export pipeline these synthetic-OTLP checks prove is working. If/when
NIC grants the collector scrape RBAC, organic dashboards will populate without
any change to this pack.
