#!/usr/bin/env bash
# Verify Grafana is healthy and all three LGTM datasources are provisioned
# AND pass Grafana's own datasource health check. Uses admin basic auth;
# OAuth being enabled on the deployment does not affect the local API.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/e2e/lib.sh
source "${HERE}/lib.sh"

LPORT=3000
pf "${LGTM_NS}" "svc/${GRAFANA_SVC}" "${LPORT}" 80
BASE="http://127.0.0.1:${LPORT}"
AUTH=(-u "${GRAFANA_USER}:${GRAFANA_PASS}")

echo "=== Grafana /api/health ==="
# Grafana may take a moment after pod-ready to serve a healthy DB; poll.
# (Functions passed to retry rather than `bash -c` strings: the script's
# `set -o pipefail` already covers the curl|jq pipe, and argv stays unquoted-safe.)
# shellcheck disable=SC2329  # invoked indirectly via retry "$@"
health_ok() { curl -sf "${BASE}/api/health" | jq -e '.database == "ok"' >/dev/null; }
retry 120 "grafana database healthy" health_ok

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
# shellcheck disable=SC2329  # invoked indirectly via retry "$@"
ds_health_ok() {
  curl -sf "${AUTH[@]}" "${BASE}/api/datasources/uid/${1}/health" \
    | jq -e '.status == "OK"' >/dev/null
}
for name in Loki Tempo Mimir; do
  uid="$(echo "${DS_JSON}" | jq -r --arg n "${name}" '.[] | select(.name==$n) | .uid')"
  retry 120 "${name} datasource health" ds_health_ok "${uid}"
done

echo "OK: Grafana healthy and Loki/Tempo/Mimir datasources are working."
