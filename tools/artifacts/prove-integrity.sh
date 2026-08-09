#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

prove_home_path_rejection() {
  local fixture log output status
  mkdir -p "${PLATFORM_STATE_DIR}"
  fixture="$(mktemp -d "${PLATFORM_STATE_DIR}/artifact-home-path.XXXXXX")"
  log="$(mktemp "${PLATFORM_STATE_DIR}/artifact-home-path.XXXXXX.log")"
  output="${PLATFORM_STATE_DIR}/artifact-home-path-red.zip"
  printf 'synthetic workstation path: /%s\n' \
    'home/alice/project/worktree' >"${fixture}/leak.txt"
  rm -f "${output}" "${output}.sha256"

  set +e
  (
    cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    go run . pack --source "${fixture}" --output "${output}"
  ) >"${log}" 2>&1
  status=$?
  set -e

  rm -rf "${fixture}"
  rm -f "${output}" "${output}.sha256"
  if ((status == 0)); then
    rm -f "${log}"
    printf 'FAIL  artifact-red  workstation home path unexpectedly passed\n' >&2
    return 1
  fi
  if ! grep -Fq 'home path' "${log}"; then
    cat "${log}" >&2
    rm -f "${log}"
    printf 'FAIL  artifact-red  rejection reason was not home-path policy\n' >&2
    return 1
  fi
  rm -f "${log}"
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
