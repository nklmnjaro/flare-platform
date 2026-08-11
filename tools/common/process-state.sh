#!/usr/bin/env bash

# Linux-only process-state predicates for bounded child/process-group cleanup.
# A zombie still answers kill -0, but it is no longer executing and owns no
# resources that cleanup can release. Unreadable persistent state fails closed.

linux_process_read_stat() {
  local pid="$1"
  local stat_path record fields state parent_pid process_group _
  if [[ ! "${pid}" =~ ^[0-9]+$ ]] || ((10#${pid} < 1)); then
    return 2
  fi
  stat_path="/proc/${pid}/stat"
  [[ -e "${stat_path}" ]] || return 1
  if ! IFS= read -r record <"${stat_path}"; then
    [[ -e "${stat_path}" ]] && return 2
    return 1
  fi
  fields="${record##*) }"
  [[ "${fields}" != "${record}" ]] || return 2
  read -r state parent_pid process_group _ <<<"${fields}" || return 2
  if [[ ! "${state}" =~ ^[A-Za-z]$ || ! "${parent_pid}" =~ ^[0-9]+$ ||
    ! "${process_group}" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  printf '%s %s\n' "${state}" "${process_group}"
}

linux_process_state() {
  local fields
  fields="$(linux_process_read_stat "$1")" || return
  printf '%s\n' "${fields%% *}"
}

linux_process_is_live() {
  local fields state read_status
  if fields="$(linux_process_read_stat "$1")"; then
    state="${fields%% *}"
    case "${state}" in
      Z | X | x) return 1 ;;
      *) return 0 ;;
    esac
  else
    read_status=$?
  fi
  [[ "${read_status}" -eq 1 ]] && return 1
  return 0
}

linux_process_group_has_live_member() {
  local process_group="$1"
  local stat_path pid fields state member_group read_status
  local unknown_state=false
  if [[ ! "${process_group}" =~ ^[0-9]+$ ]] ||
    ((10#${process_group} <= 1)); then
    return 2
  fi
  for stat_path in /proc/[0-9]*/stat; do
    [[ -e "${stat_path}" ]] || continue
    pid="${stat_path#/proc/}"
    pid="${pid%/stat}"
    if fields="$(linux_process_read_stat "${pid}")"; then
      state="${fields%% *}"
      member_group="${fields#* }"
      if [[ "${member_group}" == "${process_group}" ]]; then
        case "${state}" in
          Z | X | x) ;;
          *) return 0 ;;
        esac
      fi
    else
      read_status=$?
      [[ "${read_status}" -eq 2 ]] && unknown_state=true
    fi
  done
  [[ "${unknown_state}" != true ]] || return 2
  return 1
}

linux_process_or_group_is_live() {
  local pid="$1" group_status
  linux_process_is_live "${pid}" && return 0
  if linux_process_group_has_live_member "${pid}"; then
    return 0
  else
    group_status=$?
  fi
  [[ "${group_status}" -eq 1 ]] && return 1
  return 0
}

linux_wait_for_process_group_absence() {
  local tracked_pid="$1" attempt
  for ((attempt = 1; attempt <= 20; attempt++)); do
    linux_process_or_group_is_live "${tracked_pid}" || return 0
    sleep 0.02
  done
  ! linux_process_or_group_is_live "${tracked_pid}"
}
