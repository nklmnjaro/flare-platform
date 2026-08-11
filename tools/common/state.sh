#!/usr/bin/env bash
builtin set -euo pipefail

validate_state_relative_path() {
  local relative="$1"
  local component
  local -a components=()
  if [[ "${relative}" == /* || "${relative}" == */ || "${relative}" == *//* ]]; then
    builtin printf 'FAIL  state-guard   unsafe generated-state path: %q\n' \
      "${relative}" >&2
    return 1
  fi
  if [[ "${relative}" == *$'\n'* || "${relative}" == *$'\r'* || "${relative}" == *$'\t'* ]]; then
    builtin printf \
      'FAIL  state-guard   control character in generated-state path: %q\n' \
      "${relative}" >&2
    return 1
  fi
  [[ -z "${relative}" ]] && return 0
  IFS='/' builtin read -r -a components <<<"${relative}"
  for component in "${components[@]}"; do
    if [[ -z "${component}" || "${component}" == . || "${component}" == .. ]]; then
      builtin printf 'FAIL  state-guard   unsafe generated-state path: %q\n' \
        "${relative}" >&2
      return 1
    fi
  done
}

assert_existing_directory_component() {
  local path="$1"
  if [[ -L "${path}" ]]; then
    builtin printf \
      'FAIL  state-guard   generated directory must not be a symlink: %s\n' \
      "${path}" >&2
    return 1
  fi
  if [[ -e "${path}" && ! -d "${path}" ]]; then
    builtin printf \
      'FAIL  state-guard   generated path is not a directory: %s\n' \
      "${path}" >&2
    return 1
  fi
}

assert_existing_state_directory() {
  local relative="${1:-}"
  local current="${PLATFORM_STATE_DIR}"
  local component
  local -a components=()
  validate_state_relative_path "${relative}" || return
  assert_existing_directory_component "${current}" || return
  [[ -e "${current}" ]] || return 0
  [[ -z "${relative}" ]] && return 0
  IFS='/' builtin read -r -a components <<<"${relative}"
  for component in "${components[@]}"; do
    current="${current}/${component}"
    assert_existing_directory_component "${current}" || return
    [[ -e "${current}" ]] || return 0
  done
}

ensure_directory_component() {
  local path="$1"
  assert_existing_directory_component "${path}" || return
  [[ -e "${path}" ]] && return 0
  if (umask 077 && run_host_command mkdir -- "${path}") 2>/dev/null; then
    return 0
  fi
  assert_existing_directory_component "${path}" || return
  if [[ ! -d "${path}" ]]; then
    builtin printf \
      'FAIL  state-guard   unable to create generated directory: %s\n' \
      "${path}" >&2
    return 1
  fi
}

ensure_state_directory() {
  local relative="${1:-}"
  local current="${PLATFORM_STATE_DIR}"
  local component
  local -a components=()
  validate_state_relative_path "${relative}" || return
  ensure_directory_component "${current}" || return
  [[ -z "${relative}" ]] && return 0
  IFS='/' builtin read -r -a components <<<"${relative}"
  for component in "${components[@]}"; do
    current="${current}/${component}"
    ensure_directory_component "${current}" || return
  done
}

prepare_state_file() {
  local relative="$1"
  local parent=""
  local target
  validate_state_relative_path "${relative}" || return
  if [[ -z "${relative}" ]]; then
    builtin printf \
      'FAIL  state-guard   generated-state file path is empty\n' >&2
    return 1
  fi
  [[ "${relative}" == */* ]] && parent="${relative%/*}"
  ensure_state_directory "${parent}" || return
  target="${PLATFORM_STATE_DIR}/${relative}"
  if [[ -L "${target}" ]]; then
    builtin printf \
      'FAIL  state-guard   refusing generated-state file symlink: %s\n' \
      "${target}" >&2
    return 1
  fi
  if [[ -e "${target}" && ! -f "${target}" ]]; then
    builtin printf \
      'FAIL  state-guard   generated-state file is not regular: %s\n' \
      "${target}" >&2
    return 1
  fi
  builtin printf '%s\n' "${target}"
}

reset_state_directory() {
  local relative="$1"
  local parent=""
  local target
  validate_state_relative_path "${relative}" || return
  if [[ -z "${relative}" ]]; then
    builtin printf 'FAIL  state-guard   reset directory path is empty\n' >&2
    return 1
  fi
  [[ "${relative}" == */* ]] && parent="${relative%/*}"
  ensure_state_directory "${parent}" || return
  target="${PLATFORM_STATE_DIR}/${relative}"
  assert_existing_directory_component "${target}" || return
  run_host_command rm -rf -- "${target}" || return
  ensure_directory_component "${target}"
}
