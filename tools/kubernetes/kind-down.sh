#!/bin/bash -p
set -euo pipefail

KIND_DOWN_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${KIND_DOWN_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || KIND_DOWN_SOURCE_DIR=.
builtin source "${KIND_DOWN_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
unset KIND_DOWN_SOURCE_DIR

export_owned_cluster() {
  prepare_kubeconfig_output
  if ! kind_command 30s export kubeconfig --name "${PLATFORM_CLUSTER_NAME}" \
    --kubeconfig "${KUBECONFIG}"; then
    run_host_command rm -f -- "${KUBECONFIG}"
    return 1
  fi
  run_host_command chmod 600 "${KUBECONFIG}"
  if ! "${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"; then
    run_host_command rm -f -- "${KUBECONFIG}"
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

  if ! require_tool kind >/dev/null 2>&1; then
    if [[ "${if_present}" == true && ! -e "${KUBECONFIG}" && ! -L "${KUBECONFIG}" ]]; then
      printf 'PASS  kind-down     no local cluster state; no mutation attempted\n'
      return 0
    fi
    require_tool kind
    return 1
  fi

  docker_target_ensure || return
  presence="$(cluster_presence)"
  if [[ "${presence}" == absent ]]; then
    run_host_command rm -f -- "${KUBECONFIG}"
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
  run_host_command rm -f -- "${KUBECONFIG}"
  printf 'PASS  kind-down     deleted owned cluster %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
