#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

current_context() {
  if [[ -n "${PLATFORM_TEST_CURRENT_CONTEXT:-}" ]]; then
    printf '%s\n' "${PLATFORM_TEST_CURRENT_CONTEXT}"
    return 0
  fi
  kubectl_command 10s config current-context
}

main() {
  local actual
  if [[ "${KUBECONFIG}" != "${PLATFORM_STATE_DIR}/kubeconfig" ]]; then
    printf 'FAIL  kube-guard    unexpected kubeconfig: %s\n' "${KUBECONFIG}" >&2
    return 1
  fi
  if [[ -z "${PLATFORM_TEST_CURRENT_CONTEXT:-}" ]]; then
    if [[ ! -f "${KUBECONFIG}" || -L "${KUBECONFIG}" ]]; then
      printf 'FAIL  kube-guard    project kubeconfig is missing or a symlink\n' >&2
      return 1
    fi
  fi
  actual="$(current_context)"
  if [[ "${actual}" != "${PLATFORM_CONTEXT}" ]]; then
    printf 'FAIL  kube-guard    expected %s, got %s\n' "${PLATFORM_CONTEXT}" "${actual}" >&2
    return 1
  fi
  printf 'PASS  kube-guard    %s\n' "${actual}"
}

main "$@"
