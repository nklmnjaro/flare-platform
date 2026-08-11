#!/usr/bin/env bash
# Source-module constants and exports are consumed by other entrypoints.
# shellcheck disable=SC2034

# This module is sourced by bootstrap entrypoints. It must not execute a main.
# Callers source it exactly once. Canonical definitions must never be skipped
# merely because an inherited shell function has the same name.

# An exported variable keeps its export attribute when Bash assigns a new
# value. Remove that attribute before defining the trusted constants so no
# inherited AQUA_* input can leak through the sealed execution wrappers below.
builtin export -n AQUA_VERSION AQUA_SHA256 AQUA_BIN_SHA256 AQUA_PROXY_BIN_SHA256 \
  AQUA_ARCHIVE AQUA_URL AQUA_BOOTSTRAP_DIR AQUA_BIN \
  AQUA_CHECKSUM_FILE \
  AQUA_TRUST_SHA256SUM AQUA_TRUST_READLINK AQUA_TRUST_TIMEOUT \
  AQUA_CANDIDATE_MISSING AQUA_CANDIDATE_UNSAFE_TYPE \
  AQUA_CANDIDATE_NOT_EXECUTABLE AQUA_CANDIDATE_HASH_MISMATCH 2>/dev/null ||
  builtin true
builtin readonly AQUA_VERSION="2.62.3"
builtin readonly AQUA_SHA256="89cb081adb19e425b1dca6b16d912c349a43535ce88d8713050738c9263618d0"
builtin readonly AQUA_BIN_SHA256="e3e28482e8a0ef5258cf273e87b3f0cb72e50cb2c9f52d6a10fc8270f5571e5f"
builtin readonly AQUA_PROXY_BIN_SHA256="0614f38f20377799ad36edb9a3e53c703546ed49ecf5ecd2e395379dd3a4bc3a"
builtin readonly AQUA_ARCHIVE="aqua_linux_amd64.tar.gz"
builtin readonly AQUA_URL="https://github.com/aquaproj/aqua/releases/download/v${AQUA_VERSION}/${AQUA_ARCHIVE}"
builtin readonly AQUA_BOOTSTRAP_DIR="${PLATFORM_STATE_DIR}/bootstrap"
builtin readonly AQUA_BIN="${AQUA_BOOTSTRAP_DIR}/aqua"
builtin readonly AQUA_CHECKSUM_FILE="${PLATFORM_ROOT}/aqua-checksums.json"
AQUA_TRUST_SHA256SUM="$(host_command_path sha256sum)" || {
  aqua_trust_status=$?
  # shellcheck disable=SC2317
  builtin return "${aqua_trust_status}" 2>/dev/null ||
    builtin exit "${aqua_trust_status}"
}
AQUA_TRUST_READLINK="$(host_command_path readlink)" || {
  aqua_trust_status=$?
  # shellcheck disable=SC2317
  builtin return "${aqua_trust_status}" 2>/dev/null ||
    builtin exit "${aqua_trust_status}"
}
AQUA_TRUST_TIMEOUT="$(host_command_path timeout)" || {
  aqua_trust_status=$?
  # shellcheck disable=SC2317
  builtin return "${aqua_trust_status}" 2>/dev/null ||
    builtin exit "${aqua_trust_status}"
}
builtin readonly AQUA_TRUST_SHA256SUM AQUA_TRUST_READLINK AQUA_TRUST_TIMEOUT
builtin unset aqua_trust_status

builtin readonly AQUA_CANDIDATE_MISSING=10
builtin readonly AQUA_CANDIDATE_UNSAFE_TYPE=11
builtin readonly AQUA_CANDIDATE_NOT_EXECUTABLE=12
builtin readonly AQUA_CANDIDATE_HASH_MISMATCH=13

aqua_prepare_normal_environment() {
  builtin local checksum_mode="${1:-required}"
  builtin local execution_root="${2:-${AQUA_ROOT_DIR}}" aqua_name
  if [[ "${checksum_mode}" != required &&
    "${checksum_mode}" != allow-missing ]]; then
    builtin printf 'FAIL  aqua-trust    invalid checksum admission mode\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  fi
  if [[ -L "${AQUA_CONFIG}" || ! -f "${AQUA_CONFIG}" ||
    ("${checksum_mode}" == required &&
    (-L "${AQUA_CHECKSUM_FILE}" || ! -f "${AQUA_CHECKSUM_FILE}")) ||
    ("${checksum_mode}" == allow-missing &&
    (-L "${AQUA_CHECKSUM_FILE}" ||
    (-e "${AQUA_CHECKSUM_FILE}" && ! -f "${AQUA_CHECKSUM_FILE}"))) ]]; then
    builtin printf \
      'FAIL  aqua-trust    project Aqua config or checksum lock is unsafe\n' >&2
    builtin return "${HOST_COMMAND_UNTRUSTED_STATUS}"
  fi
  if [[ "${execution_root}" != /* || "${execution_root}" == *$'\n'* ||
    "${execution_root}" == *$'\r'* || "${execution_root}" == *$'\t'* ||
    -L "${execution_root}" || ! -d "${execution_root}" ]]; then
    builtin printf 'FAIL  aqua-trust    execution root is unsafe\n' >&2
    builtin return "${HOST_COMMAND_UNTRUSTED_STATUS}"
  fi
  while IFS= builtin read -r aqua_name; do
    builtin unset -v "${aqua_name}" || builtin return
  done < <(builtin compgen -A export AQUA_)
  builtin unset KIND_EXPERIMENTAL_PROVIDER KIND_EXPERIMENTAL_DOCKER_NETWORK
  builtin unset KIND_EXPERIMENTAL_PODMAN_NETWORK
  builtin unset KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER
  builtin unset KIND_CLUSTER_NAME KIND_DNS_SEARCH
  builtin export AQUA_ROOT_DIR="${execution_root}"
  builtin export AQUA_CONFIG="${PLATFORM_ROOT}/aqua.yaml"
  builtin export AQUA_DISABLE_LAZY_INSTALL=true
  builtin export PATH="${PLATFORM_HOST_PATH}"
}

aqua_validate_execution_arguments() {
  builtin local target="${1:-}"
  if [[ -z "${target}" || "${target}" != /* || "${target}" == *$'\n'* ||
    "${target}" == *$'\r'* || "${target}" == *$'\t'* ||
    ! -f "${target}" || ! -x "${target}" ]]; then
    builtin printf 'FAIL  aqua-trust    exact executable target is required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  fi
}

aqua_validate_bounded_duration() {
  builtin local duration="${1:-}"
  builtin local seconds
  if [[ "${duration}" =~ ^[1-9][0-9]{0,2}s$ ]]; then
    seconds="${duration%s}"
    if ((10#${seconds} <= 600)); then
      builtin return 0
    fi
  fi
  builtin printf \
    'FAIL  aqua-trust    invalid bounded duration: %q; expected 1s..600s\n' \
    "${duration}" >&2
  builtin return "${HOST_COMMAND_USAGE_STATUS}"
}

run_project_aqua() (
  builtin local target="${1:-}"
  (($# > 0)) || {
    builtin printf 'FAIL  aqua-trust    executable target is required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift
  aqua_validate_execution_arguments "${target}" || builtin return
  aqua_prepare_normal_environment || builtin return
  builtin exec "${target}" "$@"
)

run_project_aqua_bounded_with_checksum_mode() (
  builtin local max_time="${1:-}" target="${2:-}" checksum_mode="${3:-}"
  (($# >= 3)) || {
    builtin printf \
      'FAIL  aqua-trust    timeout, executable target and checksum mode are required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift 3
  aqua_validate_bounded_duration "${max_time}" || builtin return
  aqua_validate_execution_arguments "${target}" || builtin return
  aqua_prepare_normal_environment "${checksum_mode}" || builtin return
  builtin exec "${AQUA_TRUST_TIMEOUT}" --signal=TERM --kill-after=2s \
    "${max_time}" "${target}" "$@"
)

run_project_aqua_bounded() {
  builtin local max_time="${1:-}" target="${2:-}"
  (($# >= 2)) || {
    builtin printf \
      'FAIL  aqua-trust    timeout and executable target are required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift 2
  run_project_aqua_bounded_with_checksum_mode \
    "${max_time}" "${target}" required "$@"
}

run_project_aqua_command() (
  builtin local command_name="${1:-}"
  (($# > 0)) || {
    builtin printf 'FAIL  aqua-trust    managed command name is required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift
  if [[ ! "${command_name}" =~ ^[a-z][a-z0-9-]{0,63}$ ]]; then
    builtin printf 'FAIL  aqua-trust    unsafe managed command name: %q\n' \
      "${command_name}" >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  fi
  aqua_prepare_normal_environment || builtin return
  builtin exec "${AQUA_BIN}" exec -- "${command_name}" "$@"
)

run_project_aqua_command_bounded() (
  builtin local duration="${1:-}" command_name="${2:-}"
  (($# >= 2)) || {
    builtin printf \
      'FAIL  aqua-trust    timeout and managed command are required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift 2
  aqua_validate_bounded_duration "${duration}" || builtin return
  if [[ ! "${command_name}" =~ ^[a-z][a-z0-9-]{0,63}$ ]]; then
    builtin printf 'FAIL  aqua-trust    unsafe managed command name: %q\n' \
      "${command_name}" >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  fi
  aqua_prepare_normal_environment || builtin return
  builtin exec "${AQUA_TRUST_TIMEOUT}" --signal=TERM --kill-after=2s \
    "${duration}" "${AQUA_BIN}" exec -- "${command_name}" "$@"
)

# Tail-exec API for a caller that already owns an isolated process group.
exec_project_aqua_command_bounded() {
  builtin local duration="${1:-}" command_name="${2:-}"
  (($# >= 2)) || {
    builtin printf \
      'FAIL  aqua-trust    timeout and managed command are required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift 2
  aqua_validate_bounded_duration "${duration}" || builtin return
  if [[ ! "${command_name}" =~ ^[a-z][a-z0-9-]{0,63}$ ]]; then
    builtin printf 'FAIL  aqua-trust    unsafe managed command name: %q\n' \
      "${command_name}" >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  fi
  aqua_prepare_normal_environment || builtin return
  builtin exec "${AQUA_TRUST_TIMEOUT}" --signal=TERM --kill-after=2s \
    "${duration}" "${AQUA_BIN}" exec -- "${command_name}" "$@"
}

run_project_aqua_observation_bounded() (
  builtin local duration="${1:-}" observation_root="${2:-}"
  (($# >= 3)) || {
    builtin printf \
      'FAIL  aqua-trust    timeout, observation root and Aqua command are required\n' \
      >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift 2
  aqua_validate_bounded_duration "${duration}" || builtin return
  verify_existing_aqua aqua-observation >/dev/null 2>&1 || {
    builtin printf \
      'FAIL  aqua-trust    cached Aqua changed before observation\n' >&2
    builtin return 1
  }
  aqua_validate_execution_arguments "${AQUA_BIN}" || builtin return
  aqua_prepare_normal_environment required "${observation_root}" ||
    builtin return
  builtin exec "${AQUA_TRUST_TIMEOUT}" --signal=TERM --kill-after=2s \
    "${duration}" "${AQUA_BIN}" "$@"
)

run_project_aqua_install() (
  (($# == 0)) || {
    builtin printf \
      'FAIL  aqua-trust    install wrapper does not accept arguments\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  verify_existing_aqua aqua-install >/dev/null 2>&1 || {
    builtin printf \
      'FAIL  aqua-trust    cached Aqua changed before install\n' >&2
    builtin return 1
  }
  aqua_validate_execution_arguments "${AQUA_BIN}" || builtin return
  aqua_prepare_normal_environment || builtin return
  builtin export AQUA_ENFORCE_CHECKSUM=true
  builtin export AQUA_ENFORCE_REQUIRE_CHECKSUM=true
  builtin exec "${AQUA_BIN}" install
)

run_project_aqua_update_checksum() (
  (($# == 0)) || {
    builtin printf \
      'FAIL  aqua-trust    checksum wrapper does not accept arguments\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  verify_existing_aqua aqua-lock allow-missing >/dev/null 2>&1 || {
    builtin printf \
      'FAIL  aqua-trust    cached Aqua changed before checksum update\n' >&2
    builtin return 1
  }
  aqua_validate_execution_arguments "${AQUA_BIN}" || builtin return
  aqua_prepare_normal_environment allow-missing || builtin return
  builtin exec "${AQUA_BIN}" update-checksum -prune
)

aqua_file_sha256_matches() {
  builtin local expected="$1"
  builtin local target="$2"
  builtin local digest
  digest="$("${AQUA_TRUST_SHA256SUM}" -- "${target}")" || builtin return
  digest="${digest%% *}"
  [[ "${digest}" == "${expected}" ]]
}

aqua_cached_candidate_status() {
  builtin local target="$1"
  if [[ -L "${target}" ]]; then
    builtin return "${AQUA_CANDIDATE_UNSAFE_TYPE}"
  fi
  if [[ -e "${target}" && ! -f "${target}" ]]; then
    builtin return "${AQUA_CANDIDATE_UNSAFE_TYPE}"
  fi
  [[ -e "${target}" ]] || builtin return "${AQUA_CANDIDATE_MISSING}"
  [[ -x "${target}" ]] || builtin return "${AQUA_CANDIDATE_NOT_EXECUTABLE}"
  aqua_file_sha256_matches "${AQUA_BIN_SHA256}" "${target}" ||
    builtin return "${AQUA_CANDIDATE_HASH_MISMATCH}"
}

aqua_verify_exact_version() {
  builtin local target="$1"
  builtin local actor="$2"
  builtin local origin="$3"
  builtin local checksum_mode="${4:-required}"
  builtin local output
  builtin local status=0
  output="$(run_project_aqua_bounded_with_checksum_mode \
    10s "${target}" "${checksum_mode}" version)" ||
    status=$?
  if [[ "${status}" != "0" ]]; then
    builtin printf 'FAIL  %-13s %s Aqua version check exited %s\n' \
      "${actor}" "${origin}" "${status}" >&2
    builtin return 1
  fi
  if [[ "${output}" != "${AQUA_VERSION}" ]]; then
    builtin printf \
      'FAIL  %-13s %s Aqua reported an unexpected exact version: %q\n' \
      "${actor}" "${origin}" "${output}" >&2
    builtin return 1
  fi
}

verify_existing_aqua() {
  builtin local actor="${1:-toolchain}"
  builtin local checksum_mode="${2:-required}"
  builtin local status=0
  aqua_cached_candidate_status "${AQUA_BIN}" || status=$?
  case "${status}" in
    0) ;;
    "${AQUA_CANDIDATE_MISSING}")
      builtin printf \
        'FAIL  %-13s Aqua is not bootstrapped; run make bootstrap first.\n' \
        "${actor}" >&2
      builtin return 1
      ;;
    "${AQUA_CANDIDATE_UNSAFE_TYPE}")
      builtin printf 'FAIL  %-13s cached Aqua is not a regular file: %s\n' \
        "${actor}" "${AQUA_BIN}" >&2
      builtin return 1
      ;;
    "${AQUA_CANDIDATE_NOT_EXECUTABLE}")
      builtin printf 'FAIL  %-13s cached Aqua is not executable: %s\n' \
        "${actor}" "${AQUA_BIN}" >&2
      builtin return 1
      ;;
    "${AQUA_CANDIDATE_HASH_MISMATCH}")
      builtin printf 'FAIL  %-13s cached Aqua integrity mismatch: %s\n' \
        "${actor}" "${AQUA_BIN}" >&2
      builtin return 1
      ;;
    *)
      builtin printf \
        'FAIL  %-13s unexpected cached Aqua inspection status: %s\n' \
        "${actor}" "${status}" >&2
      builtin return 1
      ;;
  esac
  aqua_verify_exact_version \
    "${AQUA_BIN}" "${actor}" "cached" "${checksum_mode}"
}

verify_existing_aqua_proxy() {
  builtin local actor="${1:-toolchain}"
  builtin local candidate="${AQUA_ROOT_DIR}/aqua-proxy" root resolved
  if [[ ! -L "${candidate}" ]]; then
    builtin printf 'FAIL  %-13s Aqua proxy link is absent or unsafe\n' \
      "${actor}" >&2
    builtin return 1
  fi
  root="$("${AQUA_TRUST_READLINK}" -f -- "${AQUA_ROOT_DIR}")" ||
    builtin return
  resolved="$("${AQUA_TRUST_READLINK}" -f -- "${candidate}")" ||
    builtin return
  case "${resolved}" in
    "${root}"/internal/pkgs/*) ;;
    *)
      builtin printf 'FAIL  %-13s Aqua proxy escaped project state\n' \
        "${actor}" >&2
      builtin return 1
      ;;
  esac
  if [[ -L "${resolved}" || ! -f "${resolved}" || ! -x "${resolved}" ]]; then
    builtin printf \
      'FAIL  %-13s Aqua proxy target is not a regular executable\n' \
      "${actor}" >&2
    builtin return 1
  fi
  if ! aqua_file_sha256_matches "${AQUA_PROXY_BIN_SHA256}" "${resolved}"; then
    builtin printf 'FAIL  %-13s Aqua proxy integrity mismatch\n' "${actor}" >&2
    builtin return 1
  fi
}
