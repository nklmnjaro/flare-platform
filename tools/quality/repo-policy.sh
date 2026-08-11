#!/bin/bash -p
set -euo pipefail

REPO_POLICY_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${REPO_POLICY_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  REPO_POLICY_SOURCE_DIR=.
builtin source "${REPO_POLICY_SOURCE_DIR}/../common/env.sh"
unset REPO_POLICY_SOURCE_DIR

check_generated_state() {
  if run_host_command git ls-files '.platform/**' |
    run_host_command grep -q .; then
    printf 'FAIL  policy        .platform state must never be tracked\n' >&2
    return 1
  fi
}

main() {
  local failed=0
  check_generated_state || failed=1
  run_host_command git diff --no-ext-diff --no-textconv --check || failed=1
  run_host_command git diff --cached --no-ext-diff --no-textconv --check || failed=1
  if ((failed)); then
    return 1
  fi
  printf 'PASS  policy        repository invariants\n'
}

main "$@"
