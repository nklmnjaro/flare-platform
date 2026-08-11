#!/bin/bash -p
set -euo pipefail

GUARD_CONTEXT_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${GUARD_CONTEXT_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  GUARD_CONTEXT_SOURCE_DIR=.
builtin source "${GUARD_CONTEXT_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
builtin unset GUARD_CONTEXT_SOURCE_DIR

current_context() {
  kubectl_command 10s config current-context
}

main() {
  local actual
  if [[ "${KUBECONFIG}" != "${PLATFORM_STATE_DIR}/kubeconfig" ]]; then
    printf 'FAIL  kube-guard    unexpected kubeconfig: %s\n' "${KUBECONFIG}" >&2
    return 1
  fi
  if [[ ! -f "${KUBECONFIG}" || -L "${KUBECONFIG}" ]]; then
    printf 'FAIL  kube-guard    project kubeconfig is missing or a symlink\n' >&2
    return 1
  fi
  actual="$(current_context)" || {
    printf 'FAIL  kube-guard    unable to read current context\n' >&2
    return 1
  }
  if [[ "${actual}" != "${PLATFORM_CONTEXT}" ]]; then
    printf 'FAIL  kube-guard    expected %s, got %s\n' "${PLATFORM_CONTEXT}" "${actual}" >&2
    return 1
  fi
  printf 'PASS  kube-guard    %s\n' "${actual}"
}

main "$@"
