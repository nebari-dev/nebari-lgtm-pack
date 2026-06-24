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

# pf <namespace> <target> <local_port> <remote_port>
# Backgrounds `kubectl port-forward` and blocks until the local port accepts
# connections (max ~20s). Records the PID for cleanup on exit. <target> is a
# kubectl port-forward target ref, e.g. "svc/my-svc" or "pod/my-pod" — the
# collector is a serviceless DaemonSet, so its OTLP receiver must be reached
# via a pod target.
# NOTE: the local listener binds as soon as the forward starts, before the
# upstream backend is necessarily serving. This readiness check is a best-effort
# guard, NOT a guarantee the backend is ready — callers must still poll the
# actual API via retry().
pf() {
  local ns="$1" target="$2" lport="$3" rport="$4"
  kubectl -n "${ns}" port-forward "${target}" "${lport}:${rport}" >/dev/null 2>&1 &
  local pid=$!
  _PF_PIDS+=("${pid}")
  for _ in $(seq 1 40); do
    if curl -sf -o /dev/null "http://127.0.0.1:${lport}" 2>/dev/null \
       || nc -z 127.0.0.1 "${lport}" 2>/dev/null; then
      return 0
    fi
    # Bail early if the port-forward process already died.
    kill -0 "${pid}" 2>/dev/null || { echo "port-forward to ${target} died"; return 1; }
    sleep 0.5
  done
  echo "timed out waiting for port-forward ${target} :${lport}"
  return 1
}

# otel_pod -> name of a Running NIC OpenTelemetry collector pod in MON_NS.
# NIC deploys the collector as a DaemonSet (no Service), so callers port-forward
# directly to a pod to reach its OTLP receiver. Matches by name prefix
# (opentelemetry-collector*) rather than a label, since labels vary across NIC
# versions. Echoes the pod name, or empty if none found.
otel_pod() {
  kubectl -n "${MON_NS}" get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | awk '$2=="Running" && $1 ~ /^opentelemetry-collector/ {print $1; exit}'
}

# ensure_otel_pf <local_port> -> guarantees a live port-forward to a CURRENT
# collector pod's OTLP/HTTP receiver (4318) on <local_port>, re-resolving the
# pod and re-forwarding if the previous one died. The collector DaemonSet pod
# is replaced on rollouts (e.g. the chart's post-install rollout, or platform
# upgrades), which would otherwise kill a pinned port-forward mid-check and make
# every push silently fail. Call this before each push so a retry loop recovers
# within one cycle. Returns non-zero if no Running collector pod is available
# yet (caller's retry will try again).
_OTEL_PF_PID=""
ensure_otel_pf() {
  local lport="$1" pod
  if [[ -n "${_OTEL_PF_PID}" ]] && kill -0 "${_OTEL_PF_PID}" 2>/dev/null \
     && nc -z 127.0.0.1 "${lport}" 2>/dev/null; then
    return 0
  fi
  pod="$(otel_pod)"
  [[ -n "${pod}" ]] || return 1
  kubectl -n "${MON_NS}" port-forward "pod/${pod}" "${lport}:4318" >/dev/null 2>&1 &
  _OTEL_PF_PID=$!
  _PF_PIDS+=("${_OTEL_PF_PID}")
  for _ in $(seq 1 20); do
    nc -z 127.0.0.1 "${lport}" 2>/dev/null && return 0
    kill -0 "${_OTEL_PF_PID}" 2>/dev/null || return 1
    sleep 0.5
  done
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
