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
  run_bounded "${duration}" kind "$@"
}

kubectl_command() {
  local duration="$1"
  shift
  run_bounded "${duration}" kubectl --request-timeout=10s "$@"
}

docker_command() {
  local duration="$1"
  shift
  run_bounded "${duration}" docker "$@"
}

prepare_kubeconfig_output() {
  local expected="${PLATFORM_STATE_DIR}/kubeconfig"
  if [[ "${KUBECONFIG}" != "${expected}" ]]; then
    printf 'FAIL  kube-guard    unexpected kubeconfig output: %s\n' "${KUBECONFIG}" >&2
    return 1
  fi
  if [[ -L "${PLATFORM_STATE_DIR}" ]]; then
    printf 'FAIL  kube-guard    project state directory must not be a symlink\n' >&2
    return 1
  fi
  mkdir -p "${PLATFORM_STATE_DIR}"
  if [[ -L "${KUBECONFIG}" || (-e "${KUBECONFIG}" && ! -f "${KUBECONFIG}") ]]; then
    printf 'FAIL  kube-guard    refusing unsafe kubeconfig output path\n' >&2
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
