#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

cleanup() {
  "${PLATFORM_ROOT}/tools/kubernetes/kind-down.sh" --if-present || true
}

main() {
  trap cleanup EXIT
  "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh"
  "${PLATFORM_ROOT}/tools/kubernetes/negative-smoke.sh"
}

main "$@"
