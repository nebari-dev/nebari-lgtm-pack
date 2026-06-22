# LGTM pack end-to-end verification

Black-box checks that the lgtm-pack works when installed on a real Nebari
platform (NIC + foundational stack). These run in CI via
`.github/workflows/e2e-platform.yaml`, but each script is standalone and can be
run by hand against any platform cluster that already has the pack installed.

## What each script asserts

| Script               | Asserts                                                                 |
|----------------------|-------------------------------------------------------------------------|
| `verify-grafana.sh`  | Grafana `/api/health` ok; Loki/Tempo/Mimir datasources provisioned & healthy |
| `verify-logs.sh`     | Loki has organic logs (Promtail → Loki)                                 |
| `verify-metrics.sh`  | Mimir has kubernetes metrics (cAdvisor/kubelet/kube-state → collector → Mimir) |
| `verify-traces.sh`   | A synthetic OTLP span pushed through NIC's collector is retrievable from Tempo |

`run.sh` runs all four in order.

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

## Note on the gateway dashboard

The chart ships `nebari-gateway-traffic.json` (Envoy metrics), but NIC's
foundational collector has no Envoy scrape job, so those series do not flow on
a stock platform and this suite does not assert on them. Tracked separately.
