#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

prove_home_path_rejection() {
  local output="${PLATFORM_STATE_DIR}/artifact-home-path-red.zip"
  rm -f "${output}" "${output}.sha256"
  if (
    cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    go run . pack \
      --source "${PLATFORM_ROOT}/tests/fixtures/artifacts/home-path" \
      --output "${output}"
  ) >/dev/null 2>&1; then
    printf 'FAIL  artifact-red  workstation home path unexpectedly passed\n' >&2
    return 1
  fi
  printf 'PASS  artifact-red  workstation home path rejected\n'
}

main() {
  require_tool go
  (
    cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    go test -run 'TestVerifyRejectsTamperedContent|TestDetachedChecksumRejectsArchiveMutation' -v ./...
  )
  prove_home_path_rejection
  printf 'PASS  artifact-red  integrity mutations rejected\n'
}

main "$@"
