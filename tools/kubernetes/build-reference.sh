#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

main() {
  local output="${PLATFORM_STATE_DIR}/reference/server"
  local binary_sha
  require_tool go
  require_tool docker

  mkdir -p "$(dirname -- "${output}")"
  rm -f "${output}"
  (
    cd "${PLATFORM_ROOT}/kubernetes/reference/server"
    run_bounded 90s env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -buildvcs=false -trimpath -ldflags='-s -w -buildid=' -o "${output}" .
  )
  binary_sha="$(sha256sum "${output}" | cut -d ' ' -f 1)"
  docker_command 120s build --network=none --pull=false \
    --file "${PLATFORM_ROOT}/kubernetes/reference/Dockerfile" \
    --tag "${PLATFORM_IMAGE}" "${PLATFORM_ROOT}"
  printf 'PASS  image         %s binary_sha256=%s\n' "${PLATFORM_IMAGE}" "${binary_sha}"
}

main "$@"
