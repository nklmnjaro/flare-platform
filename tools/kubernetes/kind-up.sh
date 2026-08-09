#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${PLATFORM_CLUSTER_NAME}"
}

main() {
  require_tool kind
  require_tool kubectl
  command -v docker >/dev/null 2>&1 || {
    printf 'FAIL  kind-up       docker is required\n' >&2
    return 1
  }
  docker info >/dev/null
  mkdir -p "${PLATFORM_STATE_DIR}"

  if cluster_exists; then
    kind export kubeconfig --name "${PLATFORM_CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}"
    "${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"
  else
    kind create cluster \
      --name "${PLATFORM_CLUSTER_NAME}" \
      --config "${PLATFORM_ROOT}/clusters/kind/kind.yaml" \
      --kubeconfig "${KUBECONFIG}" \
      --wait 120s
    "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
    kubectl apply -f "${PLATFORM_ROOT}/clusters/kind/ownership.yaml"
    "${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"
  fi

  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
  kubectl wait --for=condition=Ready nodes --all --timeout=60s
  printf 'PASS  kind-up       %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
