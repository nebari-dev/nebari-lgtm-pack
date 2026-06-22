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
