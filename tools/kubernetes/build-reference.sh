#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

main() {
  local output="${PLATFORM_STATE_DIR}/reference/server"
  require_tool go
  command -v docker >/dev/null 2>&1 || {
    printf 'FAIL  image         docker is required\n' >&2
    return 1
  }

  mkdir -p "$(dirname -- "${output}")"
  (
    cd "${PLATFORM_ROOT}/kubernetes/reference/server"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -trimpath -ldflags='-s -w -buildid=' -o "${output}" .
  )
  docker build --network=none \
    --file "${PLATFORM_ROOT}/kubernetes/reference/Dockerfile" \
    --tag "${PLATFORM_IMAGE}" "${PLATFORM_ROOT}"
  printf 'PASS  image         built %s without build-network access\n' "${PLATFORM_IMAGE}"
}

main "$@"
