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

# ── Reach the collector's OTLP/HTTP receiver (serviceless DaemonSet -> pod) ────
# NIC deploys the collector as a DaemonSet with no Service. ensure_otel_pf
# (called inside push) re-resolves the pod and re-forwards if it's replaced
# mid-check, so a collector rollout doesn't wedge the push.
OTEL_PORT=4318
OTEL_BASE="http://127.0.0.1:${OTEL_PORT}"

# Minimal OTLP/HTTP trace payload. start/end are unix-nano; any recent value is
# fine for ingest. Timestamps are recomputed on every push (below) so they stay
# fresh across the retry window; TRACE_ID/SPAN_ID stay static for the lookup.
echo "=== Pushing synthetic span through the collector ==="
# shellcheck disable=SC2329  # invoked indirectly via retry "$@"
push_span() {
  local now_ns start_ns span_json code
  ensure_otel_pf "${OTEL_PORT}" || return 1
  now_ns="$(date +%s)000000000"
  start_ns="$(( $(date +%s) - 1 ))000000000"
  span_json="$(cat <<JSON
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
        "startTimeUnixNano": "${start_ns}",
        "endTimeUnixNano": "${now_ns}"
      }]
    }]
  }]
}
JSON
)"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${OTEL_BASE}/v1/traces" \
    -H 'Content-Type: application/json' \
    --data "${span_json}")"
  [[ "${code}" == "200" || "${code}" == "202" ]]
}
retry 60 "collector accepts OTLP span" push_span

# ── Read back from Tempo ──────────────────────────────────────────────────────
TEMPO_PORT=3200
pf "${LGTM_NS}" "svc/${TEMPO_SVC}" "${TEMPO_PORT}" 3200
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
