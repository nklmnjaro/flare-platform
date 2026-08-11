#!/usr/bin/env bash

# This module is sourced by bootstrap entrypoints. It must not execute a main.
# Callers source it exactly once. Canonical definitions must never be skipped
# merely because an inherited shell function has the same name.

readonly AQUA_VERSION="2.62.3"
readonly AQUA_SHA256="89cb081adb19e425b1dca6b16d912c349a43535ce88d8713050738c9263618d0"
readonly AQUA_BIN_SHA256="e3e28482e8a0ef5258cf273e87b3f0cb72e50cb2c9f52d6a10fc8270f5571e5f"
readonly AQUA_ARCHIVE="aqua_linux_amd64.tar.gz"
readonly AQUA_URL="https://github.com/aquaproj/aqua/releases/download/v${AQUA_VERSION}/${AQUA_ARCHIVE}"
readonly AQUA_BOOTSTRAP_DIR="${PLATFORM_STATE_DIR}/bootstrap"
readonly AQUA_BIN="${AQUA_BOOTSTRAP_DIR}/aqua"
export AQUA_SHA256 AQUA_URL

readonly AQUA_CANDIDATE_MISSING=10
readonly AQUA_CANDIDATE_UNSAFE_TYPE=11
readonly AQUA_CANDIDATE_NOT_EXECUTABLE=12
readonly AQUA_CANDIDATE_HASH_MISMATCH=13

aqua_file_sha256_matches() {
  local expected="$1"
  local target="$2"
  local digest
  digest="$(sha256sum -- "${target}")" || return
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
  output="$(timeout --foreground --kill-after=2s 10s "${target}" version)" ||
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
