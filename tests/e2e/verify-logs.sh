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
