#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

export_owned_cluster() {
  prepare_kubeconfig_output
  if ! kind_command 30s export kubeconfig --name "${PLATFORM_CLUSTER_NAME}" \
    --kubeconfig "${KUBECONFIG}"; then
    rm -f "${KUBECONFIG}"
    return 1
  fi
  chmod 600 "${KUBECONFIG}"
  if ! "${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"; then
    rm -f "${KUBECONFIG}"
    return 1
  fi
}

main() {
  local presence
  local if_present=false
  [[ "${1:-}" == "--if-present" ]] && if_present=true
  if [[ $# -gt 1 || ($# -eq 1 && "${1:-}" != "--if-present") ]]; then
    printf 'FAIL  kind-down     only --if-present is accepted\n' >&2
    return 2
  fi

  if ! command -v kind >/dev/null 2>&1; then
    if [[ "${if_present}" == true && ! -e "${KUBECONFIG}" && ! -L "${KUBECONFIG}" ]]; then
      printf 'PASS  kind-down     no local cluster state; no mutation attempted\n'
      return 0
    fi
    require_tool kind
    return 1
  fi

  presence="$(cluster_presence)"
  if [[ "${presence}" == absent ]]; then
    rm -f "${KUBECONFIG}"
    printf 'PASS  kind-down     cluster already absent\n'
    return 0
  fi

  require_tool kubectl
  umask 077
  export_owned_cluster
  kind_command 120s delete cluster --name "${PLATFORM_CLUSTER_NAME}"

  presence="$(cluster_presence)"
  if [[ "${presence}" != absent ]]; then
    printf 'FAIL  kind-down     cluster still exists after delete\n' >&2
    return 1
  fi
  rm -f "${KUBECONFIG}"
  printf 'PASS  kind-down     deleted owned cluster %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
