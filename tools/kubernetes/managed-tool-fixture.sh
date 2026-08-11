#!/bin/bash -p

# Explicit dependency adapter for isolated Kubernetes shell fixtures only.
# Production scripts never source this file.

MANAGED_TOOL_FIXTURE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${MANAGED_TOOL_FIXTURE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  MANAGED_TOOL_FIXTURE_SOURCE_DIR=.
# shellcheck source=../common/tooling.sh
builtin source "${MANAGED_TOOL_FIXTURE_SOURCE_DIR}/tooling-production.sh"
unset MANAGED_TOOL_FIXTURE_SOURCE_DIR

MANAGED_TOOL_TEST_ADAPTER_STATUS=78
MANAGED_TOOL_TEST_CONTRACT_EXPECTED="flare-platform-runtime-fixture-v1"
MANAGED_TOOL_TEST_ADAPTER_SOURCE="$(run_host_command readlink -f -- \
  "${BASH_SOURCE[0]}")" || return

managed_tool_fixture_fail() {
  printf 'FAIL  runtime-test  %s\n' "$*" >&2
  return "${MANAGED_TOOL_TEST_ADAPTER_STATUS}"
}

managed_tool_fixture_root() {
  local requested="${PLATFORM_RUNTIME_TEST_ROOT-}"
  local expected="${PLATFORM_ROOT}/.platform/aqua/test-fixtures"
  local production="${PLATFORM_ROOT}/tools/common/tooling-production.sh"
  local canonical marker_size requested_canonical
  local token="${PLATFORM_RUNTIME_TEST_TOKEN-}"
  local -a owner_lines=()
  if [[ "${PLATFORM_RUNTIME_TEST_CONTRACT-}" != "${MANAGED_TOOL_TEST_CONTRACT_EXPECTED}" ||
    "${MANAGED_TOOL_TEST_ADAPTER_SOURCE}" != "${PLATFORM_ROOT}/tools/common/tooling.sh" ||
    "${requested}" != "${expected}" || -L "${requested}" ||
    ! -d "${requested}" || -z "${token}" ||
    ! "${token}" =~ ^[0-9A-Za-z._:-]{8,128}$ ]]; then
    managed_tool_fixture_fail 'exact fixture contract or repository root is absent'
    return
  fi
  requested_canonical="$(run_host_command readlink -f -- "${requested}")" || {
    managed_tool_fixture_fail 'fixture root cannot be canonicalized'
    return
  }
  canonical="$(run_host_command readlink -f -- "${production}")" || {
    managed_tool_fixture_fail 'production tooling dependency cannot be canonicalized'
    return
  }
  if [[ "${requested_canonical}" != "${requested}" ||
    "${canonical}" != "${production}" || -L "${production}" ||
    ! -f "${production}" || -L "${requested}/.runtime-fixture-owner" ||
    ! -f "${requested}/.runtime-fixture-owner" ]]; then
    managed_tool_fixture_fail 'fixture dependency source or owner is unsafe'
    return
  fi
  mapfile -t owner_lines <"${requested}/.runtime-fixture-owner" || {
    managed_tool_fixture_fail 'fixture ownership marker is unreadable'
    return
  }
  marker_size="$(run_host_command stat -Lc '%s' -- \
    "${requested}/.runtime-fixture-owner")" || {
    managed_tool_fixture_fail 'fixture ownership marker size is unavailable'
    return
  }
  if [[ "${#owner_lines[@]}" -ne 1 || "${owner_lines[0]}" != "${token}" ||
    "${marker_size}" != "$((${#token} + 1))" ]]; then
    managed_tool_fixture_fail 'fixture ownership marker differs'
    return
  fi
  printf '%s\n' "${requested}"
}

resolve_managed_tool() {
  local command_name="$1"
  local fixture_root candidate resolved
  is_managed_tool "${command_name}" || return 2
  fixture_root="$(managed_tool_fixture_root)" || return
  candidate="${fixture_root}/${command_name}"
  if [[ -L "${candidate}" || ! -f "${candidate}" || ! -x "${candidate}" ]]; then
    managed_tool_fixture_fail "fixture command is unsafe: ${command_name}"
    return
  fi
  resolved="$(run_host_command readlink -f -- "${candidate}")" || {
    managed_tool_fixture_fail "fixture command cannot be canonicalized: ${command_name}"
    return
  }
  case "${resolved}" in
    "${fixture_root}"/*) ;;
    *)
      managed_tool_fixture_fail "fixture command escaped its root: ${command_name}"
      return
      ;;
  esac
  # Published for the production tooling module that sourced this adapter.
  # shellcheck disable=SC2034
  MANAGED_TOOL_PATH="${candidate}"
}

run_managed_tool() {
  local command_name="${1:-}"
  (($# > 0)) || return "${HOST_COMMAND_USAGE_STATUS}"
  shift
  resolve_managed_tool "${command_name}" || return
  "${MANAGED_TOOL_PATH}" "$@"
}

run_managed_tool_bounded() {
  local duration="${1:-}" command_name="${2:-}"
  (($# >= 2)) || return "${HOST_COMMAND_USAGE_STATUS}"
  shift 2
  aqua_validate_bounded_duration "${duration}" || return
  resolve_managed_tool "${command_name}" || return
  run_host_command timeout --signal=TERM --kill-after=2s \
    "${duration}" "${MANAGED_TOOL_PATH}" "$@"
}
