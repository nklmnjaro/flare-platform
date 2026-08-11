#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/aqua-trust.sh"

CHECKSUM_FILE="${PLATFORM_ROOT}/aqua-checksums.json"
LOCK_BACKUP_DIR=""
LOCK_COMPLETE=false

restore_previous_state() {
  cp "${LOCK_BACKUP_DIR}/aqua.yaml" "${AQUA_CONFIG}"
  if [[ -f "${LOCK_BACKUP_DIR}/aqua-checksums.json" ]]; then
    cp "${LOCK_BACKUP_DIR}/aqua-checksums.json" "${CHECKSUM_FILE}"
  else
    rm -f "${CHECKSUM_FILE}"
  fi
}

cleanup_tool_lock() {
  [[ -z "${LOCK_BACKUP_DIR}" ]] && return 0
  [[ "${LOCK_COMPLETE}" == true ]] || restore_previous_state
  rm -rf "${LOCK_BACKUP_DIR}"
}

set_require_checksum() {
  local temporary
  local count
  count="$(grep -Ec '^  require_checksum: (true|false)$' "${AQUA_CONFIG}")"
  if [[ "${count}" != "1" ]]; then
    printf 'FAIL  tool-lock     expected one require_checksum setting.\n' >&2
    return 1
  fi
  temporary="$(mktemp "${PLATFORM_ROOT}/.aqua.yaml.XXXXXX")"
  sed 's/^  require_checksum: false$/  require_checksum: true/' \
    "${AQUA_CONFIG}" >"${temporary}"
  grep -Fqx '  require_checksum: true' "${temporary}" || {
    rm -f "${temporary}"
    printf 'FAIL  tool-lock     unsupported require_checksum setting.\n' >&2
    return 1
  }
  mv "${temporary}" "${AQUA_CONFIG}"
}

main() {
  verify_existing_aqua "tool-lock" || return

  LOCK_BACKUP_DIR="$(mktemp -d "${PLATFORM_STATE_DIR}/tool-lock.XXXXXX")"
  cp "${AQUA_CONFIG}" "${LOCK_BACKUP_DIR}/aqua.yaml"
  [[ ! -f "${CHECKSUM_FILE}" ]] || cp "${CHECKSUM_FILE}" \
    "${LOCK_BACKUP_DIR}/aqua-checksums.json"
  trap cleanup_tool_lock EXIT

  (cd "${PLATFORM_ROOT}" && "${AQUA_BIN}" update-checksum -prune)
  [[ -s "${CHECKSUM_FILE}" ]] || {
    printf 'FAIL  tool-lock     aqua-checksums.json was not created.\n' >&2
    return 2
  }
  AQUA_ENFORCE_REQUIRE_CHECKSUM=true "${AQUA_BIN}" install
  set_require_checksum
  AQUA_ENFORCE_REQUIRE_CHECKSUM=true "${AQUA_BIN}" install
  LOCK_COMPLETE=true
  printf 'PASS  tool-lock     checksums locked and require_checksum enabled.\n'
}

main "$@"
