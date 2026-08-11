#!/bin/bash -p
set -euo pipefail

KIND_UP_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${KIND_UP_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || KIND_UP_SOURCE_DIR=.
builtin source "${KIND_UP_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
unset KIND_UP_SOURCE_DIR

CREATED_BY_THIS_RUN=false
CREATE_COMPLETE=false
KUBECONFIG_PREPARED=false

cleanup_failed_creation() {
  if [[ "${KUBECONFIG_PREPARED}" == true ]]; then
    run_host_command rm -f -- "${KUBECONFIG}"
  fi
  if [[ "${CREATED_BY_THIS_RUN}" == true && "${CREATE_COMPLETE}" == false ]]; then
    printf 'WARN  kind-up       removing incomplete cluster created by this run\n' >&2
    if kind_command 120s delete cluster \
      --name "${PLATFORM_CLUSTER_NAME}" >/dev/null; then
      :
    else
      printf 'WARN  kind-up       incomplete cluster cleanup failed status=%s\n' \
        "$?" >&2
    fi
  fi
}

export_owned_cluster() {
  prepare_kubeconfig_output
  KUBECONFIG_PREPARED=true
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

create_cluster() {
  prepare_kubeconfig_output
  KUBECONFIG_PREPARED=true
  kind_command 180s create cluster \
    --name "${PLATFORM_CLUSTER_NAME}" \
    --config "${PLATFORM_ROOT}/clusters/kind/kind.yaml" \
    --kubeconfig "${KUBECONFIG}" \
    --wait 120s
  CREATED_BY_THIS_RUN=true
  run_host_command chmod 600 "${KUBECONFIG}"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
  kubectl_command 30s apply -f "${PLATFORM_ROOT}/clusters/kind/ownership.yaml"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"
}

main() {
  local presence
  docker_target_ensure || return
  require_tool kind
  require_tool kubectl
  docker_command 20s info >/dev/null
  umask 077
  ensure_state_directory "" || return
  trap cleanup_failed_creation EXIT

  presence="$(cluster_presence)"
  if [[ "${presence}" == present ]]; then
    export_owned_cluster
  else
    create_cluster
  fi

  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
  kubectl_command 90s wait --for=condition=Ready nodes --all --timeout=60s
  CREATE_COMPLETE=true
  trap - EXIT
  printf 'PASS  kind-up       %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
