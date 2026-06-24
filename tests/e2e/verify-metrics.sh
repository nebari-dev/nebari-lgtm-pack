#!/usr/bin/env bash
# Verify the override's metrics pipeline (otlp receiver -> otlphttp/mimir) by
# pushing a synthetic OTLP gauge THROUGH NIC's collector and reading it back
# from Mimir. This validates the LGTM pack's contract — the export pipeline —
# deterministically.
#
# Why synthetic rather than organically-scraped kubernetes metrics: on NIC
# `latest` the foundational collector cannot scrape. Its ServiceAccount lacks
# pod list/watch RBAC (logs spam "pods is forbidden") and the released config
# ships only the kubernetes-pods job, so kube-state/node metrics never reach
# Mimir and the Kubernetes dashboards stay empty. That is an upstream NIC gap
# (tracked separately), not the LGTM pack's responsibility. The pack owns the
# override export pipeline, which is exactly what this push exercises.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "${HERE}/lib.sh"

SERVICE_NAME="lgtm-e2e-metrics"
METRIC="lgtm_e2e_probe"

# ── Reach the collector's OTLP/HTTP receiver (serviceless DaemonSet -> pod) ────
# ensure_otel_pf (called inside push) re-resolves the collector pod and
# re-forwards if it's replaced mid-check, so a rollout doesn't wedge the push.
OTEL_PORT=4318
OTEL_BASE="http://127.0.0.1:${OTEL_PORT}"

# Push a synthetic OTLP gauge. Re-pushable (fresh timestamp each call).
# shellcheck disable=SC2329  # invoked indirectly via retry "$@"
push_metric() {
  local now_ns code
  ensure_otel_pf "${OTEL_PORT}" || return 1
  now_ns="$(date +%s)000000000"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${OTEL_BASE}/v1/metrics" \
    -H 'Content-Type: application/json' \
    --data @- <<JSON
{
  "resourceMetrics": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "${SERVICE_NAME}"}}]},
    "scopeMetrics": [{
      "scope": {"name": "lgtm-e2e"},
      "metrics": [{
        "name": "${METRIC}",
        "gauge": {
          "dataPoints": [{
            "asDouble": 1,
            "timeUnixNano": "${now_ns}"
          }]
        }
      }]
    }]
  }]
}
JSON
)"
  [[ "${code}" == "200" || "${code}" == "202" ]]
}

echo "=== Pushing synthetic OTLP metric through the collector ==="
retry 60 "collector accepts OTLP metric" push_metric

# ── Read back from Mimir ──────────────────────────────────────────────────────
MIMIR_PORT=9009
pf "${LGTM_NS}" "svc/${MIMIR_SVC}" "${MIMIR_PORT}" 80
# Mimir's Prometheus-compatible API is served under /prometheus.
MIMIR_BASE="http://127.0.0.1:${MIMIR_PORT}/prometheus"

# Match on a name prefix: Mimir's OTLP ingest may append unit/type suffixes, so
# don't pin the exact metric name.
check_metric() {
  push_metric || true
  local resp
  resp="$(curl -sf -G "${MIMIR_BASE}/api/v1/query" \
    --data-urlencode "query={__name__=~\"${METRIC}.*\"}")" || return 1
  echo "${resp}" | jq -e '.status == "success" and (.data.result | length) > 0' >/dev/null
}

echo "=== Querying Mimir for ${METRIC} ==="
retry 180 "mimir has the synthetic metric" check_metric
echo "OK: synthetic metric traversed collector -> Mimir (otlphttp/mimir override leg works)."
