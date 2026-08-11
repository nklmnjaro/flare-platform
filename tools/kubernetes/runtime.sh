#!/usr/bin/env bash
set -euo pipefail

run_bounded() {
  local duration="$1"
  shift
  timeout --signal=TERM --kill-after=5s "${duration}" "$@"
}

kind_command() {
  local duration="$1"
  shift
  local command_path
  command_path="$(managed_tool_path kind)" || return
  run_bounded "${duration}" "${command_path}" "$@"
}

kubectl_command() {
  local duration="$1"
  shift
  local command_path
  command_path="$(managed_tool_path kubectl)" || return
  run_bounded "${duration}" "${command_path}" --request-timeout=10s "$@"
}

docker_command() {
  local duration="$1"
  shift
  run_bounded "${duration}" docker "$@"
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
  rm -f "${KUBECONFIG}"
}

cluster_presence() {
  local clusters
  clusters="$(kind_command 20s get clusters)" || {
    printf 'FAIL  kind-state    unable to list kind clusters\n' >&2
    return 1
  }
  if grep -Fxq "${PLATFORM_CLUSTER_NAME}" <<<"${clusters}"; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}
