#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

check_generated_state() {
  if git ls-files '.platform/**' | grep -q .; then
    printf 'FAIL  policy        .platform state must never be tracked\n' >&2
    return 1
  fi
}

main() {
  local failed=0
  check_generated_state || failed=1
  git diff --check || failed=1
  git diff --cached --check || failed=1
  if ((failed)); then
    return 1
  fi
  printf 'PASS  policy        repository invariants\n'
}

main "$@"
