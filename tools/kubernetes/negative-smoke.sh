#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

cleanup() {
  kubectl delete namespace "${PLATFORM_NAMESPACE}" --wait=true --timeout=30s >/dev/null 2>&1 || true
}

main() {
  local fixture="${PLATFORM_ROOT}/tests/fixtures/kubernetes/failing-workload.yaml"
  "${PLATFORM_ROOT}/tools/kubernetes/kind-up.sh"
  "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  kind load docker-image "${PLATFORM_IMAGE}" --name "${PLATFORM_CLUSTER_NAME}"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"

  kubectl apply -f "${PLATFORM_ROOT}/kubernetes/reference/namespace.yaml"
  kubectl apply -f "${fixture}"

  if kubectl -n "${PLATFORM_NAMESPACE}" rollout status deployment/platform-reference --timeout=15s; then
    cleanup
    printf 'FAIL  kind-negative failing workload unexpectedly became ready\n' >&2
    return 1
  fi

  "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh"
  cleanup
  printf 'PASS  kind-negative failure detected and bounded diagnostics captured\n'
}

main "$@"
