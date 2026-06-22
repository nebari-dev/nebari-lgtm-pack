# LGTM pack end-to-end platform test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a CI workflow + black-box verification scripts that install the lgtm-pack onto a real Nebari platform (NIC + foundational stack) via GitOps and prove telemetry actually flows into Loki/Tempo/Mimir.

**Architecture:** A new GitHub Actions workflow uses `nebari-dev/action-nebari-sandbox@v2` (`profile: platform`, NIC `latest`) to bootstrap k3d + NIC, then its `add-software-pack` sub-action to register the local `./chart` as an ArgoCD Application. Four standalone, locally-runnable bash scripts under `tests/e2e/` port-forward each backend and assert: Grafana health + datasource health, organic logs in Loki, organic kubernetes metrics in Mimir, and a synthetic OTLP span round-tripped through NIC's collector into Tempo.

**Tech Stack:** GitHub Actions, bash, kubectl, helm, k3d (via the action), curl, jq, yq. No application code; the deliverables are CI + shell test artifacts.

---

## Why TDD looks different here

These scripts **are** the tests. There is no unit under test to drive with a red/green loop — the meaningful verification is (a) static: `bash -n` + `shellcheck`, and (b) dynamic: running the whole suite against a live platform, which only happens in CI (or locally via the optional path in `tests/e2e/README.md`). So each task's loop is: write the artifact → lint it (`bash -n`, `shellcheck`) → commit. The final task pushes the branch and validates the real end-to-end run, with explicit expected output. Treat that run as the acceptance test for the whole plan.

Install `shellcheck` locally if absent (`brew install shellcheck`). If it genuinely cannot be installed, `bash -n` alone is the fallback gate — note that in the commit.

## File structure

- `tests/e2e/lib.sh` — shared config (service names, namespaces) + helpers (`pf`, `retry`, cleanup trap). Sourced by every script. Single source of truth for names so a rename touches one file.
- `tests/e2e/lgtm-application.yaml` — the ArgoCD `Application` manifest registered into the GitOps repo (envsubst-rendered by the sub-action).
- `tests/e2e/verify-grafana.sh` — Grafana `/api/health` + datasource provisioning + per-datasource health.
- `tests/e2e/verify-logs.sh` — Loki has organic Promtail logs.
- `tests/e2e/verify-metrics.sh` — Mimir has organic kubernetes metrics (cAdvisor/kubelet/kube-state).
- `tests/e2e/verify-traces.sh` — synthetic OTLP span pushed through NIC's collector, read back from Tempo.
- `tests/e2e/run.sh` — runs the four verify scripts in order; the workflow's single entry point.
- `tests/e2e/README.md` — how to run the suite locally against any platform cluster.
- `.github/workflows/e2e-platform.yaml` — the CI workflow tying it together.

## Fixed facts (do not re-derive — verified against NIC + chart source)

- **Helm release name** = the `app-name` passed to `add-software-pack` = `nebari-lgtm-pack`. So services render as `nebari-lgtm-pack-<component>`.
- **Install namespace** = `lgtm` (Application `destination.namespace`, `CreateNamespace=true`).
- **Service endpoints** (in namespace `lgtm` unless noted):
  - Grafana: `nebari-lgtm-pack-grafana` : 80, admin/admin basic auth.
  - Loki: `nebari-lgtm-pack-loki` : 3100.
  - Tempo: `nebari-lgtm-pack-tempo` : 3200 (HTTP query API; trace lookup `GET /api/traces/<id>`).
  - Mimir: `nebari-lgtm-pack-mimir-gateway` : 80, Prometheus API under `/prometheus` (e.g. `/prometheus/api/v1/query`).
  - NIC collector: `opentelemetry-collector` : 4318 (OTLP/HTTP) in namespace `monitoring`. OTLP/HTTP trace ingest path `POST /v1/traces`.
- **Datasource UIDs** (from `chart/templates/grafana-datasources.yaml`): Loki `loki`, Mimir `mimir`, Tempo has **no** fixed uid → resolve its uid by name at runtime.
- **Collector scrape jobs** (from NIC `opentelemetry-collector.yaml`): `kubernetes-cadvisor`, `kubernetes-kubelet`, `kubernetes-pods` (keeps `prometheus.io/scrape: "true"` pods — kube-state-metrics + node-exporter, both bundled & annotated in this chart). These feed Mimir via the chart's override ConfigMap. **No Envoy scrape job exists** — do not assert on `envoy_*`.
- **Sandbox action outputs used:** `kubeconfig`, `cluster-name`, `gitops-dir`.

---

## Task 1: Shared library (`tests/e2e/lib.sh`)

**Files:**
- Create: `tests/e2e/lib.sh`

- [ ] **Step 1: Write `lib.sh`**

```bash
#!/usr/bin/env bash
# Shared config + helpers for the LGTM e2e verification scripts.
# Source this from each verify-*.sh. Requires: kubectl, curl, jq.
#
# Every script that sources this gets:
#   - canonical service/namespace names (override via env if needed)
#   - pf()      : start a backgrounded port-forward, wait until it's listening
#   - retry()   : poll a command until it succeeds or a deadline passes
#   - automatic cleanup of all port-forwards on exit

set -euo pipefail

# ── Canonical names (env-overridable so the suite can target a custom install) ─
RELEASE="${LGTM_RELEASE:-nebari-lgtm-pack}"
LGTM_NS="${LGTM_NS:-lgtm}"
MON_NS="${MON_NS:-monitoring}"

GRAFANA_SVC="${RELEASE}-grafana"
LOKI_SVC="${RELEASE}-loki"
TEMPO_SVC="${RELEASE}-tempo"
MIMIR_SVC="${RELEASE}-mimir-gateway"
OTEL_SVC="opentelemetry-collector"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"

# ── Port-forward bookkeeping ──────────────────────────────────────────────────
_PF_PIDS=()
_cleanup() {
  for pid in "${_PF_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  done
}
trap _cleanup EXIT

# pf <namespace> <svc> <local_port> <remote_port>
# Backgrounds `kubectl port-forward` and blocks until the local port accepts
# connections (max ~20s). Records the PID for cleanup on exit.
pf() {
  local ns="$1" svc="$2" lport="$3" rport="$4"
  kubectl -n "${ns}" port-forward "svc/${svc}" "${lport}:${rport}" >/dev/null 2>&1 &
  local pid=$!
  _PF_PIDS+=("${pid}")
  for _ in $(seq 1 40); do
    if curl -sf -o /dev/null "http://127.0.0.1:${lport}" 2>/dev/null \
       || nc -z 127.0.0.1 "${lport}" 2>/dev/null; then
      return 0
    fi
    # Bail early if the port-forward process already died.
    kill -0 "${pid}" 2>/dev/null || { echo "port-forward to ${svc} died"; return 1; }
    sleep 0.5
  done
  echo "timed out waiting for port-forward ${svc} :${lport}"
  return 1
}

# retry <timeout_seconds> <description> <command...>
# Runs the command repeatedly (every 5s) until it exits 0 or the timeout
# elapses. The command's own stdout/stderr is suppressed; we print progress.
retry() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  local attempt=0
  while (( $(date +%s) < deadline )); do
    attempt=$((attempt + 1))
    if "$@" >/dev/null 2>&1; then
      echo "  ${desc}: ok (attempt ${attempt})"
      return 0
    fi
    echo "  ${desc}: not yet (attempt ${attempt})..."
    sleep 5
  done
  echo "::error::${desc}: timed out after ${timeout}s"
  return 1
}
```

- [ ] **Step 2: Lint**

Run: `bash -n tests/e2e/lib.sh && shellcheck tests/e2e/lib.sh`
Expected: no syntax errors; shellcheck clean (or only `SC1090/SC2034`-style info on unused vars, which are intentional shared config — acceptable).

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/lib.sh
git commit -m "test(e2e): add shared lib for platform verification scripts"
```

---

## Task 2: Grafana verification (`tests/e2e/verify-grafana.sh`)

**Files:**
- Create: `tests/e2e/verify-grafana.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Verify Grafana is healthy and all three LGTM datasources are provisioned
# AND pass Grafana's own datasource health check. Uses admin basic auth;
# OAuth being enabled on the deployment does not affect the local API.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "${HERE}/lib.sh"

LPORT=3000
pf "${LGTM_NS}" "${GRAFANA_SVC}" "${LPORT}" 80
BASE="http://127.0.0.1:${LPORT}"
AUTH=(-u "${GRAFANA_USER}:${GRAFANA_PASS}")

echo "=== Grafana /api/health ==="
# Grafana may take a moment after pod-ready to serve a healthy DB; poll.
retry 120 "grafana database healthy" bash -c \
  "curl -sf ${BASE}/api/health | jq -e '.database == \"ok\"'"

echo "=== Datasources provisioned ==="
DS_JSON="$(curl -sf "${AUTH[@]}" "${BASE}/api/datasources")"
echo "${DS_JSON}" | jq -r '.[].name'
for name in Loki Tempo Mimir; do
  echo "${DS_JSON}" | jq -e --arg n "${name}" 'any(.[]; .name == $n)' >/dev/null \
    || { echo "::error::datasource ${name} not provisioned"; exit 1; }
  echo "  ${name}: present"
done

echo "=== Datasource health checks ==="
# Resolve uid by name (Tempo has no fixed uid in provisioning) and hit the
# per-datasource health endpoint. Returns {"status":"OK",...} when reachable.
for name in Loki Tempo Mimir; do
  uid="$(echo "${DS_JSON}" | jq -r --arg n "${name}" '.[] | select(.name==$n) | .uid')"
  retry 120 "${name} datasource health" bash -c \
    "curl -sf ${AUTH[*]} ${BASE}/api/datasources/uid/${uid}/health | jq -e '.status == \"OK\"'"
done

echo "OK: Grafana healthy and Loki/Tempo/Mimir datasources are working."
```

- [ ] **Step 2: Lint**

Run: `bash -n tests/e2e/verify-grafana.sh && shellcheck -x tests/e2e/verify-grafana.sh`
Expected: clean. (`-x` lets shellcheck follow the `source`.)

- [ ] **Step 3: Make executable + commit**

```bash
chmod +x tests/e2e/verify-grafana.sh
git add tests/e2e/verify-grafana.sh
git commit -m "test(e2e): verify Grafana health and datasource health"
```

---

## Task 3: Logs verification (`tests/e2e/verify-logs.sh`)

**Files:**
- Create: `tests/e2e/verify-logs.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Verify the bundled Promtail is shipping pod logs into Loki. The monitoring
# namespace (OTel collector et al.) is reliably chatty, so query for any log
# line from it within the last 15m and assert a non-empty result.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "${HERE}/lib.sh"

LPORT=3100
pf "${LGTM_NS}" "${LOKI_SVC}" "${LPORT}" 3100
BASE="http://127.0.0.1:${LPORT}"

# Loki labels populate only after the first push; poll until the query returns
# at least one stream. query_range needs start/end nanosecond timestamps.
check_logs() {
  local end start resp
  end="$(date +%s)000000000"
  start="$(( $(date +%s) - 900 ))000000000"
  resp="$(curl -sf -G "${BASE}/loki/api/v1/query_range" \
    --data-urlencode 'query={namespace="'"${MON_NS}"'"}' \
    --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" \
    --data-urlencode 'limit=5')" || return 1
  # data.result must be a non-empty array.
  echo "${resp}" | jq -e '(.data.result | length) > 0' >/dev/null
}

echo "=== Querying Loki for logs from namespace=${MON_NS} ==="
retry 180 "loki has logs" check_logs
echo "OK: Loki is receiving logs (Promtail -> Loki path works)."
```

- [ ] **Step 2: Lint**

Run: `bash -n tests/e2e/verify-logs.sh && shellcheck -x tests/e2e/verify-logs.sh`
Expected: clean.

- [ ] **Step 3: Make executable + commit**

```bash
chmod +x tests/e2e/verify-logs.sh
git add tests/e2e/verify-logs.sh
git commit -m "test(e2e): verify Promtail logs land in Loki"
```

---

## Task 4: Metrics verification (`tests/e2e/verify-metrics.sh`)

**Files:**
- Create: `tests/e2e/verify-metrics.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Verify kubernetes metrics flow into Mimir via NIC's collector + this chart's
# override. These are exactly the series the Kubernetes dashboards render.
# NIC's collector scrapes cAdvisor, the kubelet, and prometheus.io/scrape pods
# (kube-state-metrics, node-exporter) and routes them to Mimir through our
# override ConfigMap. We poll because metrics appear only after a scrape cycle
# + export + Mimir ingest.
#
# Deliberately NOT asserting envoy_* — NIC ships no Envoy scrape job, so those
# series do not exist on a stock platform (separate product gap).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "${HERE}/lib.sh"

LPORT=9009
pf "${LGTM_NS}" "${MIMIR_SVC}" "${LPORT}" 80
# Mimir's Prometheus-compatible API is served under /prometheus (matches the
# Grafana datasource URL in the chart).
BASE="http://127.0.0.1:${LPORT}/prometheus"

# query <promql> -> succeeds if the instant query returns >=1 result series.
query_has_series() {
  local q="$1" resp
  resp="$(curl -sf -G "${BASE}/api/v1/query" --data-urlencode "query=${q}")" || return 1
  echo "${resp}" | jq -e '.status == "success" and (.data.result | length) > 0' >/dev/null
}

# Each entry: a human label and a PromQL probe that must return series.
declare -a CHECKS=(
  'cadvisor scrape up|up{job="kubernetes-cadvisor"}'
  'kubelet scrape up|up{job="kubernetes-kubelet"}'
  'container memory (cAdvisor)|container_memory_working_set_bytes'
  'kube-state pod info|kube_pod_info'
)

for entry in "${CHECKS[@]}"; do
  label="${entry%%|*}"
  promql="${entry#*|}"
  echo "=== Mimir check: ${label} -> ${promql} ==="
  retry 180 "${label}" query_has_series "${promql}"
done

echo "OK: kubernetes metrics are present in Mimir (collector -> override -> Mimir)."
```

- [ ] **Step 2: Lint**

Run: `bash -n tests/e2e/verify-metrics.sh && shellcheck -x tests/e2e/verify-metrics.sh`
Expected: clean.

- [ ] **Step 3: Make executable + commit**

```bash
chmod +x tests/e2e/verify-metrics.sh
git add tests/e2e/verify-metrics.sh
git commit -m "test(e2e): verify kubernetes metrics reach Mimir"
```

---

## Task 5: Traces verification (`tests/e2e/verify-traces.sh`)

**Files:**
- Create: `tests/e2e/verify-traces.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Push a synthetic OTLP span THROUGH NIC's collector (OTLP/HTTP receiver) and
# read it back from Tempo, exercising the override's otlp -> otlp/tempo leg.
# Traces have no organic source in an idle cluster, so the synthetic push is
# what keeps this check meaningful.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "${HERE}/lib.sh"

# A fixed, recognizable 32-hex-char trace id and 16-hex span id. Static so the
# Tempo lookup is deterministic. (Date.now-style uniqueness is unnecessary; the
# cluster is ephemeral per run.)
TRACE_ID="0af7651916cd43dd8448eb211c80319c"
SPAN_ID="b7ad6b7169203331"

# ── Push to the collector's OTLP/HTTP receiver ────────────────────────────────
OTEL_PORT=4318
pf "${MON_NS}" "${OTEL_SVC}" "${OTEL_PORT}" 4318
OTEL_BASE="http://127.0.0.1:${OTEL_PORT}"

# Minimal OTLP/HTTP trace payload. start/end are unix-nano; any recent value is
# fine for ingest. Use `date` for a plausible window.
NOW_NS="$(date +%s)000000000"
START_NS="$(( $(date +%s) - 1 ))000000000"
read -r -d '' SPAN_JSON <<JSON || true
{
  "resourceSpans": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "lgtm-e2e-probe"}}]},
    "scopeSpans": [{
      "scope": {"name": "lgtm-e2e"},
      "spans": [{
        "traceId": "${TRACE_ID}",
        "spanId": "${SPAN_ID}",
        "name": "e2e-synthetic-span",
        "kind": 1,
        "startTimeUnixNano": "${START_NS}",
        "endTimeUnixNano": "${NOW_NS}"
      }]
    }]
  }]
}
JSON

echo "=== Pushing synthetic span to collector ${OTEL_SVC}:4318 ==="
push_span() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${OTEL_BASE}/v1/traces" \
    -H 'Content-Type: application/json' \
    --data "${SPAN_JSON}")"
  [[ "${code}" == "200" || "${code}" == "202" ]]
}
retry 60 "collector accepts OTLP span" push_span

# ── Read back from Tempo ──────────────────────────────────────────────────────
TEMPO_PORT=3200
pf "${LGTM_NS}" "${TEMPO_SVC}" "${TEMPO_PORT}" 3200
TEMPO_BASE="http://127.0.0.1:${TEMPO_PORT}"

echo "=== Querying Tempo for trace ${TRACE_ID} ==="
trace_present() {
  # Tempo returns 200 with the trace body when found, 404 while not yet ingested.
  # Re-push on each attempt so we don't lose to a dropped batch during startup.
  push_span || true
  curl -sf "${TEMPO_BASE}/api/traces/${TRACE_ID}" -o /dev/null
}
retry 180 "trace retrievable from Tempo" trace_present

echo "OK: synthetic span traversed collector -> Tempo (otlp/tempo override leg works)."
```

- [ ] **Step 2: Lint**

Run: `bash -n tests/e2e/verify-traces.sh && shellcheck -x tests/e2e/verify-traces.sh`
Expected: clean. (`SC2034` on `SPAN_JSON` via heredoc is fine; it is used.)

- [ ] **Step 3: Make executable + commit**

```bash
chmod +x tests/e2e/verify-traces.sh
git add tests/e2e/verify-traces.sh
git commit -m "test(e2e): verify synthetic span round-trips collector to Tempo"
```

---

## Task 6: Suite runner (`tests/e2e/run.sh`)

**Files:**
- Create: `tests/e2e/run.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Run the full LGTM e2e verification suite in order. Single entry point for the
# CI workflow and for local runs. Requires KUBECONFIG to point at a platform
# cluster that already has the lgtm-pack installed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KUBECONFIG:?KUBECONFIG must point at the platform cluster}"

SCRIPTS=(
  verify-grafana.sh
  verify-logs.sh
  verify-metrics.sh
  verify-traces.sh
)

fail=0
for s in "${SCRIPTS[@]}"; do
  echo "::group::${s}"
  if "${HERE}/${s}"; then
    echo "PASS: ${s}"
  else
    echo "::error::FAIL: ${s}"
    fail=1
  fi
  echo "::endgroup::"
done

if (( fail )); then
  echo "::error::One or more LGTM e2e checks failed."
  exit 1
fi
echo "All LGTM e2e checks passed."
```

- [ ] **Step 2: Lint**

Run: `bash -n tests/e2e/run.sh && shellcheck tests/e2e/run.sh`
Expected: clean.

- [ ] **Step 3: Make executable + commit**

```bash
chmod +x tests/e2e/run.sh
git add tests/e2e/run.sh
git commit -m "test(e2e): add suite runner"
```

---

## Task 7: ArgoCD Application manifest (`tests/e2e/lgtm-application.yaml`)

**Files:**
- Create: `tests/e2e/lgtm-application.yaml`

- [ ] **Step 1: Write the manifest**

`repoURL` uses `${GITOPS_DIR}` — the sub-action runs `envsubst` over this file before writing it into the gitops repo. Inline Helm values turn on the full production path (NebariApp CRD + OAuth + OTel override). `releaseName` is pinned to `nebari-lgtm-pack` so rendered service names match what the verification scripts expect.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nebari-lgtm-pack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "file://${GITOPS_DIR}"
    targetRevision: HEAD
    path: nebari-lgtm-pack
    helm:
      releaseName: nebari-lgtm-pack
      values: |
        nebariapp:
          enabled: true
          hostname: grafana.nebari.local
          auth:
            enabled: true
        otelCollectorOverrides:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: lgtm
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate YAML**

Run: `yq '.' tests/e2e/lgtm-application.yaml >/dev/null && echo OK`
Expected: `OK` (well-formed YAML).

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/lgtm-application.yaml
git commit -m "test(e2e): add ArgoCD Application manifest for lgtm-pack"
```

---

## Task 8: Local-run docs (`tests/e2e/README.md`)

**Files:**
- Create: `tests/e2e/README.md`

- [ ] **Step 1: Write the README**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add tests/e2e/README.md
git commit -m "docs(e2e): document local run of the verification suite"
```

---

## Task 9: CI workflow (`.github/workflows/e2e-platform.yaml`)

**Files:**
- Create: `.github/workflows/e2e-platform.yaml`

- [ ] **Step 1: Write the workflow**

```yaml
name: E2E Platform Test

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

# A full platform + LGTM stack is heavy; only one run at a time per ref.
concurrency:
  group: e2e-platform-${{ github.ref }}
  cancel-in-progress: true

jobs:
  e2e:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - name: Checkout
        uses: actions/checkout@8e8c483db84b4bee98b60c0593521ed34d9990e8  # v6.0.1

      - name: Install Helm
        run: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

      - name: Vendor chart dependencies
        run: helm dependency update chart

      - name: Bootstrap Nebari platform (NIC latest)
        id: sandbox
        uses: nebari-dev/action-nebari-sandbox@v2
        with:
          profile: platform
          # nic-version defaults to 'latest' (prebuilt binary, no Go needed).

      - name: Surface KUBECONFIG for sub-action wait + verification
        run: echo "KUBECONFIG=${{ steps.sandbox.outputs.kubeconfig }}" >> "$GITHUB_ENV"

      - name: Install lgtm-pack via GitOps
        uses: nebari-dev/action-nebari-sandbox/add-software-pack@v2
        with:
          gitops-dir:           ${{ steps.sandbox.outputs.gitops-dir }}
          app-name:             nebari-lgtm-pack
          chart-source:         ./chart
          application-manifest: ./tests/e2e/lgtm-application.yaml
          wait-timeout:         15m

      - name: Run LGTM e2e verification suite
        run: ./tests/e2e/run.sh

      - name: Diagnostics on failure
        if: failure()
        run: |
          echo "=== ArgoCD applications ==="
          kubectl get applications -n argocd || true
          echo "=== lgtm-pack Application detail ==="
          kubectl get application/nebari-lgtm-pack -n argocd -o yaml || true
          echo "=== Pods (lgtm) ==="
          kubectl get pods -n lgtm -o wide || true
          echo "=== Pods (monitoring) ==="
          kubectl get pods -n monitoring -o wide || true
          echo "=== OTel collector override CM ==="
          kubectl get cm opentelemetry-collector-overrides -n monitoring -o yaml || true
          echo "=== OTel collector logs ==="
          kubectl logs -n monitoring daemonset/opentelemetry-collector-agent --tail=200 || true
          echo "=== Grafana logs ==="
          kubectl logs -n lgtm -l app.kubernetes.io/name=grafana --tail=100 || true
          echo "=== Events (lgtm) ==="
          kubectl get events -n lgtm --sort-by=.lastTimestamp || true

      - name: Cleanup
        if: always()
        run: k3d cluster delete ${{ steps.sandbox.outputs.cluster-name }} || true
```

- [ ] **Step 2: Validate workflow YAML**

Run: `yq '.' .github/workflows/e2e-platform.yaml >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/e2e-platform.yaml
git commit -m "ci: add end-to-end platform test workflow"
```

---

## Task 10: End-to-end validation (the real acceptance test)

**Files:** none (validation only)

This is where the suite is actually exercised. The static lints in prior tasks only prove the scripts parse; this proves they work against a live platform.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin e2e-platform-test
```

- [ ] **Step 2: Watch the `E2E Platform Test` workflow**

Run: `gh run watch "$(gh run list --workflow=e2e-platform.yaml --branch e2e-platform-test --limit 1 --json databaseId -q '.[0].databaseId')"`
Expected: the `e2e` job completes green; the `Run LGTM e2e verification suite` step prints `All LGTM e2e checks passed.`

- [ ] **Step 3: Triage any red, then re-push**

If a step fails, read the `Diagnostics on failure` output. Likely culprits and where to look:
  - **Application never reaches Healthy** → `add-software-pack` step log + Application detail. Check the override CM rendered into `monitoring` and that `nebari-lgtm-pack-*` services exist in `lgtm`.
  - **`verify-grafana` datasource health red** → datasource URLs vs actual service names; collector/backends not ready.
  - **`verify-metrics` timeout** → check the OTel rollout Job ran (collector picked up the override) and that kube-state-metrics/node-exporter pods are `prometheus.io/scrape`-annotated and Running.
  - **`verify-traces` timeout** → confirm the collector OTLP/HTTP service is `opentelemetry-collector:4318` in `monitoring`; check collector logs for export errors to `nebari-lgtm-pack-tempo:4317`.
  - **OOM / pods Pending** → resource pressure (known risk); reduce backend resource requests or stack footprint, do not weaken assertions.

Fix forward, commit, push, repeat until green.

- [ ] **Step 4: Confirm done**

Run: `gh run list --workflow=e2e-platform.yaml --branch e2e-platform-test --limit 1`
Expected: latest run `completed / success`. The plan is complete when this is green.

---

## Self-review notes (addressed)

- **Spec coverage:** workflow (Tasks 9), GitOps install via add-software-pack (Task 9 + manifest Task 7), local `./chart` + dep vendoring (Task 9 step), all four verification scripts incl. synthetic-trace-through-collector (Tasks 2–5), `run.sh` (Task 6), local-run docs (Task 8), cleanup + diagnostics + generous timeout (Task 9), real validation (Task 10). Metrics pivoted to deterministic kubernetes series per the spec's updated `verify-metrics` section and Envoy note.
- **Name consistency:** release/app-name `nebari-lgtm-pack`, namespace `lgtm`, collector svc `opentelemetry-collector`/daemonset `opentelemetry-collector-agent`, Mimir `/prometheus` path, helper names `pf`/`retry` — all used identically across `lib.sh`, the verify scripts, the manifest, and the workflow.
- **No placeholders:** every script and manifest is complete and runnable.
