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

The chart source lives in [`chart/`](chart/). From a clone:

```bash
helm dependency update chart
helm install lgtm-pack chart --namespace default --set nebariapp.enabled=false
```

Or from the published Nebari Helm repository (this chart is released via [nebari-dev/helm-repository](https://github.com/nebari-dev/helm-repository)):

```bash
helm repo add nebari https://raw.githubusercontent.com/nebari-dev/helm-repository/gh-pages/
helm repo update nebari
helm install lgtm-pack nebari/nebari-lgtm-pack --namespace default --set nebariapp.enabled=false
```

Grafana will be available at port 80 of the `lgtm-pack-grafana` service (default credentials: `admin`/`admin`).

### Deploy as an ArgoCD Application

On a GitOps-managed Nebari cluster, deploy the pack by applying an ArgoCD `Application` that sources the chart from the Nebari Helm repository. A complete, ready-to-edit manifest lives at [`examples/argocd-application.yaml`](examples/argocd-application.yaml):

```bash
kubectl apply -f examples/argocd-application.yaml
```

Set `nebariapp.hostname` and `nebariapp.keycloakHostname` to your cluster's values before applying. The example pins `targetRevision` to a published chart version and opts the `monitoring` namespace into Nebari management (`nebari.dev/managed: "true"`) so the nebari-operator reconciles the bundled `NebariApp`.

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

When this chart is installed on a cluster deployed by [nebari-infrastructure-core](https://github.com/nebari-dev/nebari-infrastructure-core) (NIC), logs/traces/metrics are automatically routed to this chart's Loki/Tempo/Mimir backends. No manual edits to the GitOps repo are required.

**How it works**

1. NIC's OTel collector is configured to mount an optional `opentelemetry-collector-overrides` ConfigMap and pass it to the collector as an additional `--config` file. An init container resolves the override file (or falls back to an empty `{}` if no software pack has provided one).
2. This chart renders the `opentelemetry-collector-overrides` ConfigMap with our exporter and pipeline overrides — endpoints templated with `{{ .Release.Name }}` so custom release names work.
3. The OTel collector deep-merges its base config (NIC's defaults) with this override at startup. Our pipeline overrides replace the `[debug]` exporter lists with `[otlphttp/loki]`, `[otlp/tempo]`, and `[otlphttp/mimir]`.
4. A small post-install/post-upgrade Job rolls NIC's collector DaemonSet so the init container re-resolves the override file. The DaemonSet's `checksum/config` annotation is derived from Helm values, not from this external ConfigMap, so without an explicit rollout the new config would not be picked up until an unrelated pod restart.

Because NIC and this chart write to separate ConfigMaps, ArgoCD never has to choose between conflicting desired states — sidestepping upstream issue [argo-cd#7478](https://github.com/argoproj/argo-cd/issues/7478) where `ignoreDifferences` is bypassed during sync.

**Disabling**

Set `otelCollectorOverrides.enabled=false` if NIC is not managing the collector (e.g. standalone LGTM against a user-managed collector). Without the override ConfigMap, NIC's collector runs with debug exporters only.

**Uninstall behavior**

`helm uninstall` removes the `opentelemetry-collector-overrides` ConfigMap. NIC's collector pods continue using the previously-resolved override until they restart for any reason; at that point the init container falls back to empty `{}` and the collector reverts to debug exporters. To force the revert immediately:

```bash
kubectl -n monitoring rollout restart daemonset opentelemetry-collector-agent
```

## Contributing dashboards from other software packs

Any Nebari software pack can ship a Grafana dashboard that is auto-provisioned alongside this pack's — the dashboard analog of the OpenTelemetry collector override above. No edits to this chart are required.

**How it works**

Grafana's dashboard sidecar runs with `grafana.sidecar.dashboards.searchNamespace=ALL` (the default in this chart). It watches **every** namespace for ConfigMaps (or Secrets) labeled `grafana_dashboard` and live-loads the JSON they contain into Grafana within ~30s — no Grafana restart. The grafana subchart grants the sidecar cluster-wide ConfigMap list/watch via a ClusterRole when `searchNamespace=ALL`.

**Contract**

Your pack renders a ConfigMap, in its own namespace, that looks like this:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-pack-dashboards
  namespace: my-pack            # your pack's namespace, not monitoring
  labels:
    grafana_dashboard: "1"      # discovery key the sidecar matches on
  annotations:
    grafana_folder: "My Pack"   # optional: groups the dashboard into a folder
data:
  my-dashboard.json: |          # key must end in .json
    { ...grafana dashboard model... }
```

In a Helm chart, render every JSON file under a `dashboards/` directory so adding a dashboard is just dropping in a file:

```yaml
# templates/grafana-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "my-pack.fullname" . }}-dashboards
  namespace: {{ .Release.Namespace }}
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "My Pack"
data:
{{- range $path, $bytes := .Files.Glob "dashboards/*.json" }}
  {{ base $path }}: |-
{{ $.Files.Get $path | indent 4 }}
{{- end }}
```

**Point panels at the existing datasources**

The sidecar only loads dashboards; it does not create datasources. Reference the datasources this pack already provisions, by `uid`:

```json
"datasource": { "type": "prometheus", "uid": "mimir" }
```

Available uids: `mimir` (metrics), `loki` (logs), `tempo` (traces). A panel pointing at a uid that does not exist renders empty.

**Soft dependency**

This is a soft dependency on the LGTM pack: if this pack (and therefore Grafana) is not installed, the contributing pack's ConfigMap simply sits unused — no error, no coupling — exactly like the OTel override ConfigMap when no collector is present.

**Restricting discovery**

To stop watching other namespaces, set `grafana.sidecar.dashboards.searchNamespace` to the release namespace (or a comma-separated list). Only this pack's own dashboards are then provisioned.

## License

Apache 2.0 — see [LICENSE](LICENSE).
