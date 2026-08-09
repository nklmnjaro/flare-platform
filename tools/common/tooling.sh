#!/usr/bin/env bash
set -euo pipefail

require_tool() {
  local command_name="$1"
  if command -v "${command_name}" >/dev/null 2>&1; then
    return 0
  fi
  printf 'FAIL  tooling       %s missing; run make bootstrap\n' "${command_name}" >&2
  return 1
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL  red-fixture   %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  red-fixture   %s rejected\n' "${label}"
}

expect_success() {
  local label="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL  green-fixture %s unexpectedly failed\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  green-fixture %s accepted\n' "${label}"
}
