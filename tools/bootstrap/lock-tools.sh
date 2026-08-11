#!/bin/bash -p
set -euo pipefail

LOCK_TOOLS_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${LOCK_TOOLS_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  LOCK_TOOLS_SOURCE_DIR=.
builtin source "${LOCK_TOOLS_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh"
unset LOCK_TOOLS_SOURCE_DIR

CHECKSUM_FILE="${PLATFORM_ROOT}/aqua-checksums.json"
LOCK_BACKUP_DIR=""
LOCK_BACKUP_READY=false
LOCK_MUTATION_STARTED=false
LOCK_COMPLETE=false

restore_regular_file() {
  local source="$1" target="$2" temporary
  temporary="$(run_host_command mktemp "${target}.restore.XXXXXXXX")" || return
  if ! run_host_command cp -pT -- "${source}" "${temporary}" ||
    ! run_host_command mv -fT -- "${temporary}" "${target}"; then
    run_host_command rm -f -- "${temporary}" || true
    return 1
  fi
}

restore_previous_state() {
  local status=0
  restore_regular_file "${LOCK_BACKUP_DIR}/aqua.yaml" "${AQUA_CONFIG}" ||
    status=1
  if [[ -f "${LOCK_BACKUP_DIR}/aqua-checksums.json" ]]; then
    restore_regular_file "${LOCK_BACKUP_DIR}/aqua-checksums.json" \
      "${CHECKSUM_FILE}" || status=1
  else
    run_host_command rm -f -- "${CHECKSUM_FILE}" || status=1
  fi
  return "${status}"
}

cleanup_tool_lock() {
  local status=$?
  trap - EXIT
  if [[ -n "${LOCK_BACKUP_DIR}" ]]; then
    if [[ "${LOCK_COMPLETE}" == true || "${LOCK_BACKUP_READY}" != true ||
      "${LOCK_MUTATION_STARTED}" != true ]]; then
      run_host_command rm -rf -- "${LOCK_BACKUP_DIR}" || status=1
    elif restore_previous_state; then
      run_host_command rm -rf -- "${LOCK_BACKUP_DIR}" || status=1
    else
      builtin printf \
        'FAIL  tool-lock     rollback failed; prior files retained at %s\n' \
        "${LOCK_BACKUP_DIR}" >&2
      status=74
    fi
  fi
  exit "${status}"
}

set_require_checksum() {
  local temporary
  local count
  count="$(run_host_command grep -Ec \
    '^  require_checksum: (true|false)$' "${AQUA_CONFIG}")"
  if [[ "${count}" != "1" ]]; then
    printf 'FAIL  tool-lock     expected one require_checksum setting.\n' >&2
    return 1
  fi
  temporary="$(run_host_command mktemp \
    "${PLATFORM_ROOT}/.aqua.yaml.XXXXXX")" || return
  if ! run_host_command sed \
    's/^  require_checksum: false$/  require_checksum: true/' \
    "${AQUA_CONFIG}" >"${temporary}"; then
    run_host_command rm -f -- "${temporary}" || true
    return 1
  fi
  if ! run_host_command grep -Fqx \
    '  require_checksum: true' "${temporary}"; then
    run_host_command rm -f -- "${temporary}" || true
    printf 'FAIL  tool-lock     unsupported require_checksum setting.\n' >&2
    return 1
  fi
  if ! run_host_command chmod --reference="${AQUA_CONFIG}" -- \
    "${temporary}"; then
    run_host_command rm -f -- "${temporary}" || true
    return 1
  fi
  if ! run_host_command mv -fT -- "${temporary}" "${AQUA_CONFIG}"; then
    run_host_command rm -f -- "${temporary}" || true
    return 1
  fi
}

main() {
  if [[ -L "${AQUA_CONFIG}" || ! -f "${AQUA_CONFIG}" ||
    (-e "${CHECKSUM_FILE}" && (-L "${CHECKSUM_FILE}" ||
    ! -f "${CHECKSUM_FILE}")) ]]; then
    builtin printf 'FAIL  tool-lock     lock input path is unsafe\n' >&2
    return 69
  fi
  verify_existing_aqua "tool-lock" allow-missing || return

  LOCK_BACKUP_DIR="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/tool-lock.XXXXXX")"
  trap cleanup_tool_lock EXIT
  if ! run_host_command cp -pT -- "${AQUA_CONFIG}" \
    "${LOCK_BACKUP_DIR}/aqua.yaml"; then
    builtin printf 'FAIL  tool-lock     unable to back up aqua.yaml\n' >&2
    return 74
  fi
  if [[ -f "${CHECKSUM_FILE}" ]] && ! run_host_command cp -pT -- \
    "${CHECKSUM_FILE}" "${LOCK_BACKUP_DIR}/aqua-checksums.json"; then
    builtin printf \
      'FAIL  tool-lock     unable to back up aqua-checksums.json\n' >&2
    return 74
  fi
  LOCK_BACKUP_READY=true

  LOCK_MUTATION_STARTED=true
  (builtin cd -- "${PLATFORM_ROOT}" && run_project_aqua_update_checksum)
  [[ -s "${CHECKSUM_FILE}" ]] || {
    printf 'FAIL  tool-lock     aqua-checksums.json was not created.\n' >&2
    return 2
  }
  (builtin cd -- "${PLATFORM_ROOT}" && run_project_aqua_install)
  set_require_checksum
  (builtin cd -- "${PLATFORM_ROOT}" && run_project_aqua_install)
  LOCK_COMPLETE=true
  printf 'PASS  tool-lock     checksums locked and require_checksum enabled.\n'
}

main "$@"
