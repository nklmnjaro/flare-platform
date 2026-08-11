#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh" || exit 1
source "$(dirname -- "${BASH_SOURCE[0]}")/aqua-trust.sh" || exit 1

require_checksum_enabled() {
  local counts
  counts="$(
    awk '
      /^[[:space:]]*require_checksum[[:space:]]*:/ { keys++ }
      /^[[:space:]]*require_checksum[[:space:]]*:[[:space:]]*true[[:space:]]*$/ {
        locked++
      }
      END { printf "%d:%d\n", keys, locked }
    ' "${AQUA_CONFIG}"
  )" || return
  [[ "${counts}" == "1:1" ]]
}

enforce_ci_checksum_policy() {
  if [[ "${CI:-}" != "true" ]] || require_checksum_enabled; then
    return 0
  fi
  printf 'FAIL  bootstrap     CI requires committed Aqua checksums.\n' >&2
  printf '      Expected exactly one require_checksum: true setting.\n' >&2
  printf '      Run make tool-lock on a trusted online host and commit both lock files.\n' >&2
  return 1
}

inspect_cached_aqua() {
  local status=0
  aqua_cached_candidate_status "${AQUA_BIN}" || status=$?
  case "${status}" in
    0) aqua_verify_exact_version "${AQUA_BIN}" "bootstrap" "cached" ;;
    "${AQUA_CANDIDATE_MISSING}") return 1 ;;
    "${AQUA_CANDIDATE_UNSAFE_TYPE}")
      if [[ -L "${AQUA_BIN}" ]]; then
        printf 'FAIL  bootstrap     cached Aqua candidate is a symlink: %s\n' \
          "${AQUA_BIN}" >&2
      else
        printf 'FAIL  bootstrap     cached Aqua candidate is not a regular file: %s\n' \
          "${AQUA_BIN}" >&2
      fi
      return 2
      ;;
    "${AQUA_CANDIDATE_NOT_EXECUTABLE}")
      printf 'INFO  bootstrap     cached Aqua is not executable; staging verified replacement\n' >&2
      return 1
      ;;
    "${AQUA_CANDIDATE_HASH_MISMATCH}")
      printf 'INFO  bootstrap     cached Aqua integrity mismatch; staging verified replacement\n' >&2
      return 1
      ;;
    *)
      printf 'FAIL  bootstrap     unexpected cached Aqua inspection status: %s\n' \
        "${status}" >&2
      return 2
      ;;
  esac
}

cleanup_aqua_staging() {
  local staging="$1"
  case "${staging}" in
    "${AQUA_BOOTSTRAP_DIR}"/.aqua-install.*)
      rm -rf -- "${staging}"
      ;;
    *)
      printf 'FAIL  bootstrap     refusing unsafe Aqua staging cleanup: %s\n' \
        "${staging}" >&2
      return 1
      ;;
  esac
}

publish_verified_aqua() {
  local staging=""
  local archive
  local extract_dir
  local candidate
  local aqua_bin
  local status=0

  staging="$(mktemp -d "${AQUA_BOOTSTRAP_DIR}/.aqua-install.XXXXXXXXXX")" || {
    printf 'FAIL  bootstrap     unable to create guarded Aqua staging directory\n' >&2
    return 1
  }
  if [[ -L "${staging}" || ! -d "${staging}" ]]; then
    printf 'FAIL  bootstrap     Aqua staging path is not a regular directory\n' >&2
    cleanup_aqua_staging "${staging}" || return
    return 1
  fi
  archive="${staging}/${AQUA_ARCHIVE}"
  extract_dir="${staging}/extract"
  candidate="${extract_dir}/aqua"

  if ! curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 120 --retry 3 --retry-connrefused \
    --output "${archive}" "${AQUA_URL}"; then
    printf 'FAIL  bootstrap     verified Aqua download failed\n' >&2
    status=1
  elif [[ -L "${archive}" || ! -f "${archive}" ]]; then
    printf 'FAIL  bootstrap     downloaded Aqua archive is not a regular file\n' >&2
    status=1
  elif ! aqua_file_sha256_matches "${AQUA_SHA256}" "${archive}"; then
    printf 'FAIL  bootstrap     downloaded Aqua archive checksum mismatch\n' >&2
    status=1
  elif ! (umask 077 && mkdir -- "${extract_dir}"); then
    printf 'FAIL  bootstrap     unable to create guarded Aqua extraction directory\n' >&2
    status=1
  elif ! tar -xzf "${archive}" -C "${extract_dir}" aqua; then
    printf 'FAIL  bootstrap     unable to extract verified Aqua archive\n' >&2
    status=1
  elif [[ -L "${candidate}" || ! -f "${candidate}" ]]; then
    printf 'FAIL  bootstrap     extracted Aqua candidate is not a regular file\n' >&2
    status=1
  elif ! aqua_file_sha256_matches "${AQUA_BIN_SHA256}" "${candidate}"; then
    printf 'FAIL  bootstrap     extracted Aqua binary checksum mismatch\n' >&2
    status=1
  elif ! chmod 0755 -- "${candidate}"; then
    printf 'FAIL  bootstrap     unable to make verified Aqua executable\n' >&2
    status=1
  elif ! aqua_verify_exact_version "${candidate}" "bootstrap" "extracted"; then
    status=1
  else
    aqua_bin="$(prepare_state_file "bootstrap/aqua")" || status=$?
    if [[ "${status}" == "0" && "${aqua_bin}" != "${AQUA_BIN}" ]]; then
      printf 'FAIL  bootstrap     state helper returned unexpected Aqua path\n' >&2
      status=1
    fi
    if [[ "${status}" == "0" ]] && ! mv -fT -- "${candidate}" "${AQUA_BIN}"; then
      printf 'FAIL  bootstrap     unable to publish verified Aqua atomically\n' >&2
      status=1
    fi
  fi

  if ! cleanup_aqua_staging "${staging}"; then
    return 1
  fi
  return "${status}"
}

install_aqua() {
  local cache_status=0
  ensure_state_directory "bootstrap" || return
  ensure_state_directory "aqua" || return

  inspect_cached_aqua || cache_status=$?
  case "${cache_status}" in
    0) return 0 ;;
    1) ;;
    2) return 1 ;;
    *)
      printf 'FAIL  bootstrap     unexpected cached Aqua inspection status: %s\n' \
        "${cache_status}" >&2
      return 1
      ;;
  esac

  if ! publish_verified_aqua; then
    if [[ -e "${AQUA_BIN}" ]]; then
      printf 'FAIL  bootstrap     cached Aqua integrity rejected; verified replacement failed\n' >&2
    fi
    return 1
  fi
}

main() {
  "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only || return
  enforce_ci_checksum_policy || return
  install_aqua || return
  (cd "${PLATFORM_ROOT}" && "${AQUA_BIN}" install) || return
  verify_existing_aqua_proxy bootstrap || return
  printf 'PASS  bootstrap     pinned tools installed under %s\n' "${AQUA_ROOT_DIR}"
}

main "$@"
