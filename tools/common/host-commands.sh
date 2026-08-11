#!/usr/bin/env bash

# Source-only admission boundary for host-owned commands. env.sh captures the
# caller search path before loading this module and before publishing any
# project environment. Project-generated state is never a command source.

HOST_COMMAND_USAGE_STATUS=64
HOST_COMMAND_UNTRUSTED_STATUS=69
HOST_COMMAND_PATH=""
PLATFORM_HOST_PATH=""
builtin declare -gA HOST_COMMAND_PATH_CACHE
HOST_COMMAND_PATH_CACHE=()

host_command_fail() {
  builtin local command_name="$1"
  builtin shift
  builtin printf 'FAIL  host-command  %s: %s\n' \
    "${command_name}" "$*" >&2
  builtin return "${HOST_COMMAND_UNTRUSTED_STATUS}"
}

host_command_is_supported() {
  case "$1" in
    awk | basename | bash | cat | chmod | cmp | cp | curl | cut | diff | \
      dirname | docker | env | find | flock | git | grep | gzip | head | ln | make | \
      mkdir | mkfifo | mktemp | mv | od | readlink | rm | sed | sha256sum | \
      sleep | sort | stat | tail | tar | tee | timeout | tr | uname | wc)
      builtin return 0
      ;;
    *) builtin return 1 ;;
  esac
}

host_command_path_is_project_owned() {
  builtin local candidate="$1"
  if [[ "${candidate}" =~ ^/tmp/flare-platform-lifecycle-lease-[0-9a-f]{64}(/.*)?$ ]]; then
    builtin return 0
  fi
  case "${candidate}" in
    "${PLATFORM_ROOT}" | "${PLATFORM_ROOT}"/* | \
      "${PLATFORM_STATE_DIR}" | "${PLATFORM_STATE_DIR}"/* | \
      */.platform | */.platform/*)
      builtin return 0
      ;;
    *) builtin return 1 ;;
  esac
}

host_command_find_candidate() {
  builtin local command_name="$1"
  builtin local command_type candidate
  command_type="$(PATH="${PLATFORM_CALLER_HOST_PATH}" \
    builtin type -t -- "${command_name}" 2>/dev/null || builtin true)"
  if [[ -n "${command_type}" && "${command_type}" != file ]]; then
    host_command_fail "${command_name}" \
      "shadowed by shell ${command_type}"
    builtin return
  fi
  candidate="$(PATH="${PLATFORM_CALLER_HOST_PATH}" \
    builtin type -P -- "${command_name}" 2>/dev/null || builtin true)"
  if [[ -z "${candidate}" ]]; then
    host_command_fail "${command_name}" \
      "missing from caller host search path"
    builtin return
  fi
  if [[ "${candidate}" != /* || "${candidate}" == *$'\n'* ||
    "${candidate}" == *$'\r'* || "${candidate}" == *$'\t'* ]]; then
    host_command_fail "${command_name}" "resolved to an unsafe path"
    builtin return
  fi
  HOST_COMMAND_PATH="${candidate}"
}

host_command_admit_bootstrap_readlink() {
  builtin local candidate parent basename physical_parent canonical
  host_command_find_candidate readlink || builtin return
  candidate="${HOST_COMMAND_PATH}"
  if host_command_path_is_project_owned "${candidate}"; then
    host_command_fail readlink \
      "lookup location is inside repository or generated command state"
    builtin return
  fi
  parent="${candidate%/*}"
  basename="${candidate##*/}"
  physical_parent="$(builtin cd -P -- "${parent}" 2>/dev/null &&
    builtin pwd -P)" || {
    host_command_fail readlink "parent directory is not canonical"
    builtin return
  }
  canonical="${physical_parent}/${basename}"
  if host_command_path_is_project_owned "${canonical}"; then
    host_command_fail readlink \
      "physical lookup location is inside repository or generated command state"
    builtin return
  fi
  if [[ -L "${canonical}" || ! -f "${canonical}" || ! -x "${canonical}" ]]; then
    host_command_fail readlink \
      "bootstrap resolver is not a regular executable"
    builtin return
  fi
  HOST_COMMAND_PATH_CACHE[readlink]="${canonical}"
  HOST_COMMAND_PATH="${canonical}"
}

host_command_admit() {
  builtin local command_name="${1:-}" candidate canonical lookup_location
  builtin local physical_parent readlink_path
  if [[ -z "${command_name}" || ! "${command_name}" =~ ^[a-z][a-z0-9]*$ ]] ||
    ! host_command_is_supported "${command_name}"; then
    builtin printf 'FAIL  host-command  unsupported prerequisite: %q\n' \
      "${command_name}" >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  fi
  if [[ -v "HOST_COMMAND_PATH_CACHE[${command_name}]" ]]; then
    HOST_COMMAND_PATH="${HOST_COMMAND_PATH_CACHE[${command_name}]}"
    builtin return 0
  fi
  if [[ "${command_name}" == readlink ]]; then
    host_command_admit_bootstrap_readlink
    builtin return
  fi
  host_command_find_candidate "${command_name}" || builtin return
  candidate="${HOST_COMMAND_PATH}"
  if host_command_path_is_project_owned "${candidate}"; then
    host_command_fail "${command_name}" \
      "lookup location is inside repository or generated command state"
    builtin return
  fi
  physical_parent="$(builtin cd -P -- "${candidate%/*}" 2>/dev/null &&
    builtin pwd -P)" || {
    host_command_fail "${command_name}" \
      "lookup parent directory is not canonical"
    builtin return
  }
  lookup_location="${physical_parent}/${candidate##*/}"
  if host_command_path_is_project_owned "${lookup_location}"; then
    host_command_fail "${command_name}" \
      "physical lookup location is inside repository or generated command state"
    builtin return
  fi
  readlink_path="${HOST_COMMAND_PATH_CACHE[readlink]:-}"
  if [[ -z "${readlink_path}" ]]; then
    host_command_admit_bootstrap_readlink || builtin return
    readlink_path="${HOST_COMMAND_PATH}"
  fi
  canonical="$("${readlink_path}" -f -- "${candidate}" 2>/dev/null)" || {
    host_command_fail "${command_name}" "canonical path is unavailable"
    builtin return
  }
  if [[ "${canonical}" != /* || "${canonical}" == *$'\n'* ||
    "${canonical}" == *$'\r'* || "${canonical}" == *$'\t'* ||
    -L "${canonical}" || ! -f "${canonical}" || ! -x "${canonical}" ]]; then
    host_command_fail "${command_name}" \
      "canonical target is not a regular executable"
    builtin return
  fi
  if host_command_path_is_project_owned "${canonical}"; then
    host_command_fail "${command_name}" \
      "resolved inside repository or generated command state"
    builtin return
  fi
  HOST_COMMAND_PATH_CACHE["${command_name}"]="${canonical}"
  HOST_COMMAND_PATH="${canonical}"
}

host_command_path() {
  host_command_admit "${1:-}" || builtin return
  builtin printf '%s\n' "${HOST_COMMAND_PATH}"
}

run_host_command() {
  builtin local command_name="${1:-}"
  (($# > 0)) || {
    builtin printf 'FAIL  host-command  command name is required\n' >&2
    builtin return "${HOST_COMMAND_USAGE_STATUS}"
  }
  builtin shift
  host_command_admit "${command_name}" || builtin return
  "${HOST_COMMAND_PATH}" "$@"
}

host_command_sanitize_process_path() {
  builtin local entry canonical sanitized="" readlink_path
  builtin local -a entries
  entries=()
  readlink_path="${HOST_COMMAND_PATH_CACHE[readlink]:-}"
  [[ -n "${readlink_path}" ]] ||
    builtin return "${HOST_COMMAND_UNTRUSTED_STATUS}"
  IFS=: builtin read -r -a entries <<<"${PLATFORM_CALLER_HOST_PATH}"
  for entry in "${entries[@]}"; do
    [[ "${entry}" == /* && "${entry}" != *$'\n'* &&
      "${entry}" != *$'\r'* && "${entry}" != *$'\t'* ]] || continue
    [[ -d "${entry}" ]] || continue
    canonical="$("${readlink_path}" -f -- "${entry}" 2>/dev/null)" ||
      continue
    [[ -d "${canonical}" ]] || continue
    host_command_path_is_project_owned "${canonical}" && continue
    case ":${sanitized}:" in
      *:"${canonical}":*) ;;
      *) sanitized="${sanitized:+${sanitized}:}${canonical}" ;;
    esac
  done
  if [[ -z "${sanitized}" ]]; then
    host_command_fail PATH "no external host search directory remains"
    builtin return
  fi
  PLATFORM_HOST_PATH="${sanitized}"
  builtin export PLATFORM_HOST_PATH
  builtin export PATH="${PLATFORM_HOST_PATH}"
}

host_command_initialize() {
  host_command_admit readlink || builtin return
  host_command_sanitize_process_path
}
