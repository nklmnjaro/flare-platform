#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${PLATFORM_CLUSTER_NAME}"
}

main() {
  local if_present=false
  [[ "${1:-}" == "--if-present" ]] && if_present=true

  if ! command -v kind >/dev/null 2>&1; then
    [[ "${if_present}" == true ]] && return 0
    printf 'FAIL  kind-down     kind is missing; run make bootstrap\n' >&2
    return 1
  fi

  if ! cluster_exists; then
    rm -f "${KUBECONFIG}"
    printf 'PASS  kind-down     cluster already absent\n'
    return 0
  fi

  command -v kubectl >/dev/null 2>&1 || {
    printf 'FAIL  kind-down     kubectl is required for ownership proof\n' >&2
    return 1
  }
  mkdir -p "${PLATFORM_STATE_DIR}"
  kind export kubeconfig --name "${PLATFORM_CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"
  kind delete cluster --name "${PLATFORM_CLUSTER_NAME}"
  rm -f "${KUBECONFIG}"
  printf 'PASS  kind-down     deleted owned cluster %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
