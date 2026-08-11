#!/bin/bash -p

builtin set +e

raw_output=${1:-}
status_output=${2:-}
raw_max=${3:-}
boundary_status=${4:-}
process_state_source=${5:-}
head_path=${6:-}
cat_path=${7:-}
mktemp_path=${8:-}
rm_path=${9:-}
sleep_path=${10:-}
builtin shift 10 || builtin exit 70

command_pid=""
command_starttime=""
collector_pid=""
writer_fd=""
start_gate=""
command_group_state=""

[[ -f "${process_state_source}" && ! -L "${process_state_source}" ]] ||
  builtin exit "${boundary_status}"
# shellcheck source=process-state.sh
builtin source "${process_state_source}" || builtin exit "${boundary_status}"
builtin set -m || builtin exit "${boundary_status}"

read_command_group_state() {
  command_group_state="$(linux_process_group_state \
    "${command_pid}" "${command_starttime}")" || return "${boundary_status}"
}

stop_live_command_group() {
  [[ -n "${command_pid}" ]] || return 0
  if [[ -z "${command_starttime}" ]]; then
    builtin kill -KILL "${command_pid}" 2>/dev/null || builtin true
    return 0
  fi
  read_command_group_state || return
  [[ "${command_group_state}" != live ]] ||
    builtin kill -KILL -- "-${command_pid}" 2>/dev/null || builtin true
}

cleanup_capture() {
  local saved_status=$?
  builtin trap - EXIT TERM INT HUP
  stop_live_command_group || saved_status="${boundary_status}"
  [[ -z "${collector_pid}" ]] ||
    builtin kill -KILL -- "-${collector_pid}" 2>/dev/null || builtin true
  [[ -z "${writer_fd}" ]] || exec {writer_fd}>&-
  [[ -z "${command_pid}" ]] ||
    builtin wait "${command_pid}" 2>/dev/null || builtin true
  [[ -z "${collector_pid}" ]] ||
    builtin wait "${collector_pid}" 2>/dev/null || builtin true
  if [[ -n "${start_gate}" ]] &&
    ! "${rm_path}" -f -- "${start_gate}"; then
    saved_status="${boundary_status}"
  fi
  builtin exit "${saved_status}"
}

builtin trap cleanup_capture EXIT
builtin trap 'builtin exit 124' TERM INT HUP
coproc EVIDENCE_COLLECTOR {
  collector_status=0
  "${head_path}" -c "$((raw_max + 1))" >"${raw_output}" || collector_status=$?
  "${cat_path}" >/dev/null || collector_status=$?
  builtin exit "${collector_status}"
}
collector_pid=${EVIDENCE_COLLECTOR_PID:-}
[[ -n "${collector_pid}" && ${#EVIDENCE_COLLECTOR[@]} -eq 2 ]] ||
  builtin exit "${boundary_status}"
collector_output_fd=${EVIDENCE_COLLECTOR[0]}
exec {writer_fd}>&"${EVIDENCE_COLLECTOR[1]}" ||
  builtin exit "${boundary_status}"
collector_input_fd=${EVIDENCE_COLLECTOR[1]}
exec {collector_input_fd}>&- || builtin exit "${boundary_status}"
exec {collector_output_fd}<&- || builtin exit "${boundary_status}"
start_gate="$("${mktemp_path}" "${status_output}.gate.XXXXXXXX")" ||
  builtin exit "${boundary_status}"
[[ -f "${start_gate}" && ! -L "${start_gate}" ]] ||
  builtin exit "${boundary_status}"
(
  builtin set +m || builtin exit "${boundary_status}"
  while [[ ! -s "${start_gate}" ]]; do :; done
  [[ "$(<"${start_gate}")" == go ]] || builtin exit "${boundary_status}"
  ulimit -c 0 || builtin exit "${boundary_status}"
  "$@"
  command_status=$?
  builtin printf '%s\n' "${command_status}" >"${status_output}" ||
    builtin exit "${boundary_status}"
  builtin exit 0
) >&"${writer_fd}" 2>&1 &
command_pid=$!
command_snapshot="$(linux_process_snapshot "${command_pid}")" ||
  builtin exit "${boundary_status}"
command_snapshot_tab="$(builtin printf '\t')"
IFS="${command_snapshot_tab}" builtin read -r \
  observed_pid observed_pgrp observed_starttime command_kernel_state \
  <<<"${command_snapshot}"
if [[ "${observed_pid}" != "${command_pid}" ||
  "${observed_pgrp}" != "${command_pid}" ]] ||
  linux_process_terminal_kernel_state "${command_kernel_state}"; then
  builtin exit "${boundary_status}"
fi
command_starttime="${observed_starttime}"
builtin printf 'go\n' >"${start_gate}" || builtin exit "${boundary_status}"
exec {writer_fd}>&- || builtin exit "${boundary_status}"
writer_fd=""
builtin set +m || builtin exit "${boundary_status}"
builtin wait "${command_pid}"
producer_status=$?
read_command_group_state || builtin exit "${boundary_status}"
if [[ "${command_group_state}" == live ]]; then
  builtin kill -KILL -- "-${command_pid}" 2>/dev/null || builtin true
fi
for _ in {1..50}; do
  read_command_group_state || builtin exit "${boundary_status}"
  [[ "${command_group_state}" == live ]] || break
  "${sleep_path}" 0.02
done
[[ "${command_group_state}" != live ]] || builtin exit "${boundary_status}"
"${sleep_path}" 0.02
read_command_group_state || builtin exit "${boundary_status}"
[[ "${command_group_state}" != live ]] || builtin exit "${boundary_status}"
builtin wait "${collector_pid}"
collector_status=$?
"${rm_path}" -f -- "${start_gate}" || builtin exit "${boundary_status}"
start_gate=""
command_pid=""
collector_pid=""
builtin trap - EXIT TERM INT HUP
[[ "${producer_status}" -eq 0 && "${collector_status}" -eq 0 ]]
