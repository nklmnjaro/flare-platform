#!/bin/bash -p

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  builtin printf 'FAIL  process-state this file must be sourced\n' >&2
  builtin exit 2
fi

case "$(builtin declare -p PLATFORM_PROCESS_STATE_MODULE_LOADED 2>/dev/null ||
  builtin true)" in
  'declare -r PLATFORM_PROCESS_STATE_MODULE_LOADED="true"') builtin return 0 ;;
esac

process_state_boundary_failure() {
  builtin printf \
    'FAIL  process-state unable to establish process-state boundary\n' >&2
  # This is the executed-script fallback.
  # shellcheck disable=SC2317
  builtin return 76 2>/dev/null || builtin exit 76
}

for process_state_name in PLATFORM_PROCESS_STATE_MODULE_LOADED \
  PROCESS_STATE_INSPECTION_STATUS PROCESS_STATE_PROC_ROOT; do
  builtin unset "${process_state_name}" || process_state_boundary_failure
done
for process_state_name in linux_process_valid_id \
  linux_process_terminal_kernel_state _linux_process_parse_stat \
  _linux_process_root_available _linux_process_load_stat_at \
  _linux_process_snapshot_at linux_process_snapshot _linux_process_state_at \
  linux_process_state linux_process_group_state; do
  builtin unset -f "${process_state_name}" 2>/dev/null ||
    process_state_boundary_failure
done
builtin unset process_state_name

# The marker is consumed by the guarded reload check above.
# shellcheck disable=SC2034
builtin readonly PLATFORM_PROCESS_STATE_MODULE_LOADED=true
builtin readonly PROCESS_STATE_INSPECTION_STATUS=76
builtin readonly PROCESS_STATE_PROC_ROOT=/proc

linux_process_valid_id() {
  [[ "${1:-}" =~ ^[1-9][0-9]{0,9}$ ]]
}

linux_process_terminal_kernel_state() {
  [[ "${1:-}" == Z || "${1:-}" == X || "${1:-}" == x ]]
}

_linux_process_parse_stat() {
  local pid="${1:-}" record="${2:-}" suffix observed_pid
  local -a fields=()
  observed_pid="${record%% *}"
  suffix="${record##*) }"
  builtin read -r -a fields <<<"${suffix}"
  if [[ "${observed_pid}" != "${pid}" || "${suffix}" == "${record}" ||
    "${#fields[@]}" -lt 20 || ! "${fields[0]:-}" =~ ^[A-Za-z]$ ||
    ! "${fields[2]:-}" =~ ^[0-9]{1,10}$ ||
    ! "${fields[19]:-}" =~ ^[0-9]+$ ]]; then
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  fi
  _LINUX_PROCESS_PID="${pid}"
  _LINUX_PROCESS_PGRP="${fields[2]}"
  _LINUX_PROCESS_STARTTIME="${fields[19]}"
  _LINUX_PROCESS_KERNEL_STATE="${fields[0]}"
}

_linux_process_root_available() {
  local proc_root="${1:-}" path record
  [[ -d "${proc_root}" && ! -L "${proc_root}" ]] ||
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  path="${proc_root}/self/stat"
  [[ -e "${path}" && ! -L "${path}" ]] ||
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  if ! IFS= builtin read -r record 2>/dev/null <"${path}"; then
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  fi
  [[ -n "${record}" ]] || return "${PROCESS_STATE_INSPECTION_STATUS}"
}

_linux_process_load_stat_at() {
  local pid="${1:-}" proc_root="${2:-}" path record
  linux_process_valid_id "${pid}" || return "${PROCESS_STATE_INSPECTION_STATUS}"
  _linux_process_root_available "${proc_root}" || return
  path="${proc_root}/${pid}/stat"
  if [[ ! -e "${path}" ]]; then
    _linux_process_root_available "${proc_root}" || return
    return 1
  fi
  if [[ -L "${path}" ]] || ! IFS= builtin read -r record 2>/dev/null <"${path}"; then
    if [[ ! -e "${path}" ]]; then
      _linux_process_root_available "${proc_root}" || return
      return 1
    fi
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  fi
  _linux_process_parse_stat "${pid}" "${record}"
}

_linux_process_snapshot_at() {
  _linux_process_load_stat_at "${1:-}" "${2:-}" || return
  builtin printf '%s\t%s\t%s\t%s\n' \
    "${_LINUX_PROCESS_PID}" "${_LINUX_PROCESS_PGRP}" \
    "${_LINUX_PROCESS_STARTTIME}" "${_LINUX_PROCESS_KERNEL_STATE}"
}

# Print one TSV record: PID, process group, starttime, and kernel state.
# Status 1 means absent; status 76 means inspection failed.
linux_process_snapshot() {
  _linux_process_snapshot_at "${1:-}" "${PROCESS_STATE_PROC_ROOT}"
}

_linux_process_state_at() {
  local pid="${1:-}" expected_starttime="${2:-}" proc_root="${3:-}" status
  if [[ -n "${expected_starttime}" &&
    ! "${expected_starttime}" =~ ^[0-9]+$ ]]; then
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  fi
  if _linux_process_load_stat_at "${pid}" "${proc_root}"; then
    :
  else
    status=$?
    if [[ "${status}" -eq 1 ]]; then
      builtin printf 'absent\n'
      return 0
    fi
    return "${status}"
  fi
  if [[ -n "${expected_starttime}" &&
    "${_LINUX_PROCESS_STARTTIME}" != "${expected_starttime}" ]]; then
    builtin printf 'replaced\n'
  elif linux_process_terminal_kernel_state "${_LINUX_PROCESS_KERNEL_STATE}"; then
    builtin printf 'terminal\n'
  else
    builtin printf 'live\n'
  fi
}

# Print live, terminal, absent, or replaced for one PID identity.
linux_process_state() {
  _linux_process_state_at "${1:-}" "${2:-}" "${PROCESS_STATE_PROC_ROOT}"
}

# Print aggregate state for a process group bound to its leader starttime.
linux_process_group_state() (
  local pgid="${1:-}" expected_starttime="${2:-}" status path observed_pid
  local terminal_found=false
  linux_process_valid_id "${pgid}" || return "${PROCESS_STATE_INSPECTION_STATUS}"
  [[ "${expected_starttime}" =~ ^[0-9]+$ ]] ||
    return "${PROCESS_STATE_INSPECTION_STATUS}"
  _linux_process_root_available "${PROCESS_STATE_PROC_ROOT}" || return
  if _linux_process_load_stat_at "${pgid}" "${PROCESS_STATE_PROC_ROOT}"; then
    if [[ "${_LINUX_PROCESS_STARTTIME}" != "${expected_starttime}" ]]; then
      builtin printf 'replaced\n'
      return 0
    fi
  else
    status=$?
    [[ "${status}" -eq 1 ]] || return "${status}"
  fi
  builtin shopt -s nullglob
  for path in "${PROCESS_STATE_PROC_ROOT}"/[0-9]*/stat; do
    observed_pid="${path%/stat}"
    observed_pid="${observed_pid##*/}"
    if _linux_process_load_stat_at \
      "${observed_pid}" "${PROCESS_STATE_PROC_ROOT}"; then
      :
    else
      status=$?
      [[ "${status}" -eq 1 ]] && continue
      return "${status}"
    fi
    [[ "${_LINUX_PROCESS_PGRP}" == "${pgid}" ]] || continue
    if linux_process_terminal_kernel_state "${_LINUX_PROCESS_KERNEL_STATE}"; then
      terminal_found=true
    else
      builtin printf 'live\n'
      return 0
    fi
  done
  _linux_process_root_available "${PROCESS_STATE_PROC_ROOT}" || return
  if [[ "${terminal_found}" == true ]]; then
    builtin printf 'terminal\n'
  else
    builtin printf 'absent\n'
  fi
)
