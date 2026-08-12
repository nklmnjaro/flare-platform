#!/bin/bash -p
set -euo pipefail

PROVE_STATE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_STATE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_STATE_SOURCE_DIR=.
builtin source "${PROVE_STATE_SOURCE_DIR}/env.sh"
unset PROVE_STATE_SOURCE_DIR

WORK_DIR=""
BASE_PATH="${PLATFORM_HOST_PATH}"

copy_diagnostics_fixture() {
  local target="$1"
  run_host_command mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/diagnostics" "${target}/tools/kubernetes"
  run_host_command cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/docker-target.sh" \
    "${target}/tools/common/docker-target.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/env.sh" \
    "${target}/tools/common/env.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${target}/tools/common/host-commands.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/process-state.sh" \
    "${target}/tools/common/process-state.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/state.sh" \
    "${target}/tools/common/state.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/tooling.sh" \
    "${target}/tools/common/tooling.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/diagnostics/collect.sh" \
    "${target}/tools/diagnostics/collect.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/diagnostics/evidence.sh" \
    "${target}/tools/diagnostics/evidence.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh" \
    "${target}/tools/kubernetes/runtime.sh"
}

run_collect() {
  local target="$1"
  run_host_command env PATH="${BASE_PATH}" \
    "${target}/tools/diagnostics/collect.sh"
}

expect_collect_rejection() {
  local label="$1"
  local target="$2"
  local expected="$3"
  local log="${target}/rejection.log"
  if run_collect "${target}" >"${log}" 2>&1; then
    printf 'FAIL  state-red      %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  if ! run_host_command grep -Fq "${expected}" "${log}"; then
    printf 'FAIL  state-red      %s failed for the wrong reason\n' "${label}" >&2
    run_host_command cat -- "${log}" >&2
    return 1
  fi
  printf 'PASS  state-red      %s rejected before mutation\n' "${label}"
}

expect_state_file_rejection() {
  local label="$1"
  local state="$2"
  local relative="$3"
  local expected="$4"
  local log="${state%/.platform}/${label}.log"
  if PLATFORM_STATE_DIR="${state}" \
    prepare_state_file "${relative}" >"${log}" 2>&1; then
    printf 'FAIL  state-red      %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  if ! run_host_command grep -Fq "${expected}" "${log}"; then
    printf 'FAIL  state-red      %s failed for the wrong reason\n' \
      "${label}" >&2
    run_host_command cat -- "${log}" >&2
    return 1
  fi
  printf 'PASS  state-red      %s rejected before mutation\n' "${label}"
}

assert_directory_empty() {
  local target="$1"
  if run_host_command find "${target}" -mindepth 1 -print -quit |
    run_host_command grep -q .; then
    printf 'FAIL  state-red      external target was mutated: %s\n' "${target}" >&2
    return 1
  fi
}

prove_root_symlink_rejected() {
  local target="${WORK_DIR}/root-symlink"
  local outside="${WORK_DIR}/root-symlink-outside"
  run_host_command mkdir -p "${target}" "${outside}"
  copy_diagnostics_fixture "${target}"
  run_host_command ln -s "${outside}" "${target}/.platform"
  expect_collect_rejection root-state-symlink "${target}" \
    'generated directory must not be a symlink'
  assert_directory_empty "${outside}"
}

prove_nested_symlink_rejected() {
  local target="${WORK_DIR}/nested-symlink"
  local outside="${WORK_DIR}/nested-symlink-outside"
  run_host_command mkdir -p "${target}/.platform" "${outside}"
  copy_diagnostics_fixture "${target}"
  run_host_command ln -s "${outside}" "${target}/.platform/diagnostics"
  expect_collect_rejection nested-state-symlink "${target}" \
    'generated directory must not be a symlink'
  assert_directory_empty "${outside}"
}

prove_execution_path_symlink_rejected() {
  local target="${WORK_DIR}/execution-path-symlink"
  local outside="${WORK_DIR}/execution-path-outside"
  local log="${target}/rejection.log"
  run_host_command mkdir -p \
    "${target}/.platform" "${target}/tools/common" "${outside}"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/env.sh" \
    "${target}/tools/common/env.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${target}/tools/common/host-commands.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/state.sh" \
    "${target}/tools/common/state.sh"
  run_host_command ln -s "${outside}" "${target}/.platform/aqua"
  # The positional argument expands in the fixture shell.
  # shellcheck disable=SC2016
  if run_host_command env PATH="${BASE_PATH}" \
    "$(host_command_path bash)" -p -c \
    'if builtin source "$1"; then exit 0; fi; exit 1' _ \
    "${target}/tools/common/env.sh" >"${log}" 2>&1; then
    printf 'FAIL  state-red      symlinked executable path was accepted\n' >&2
    return 1
  fi
  run_host_command grep -Fq \
    'generated directory must not be a symlink' "${log}"
  printf 'PASS  state-red      symlinked executable path rejected before PATH use\n'
}

prove_summary_file_symlink_rejected() {
  local target="${WORK_DIR}/summary-file-symlink"
  local sentinel="${WORK_DIR}/summary-sentinel"
  run_host_command mkdir -p "${target}/.platform/diagnostics/raw"
  printf 'outside-sentinel\n' >"${sentinel}"
  run_host_command ln -s "${sentinel}" \
    "${target}/.platform/diagnostics/raw/platform.txt"
  expect_state_file_rejection summary-file-symlink "${target}/.platform" \
    'diagnostics/raw/platform.txt' \
    'refusing generated-state file symlink'
  run_host_command grep -Fqx outside-sentinel "${sentinel}"
}

prove_status_file_symlink_rejected() {
  local target="${WORK_DIR}/status-file-symlink"
  local sentinel="${WORK_DIR}/status-sentinel"
  run_host_command mkdir -p "${target}/.platform/diagnostics/raw"
  printf 'outside-sentinel\n' >"${sentinel}"
  run_host_command ln -s "${sentinel}" \
    "${target}/.platform/diagnostics/raw/kubernetes-status.txt"
  expect_state_file_rejection status-file-symlink "${target}/.platform" \
    'diagnostics/raw/kubernetes-status.txt' \
    'refusing generated-state file symlink'
  run_host_command grep -Fqx outside-sentinel "${sentinel}"
}

prove_reset_symlink_rejected() {
  local state="${WORK_DIR}/reset/.platform"
  local outside="${WORK_DIR}/reset-outside"
  run_host_command mkdir -p "${state}/diagnostics/raw" "${outside}"
  printf 'outside-sentinel\n' >"${outside}/sentinel.txt"
  run_host_command ln -s "${outside}" "${state}/diagnostics/raw/kubernetes"
  if PLATFORM_STATE_DIR="${state}" \
    reset_state_directory 'diagnostics/raw/kubernetes' >/dev/null 2>&1; then
    printf 'FAIL  state-red      symlinked reset target was accepted\n' >&2
    return 1
  fi
  run_host_command grep -Fqx outside-sentinel "${outside}/sentinel.txt"
  printf 'PASS  state-red      symlinked reset target preserved external data\n'
}

prove_reset_failure_propagates() {
  local state="${WORK_DIR}/reset-failure/.platform"
  run_host_command mkdir -p "${state}/diagnostics"
  printf 'retained\n' >"${state}/diagnostics/sentinel.txt"
  if (
    # Invoked only through the sourced cleanup function in this child.
    # shellcheck disable=SC2317,SC2329
    run_host_command() { [[ "$1" != rm ]] || return 7; }
    PLATFORM_STATE_DIR="${state}" reset_state_directory diagnostics
  ) >/dev/null 2>&1; then
    printf 'FAIL  state-red      failed reset returned false green\n' >&2
    return 1
  fi
  run_host_command grep -Fqx retained "${state}/diagnostics/sentinel.txt"
  printf 'PASS  state-red      failed reset propagated through conditional call\n'
}

prove_helper_contract() {
  local state="${WORK_DIR}/helper/.platform"
  local output
  run_host_command mkdir -p "${WORK_DIR}/helper"
  PLATFORM_STATE_DIR="${state}" ensure_state_directory 'diagnostics/raw'
  output="$(PLATFORM_STATE_DIR="${state}" prepare_state_file 'diagnostics/raw/status.txt')"
  printf 'safe\n' >"${output}"
  run_host_command grep -Fqx safe "${output}"
  [[ "$(run_host_command stat -c '%a' "${state}")" == 700 ]]
  if PLATFORM_STATE_DIR="${state}" ensure_state_directory '../escape' >/dev/null 2>&1; then
    printf 'FAIL  state-red      parent traversal was accepted\n' >&2
    return 1
  fi
  if PLATFORM_STATE_DIR="${state}" ensure_state_directory 'a//b' >/dev/null 2>&1; then
    printf 'FAIL  state-red      noncanonical state path was accepted\n' >&2
    return 1
  fi
  if PLATFORM_STATE_DIR="${WORK_DIR}/missing-parent/.platform" \
    ensure_state_directory 'diagnostics' >/dev/null 2>&1; then
    printf 'FAIL  state-red      missing project root was created implicitly\n' >&2
    return 1
  fi
  printf 'PASS  state-green    canonical project-local state accepted\n'
  printf 'PASS  state-red      traversal and noncanonical paths rejected\n'
}

main() {
  WORK_DIR="$(run_host_command mktemp -d)"
  trap 'run_host_command rm -rf -- "${WORK_DIR}"' EXIT
  prove_root_symlink_rejected
  prove_nested_symlink_rejected
  prove_execution_path_symlink_rejected
  prove_summary_file_symlink_rejected
  prove_status_file_symlink_rejected
  prove_reset_symlink_rejected
  prove_reset_failure_propagates
  prove_helper_contract
}

main "$@"
