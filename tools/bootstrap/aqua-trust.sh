#!/usr/bin/env bash

# This module is sourced by bootstrap entrypoints. It must not execute a main.
# Callers source it exactly once. Canonical definitions must never be skipped
# merely because an inherited shell function has the same name.

readonly AQUA_VERSION="2.62.3"
readonly AQUA_SHA256="89cb081adb19e425b1dca6b16d912c349a43535ce88d8713050738c9263618d0"
readonly AQUA_BIN_SHA256="e3e28482e8a0ef5258cf273e87b3f0cb72e50cb2c9f52d6a10fc8270f5571e5f"
readonly AQUA_PROXY_BIN_SHA256="0614f38f20377799ad36edb9a3e53c703546ed49ecf5ecd2e395379dd3a4bc3a"
readonly AQUA_ARCHIVE="aqua_linux_amd64.tar.gz"
readonly AQUA_URL="https://github.com/aquaproj/aqua/releases/download/v${AQUA_VERSION}/${AQUA_ARCHIVE}"
readonly AQUA_BOOTSTRAP_DIR="${PLATFORM_STATE_DIR}/bootstrap"
readonly AQUA_BIN="${AQUA_BOOTSTRAP_DIR}/aqua"
AQUA_TRUST_SHA256SUM="$(builtin command -p -v sha256sum 2>/dev/null || true)"
AQUA_TRUST_READLINK="$(builtin command -p -v readlink 2>/dev/null || true)"
AQUA_TRUST_TIMEOUT="$(builtin command -p -v timeout 2>/dev/null || true)"
readonly AQUA_TRUST_SHA256SUM AQUA_TRUST_READLINK AQUA_TRUST_TIMEOUT
export AQUA_SHA256 AQUA_URL

for aqua_trust_command in \
  "${AQUA_TRUST_SHA256SUM}" "${AQUA_TRUST_READLINK}" "${AQUA_TRUST_TIMEOUT}"; do
  if [[ "${aqua_trust_command}" != /* || -L "${aqua_trust_command}" ||
    ! -f "${aqua_trust_command}" || ! -x "${aqua_trust_command}" ]]; then
    printf 'FAIL  aqua-trust    trusted host command boundary is unavailable\n' >&2
    # The exit is the executed-script fallback.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
  fi
done
unset aqua_trust_command

readonly AQUA_CANDIDATE_MISSING=10
readonly AQUA_CANDIDATE_UNSAFE_TYPE=11
readonly AQUA_CANDIDATE_NOT_EXECUTABLE=12
readonly AQUA_CANDIDATE_HASH_MISMATCH=13

aqua_file_sha256_matches() {
  local expected="$1"
  local target="$2"
  local digest
  digest="$("${AQUA_TRUST_SHA256SUM}" -- "${target}")" || return
  digest="${digest%% *}"
  [[ "${digest}" == "${expected}" ]]
}

aqua_cached_candidate_status() {
  local target="$1"
  if [[ -L "${target}" ]]; then
    return "${AQUA_CANDIDATE_UNSAFE_TYPE}"
  fi
  if [[ -e "${target}" && ! -f "${target}" ]]; then
    return "${AQUA_CANDIDATE_UNSAFE_TYPE}"
  fi
  [[ -e "${target}" ]] || return "${AQUA_CANDIDATE_MISSING}"
  [[ -x "${target}" ]] || return "${AQUA_CANDIDATE_NOT_EXECUTABLE}"
  aqua_file_sha256_matches "${AQUA_BIN_SHA256}" "${target}" ||
    return "${AQUA_CANDIDATE_HASH_MISMATCH}"
}

aqua_verify_exact_version() {
  local target="$1"
  local actor="$2"
  local origin="$3"
  local output
  local status=0
  output="$("${AQUA_TRUST_TIMEOUT}" --foreground --kill-after=2s 10s \
    "${target}" version)" ||
    status=$?
  if [[ "${status}" != "0" ]]; then
    printf 'FAIL  %-13s %s Aqua version check exited %s\n' \
      "${actor}" "${origin}" "${status}" >&2
    return 1
  fi
  if [[ "${output}" != "${AQUA_VERSION}" ]]; then
    printf 'FAIL  %-13s %s Aqua reported an unexpected exact version: %q\n' \
      "${actor}" "${origin}" "${output}" >&2
    return 1
  fi
}

verify_existing_aqua() {
  local actor="${1:-toolchain}"
  local status=0
  aqua_cached_candidate_status "${AQUA_BIN}" || status=$?
  case "${status}" in
    0) ;;
    "${AQUA_CANDIDATE_MISSING}")
      printf 'FAIL  %-13s Aqua is not bootstrapped; run make bootstrap first.\n' \
        "${actor}" >&2
      return 1
      ;;
    "${AQUA_CANDIDATE_UNSAFE_TYPE}")
      printf 'FAIL  %-13s cached Aqua is not a regular file: %s\n' \
        "${actor}" "${AQUA_BIN}" >&2
      return 1
      ;;
    "${AQUA_CANDIDATE_NOT_EXECUTABLE}")
      printf 'FAIL  %-13s cached Aqua is not executable: %s\n' \
        "${actor}" "${AQUA_BIN}" >&2
      return 1
      ;;
    "${AQUA_CANDIDATE_HASH_MISMATCH}")
      printf 'FAIL  %-13s cached Aqua integrity mismatch: %s\n' \
        "${actor}" "${AQUA_BIN}" >&2
      return 1
      ;;
    *)
      printf 'FAIL  %-13s unexpected cached Aqua inspection status: %s\n' \
        "${actor}" "${status}" >&2
      return 1
      ;;
  esac
  aqua_verify_exact_version "${AQUA_BIN}" "${actor}" "cached"
}

verify_existing_aqua_proxy() {
  local actor="${1:-toolchain}"
  local candidate="${AQUA_ROOT_DIR}/aqua-proxy" root resolved
  if [[ ! -L "${candidate}" ]]; then
    printf 'FAIL  %-13s Aqua proxy link is absent or unsafe\n' "${actor}" >&2
    return 1
  fi
  root="$("${AQUA_TRUST_READLINK}" -f -- "${AQUA_ROOT_DIR}")" || return
  resolved="$("${AQUA_TRUST_READLINK}" -f -- "${candidate}")" || return
  case "${resolved}" in
    "${root}"/internal/pkgs/*) ;;
    *)
      printf 'FAIL  %-13s Aqua proxy escaped project state\n' "${actor}" >&2
      return 1
      ;;
  esac
  if [[ -L "${resolved}" || ! -f "${resolved}" || ! -x "${resolved}" ]]; then
    printf 'FAIL  %-13s Aqua proxy target is not a regular executable\n' \
      "${actor}" >&2
    return 1
  fi
  if ! aqua_file_sha256_matches "${AQUA_PROXY_BIN_SHA256}" "${resolved}"; then
    printf 'FAIL  %-13s Aqua proxy integrity mismatch\n' "${actor}" >&2
    return 1
  fi
}
