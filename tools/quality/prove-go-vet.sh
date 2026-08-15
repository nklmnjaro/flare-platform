#!/bin/bash -p
set -euo pipefail

GO_VET_PROOF_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${GO_VET_PROOF_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  GO_VET_PROOF_SOURCE_DIR=.
builtin source "${GO_VET_PROOF_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
unset GO_VET_PROOF_SOURCE_DIR

main() {
  local fixture="${PLATFORM_ROOT}/tests/fixtures/go/vet-invalid"
  local output status
  require_tool go
  reset_state_directory go-vet-proof || return
  output="$(prepare_state_file go-vet-proof/output.txt)" || return
  (
    builtin cd -- "${fixture}"
    run_managed_tool go test -vet=off ./...
  ) >/dev/null
  if (
    builtin cd -- "${fixture}"
    run_managed_tool go vet ./...
  ) >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "${status}" -ne 1 ]] || ! run_host_command grep -Fq \
    'fmt.Printf format %d has arg "wrong-type" of wrong type string' \
    "${output}"; then
    run_host_command sed -n '1,20p' "${output}" >&2 || true
    printf 'FAIL  go-vet-red    intentional printf analyzer fixture drifted\n' >&2
    return 1
  fi
  printf 'PASS  go-vet-red    compiling printf analyzer fixture rejected\n'
}

main "$@"
