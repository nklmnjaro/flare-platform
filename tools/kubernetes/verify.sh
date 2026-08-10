#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

emergency_teardown() {
  local status=$?
  "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present >/dev/null 2>&1 || true
  return "${status}"
}

prove_cluster_absent() {
  local phase="$1"
  local presence
  presence="$(cluster_presence)" || return
  if [[ "${presence}" != absent ]]; then
    printf 'FAIL  verify-runtime cluster_%s=%s\n' "${phase}" "${presence}" >&2
    return 1
  fi
  printf 'PASS  verify-runtime cluster_%s=absent\n' "${phase}"
}

main() {
  local status=0
  local final_cluster_state=unknown repeated_cluster_state=unknown
  reset_state_directory "diagnostics/raw" || return
  reset_state_directory "runtime-identity" || return
  trap emergency_teardown EXIT

  "${PLATFORM_ROOT}/tools/kubernetes/prove-identity.sh" || status=1
  if [[ "${status}" == 0 ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/identity-negative-smoke.sh" || status=1
  fi
  if [[ "${status}" == 0 ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh" || status=1
  fi
  if [[ "${status}" == 0 ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/negative-smoke.sh" || status=1
  fi
  "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present || status=1
  if prove_cluster_absent after_final_teardown; then
    final_cluster_state=absent
  else
    status=1
  fi
  "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present || status=1
  if prove_cluster_absent after_idempotent_teardown; then
    repeated_cluster_state=absent
  else
    status=1
  fi
  if [[ "${status}" == 0 ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/publish-runtime-evidence.sh" \
      "${final_cluster_state}" "${repeated_cluster_state}" || status=1
  fi
  [[ "${status}" == 0 ]] || return 1
  trap - EXIT
  printf 'PASS  verify-runtime disposable cluster lifecycle proved\n'
}

main "$@"
