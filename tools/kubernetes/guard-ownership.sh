#!/bin/bash -p
set -euo pipefail

GUARD_OWNERSHIP_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${GUARD_OWNERSHIP_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  GUARD_OWNERSHIP_SOURCE_DIR=.
builtin source "${GUARD_OWNERSHIP_SOURCE_DIR}/ownership.sh"
builtin unset GUARD_OWNERSHIP_SOURCE_DIR

main() {
  ownership_current_checkout_snapshot >/dev/null || return
  printf 'PASS  ownership     checkout-bound %s\n' \
    "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
