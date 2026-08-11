#!/bin/bash -p
set -euo pipefail

RUNTIME_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${RUNTIME_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || RUNTIME_SOURCE_DIR=.
# shellcheck source=../common/docker-target.sh
builtin source "${RUNTIME_SOURCE_DIR}/../common/docker-target.sh"
unset RUNTIME_SOURCE_DIR

run_bounded() {
  local duration="$1"
  shift
  local timeout_path
  timeout_path="$(host_command_path timeout)" || return
  "${timeout_path}" --signal=TERM --kill-after=5s "${duration}" "$@"
}

kind_command() {
  local duration="$1"
  shift
  docker_target_ensure || return
  docker_target_assert_frozen || return
  docker_target_run_child \
    run_managed_tool_bounded "${duration}" kind "$@"
}

kubectl_command() {
  local duration="$1"
  shift
  docker_target_ensure || return
  docker_target_assert_frozen || return
  run_managed_tool_bounded "${duration}" kubectl --request-timeout=10s "$@"
}

docker_command() {
  local duration="$1"
  shift
  local command_path
  docker_target_ensure || return
  command_path="${DOCKER_TARGET_DOCKER_PATH}"
  docker_target_run_bounded "${duration}" "${command_path}" "$@"
}

prepare_kubeconfig_output() {
  local expected="${PLATFORM_STATE_DIR}/kubeconfig"
  local prepared
  if [[ "${KUBECONFIG}" != "${expected}" ]]; then
    printf 'FAIL  kube-guard    unexpected kubeconfig output: %s\n' "${KUBECONFIG}" >&2
    return 1
  fi
  prepared="$(prepare_state_file kubeconfig)" || return
  if [[ "${prepared}" != "${expected}" ]]; then
    printf 'FAIL  kube-guard    state helper returned unexpected kubeconfig path\n' >&2
    return 1
  fi
  run_host_command rm -f -- "${KUBECONFIG}"
}

cluster_presence() {
  local clusters
  clusters="$(kind_command 20s get clusters)" || {
    printf 'FAIL  kind-state    unable to list kind clusters\n' >&2
    return 1
  }
  if run_host_command grep -Fxq \
    "${PLATFORM_CLUSTER_NAME}" <<<"${clusters}"; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}
