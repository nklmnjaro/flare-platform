#!/bin/bash -p
set -euo pipefail

CLEAN_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${CLEAN_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || CLEAN_SOURCE_DIR=.
builtin source "${CLEAN_SOURCE_DIR}/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/lifecycle-lease.sh"
builtin unset CLEAN_SOURCE_DIR

cleanup_lifecycle_lease() {
  local status=$? lease_status=0
  trap - EXIT
  lifecycle_lease_clear_interrupt_traps
  lifecycle_lease_release || lease_status=$?
  ((status != 0)) || status="${lease_status}"
  exit "${status}"
}

main() {
  (($# == 0)) || {
    printf 'FAIL  clean         no arguments are accepted\n' >&2
    return 2
  }
  lifecycle_lease_acquire clean || return
  trap cleanup_lifecycle_lease EXIT
  lifecycle_lease_install_interrupt_traps
  "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present || return
  lifecycle_lease_assert || return
  run_host_command rm -rf -- "${PLATFORM_STATE_DIR}" || return
  lifecycle_lease_assert || return
  printf 'PASS  clean         project-local generated state removed\n'
  lifecycle_lease_release || return
  trap - EXIT
  lifecycle_lease_clear_interrupt_traps
}

main "$@"
