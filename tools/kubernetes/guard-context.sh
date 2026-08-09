#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

current_context() {
  if [[ -n "${PLATFORM_TEST_CURRENT_CONTEXT:-}" ]]; then
    printf '%s\n' "${PLATFORM_TEST_CURRENT_CONTEXT}"
    return 0
  fi
  kubectl config current-context
}

main() {
  local actual
  if [[ "${KUBECONFIG}" != "${PLATFORM_STATE_DIR}/kubeconfig" ]]; then
    printf 'FAIL  kube-guard    unexpected kubeconfig: %s\n' "${KUBECONFIG}" >&2
    return 1
  fi
  actual="$(current_context)"
  if [[ "${actual}" != "${PLATFORM_CONTEXT}" ]]; then
    printf 'FAIL  kube-guard    expected %s, got %s\n' "${PLATFORM_CONTEXT}" "${actual}" >&2
    return 1
  fi
  printf 'PASS  kube-guard    %s\n' "${actual}"
}

main "$@"
