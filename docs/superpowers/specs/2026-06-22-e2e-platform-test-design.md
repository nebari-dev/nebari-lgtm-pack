# LGTM pack end-to-end platform test — design

**Date:** 2026-06-22
**Status:** Approved

## Goal

Add black-box tests that prove the nebari-lgtm-pack works as deployed in
production: installed on top of a real Nebari platform (NIC + foundational
stack) via GitOps/ArgoCD, with telemetry actually flowing into the LGTM
backends so the Grafana dashboards render real data.

This complements — does not replace — the existing `test.yaml`, which is a
fast standalone `helm install` smoke test with a stubbed OTel DaemonSet and
never touches a real platform.

## Form factor

- A new GitHub Actions workflow: `.github/workflows/e2e-platform.yaml`,
  triggered on `push`/`pull_request` to `main`.
- Assertions live in standalone, locally-runnable scripts under `tests/e2e/`
  (mirroring how `action-nebari-sandbox` organizes `tests/scenarios/`). The
  workflow YAML stays thin; the checks are reusable and debuggable outside CI.

## Workflow flow

1. **Checkout** the lgtm-pack repo.
2. **Sandbox platform profile** — `nebari-dev/action-nebari-sandbox@v2` with
   `profile: platform`. Uses `nic-version: latest` (the default — prebuilt
   binary, no Go toolchain needed). This provisions k3d + NIC + the
   foundational stack (Envoy Gateway, cert-manager, Keycloak, ArgoCD, and the
   OpenTelemetry collector DaemonSet in the `monitoring` namespace).
   Captures the action's outputs: `kubeconfig`, `cluster-name`, `gitops-dir`,
   `gateway-ip`.
3. **Vendor subchart deps** — `helm dependency update chart`, so ArgoCD's
   repo-server can render the `file://` chart without pulling dependencies
   itself.
4. **Surface `KUBECONFIG`** into `$GITHUB_ENV` (required by the sub-action's
   wait-for-app step and by all verification scripts).
5. **Install LGTM pack** via the `add-software-pack` sub-action:
   - `gitops-dir`: the sandbox `gitops-dir` output
   - `app-name: nebari-lgtm-pack` (→ Helm release name `nebari-lgtm-pack`, so
     service names resolve as `nebari-lgtm-pack-loki`, `-tempo`, etc., matching
     the datasource and OTel-override URLs the chart renders)
   - `chart-source: ./chart`
   - `application-manifest`: a checked-in `tests/e2e/lgtm-application.yaml`
     (see below)
   - waits for the `Application` to reach `Healthy` (default behavior).
   The chart's post-install OTel-rollout Job runs as an ArgoCD PostSync hook
   and restarts NIC's collector so it picks up the override ConfigMap.
6. **Run verification scripts** (see below).
7. **Cleanup** — `k3d cluster delete <cluster-name>` with `if: always()`.
   A separate `if: failure()` step dumps diagnostics (pod status, events,
   Application status, collector + Grafana logs).

## Deployment posture

Deploy the **full production manifest**: `nebariapp.enabled=true` with
`nebariapp.auth.enabled=true` and `nebariapp.hostname: grafana.nebari.local`.
This creates the NebariApp CRD, which the NIC operator reconciles into a
Keycloak client + HTTPRoute — the real path.

Per the chosen "telemetry flows" depth, the tests **deploy** this path but do
**not** assert on the gateway-hostname / OAuth-redirect login flow (the
brittle parts). Grafana still becomes Ready and its HTTP API is reachable via
port-forward + `admin:admin` basic auth regardless of whether OAuth is wired,
so all API-based assertions work.

### Application manifest (`tests/e2e/lgtm-application.yaml`)

An ArgoCD `Application` modeled on the sandbox README example:
- `spec.source.repoURL: "file://${GITOPS_DIR}"` (envsubst-rendered by the
  sub-action)
- `spec.source.path: nebari-lgtm-pack`
- `spec.source.helm.values`: inline values setting `nebariapp.enabled: true`,
  `nebariapp.auth.enabled: true`, `nebariapp.hostname: grafana.nebari.local`,
  and `otelCollectorOverrides.enabled: true`.
- `destination.namespace`: the install namespace (e.g. `lgtm`).
- `syncPolicy.automated` + `CreateNamespace=true`.

The chart renders the OTel override ConfigMap into the `monitoring` namespace
explicitly (via `otelCollectorOverrides.namespace`), independent of the
Application's destination namespace; ArgoCD applies it there directly.

## Verification (`tests/e2e/`)

Each script is independently runnable given a `KUBECONFIG` and (where needed)
`GATEWAY_IP`. Each port-forwards the relevant service, asserts, and cleans up
its port-forward.

- **`verify-grafana.sh`** — assert `/api/health` returns `database: ok`;
  assert Loki, Tempo, and Mimir datasources are provisioned; assert each
  passes Grafana's datasource health check
  (`GET /api/datasources/uid/<uid>/health`). Basic auth `admin:admin`.
- **`verify-logs.sh`** — query Loki for logs from a known-busy namespace
  (e.g. `{namespace="monitoring"}`) and assert non-empty results. Proves the
  bundled Promtail → Loki path works (logs flow organically; no synthetic
  injection needed).
- **`verify-metrics.sh`** — the core integration check. Generate Envoy gateway
  traffic by curling the gateway IP several times, wait for a scrape interval,
  then query Mimir's Prometheus API
  (`/prometheus/api/v1/query?query=envoy_http_downstream_rq_xx`) and assert at
  least one series exists. This proves the full chain
  Envoy → NIC collector → (our override) → Mimir, i.e. the
  `nebari-gateway-traffic` dashboard will render real data.
- **`verify-traces.sh`** *(light)* — assert Tempo is Ready and its datasource
  is healthy. Optionally push one synthetic OTLP span and read it back; if not
  cheap/reliable, skip with a logged note (traces do not flow organically in
  an idle cluster).

A top-level **`tests/e2e/run.sh`** runs the four scripts in order and is what
the workflow invokes, so the whole suite can also be run locally against any
platform cluster.

## Known risks (explicit)

- **Resource pressure** — foundational stack + full LGTM stack on a
  GitHub-hosted runner (~4 vCPU / 16 GB) is tight. All LGTM backends already
  default to single-binary/monolithic mode. Use a generous job timeout
  (~35–40 min). If pods OOM, tune component resource requests or trim the
  stack; do not silently lower assertions.
- **Metric scrape coverage** — if NIC's collector does not scrape Envoy by
  default, `verify-metrics.sh` goes red. That is the correct black-box
  outcome: it means the dashboard would have no data either. Treat a red here
  as a real signal, not test flake — investigate the collector scrape config
  rather than weakening the test.

## Out of scope

- Gateway-hostname routing and Keycloak OAuth login assertions (deferred;
  deployed but not asserted).
- Changes to the chart itself. If verification surfaces a real integration
  bug, that is a separate fix.
