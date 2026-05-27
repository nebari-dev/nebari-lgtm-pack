# nebari-lgtm-pack

A Helm chart for deploying the Grafana LGTM observability stack on Kubernetes with optional [Nebari](https://nebari.dev) platform integration.

## Components

| Component | Purpose | Default Mode |
|-----------|---------|-------------|
| **Grafana** | Dashboards & visualization | Single replica |
| **Loki** | Log aggregation | SingleBinary |
| **Tempo** | Distributed tracing | Single replica |
| **Mimir** | Metrics (Prometheus-compatible) | Monolithic |

## Architecture

```
┌─────────────────────────────────────────────┐
│                  Grafana UI                  │
│            (port 3000 / svc :80)            │
│                                              │
│  Datasources:                                │
│    ├── Loki   → http://lgtm-pack-loki:3100  │
│    ├── Tempo  → http://lgtm-pack-tempo:3100 │
│    └── Mimir  → http://lgtm-pack-mimir-..   │
└─────────────────────────────────────────────┘

Push endpoints (for external ingest):
  ├── Loki   :3100  /loki/api/v1/push
  ├── Tempo  :4317  (gRPC) / :4318 (HTTP)
  └── Mimir  :80    /api/v1/push (Prometheus remote-write)
```

## Quick Start

### Prerequisites

- Kubernetes cluster (or [k3d](https://k3d.io) for local dev)
- [Helm](https://helm.sh) v3+

### Install

```bash
helm dependency update
helm install lgtm-pack . --namespace default --set nebariapp.enabled=false
```

Grafana will be available at port 80 of the `lgtm-pack-grafana` service (default credentials: `admin`/`admin`).

### Local Development

Prerequisites: Docker, [ctlptl](https://github.com/tilt-dev/ctlptl), [Tilt](https://docs.tilt.dev/install.html)

```bash
make up       # Create k3d cluster + start Tilt dev loop
              # UI: http://localhost:10350
              # Grafana: http://localhost:3000
make down     # Tear down Tilt + delete k3d cluster
```

## Configuration

All values under subchart keys pass through to the upstream charts:

| Key | Chart | Docs |
|-----|-------|------|
| `grafana.*` | grafana | [values](https://github.com/grafana/helm-charts/tree/main/charts/grafana) |
| `loki.*` | loki | [values](https://github.com/grafana/helm-charts/tree/main/charts/loki) |
| `tempo.*` | tempo | [values](https://github.com/grafana/helm-charts/tree/main/charts/tempo) |
| `mimir-distributed.*` | mimir-distributed | [values](https://github.com/grafana/helm-charts/tree/main/charts/mimir-distributed) |

### Nebari Integration

Set `nebariapp.enabled=true` and provide `nebariapp.hostname` to create a NebariApp CRD for routing and Keycloak OAuth integration. See `values.yaml` for full options.

## OpenTelemetry collector wiring

When this chart is installed on a cluster deployed by [nebari-infrastructure-core](https://github.com/nebari-dev/nebari-infrastructure-core) (NIC), a post-install Helm hook automatically rewires the OTel collector ConfigMap to ship logs/traces/metrics to this chart's Loki/Tempo/Mimir backends. No manual edits to the GitOps repo are required.

**How it works**

1. NIC ships an ArgoCD `Application` that deploys the upstream OTel collector with a default debug exporter. The Application has `ignoreDifferences` on the ConfigMap's `data.relay` field and `RespectIgnoreDifferences=true` in its sync options — meaning ArgoCD will not revert third-party changes to that field.
2. This chart's `post-install,post-upgrade` hook runs a Job that:
   - Reads the current `data.relay` from `opentelemetry-collector-agent` in `monitoring`.
   - Deep-merges the LGTM exporter and pipeline overrides via `yq`.
   - Patches the ConfigMap and stamps `nic.nebari.dev/managed-by=lgtm-pack`.
   - Rolls the collector DaemonSet so the new config is loaded.

**Disabling**

Set `otelCollectorOverrides.enabled=false` if NIC is not managing the collector (e.g. standalone LGTM against a user-managed collector).

**Uninstall behavior**

`helm uninstall` does **not** revert the ConfigMap. The collector will keep its LGTM-wired endpoints, which will start failing once the LGTM services are gone. To reset to NIC defaults, delete the ConfigMap and let ArgoCD recreate it from Helm:

```bash
kubectl -n monitoring delete configmap opentelemetry-collector-agent
```

ArgoCD's next sync will render a fresh debug-exporter ConfigMap from Helm.

## License

Apache 2.0 — see [LICENSE](LICENSE).
