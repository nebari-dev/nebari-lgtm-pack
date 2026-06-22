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
