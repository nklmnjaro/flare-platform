#!/bin/bash -p
set -euo pipefail

KIND_UP_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${KIND_UP_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || KIND_UP_SOURCE_DIR=.
builtin source "${KIND_UP_SOURCE_DIR}/ownership.sh"
builtin unset KIND_UP_SOURCE_DIR

CREATED_BY_THIS_RUN=false
MARKER_PUBLISHED_BY_THIS_RUN=false
CREATE_COMPLETE=false
KUBECONFIG_PREPARED=false
CREATED_OWNERSHIP_SNAPSHOT=''
ACTIVE_OWNERSHIP_SNAPSHOT=''

cleanup_failed_creation() {
  local status=$? presence=unknown cleanup_confirmed=false
  trap - EXIT
  set +e
  if [[ "${CREATED_BY_THIS_RUN}" == true &&
    "${MARKER_PUBLISHED_BY_THIS_RUN}" == true &&
    "${CREATE_COMPLETE}" == false &&
    -n "${CREATED_OWNERSHIP_SNAPSHOT}" ]]; then
    printf 'WARN  kind-up       validating incomplete cluster before cleanup\n' >&2
    if ownership_recheck_snapshot \
      "${CREATED_OWNERSHIP_SNAPSHOT}" >/dev/null; then
      if kind_command 120s delete cluster \
        --name "${PLATFORM_CLUSTER_NAME}" >/dev/null; then
        presence="$(cluster_presence)"
        [[ "${presence}" == absent ]] && cleanup_confirmed=true
      else
        presence="$(cluster_presence)"
        [[ "${presence}" == absent ]] && cleanup_confirmed=true
      fi
    else
      printf 'WARN  kind-up       ownership changed; incomplete cluster preserved\n' >&2
    fi
  elif [[ "${CREATED_BY_THIS_RUN}" == true &&
    "${CREATE_COMPLETE}" == false ]]; then
    printf 'WARN  kind-up       no cleanup authority; incomplete cluster preserved\n' >&2
  fi

  if [[ "${cleanup_confirmed}" == true ]]; then
    if run_host_command rm -f -- "${KUBECONFIG}"; then
      printf 'WARN  kind-up       removed authorized incomplete cluster\n' >&2
    else
      printf 'WARN  kind-up       cluster removed; kubeconfig cleanup failed\n' >&2
    fi
  elif [[ "${KUBECONFIG_PREPARED}" == true ]]; then
    printf 'WARN  kind-up       kubeconfig retained for safe diagnosis\n' >&2
  fi
  exit "${status}"
}

export_owned_cluster() {
  prepare_kubeconfig_output || return
  KUBECONFIG_PREPARED=true
  if ! kind_command 30s export kubeconfig --name "${PLATFORM_CLUSTER_NAME}" \
    --kubeconfig "${KUBECONFIG}"; then
    return 1
  fi
  run_host_command chmod 600 "${KUBECONFIG}" || return
  ACTIVE_OWNERSHIP_SNAPSHOT="$(ownership_current_checkout_snapshot)"
}

create_cluster() {
  prepare_kubeconfig_output || return
  KUBECONFIG_PREPARED=true
  kind_command 180s create cluster \
    --name "${PLATFORM_CLUSTER_NAME}" \
    --config "${PLATFORM_ROOT}/clusters/kind/kind.yaml" \
    --kubeconfig "${KUBECONFIG}" \
    --wait 120s
  CREATED_BY_THIS_RUN=true
  run_host_command chmod 600 "${KUBECONFIG}" || return
  install_ownership_marker
  MARKER_PUBLISHED_BY_THIS_RUN=true
  CREATED_OWNERSHIP_SNAPSHOT="$(ownership_current_checkout_snapshot)"
  ACTIVE_OWNERSHIP_SNAPSHOT="${CREATED_OWNERSHIP_SNAPSHOT}"
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
  ownership_recheck_snapshot "${ACTIVE_OWNERSHIP_SNAPSHOT}" >/dev/null
  CREATE_COMPLETE=true
  trap - EXIT
  printf 'PASS  kind-up       %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
