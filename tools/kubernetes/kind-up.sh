#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

CREATED_BY_THIS_RUN=false
CREATE_COMPLETE=false
KUBECONFIG_PREPARED=false

cleanup_failed_creation() {
  if [[ "${KUBECONFIG_PREPARED}" == true ]]; then
    rm -f "${KUBECONFIG}"
  fi
  if [[ "${CREATED_BY_THIS_RUN}" == true && "${CREATE_COMPLETE}" == false ]]; then
    printf 'WARN  kind-up       removing incomplete cluster created by this run\n' >&2
    kind_command 120s delete cluster --name "${PLATFORM_CLUSTER_NAME}" >/dev/null 2>&1 || true
  fi
}

export_owned_cluster() {
  prepare_kubeconfig_output
  KUBECONFIG_PREPARED=true
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

create_cluster() {
  prepare_kubeconfig_output
  KUBECONFIG_PREPARED=true
  kind_command 180s create cluster \
    --name "${PLATFORM_CLUSTER_NAME}" \
    --config "${PLATFORM_ROOT}/clusters/kind/kind.yaml" \
    --kubeconfig "${KUBECONFIG}" \
    --wait 120s
  CREATED_BY_THIS_RUN=true
  chmod 600 "${KUBECONFIG}"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
  kubectl_command 30s apply -f "${PLATFORM_ROOT}/clusters/kind/ownership.yaml"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"
}

main() {
  local presence
  require_tool kind
  require_tool kubectl
  require_tool docker
  docker_command 20s info >/dev/null
  umask 077
  mkdir -p "${PLATFORM_STATE_DIR}"
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
