#!/usr/bin/env bash
# Verify the override's logs pipeline (otlp receiver -> otlphttp/loki) by
# pushing a synthetic OTLP log THROUGH NIC's collector and reading it back from
# Loki. This exercises the LGTM pack's actual contract — telemetry sent to the
# collector reaches the LGTM backend — rather than the bundled Promtail path
# (which ships to Loki directly and would pass even if the override were
# broken).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "${HERE}/lib.sh"

SERVICE_NAME="lgtm-e2e-logs"

# ── Reach the collector's OTLP/HTTP receiver (serviceless DaemonSet -> pod) ────
POD="$(otel_pod)"
[[ -n "${POD}" ]] || { echo "::error::no Running collector pod in ${MON_NS}"; kubectl -n "${MON_NS}" get pods || true; exit 1; }
echo "Using collector pod: ${POD}"
OTEL_PORT=4318
pf "${MON_NS}" "pod/${POD}" "${OTEL_PORT}" 4318
OTEL_BASE="http://127.0.0.1:${OTEL_PORT}"

# Push a synthetic OTLP log. Re-pushable (fresh timestamp each call) so the
# readback loop can keep nudging until Loki has ingested it.
push_log() {
  local now_ns code
  now_ns="$(date +%s)000000000"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${OTEL_BASE}/v1/logs" \
    -H 'Content-Type: application/json' \
    --data @- <<JSON
{
  "resourceLogs": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "${SERVICE_NAME}"}}]},
    "scopeLogs": [{
      "scope": {"name": "lgtm-e2e"},
      "logRecords": [{
        "timeUnixNano": "${now_ns}",
        "severityText": "INFO",
        "body": {"stringValue": "lgtm-e2e log probe"}
      }]
    }]
  }]
}
JSON
)"
  [[ "${code}" == "200" || "${code}" == "202" ]]
}

echo "=== Pushing synthetic OTLP log through collector ${POD}:4318 ==="
retry 60 "collector accepts OTLP log" push_log

# ── Read back from Loki ───────────────────────────────────────────────────────
LOKI_PORT=3100
pf "${LGTM_NS}" "svc/${LOKI_SVC}" "${LOKI_PORT}" 3100
LOKI_BASE="http://127.0.0.1:${LOKI_PORT}"

# Loki maps the OTLP resource attribute service.name -> the service_name label.
check_log() {
  push_log || true
  local end start resp
  end="$(date +%s)000000000"
  start="$(( $(date +%s) - 900 ))000000000"
  resp="$(curl -sf -G "${LOKI_BASE}/loki/api/v1/query_range" \
    --data-urlencode 'query={service_name="'"${SERVICE_NAME}"'"}' \
    --data-urlencode "start=${start}" \
    --data-urlencode "end=${end}" \
    --data-urlencode 'limit=5')" || return 1
  echo "${resp}" | jq -e '(.data.result | length) > 0' >/dev/null
}

echo "=== Querying Loki for service_name=${SERVICE_NAME} ==="
if retry 180 "loki has the synthetic log" check_log; then
  echo "OK: synthetic log traversed collector -> Loki (otlphttp/loki override leg works)."
  exit 0
fi

# Didn't find it under service_name. Dump what Loki actually has so we can see
# whether the OTLP logs landed under different labels (or not at all).
echo "=== Loki introspection (debug) ==="
echo "--- all label names ---"
curl -sf "${LOKI_BASE}/loki/api/v1/labels" | jq -r '.data[]?' | sort -u | head -50 || true
echo "--- service_name label values ---"
curl -sf "${LOKI_BASE}/loki/api/v1/label/service_name/values" | jq -r '.data[]?' | sort -u | head -50 || true
end="$(date +%s)000000000"; start="$(( $(date +%s) - 900 ))000000000"
echo "--- streams seen in the last 15m (any service_name) ---"
curl -sf -G "${LOKI_BASE}/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name=~".+"}' \
  --data-urlencode "start=${start}" --data-urlencode "end=${end}" \
  --data-urlencode 'limit=20' | jq -c '.data.result[]?.stream' | sort -u | head -30 || true
exit 1
