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
