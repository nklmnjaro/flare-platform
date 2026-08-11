#!/bin/bash -p
set -euo pipefail

KIND_DOWN_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${KIND_DOWN_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || KIND_DOWN_SOURCE_DIR=.
builtin source "${KIND_DOWN_SOURCE_DIR}/ownership.sh"
builtin source "${PLATFORM_ROOT}/tools/common/lifecycle-lease.sh"
builtin unset KIND_DOWN_SOURCE_DIR

cleanup_lifecycle_lease() {
  local status=$? lease_status=0
  trap - EXIT
  lifecycle_lease_clear_interrupt_traps
  lifecycle_lease_release || lease_status=$?
  ((status != 0)) || status="${lease_status}"
  exit "${status}"
}

export_owned_cluster() {
  prepare_kubeconfig_output || return
  if ! kind_command 30s export kubeconfig --name "${PLATFORM_CLUSTER_NAME}" \
    --kubeconfig "${KUBECONFIG}" >/dev/null; then
    return 1
  fi
  run_host_command chmod 600 "${KUBECONFIG}" || return
  ownership_current_checkout_snapshot
}

main() {
  local presence ownership_snapshot
  local if_present=false
  [[ "${1:-}" == "--if-present" ]] && if_present=true
  if [[ $# -gt 1 || ($# -eq 1 && "${1:-}" != "--if-present") ]]; then
    printf 'FAIL  kind-down     only --if-present is accepted\n' >&2
    return 2
  fi
  lifecycle_lease_acquire kind-down || return
  trap cleanup_lifecycle_lease EXIT
  lifecycle_lease_install_interrupt_traps

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
  ownership_snapshot="$(export_owned_cluster)" || {
    printf 'WARN  kind-down     kubeconfig retained for safe diagnosis\n' >&2
    return 1
  }
  ownership_recheck_snapshot "${ownership_snapshot}" >/dev/null
  kind_command 120s delete cluster --name "${PLATFORM_CLUSTER_NAME}"

  presence="$(cluster_presence)"
  if [[ "${presence}" != absent ]]; then
    printf 'FAIL  kind-down     cluster still exists after delete\n' >&2
    return 1
  fi
  run_host_command rm -f -- "${KUBECONFIG}"
  printf 'PASS  kind-down     deleted owned cluster %s\n' "${PLATFORM_CLUSTER_NAME}"
  lifecycle_lease_release || return
  trap - EXIT
  lifecycle_lease_clear_interrupt_traps
}

main "$@"
