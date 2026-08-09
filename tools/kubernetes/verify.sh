#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

emergency_teardown() {
  local status=$?
  "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present >/dev/null 2>&1 || true
  return "${status}"
}

main() {
  local status=0
  reset_state_directory "diagnostics/raw" || return
  trap emergency_teardown EXIT

  "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh" || status=1
  if [[ "${status}" == 0 ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/negative-smoke.sh" || status=1
  fi
  "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present || status=1
  trap - EXIT
  [[ "${status}" == 0 ]] || return 1
  printf 'PASS  verify-runtime disposable cluster lifecycle proved\n'
}

main "$@"
