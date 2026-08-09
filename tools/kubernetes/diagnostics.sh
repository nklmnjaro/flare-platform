#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

main() {
  local target="${PLATFORM_STATE_DIR}/diagnostics"
  mkdir -p "${target}"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null

  kubectl -n "${PLATFORM_NAMESPACE}" get all -o wide >"${target}/resources.txt" 2>&1 || true
  kubectl -n "${PLATFORM_NAMESPACE}" get events --sort-by=.lastTimestamp \
    >"${target}/events.txt" 2>&1 || true
  kubectl -n "${PLATFORM_NAMESPACE}" describe pods >"${target}/describe-pods.txt" 2>&1 || true
  kubectl -n "${PLATFORM_NAMESPACE}" logs deployment/platform-reference --tail=200 \
    >"${target}/logs.txt" 2>&1 || true
  printf 'INFO  diagnostics   %s\n' "${target}"
}

main "$@"
