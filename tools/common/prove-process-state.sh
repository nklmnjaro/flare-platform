#!/bin/bash -p
builtin set -euo pipefail

PROVE_PROCESS_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_PROCESS_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_PROCESS_SOURCE_DIR=.
builtin source "${PROVE_PROCESS_SOURCE_DIR}/env.sh"
# shellcheck source=process-state.sh
builtin source "${PLATFORM_ROOT}/tools/common/process-state.sh"
builtin unset PROVE_PROCESS_SOURCE_DIR

readonly PROCESS_FIXTURE_SOURCE="${PLATFORM_ROOT}/tests/fixtures/go/process-state-helper.go"
readonly MANAGED_TOOL_RUNNER="${PLATFORM_ROOT}/tools/common/run-managed-tool.sh"

PROCESS_PROOF_DIRECTORY=""
PROCESS_FIXTURE_BINARY=""
PROCESS_FIXTURE_PARENT=""
PROCESS_FIXTURE_GROUP=""

cleanup_process_proof() {
  local status=$?
  builtin trap - EXIT
  [[ -z "${PROCESS_FIXTURE_GROUP}" ]] ||
    builtin kill -KILL -- "-${PROCESS_FIXTURE_GROUP}" 2>/dev/null || true
  [[ -z "${PROCESS_FIXTURE_PARENT}" ]] ||
    builtin kill -KILL "${PROCESS_FIXTURE_PARENT}" 2>/dev/null || true
  [[ -z "${PROCESS_FIXTURE_PARENT}" ]] ||
    builtin wait "${PROCESS_FIXTURE_PARENT}" 2>/dev/null || true
  [[ -z "${PROCESS_PROOF_DIRECTORY}" ]] ||
    run_host_command rm -rf -- "${PROCESS_PROOF_DIRECTORY}" || status=1
  builtin exit "${status}"
}

wait_for_file() {
  local path="$1" attempt
  for ((attempt = 1; attempt <= 250; attempt++)); do
    [[ ! -s "${path}" ]] || return 0
    run_host_command sleep 0.02
  done
  return 1
}

read_fixture_pid() {
  local path="$1" pid
  IFS= builtin read -r pid <"${path}" || return
  linux_process_valid_id "${pid}" || return "${PROCESS_STATE_INSPECTION_STATUS}"
  builtin printf '%s\n' "${pid}"
}

snapshot_identity() {
  local pid="$1" snapshot observed_pid pgrp starttime kernel_state
  snapshot="$(linux_process_snapshot "${pid}")" || return
  IFS=$'\t' builtin read -r observed_pid pgrp starttime kernel_state \
    <<<"${snapshot}"
  [[ "${observed_pid}" == "${pid}" ]] ||
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  builtin printf '%s\t%s\n' "${pgrp}" "${starttime}"
}

write_stat_fixture() {
  local root="$1" pid="$2" comm="$3" state="$4" pgrp="$5" starttime="$6"
  local field
  run_host_command mkdir -p -- "${root}/${pid}"
  builtin printf '%s (%s) %s 1 %s' "${pid}" "${comm}" "${state}" "${pgrp}" \
    >"${root}/${pid}/stat"
  for ((field = 6; field <= 21; field++)); do
    builtin printf ' 0' >>"${root}/${pid}/stat"
  done
  builtin printf ' %s\n' "${starttime}" >>"${root}/${pid}/stat"
}

expect_inspection_status() {
  local label="$1" status=0
  builtin shift
  "$@" >/dev/null 2>&1 || status=$?
  if [[ "${status}" -ne "${PROCESS_STATE_INSPECTION_STATUS}" ]]; then
    builtin printf 'FAIL  process-state %s returned %s, expected %s\n' \
      "${label}" "${status}" "${PROCESS_STATE_INSPECTION_STATUS}" >&2
    return 1
  fi
}

prove_parser_contracts() {
  local root="${PROCESS_PROOF_DIRECTORY}/proc" unavailable snapshot state
  run_host_command mkdir -p -- "${root}/self"
  builtin printf 'fixture proc root available\n' >"${root}/self/stat"
  write_stat_fixture "${root}" 900 'worker ) name with spaces' T 0 456
  snapshot="$(_linux_process_snapshot_at 900 "${root}")" || return
  [[ "${snapshot}" == $'900\t0\t456\tT' ]] || return 1
  state="$(_linux_process_state_at 900 '' "${root}")" || return
  [[ "${state}" == live ]] || return 1
  state="$(_linux_process_state_at 900 455 "${root}")" || return
  [[ "${state}" == replaced ]] || return 1
  builtin printf 'malformed\n' >"${root}/900/stat"
  expect_inspection_status malformed-stat _linux_process_snapshot_at 900 "${root}"
  run_host_command mkdir -p -- "${root}/901/stat"
  expect_inspection_status unreadable-stat _linux_process_snapshot_at 901 "${root}"
  unavailable="${PROCESS_PROOF_DIRECTORY}/unavailable-proc"
  run_host_command mkdir -p -- "${unavailable}"
  expect_inspection_status unavailable-proc-root \
    _linux_process_state_at 900 '' "${unavailable}"
  state="$(_linux_process_state_at 902 '' "${root}")" || return
  [[ "${state}" == absent ]] || return 1
  expect_inspection_status missing-snapshot-argument linux_process_snapshot
  expect_inspection_status missing-state-argument linux_process_state
  expect_inspection_status missing-group-argument linux_process_group_state
  expect_inspection_status missing-group-starttime linux_process_group_state "$$"
  builtin printf \
    'PASS  process-state parser handles comm, pgrp=0, stopped, malformed stat, and unavailable proc\n'
}

prove_imported_environment_guard() (
  local marker="${PROCESS_PROOF_DIRECTORY}/imported.marker" output bash_path
  bash_path="$(host_command_path bash)" || return
  # Fixture variables expand in the isolated child shell.
  # shellcheck disable=SC2016
  output="$(run_host_command bash -p -c '
    marker=$1
    module=$2
    export PLATFORM_PROCESS_STATE_MODULE_LOADED=true
    linux_process_snapshot() {
      : >"${marker}"
      printf "1\\t1\\t1\\tZ\\n"
    }
    source "${module}"
    linux_process_snapshot "$$"
  ' _ "${marker}" "${PLATFORM_ROOT}/tools/common/process-state.sh")" || return
  [[ ! -e "${marker}" && "${output}" == *$'\t'* ]] || return 1
  [[ "${bash_path}" == /* ]] || return 1
  builtin printf \
    'PASS  process-state imported environment cannot suppress canonical definitions\n'
)

prove_zombie_is_terminal() {
  local pid_file="${PROCESS_PROOF_DIRECTORY}/zombie.pid" child state snapshot
  local observed_pid pgrp starttime kernel_state attempt final_state
  "${PROCESS_FIXTURE_BINARY}" zombie "${pid_file}" &
  PROCESS_FIXTURE_PARENT=$!
  wait_for_file "${pid_file}" || return
  child="$(read_fixture_pid "${pid_file}")" || return
  for ((attempt = 1; attempt <= 250; attempt++)); do
    state="$(linux_process_state "${child}")" || return
    [[ "${state}" != live ]] && break
    run_host_command sleep 0.02
  done
  snapshot="$(linux_process_snapshot "${child}")" || return
  IFS=$'\t' builtin read -r observed_pid pgrp starttime kernel_state \
    <<<"${snapshot}"
  if [[ "${state}" != terminal || "${kernel_state}" != Z ]] ||
    ! builtin kill -0 "${child}" 2>/dev/null; then
    builtin printf 'FAIL  process-state zombie was not classified as terminal\n' >&2
    return 1
  fi
  builtin kill -TERM "${PROCESS_FIXTURE_PARENT}" 2>/dev/null || true
  builtin wait "${PROCESS_FIXTURE_PARENT}" 2>/dev/null || true
  PROCESS_FIXTURE_PARENT=""
  final_state="$(linux_process_state "${child}" "${starttime}")" || return
  [[ "${final_state}" == absent || "${final_state}" == replaced ]] || return 1
  builtin printf 'PASS  process-state kill-0=true kernel_state=Z classified=terminal\n'
}

wait_for_group_nonlive() {
  local pgid="$1" starttime="$2" attempt state
  for ((attempt = 1; attempt <= 100; attempt++)); do
    state="$(linux_process_group_state "${pgid}" "${starttime}")" || return
    [[ "${state}" != live ]] && return 0
    run_host_command sleep 0.02
  done
  return 1
}

prove_live_group_member() {
  local child_pid_file="${PROCESS_PROOF_DIRECTORY}/group-child.pid"
  local child_ready="${PROCESS_PROOF_DIRECTORY}/group-child.ready"
  local release="${PROCESS_PROOF_DIRECTORY}/group.release"
  local identity pgid starttime state child_pid
  builtin set -m
  "${PROCESS_FIXTURE_BINARY}" group-leader \
    "${child_pid_file}" "${child_ready}" "${release}" &
  PROCESS_FIXTURE_PARENT=$!
  PROCESS_FIXTURE_GROUP="${PROCESS_FIXTURE_PARENT}"
  builtin set +m
  identity="$(snapshot_identity "${PROCESS_FIXTURE_PARENT}")" || return
  IFS=$'\t' builtin read -r pgid starttime <<<"${identity}"
  [[ "${pgid}" == "${PROCESS_FIXTURE_PARENT}" ]] || return 1
  wait_for_file "${child_pid_file}" || return
  child_pid="$(read_fixture_pid "${child_pid_file}")" || return
  : >"${release}"
  builtin wait "${PROCESS_FIXTURE_PARENT}"
  PROCESS_FIXTURE_PARENT=""
  state="$(linux_process_group_state "${pgid}" "${starttime}")" || return
  [[ "${state}" == live ]] || return 1
  builtin kill -TERM -- "-${pgid}" 2>/dev/null || return
  run_host_command sleep 0.05
  state="$(linux_process_group_state "${pgid}" "${starttime}")" || return
  [[ "${state}" == live ]] || return 1
  builtin kill -KILL -- "-${pgid}" 2>/dev/null || return
  wait_for_group_nonlive "${pgid}" "${starttime}" || return
  state="$(linux_process_group_state "${pgid}" "${starttime}")" || return
  [[ "${state}" != live ]] || return 1
  run_host_command sleep 0.02
  state="$(linux_process_group_state "${pgid}" "${starttime}")" || return
  [[ "${state}" != live ]] || return 1
  PROCESS_FIXTURE_GROUP=""
  builtin printf 'PASS  process-state live_member=%s TERM=live KILL=nonlive\n' \
    "${child_pid}"
}

main() {
  reset_state_directory process-state-proof || return
  PROCESS_PROOF_DIRECTORY="${PLATFORM_STATE_DIR}/process-state-proof"
  PROCESS_FIXTURE_BINARY="${PROCESS_PROOF_DIRECTORY}/process-state-helper"
  builtin trap cleanup_process_proof EXIT
  "${MANAGED_TOOL_RUNNER}" go build -trimpath -o "${PROCESS_FIXTURE_BINARY}" \
    "${PROCESS_FIXTURE_SOURCE}"
  prove_imported_environment_guard
  prove_parser_contracts
  prove_zombie_is_terminal
  prove_live_group_member
  builtin trap - EXIT
  run_host_command rm -rf -- "${PROCESS_PROOF_DIRECTORY}"
  builtin printf 'PASS  process-state deterministic Linux liveness contracts proved\n'
}

main "$@"
