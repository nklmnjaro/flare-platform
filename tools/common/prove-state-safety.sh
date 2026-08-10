#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh"

WORK_DIR=""
BASE_PATH="/usr/bin:/bin"

copy_diagnostics_fixture() {
  local target="$1"
  mkdir -p "${target}/tools/common" "${target}/tools/diagnostics" \
    "${target}/tools/kubernetes"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  cp "${PLATFORM_ROOT}/tools/diagnostics/collect.sh" \
    "${target}/tools/diagnostics/collect.sh"
  cp "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh" \
    "${target}/tools/kubernetes/runtime.sh"
}

initialize_fixture_repo() {
  local target="$1"
  printf '.platform/\n' >"${target}/.gitignore"
  printf 'fixture\n' >"${target}/README.md"
  git -C "${target}" init -q
  git -C "${target}" add .
  git -C "${target}" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm 'test: initialize fixture'
}

run_collect() {
  local target="$1"
  env PATH="${BASE_PATH}" "${target}/tools/diagnostics/collect.sh"
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
  if ! grep -Fq "${expected}" "${log}"; then
    printf 'FAIL  state-red      %s failed for the wrong reason\n' "${label}" >&2
    cat "${log}" >&2
    return 1
  fi
  printf 'PASS  state-red      %s rejected before mutation\n' "${label}"
}

assert_directory_empty() {
  local target="$1"
  if find "${target}" -mindepth 1 -print -quit | grep -q .; then
    printf 'FAIL  state-red      external target was mutated: %s\n' "${target}" >&2
    return 1
  fi
}

prove_root_symlink_rejected() {
  local target="${WORK_DIR}/root-symlink"
  local outside="${WORK_DIR}/root-symlink-outside"
  mkdir -p "${target}" "${outside}"
  copy_diagnostics_fixture "${target}"
  ln -s "${outside}" "${target}/.platform"
  expect_collect_rejection root-state-symlink "${target}" \
    'generated directory must not be a symlink'
  assert_directory_empty "${outside}"
}

prove_nested_symlink_rejected() {
  local target="${WORK_DIR}/nested-symlink"
  local outside="${WORK_DIR}/nested-symlink-outside"
  mkdir -p "${target}/.platform" "${outside}"
  copy_diagnostics_fixture "${target}"
  ln -s "${outside}" "${target}/.platform/diagnostics"
  expect_collect_rejection nested-state-symlink "${target}" \
    'generated directory must not be a symlink'
  assert_directory_empty "${outside}"
}

prove_execution_path_symlink_rejected() {
  local target="${WORK_DIR}/execution-path-symlink"
  local outside="${WORK_DIR}/execution-path-outside"
  local log="${target}/rejection.log"
  mkdir -p "${target}/.platform" "${target}/tools/common" "${outside}"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  ln -s "${outside}" "${target}/.platform/aqua"
  # The positional argument expands in the fixture shell.
  # shellcheck disable=SC2016
  if env PATH="${BASE_PATH}" bash -c \
    'if source "$1"; then exit 0; fi; exit 1' _ \
    "${target}/tools/common/env.sh" >"${log}" 2>&1; then
    printf 'FAIL  state-red      symlinked executable path was accepted\n' >&2
    return 1
  fi
  grep -Fq 'generated directory must not be a symlink' "${log}"
  printf 'PASS  state-red      symlinked executable path rejected before PATH use\n'
}

prove_summary_file_symlink_rejected() {
  local target="${WORK_DIR}/summary-file-symlink"
  local sentinel="${WORK_DIR}/summary-sentinel"
  mkdir -p "${target}/.platform/diagnostics/raw"
  copy_diagnostics_fixture "${target}"
  initialize_fixture_repo "${target}"
  printf 'outside-sentinel\n' >"${sentinel}"
  ln -s "${sentinel}" "${target}/.platform/diagnostics/raw/platform.txt"
  expect_collect_rejection summary-file-symlink "${target}" \
    'refusing generated-state file symlink'
  grep -Fqx outside-sentinel "${sentinel}"
}

prove_status_file_symlink_rejected() {
  local target="${WORK_DIR}/status-file-symlink"
  local sentinel="${WORK_DIR}/status-sentinel"
  mkdir -p "${target}/.platform/diagnostics/raw"
  copy_diagnostics_fixture "${target}"
  initialize_fixture_repo "${target}"
  printf 'outside-sentinel\n' >"${sentinel}"
  ln -s "${sentinel}" "${target}/.platform/diagnostics/raw/kubernetes-status.txt"
  expect_collect_rejection status-file-symlink "${target}" \
    'refusing generated-state file symlink'
  grep -Fqx outside-sentinel "${sentinel}"
}

prove_reset_symlink_rejected() {
  local state="${WORK_DIR}/reset/.platform"
  local outside="${WORK_DIR}/reset-outside"
  mkdir -p "${state}/diagnostics/raw" "${outside}"
  printf 'outside-sentinel\n' >"${outside}/sentinel.txt"
  ln -s "${outside}" "${state}/diagnostics/raw/kubernetes"
  if PLATFORM_STATE_DIR="${state}" \
    reset_state_directory 'diagnostics/raw/kubernetes' >/dev/null 2>&1; then
    printf 'FAIL  state-red      symlinked reset target was accepted\n' >&2
    return 1
  fi
  grep -Fqx outside-sentinel "${outside}/sentinel.txt"
  printf 'PASS  state-red      symlinked reset target preserved external data\n'
}

prove_reset_failure_propagates() {
  local state="${WORK_DIR}/reset-failure/.platform"
  mkdir -p "${state}/diagnostics"
  printf 'retained\n' >"${state}/diagnostics/sentinel.txt"
  if (
    rm() { return 7; }
    PLATFORM_STATE_DIR="${state}" reset_state_directory diagnostics
  ) >/dev/null 2>&1; then
    printf 'FAIL  state-red      failed reset returned false green\n' >&2
    return 1
  fi
  grep -Fqx retained "${state}/diagnostics/sentinel.txt"
  printf 'PASS  state-red      failed reset propagated through conditional call\n'
}

prove_helper_contract() {
  local state="${WORK_DIR}/helper/.platform"
  local output
  mkdir -p "${WORK_DIR}/helper"
  PLATFORM_STATE_DIR="${state}" ensure_state_directory 'diagnostics/raw'
  output="$(PLATFORM_STATE_DIR="${state}" prepare_state_file 'diagnostics/raw/status.txt')"
  printf 'safe\n' >"${output}"
  grep -Fqx safe "${output}"
  [[ "$(stat -c '%a' "${state}")" == 700 ]]
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
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${WORK_DIR}"' EXIT
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
