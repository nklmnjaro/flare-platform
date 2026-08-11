#!/bin/bash -p
set -euo pipefail

VERIFY_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${VERIFY_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || VERIFY_SOURCE_DIR=.
builtin source "${VERIFY_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
builtin source "${PLATFORM_ROOT}/tools/common/lifecycle-lease.sh"
unset VERIFY_SOURCE_DIR

emergency_teardown() {
  local status=$? lease_status=0
  lifecycle_lease_clear_interrupt_traps
  if [[ "${LIFECYCLE_LEASE_INTERRUPTED}" != true ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present \
      >/dev/null 2>&1 || true
  fi
  lifecycle_lease_release || lease_status=$?
  ((status != 0)) || status="${lease_status}"
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
  local action=verify-runtime
  local final_cluster_state=unknown repeated_cluster_state=unknown
  if [[ "${1:-}" == --action ]]; then
    [[ $# -eq 2 && ("${2}" == verify || "${2}" == verify-runtime) ]] || {
      printf 'FAIL  verify-runtime usage: verify.sh [--action verify|verify-runtime]\n' >&2
      return 2
    }
    action="${2}"
  elif (($#)); then
    printf 'FAIL  verify-runtime usage: verify.sh [--action verify|verify-runtime]\n' >&2
    return 2
  fi
  lifecycle_lease_acquire "${action}" || return
  trap emergency_teardown EXIT
  lifecycle_lease_install_interrupt_traps
  docker_target_ensure || return
  "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" || return
  require_tool kind
  require_tool kubectl
  reset_state_directory "diagnostics/raw" || return
  reset_state_directory "runtime-identity" || return
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
  lifecycle_lease_release || return
  trap - EXIT
  lifecycle_lease_clear_interrupt_traps
  printf 'PASS  verify-runtime disposable cluster lifecycle proved\n'
}

main "$@"
