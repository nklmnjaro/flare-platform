#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

base_only=false
[[ "${1:-}" == "--base-only" ]] && base_only=true

is_forced_missing() {
  [[ ",${PLATFORM_TEST_FORCE_MISSING:-}," == *",$1,"* ]]
}

has_command() {
  ! is_forced_missing "$1" && command -v "$1" >/dev/null 2>&1
}

require_command() {
  local command_name="$1"
  if has_command "${command_name}"; then
    printf 'PASS  %-12s %s\n' "${command_name}" "$(command -v "${command_name}")"
    return 0
  fi
  printf 'FAIL  %-12s missing\n' "${command_name}" >&2
  return 1
}

check_docker() {
  require_command docker || return 1
  if ! timeout 15s docker info >/dev/null 2>&1; then
    printf 'FAIL  docker       daemon is not reachable within 15s\n' >&2
    return 1
  fi
}

main() {
  local failed=0
  local command_name
  local base=(awk bash curl cut find git grep gzip head make mktemp sed sha256sum sort tar timeout tr uname wc)

  if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
    printf 'FAIL  platform     supported target is Linux x86_64\n' >&2
    return 1
  fi
  printf 'PASS  platform     Linux x86_64\n'

  for command_name in "${base[@]}"; do
    require_command "${command_name}" || failed=1
  done
  if [[ "${base_only}" == false ]]; then
    check_docker || failed=1
  fi
  return "${failed}"
}

main "$@"
