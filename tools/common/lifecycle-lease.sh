#!/bin/bash -p

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  builtin printf 'FAIL  lifecycle     this file must be sourced\n' >&2
  builtin exit 2
fi

case "$(builtin declare -p PLATFORM_LIFECYCLE_LEASE_MODULE_LOADED 2>/dev/null ||
  builtin true)" in
  'declare -r PLATFORM_LIFECYCLE_LEASE_MODULE_LOADED="true"') builtin return 0 ;;
esac

for lifecycle_lease_name in PLATFORM_LIFECYCLE_LEASE_MODULE_LOADED \
  LIFECYCLE_LEASE_SCHEMA LIFECYCLE_LEASE_BUSY_STATUS \
  LIFECYCLE_LEASE_BOUNDARY_STATUS LIFECYCLE_LEASE_MAX_HOLDER_BYTES \
  LIFECYCLE_LEASE_DIRECTORY LIFECYCLE_LEASE_LOCK_FILE \
  LIFECYCLE_LEASE_HOLDER_FILE LIFECYCLE_LEASE_ACCESS_DIRECTORY \
  LIFECYCLE_LEASE_ACCESS_HOLDER_FILE LIFECYCLE_LEASE_DIRECTORY_FD \
  LIFECYCLE_LEASE_ROOT_OWNER \
  LIFECYCLE_LEASE_OWNER_PID LIFECYCLE_LEASE_OWNER_STARTTIME \
  LIFECYCLE_LEASE_FD LIFECYCLE_LEASE_RECORD LIFECYCLE_LEASE_INTERRUPTED \
  LIFECYCLE_RECORD_SCHEMA LIFECYCLE_RECORD_PID LIFECYCLE_RECORD_STARTTIME \
  LIFECYCLE_RECORD_CHECKOUT_ID LIFECYCLE_RECORD_ACTION \
  LIFECYCLE_RECORD_TOKEN; do
  builtin unset "${lifecycle_lease_name}" || builtin return 76
done
builtin unset lifecycle_lease_name

# The marker is consumed by the guarded reload check above.
# shellcheck disable=SC2034
builtin readonly PLATFORM_LIFECYCLE_LEASE_MODULE_LOADED=true
builtin readonly LIFECYCLE_LEASE_SCHEMA='flare-platform-lifecycle-lease-v1'
builtin readonly LIFECYCLE_LEASE_BUSY_STATUS=75
builtin readonly LIFECYCLE_LEASE_BOUNDARY_STATUS=76
builtin readonly LIFECYCLE_LEASE_MAX_HOLDER_BYTES=1024
LIFECYCLE_LEASE_DIRECTORY=''
LIFECYCLE_LEASE_LOCK_FILE=''
LIFECYCLE_LEASE_HOLDER_FILE=''
LIFECYCLE_LEASE_ACCESS_DIRECTORY=''
LIFECYCLE_LEASE_ACCESS_HOLDER_FILE=''
LIFECYCLE_LEASE_DIRECTORY_FD=''

LIFECYCLE_LEASE_ROOT_OWNER=false
LIFECYCLE_LEASE_OWNER_PID=''
LIFECYCLE_LEASE_OWNER_STARTTIME=''
LIFECYCLE_LEASE_INTERRUPTED=false
LIFECYCLE_LEASE_FD=''
LIFECYCLE_LEASE_RECORD=''
LIFECYCLE_RECORD_SCHEMA=''
LIFECYCLE_RECORD_PID=''
LIFECYCLE_RECORD_STARTTIME=''
LIFECYCLE_RECORD_CHECKOUT_ID=''
LIFECYCLE_RECORD_ACTION=''
LIFECYCLE_RECORD_TOKEN=''

builtin source "${PLATFORM_ROOT}/tools/common/process-state.sh"
builtin source "${PLATFORM_ROOT}/tools/common/checkout-identity.sh"

lifecycle_lease_fail() {
  builtin printf 'FAIL  lifecycle     %s\n' "$*" >&2
  return "${LIFECYCLE_LEASE_BOUNDARY_STATUS}"
}

lifecycle_lease_busy() {
  builtin printf 'FAIL  lifecycle     another lifecycle action is active\n' >&2
  return "${LIFECYCLE_LEASE_BUSY_STATUS}"
}

lifecycle_lease_interrupt() {
  local signal="${1:-}" status
  # Consumed by the entrypoint-specific EXIT cleanup after this signal trap.
  # shellcheck disable=SC2034
  LIFECYCLE_LEASE_INTERRUPTED=true
  case "${signal}" in
    HUP) status=129 ;;
    INT) status=130 ;;
    TERM) status=143 ;;
    *) status="${LIFECYCLE_LEASE_BOUNDARY_STATUS}" ;;
  esac
  builtin exit "${status}"
}

lifecycle_lease_install_interrupt_traps() {
  trap 'lifecycle_lease_interrupt HUP' HUP
  trap 'lifecycle_lease_interrupt INT' INT
  trap 'lifecycle_lease_interrupt TERM' TERM
}

lifecycle_lease_clear_interrupt_traps() {
  trap - HUP INT TERM
}

lifecycle_lease_action_is_valid() {
  case "${1:-}" in
    verify | verify-runtime | smoke | negative-smoke | \
      identity-negative-smoke | kind-up | kind-down | delete-namespace | clean)
      return 0
      ;;
    *) return 1 ;;
  esac
}

lifecycle_lease_configure_paths() {
  local digest
  local LC_ALL=C
  [[ -z "${LIFECYCLE_LEASE_DIRECTORY}" ]] || return 0
  digest="$({
    builtin printf \
      'flare-platform-lifecycle-path-v1\0project=flare-platform\0cluster=%s\0' \
      "${PLATFORM_CLUSTER_NAME}" |
      run_host_command sha256sum --
  })" || {
    lifecycle_lease_fail 'cluster lease identity hash failed'
    return
  }
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]] || {
    lifecycle_lease_fail 'cluster lease identity hash is malformed'
    return
  }
  LIFECYCLE_LEASE_DIRECTORY="/tmp/flare-platform-lifecycle-lease-${BASH_REMATCH[1]}"
  LIFECYCLE_LEASE_LOCK_FILE="${LIFECYCLE_LEASE_DIRECTORY}/lock"
  LIFECYCLE_LEASE_HOLDER_FILE="${LIFECYCLE_LEASE_DIRECTORY}/holder"
  LIFECYCLE_LEASE_ACCESS_DIRECTORY="${LIFECYCLE_LEASE_DIRECTORY}"
  LIFECYCLE_LEASE_ACCESS_HOLDER_FILE="${LIFECYCLE_LEASE_HOLDER_FILE}"
}

lifecycle_lease_validate_tmp() {
  local identity canonical
  if [[ -L /tmp || ! -d /tmp ]]; then
    lifecycle_lease_fail 'canonical temporary root is unsafe'
    return
  fi
  identity="$(run_host_command stat -Lc '%u:%a' -- /tmp)" || {
    lifecycle_lease_fail 'canonical temporary root identity is unavailable'
    return
  }
  canonical="$(run_host_command readlink -f -- /tmp)" || return
  [[ "${identity}" == 0:1777 && "${canonical}" == /tmp ]] || {
    lifecycle_lease_fail 'canonical temporary root identity is unsafe'
    return
  }
}

lifecycle_lease_validate_directory() {
  local identity
  lifecycle_lease_configure_paths || return
  lifecycle_lease_validate_tmp || return
  if [[ -L "${LIFECYCLE_LEASE_DIRECTORY}" ]]; then
    lifecycle_lease_fail 'lease directory must not be a symlink'
    return
  fi
  if [[ -e "${LIFECYCLE_LEASE_DIRECTORY}" &&
    ! -d "${LIFECYCLE_LEASE_DIRECTORY}" ]]; then
    lifecycle_lease_fail 'lease path is not a directory'
    return
  fi
  [[ -d "${LIFECYCLE_LEASE_DIRECTORY}" ]] || return 1
  identity="$(run_host_command stat -Lc '%u:%a:%h' -- \
    "${LIFECYCLE_LEASE_DIRECTORY}")" || {
    lifecycle_lease_fail 'lease directory identity is unavailable'
    return
  }
  [[ "${identity}" == "${EUID}:700:2" ]] || {
    lifecycle_lease_fail 'lease directory identity is unsafe'
    return
  }
}

lifecycle_lease_ensure_directory() {
  local status=0
  if lifecycle_lease_validate_directory; then
    return 0
  else
    status=$?
  fi
  ((status == 1)) || return "${status}"
  if (umask 077 && run_host_command mkdir -- "${LIFECYCLE_LEASE_DIRECTORY}") \
    2>/dev/null; then
    :
  fi
  lifecycle_lease_validate_directory
}

lifecycle_lease_validate_regular_mode() {
  local path="$1" label="$2" expected_mode="$3" identity
  if [[ -L "${path}" ]]; then
    lifecycle_lease_fail "${label} must not be a symlink"
    return
  fi
  if [[ ! -e "${path}" ]]; then
    return 1
  fi
  if [[ ! -f "${path}" ]]; then
    lifecycle_lease_fail "${label} is not a regular file"
    return
  fi
  identity="$(run_host_command stat -Lc '%u:%a:%h' -- "${path}")" || {
    lifecycle_lease_fail "${label} identity is unavailable"
    return
  }
  [[ "${identity}" == "${EUID}:${expected_mode}:1" ]] || {
    lifecycle_lease_fail "${label} identity is unsafe"
    return
  }
}

lifecycle_lease_pin_directory() {
  local status=0 directory_fd path_before path_after fd_before fd_after
  local directory_canonical fd_canonical
  if [[ "${LIFECYCLE_LEASE_DIRECTORY_FD}" =~ ^[0-9]{1,4}$ ]]; then
    return 0
  fi
  LIFECYCLE_LEASE_DIRECTORY_FD=''
  LIFECYCLE_LEASE_ACCESS_DIRECTORY="${LIFECYCLE_LEASE_DIRECTORY}"
  LIFECYCLE_LEASE_ACCESS_HOLDER_FILE="${LIFECYCLE_LEASE_HOLDER_FILE}"
  lifecycle_lease_validate_directory || return
  path_before="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_DIRECTORY}")" || return
  exec {directory_fd}<"${LIFECYCLE_LEASE_DIRECTORY}" || {
    lifecycle_lease_fail 'unable to pin lease directory'
    return
  }
  fd_before="$(run_host_command stat -Lc '%d:%i:%u:%a:%h' -- \
    "/proc/self/fd/${directory_fd}")" || {
    status=$?
    exec {directory_fd}<&-
    return "${status}"
  }
  directory_canonical="$(run_host_command readlink -f -- \
    "${LIFECYCLE_LEASE_DIRECTORY}")" || {
    status=$?
    exec {directory_fd}<&-
    return "${status}"
  }
  fd_canonical="$(run_host_command readlink -f -- \
    "/proc/self/fd/${directory_fd}")" || {
    status=$?
    exec {directory_fd}<&-
    return "${status}"
  }
  if [[ "${fd_before}" != "${path_before}:${EUID}:700:2" ||
    "${directory_canonical}" != "${LIFECYCLE_LEASE_DIRECTORY}" ||
    "${fd_canonical}" != "${LIFECYCLE_LEASE_DIRECTORY}" ]]; then
    exec {directory_fd}<&-
    lifecycle_lease_fail 'lease directory changed while pinning'
    return
  fi
  path_after="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_DIRECTORY}")" || {
    status=$?
    exec {directory_fd}<&-
    return "${status}"
  }
  fd_after="$(run_host_command stat -Lc '%d:%i:%u:%a:%h' -- \
    "/proc/self/fd/${directory_fd}")" || {
    status=$?
    exec {directory_fd}<&-
    return "${status}"
  }
  if [[ "${path_after}" != "${path_before}" || "${fd_after}" != "${fd_before}" ]]; then
    exec {directory_fd}<&-
    lifecycle_lease_fail 'lease directory changed while pinning'
    return
  fi
  LIFECYCLE_LEASE_DIRECTORY_FD="${directory_fd}"
  LIFECYCLE_LEASE_ACCESS_DIRECTORY="/proc/self/fd/${directory_fd}"
  LIFECYCLE_LEASE_ACCESS_HOLDER_FILE="${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/holder"
}

lifecycle_lease_ensure_lock_file() {
  local status=0 path_before path_after access_lock access_identity path_identity
  lifecycle_lease_pin_directory || return
  access_lock="${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/lock"
  if lifecycle_lease_validate_regular_mode \
    "${access_lock}" 'lease lock' 600; then
    :
  else
    status=$?
    if ((status != 1)); then
      lifecycle_lease_close_directory_fd
      return "${status}"
    fi
    if (umask 077 && builtin set -o noclobber && : >"${access_lock}") \
      2>/dev/null; then
      :
    fi
    if lifecycle_lease_validate_regular_mode \
      "${access_lock}" 'lease lock' 600; then
      :
    else
      status=$?
      lifecycle_lease_close_directory_fd
      return "${status}"
    fi
  fi
  path_after="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_DIRECTORY}")" || {
    status=$?
    lifecycle_lease_close_directory_fd
    return "${status}"
  }
  lifecycle_lease_validate_regular_mode \
    "${LIFECYCLE_LEASE_LOCK_FILE}" 'lease lock' 600 || {
    status=$?
    lifecycle_lease_close_directory_fd
    return "${status}"
  }
  access_identity="$(run_host_command stat -Lc '%d:%i' -- "${access_lock}")" || {
    status=$?
    lifecycle_lease_close_directory_fd
    return "${status}"
  }
  path_identity="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_LOCK_FILE}")" || {
    status=$?
    lifecycle_lease_close_directory_fd
    return "${status}"
  }
  path_before="$(run_host_command stat -Lc '%d:%i' -- \
    "/proc/self/fd/${LIFECYCLE_LEASE_DIRECTORY_FD}")" || {
    status=$?
    lifecycle_lease_close_directory_fd
    return "${status}"
  }
  if [[ "${path_after}" != "${path_before}" ||
    "${access_identity}" != "${path_identity}" ]]; then
    lifecycle_lease_close_directory_fd
    lifecycle_lease_fail 'lease directory or lock changed while creating'
    return
  fi
}

lifecycle_lease_close_directory_fd() {
  local directory_fd="${LIFECYCLE_LEASE_DIRECTORY_FD}"
  if [[ "${directory_fd}" =~ ^[0-9]{1,4}$ ]]; then
    { exec {directory_fd}<&-; } 2>/dev/null || true
  fi
  LIFECYCLE_LEASE_DIRECTORY_FD=''
  LIFECYCLE_LEASE_ACCESS_DIRECTORY="${LIFECYCLE_LEASE_DIRECTORY}"
  LIFECYCLE_LEASE_ACCESS_HOLDER_FILE="${LIFECYCLE_LEASE_HOLDER_FILE}"
}

lifecycle_lease_cleanup_orphans() {
  local path basename
  local -a entries=()
  lifecycle_lease_fd_identity "${LIFECYCLE_LEASE_FD}" || return
  if ! run_host_command flock --exclusive --nonblock \
    --conflict-exit-code "${LIFECYCLE_LEASE_BUSY_STATUS}" \
    "${LIFECYCLE_LEASE_FD}"; then
    lifecycle_lease_fail 'orphan cleanup requires the exclusive lock'
    return
  fi
  builtin shopt -s nullglob dotglob
  entries=("${LIFECYCLE_LEASE_ACCESS_DIRECTORY}"/*)
  builtin shopt -u nullglob dotglob
  for path in "${entries[@]}"; do
    basename="${path##*/}"
    case "${basename}" in
      lock | holder) continue ;;
    esac
    if [[ ! "${basename}" =~ ^\.(nonce\.[A-Za-z0-9]{16}|holder\.[A-Za-z0-9]{8})$ ]]; then
      lifecycle_lease_fail 'lease directory contains an unexpected entry'
      return
    fi
    lifecycle_lease_validate_regular_mode \
      "${path}" 'orphan lease staging file' 600 || return
    run_host_command rm -f -- "${path}" || {
      lifecycle_lease_fail 'unable to remove orphan lease staging file'
      return
    }
  done
  lifecycle_lease_fd_identity "${LIFECYCLE_LEASE_FD}"
}

lifecycle_lease_fd_identity() {
  local fd="$1" directory_identity pinned_directory_identity
  local path_identity access_identity fd_identity path_canonical fd_canonical
  [[ "${fd}" =~ ^[0-9]{1,4}$ && -e "/proc/self/fd/${fd}" ]] || {
    lifecycle_lease_fail 'inherited lease descriptor is unavailable'
    return
  }
  [[ "${LIFECYCLE_LEASE_DIRECTORY_FD}" =~ ^[0-9]{1,4}$ ]] || {
    lifecycle_lease_fail 'lease directory descriptor is unavailable'
    return
  }
  lifecycle_lease_validate_directory || return
  directory_identity="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_DIRECTORY}")" || return
  pinned_directory_identity="$(run_host_command stat -Lc '%d:%i' -- \
    "/proc/self/fd/${LIFECYCLE_LEASE_DIRECTORY_FD}")" || return
  [[ "${directory_identity}" == "${pinned_directory_identity}" ]] || {
    lifecycle_lease_fail 'canonical lease directory no longer matches its descriptor'
    return
  }
  lifecycle_lease_validate_regular_mode \
    "${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/lock" 'lease lock' 600 || return
  lifecycle_lease_validate_regular_mode \
    "${LIFECYCLE_LEASE_LOCK_FILE}" 'lease lock' 600 || return
  access_identity="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/lock")" || return
  path_identity="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_LOCK_FILE}")" || return
  fd_identity="$(run_host_command stat -Lc '%d:%i' -- "/proc/self/fd/${fd}")" || {
    lifecycle_lease_fail 'inherited lease descriptor identity is unavailable'
    return
  }
  path_canonical="$(run_host_command readlink -f -- \
    "${LIFECYCLE_LEASE_LOCK_FILE}")" || return
  fd_canonical="$(run_host_command readlink -f -- "/proc/self/fd/${fd}")" || {
    lifecycle_lease_fail 'inherited lease descriptor target is unavailable'
    return
  }
  [[ "${access_identity}" == "${path_identity}" &&
    "${path_identity}" == "${fd_identity}" &&
    "${path_canonical}" == "${fd_canonical}" &&
    "${path_canonical}" == "${LIFECYCLE_LEASE_LOCK_FILE}" ]] || {
    lifecycle_lease_fail 'inherited lease descriptor does not name the canonical lock'
    return
  }
}

lifecycle_lease_read_holder_exact() (
  local path_before path_after fd_identity fd_after path_canonical fd_canonical
  local holder_fd size byte_dump byte newline_count=0 raw='' octal character
  local device inode owner mode links extra
  local -a bytes=()
  local LC_ALL=C
  lifecycle_lease_validate_regular_mode \
    "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" 'lease holder' 600 || return
  path_before="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}")" || return
  exec {holder_fd}<"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" || {
    lifecycle_lease_fail 'unable to open lease holder'
    return
  }
  # shellcheck disable=SC2317
  trap '{ exec {holder_fd}<&-; } 2>/dev/null || true' EXIT
  fd_identity="$(run_host_command stat -Lc '%d:%i:%u:%a:%h:%s' -- \
    "/proc/self/fd/${holder_fd}")" || return
  IFS=: builtin read -r device inode owner mode links size extra \
    <<<"${fd_identity}" || true
  path_canonical="$(run_host_command readlink -f -- \
    "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}")" || return
  fd_canonical="$(run_host_command readlink -f -- \
    "/proc/self/fd/${holder_fd}")" || return
  [[ "${path_before}" == "${device}:${inode}" &&
    "${owner}" == "${EUID}" && "${mode}" == 600 && "${links}" == 1 &&
    -z "${extra}" && "${path_canonical}" == "${fd_canonical}" &&
    "${path_canonical}" == "${LIFECYCLE_LEASE_HOLDER_FILE}" ]] || {
    lifecycle_lease_fail 'lease holder changed while opening'
    return
  }
  [[ "${size}" =~ ^[0-9]+$ ]] || {
    lifecycle_lease_fail 'lease holder size is malformed'
    return
  }
  if ((10#${size} == 0 || \
    10#${size} > LIFECYCLE_LEASE_MAX_HOLDER_BYTES)); then
    lifecycle_lease_fail 'lease holder size is malformed'
    return
  fi
  byte_dump="$(
    builtin set -o pipefail
    run_host_command head -c "$((LIFECYCLE_LEASE_MAX_HOLDER_BYTES + 1))" -- \
      "/proc/self/fd/${holder_fd}" |
      run_host_command od -An -v -t u1
  )" || return
  [[ "${byte_dump}" =~ ^[[:space:][:digit:]]+$ ]] || {
    lifecycle_lease_fail 'lease holder bytes are malformed'
    return
  }
  builtin read -r -a bytes <<<"${byte_dump//$'\n'/ }"
  [[ ${#bytes[@]} -eq $((10#${size})) ]] || {
    lifecycle_lease_fail 'lease holder bytes are malformed'
    return
  }
  for byte in "${bytes[@]}"; do
    [[ "${byte}" =~ ^[0-9]+$ ]] || {
      lifecycle_lease_fail 'lease holder bytes are malformed'
      return
    }
    if ((10#${byte} == 10)); then
      ((newline_count += 1))
      raw+=$'\n'
    elif ((10#${byte} < 32 || 10#${byte} > 126)); then
      lifecycle_lease_fail 'lease holder contains a forbidden byte'
      return
    else
      builtin printf -v octal '%03o' "$((10#${byte}))"
      builtin printf -v character '%b' "\\${octal}"
      raw+="${character}"
    fi
  done
  [[ $((10#${bytes[-1]})) -eq 10 && ${newline_count} -eq 6 ]] || {
    lifecycle_lease_fail 'lease holder framing is malformed'
    return
  }
  fd_after="$(run_host_command stat -Lc '%d:%i:%u:%a:%h:%s' -- \
    "/proc/self/fd/${holder_fd}")" || return
  path_after="$(run_host_command stat -Lc '%d:%i' -- \
    "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}")" || {
    lifecycle_lease_fail 'lease holder changed while reading'
    return
  }
  [[ "${fd_after}" == "${fd_identity}" &&
    "${path_after}" == "${path_before}" ]] || {
    lifecycle_lease_fail 'lease holder changed while reading'
    return
  }
  builtin printf '%s' "${raw}"
)

lifecycle_lease_validate_holder() {
  local raw status=0
  local -a lines=()
  if raw="$(lifecycle_lease_read_holder_exact)"; then
    :
  else
    status=$?
    if ((status == 1)); then
      lifecycle_lease_fail 'lease holder is unavailable'
      return
    fi
    return "${status}"
  fi
  mapfile -t lines <<<"${raw}" || return
  [[ ${#lines[@]} -eq 6 &&
    "${lines[0]}" == schema=* && "${lines[1]}" == pid=* &&
    "${lines[2]}" == starttime=* && "${lines[3]}" == checkout_id=* &&
    "${lines[4]}" == action=* && "${lines[5]}" == token=* ]] || {
    lifecycle_lease_fail 'lease holder is malformed'
    return
  }
  LIFECYCLE_RECORD_SCHEMA="${lines[0]#schema=}"
  LIFECYCLE_RECORD_PID="${lines[1]#pid=}"
  LIFECYCLE_RECORD_STARTTIME="${lines[2]#starttime=}"
  LIFECYCLE_RECORD_CHECKOUT_ID="${lines[3]#checkout_id=}"
  LIFECYCLE_RECORD_ACTION="${lines[4]#action=}"
  LIFECYCLE_RECORD_TOKEN="${lines[5]#token=}"
  if [[ "${LIFECYCLE_RECORD_SCHEMA}" != "${LIFECYCLE_LEASE_SCHEMA}" ||
    ! "${LIFECYCLE_RECORD_PID}" =~ ^[1-9][0-9]{0,9}$ ||
    ! "${LIFECYCLE_RECORD_STARTTIME}" =~ ^[0-9]+$ ||
    ! "${LIFECYCLE_RECORD_CHECKOUT_ID}" =~ ^sha256:[0-9a-f]{64}$ ||
    ! "${LIFECYCLE_RECORD_TOKEN}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    ! lifecycle_lease_action_is_valid "${LIFECYCLE_RECORD_ACTION}"; then
    lifecycle_lease_fail 'lease holder is malformed'
    return
  fi
  LIFECYCLE_LEASE_RECORD="${raw}"
}

lifecycle_lease_holder_state() {
  local state
  state="$(linux_process_state \
    "${LIFECYCLE_RECORD_PID}" "${LIFECYCLE_RECORD_STARTTIME}")" || {
    lifecycle_lease_fail 'lease holder process state is unavailable'
    return
  }
  case "${state}" in
    live | terminal | absent | replaced) builtin printf '%s\n' "${state}" ;;
    *) lifecycle_lease_fail 'lease holder process state is malformed' ;;
  esac
}

lifecycle_lease_render_holder() {
  local pid="$1" starttime="$2" checkout_id="$3" action="$4" token="$5"
  builtin printf 'schema=%s\n' "${LIFECYCLE_LEASE_SCHEMA}"
  builtin printf 'pid=%s\n' "${pid}"
  builtin printf 'starttime=%s\n' "${starttime}"
  builtin printf 'checkout_id=%s\n' "${checkout_id}"
  builtin printf 'action=%s\n' "${action}"
  builtin printf 'token=%s\n' "${token}"
}

lifecycle_lease_publish_holder() {
  local pid="$1" starttime="$2" checkout_id="$3" action="$4" token="$5"
  local temporary prepared_record status=0
  lifecycle_lease_fd_identity "${LIFECYCLE_LEASE_FD}" || return
  if ! run_host_command flock --exclusive --nonblock \
    --conflict-exit-code "${LIFECYCLE_LEASE_BUSY_STATUS}" \
    "${LIFECYCLE_LEASE_FD}"; then
    lifecycle_lease_fail 'lease holder publication requires the exclusive lock'
    return
  fi
  temporary="$(run_host_command mktemp \
    "${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/.holder.XXXXXXXX")" || {
    lifecycle_lease_fail 'unable to stage lease holder'
    return
  }
  if lifecycle_lease_validate_regular_mode \
    "${temporary}" 'lease holder staging file' 600; then
    :
  else
    status=$?
    run_host_command rm -f -- "${temporary}" || true
    return "${status}"
  fi
  if ! lifecycle_lease_render_holder \
    "${pid}" "${starttime}" "${checkout_id}" "${action}" "${token}" \
    >"${temporary}"; then
    run_host_command rm -f -- "${temporary}" || true
    return "${LIFECYCLE_LEASE_BOUNDARY_STATUS}"
  fi
  if [[ -e "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" ||
    -L "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" ]]; then
    if lifecycle_lease_validate_holder; then
      :
    else
      status=$?
      run_host_command rm -f -- "${temporary}" || true
      return "${status}"
    fi
  fi
  if ! run_host_command mv -fT -- \
    "${temporary}" "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"; then
    run_host_command rm -f -- "${temporary}" || true
    lifecycle_lease_fail 'unable to publish lease holder atomically'
    return
  fi
  lifecycle_lease_validate_holder || return
  lifecycle_lease_fd_identity "${LIFECYCLE_LEASE_FD}" || return
  prepared_record="$(lifecycle_lease_render_holder \
    "${pid}" "${starttime}" "${checkout_id}" "${action}" "${token}")" || return
  [[ "${LIFECYCLE_LEASE_RECORD}" == "${prepared_record}" ]] || {
    lifecycle_lease_fail 'published lease holder differs from requested identity'
    return
  }
}

lifecycle_lease_generate_token() {
  local pid="$1" starttime="$2" checkout_id="$3" action="$4"
  local nonce digest status=0
  nonce="$(run_host_command mktemp \
    "${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/.nonce.XXXXXXXXXXXXXXXX")" || {
    lifecycle_lease_fail 'unable to generate lease token'
    return
  }
  [[ -f "${nonce}" && ! -L "${nonce}" ]] || {
    run_host_command rm -f -- "${nonce}" 2>/dev/null || true
    lifecycle_lease_fail 'lease token source is unsafe'
    return
  }
  if lifecycle_lease_validate_regular_mode \
    "${nonce}" 'lease token source' 600; then
    :
  else
    status=$?
    run_host_command rm -f -- "${nonce}" 2>/dev/null || true
    return "${status}"
  fi
  digest="$({
    builtin printf \
      'flare-platform-lifecycle-token-v1\0pid=%s\0starttime=%s\0checkout=%s\0action=%s\0nonce=%s\0' \
      "${pid}" "${starttime}" "${checkout_id}" "${action}" "${nonce##*/}" |
      run_host_command sha256sum --
  })" || {
    run_host_command rm -f -- "${nonce}" || true
    lifecycle_lease_fail 'lease token hash failed'
    return
  }
  run_host_command rm -f -- "${nonce}" || {
    lifecycle_lease_fail 'lease token source cleanup failed'
    return
  }
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]] || {
    lifecycle_lease_fail 'lease token hash is malformed'
    return
  }
  builtin printf 'sha256:%s\n' "${BASH_REMATCH[1]}"
}

lifecycle_lease_assert_internal() {
  local checkout_id holder_state inherited_fd
  lifecycle_lease_configure_paths || return
  [[ "${PLATFORM_LIFECYCLE_LEASE_SCHEMA:-}" == "${LIFECYCLE_LEASE_SCHEMA}" &&
    "${PLATFORM_LIFECYCLE_LEASE_TOKEN:-}" =~ ^sha256:[0-9a-f]{64}$ &&
    "${PLATFORM_LIFECYCLE_LEASE_FD:-}" =~ ^[0-9]{1,4}$ ]] || {
    lifecycle_lease_fail 'inherited lease identity is incomplete'
    return
  }
  inherited_fd="${PLATFORM_LIFECYCLE_LEASE_FD}"
  lifecycle_lease_pin_directory || return
  lifecycle_lease_fd_identity "${inherited_fd}" || return
  if ! run_host_command flock --exclusive --nonblock \
    --conflict-exit-code "${LIFECYCLE_LEASE_BUSY_STATUS}" "${inherited_fd}"; then
    lifecycle_lease_fail 'inherited descriptor does not share the active lease'
    return
  fi
  lifecycle_lease_validate_holder || return
  checkout_id="$(platform_checkout_identity)" || return
  [[ "${LIFECYCLE_RECORD_CHECKOUT_ID}" == "${checkout_id}" &&
    "${LIFECYCLE_RECORD_TOKEN}" == "${PLATFORM_LIFECYCLE_LEASE_TOKEN}" ]] || {
    lifecycle_lease_fail 'inherited lease identity does not match the holder'
    return
  }
  holder_state="$(lifecycle_lease_holder_state)" || return
  [[ "${holder_state}" == live ]] || {
    lifecycle_lease_fail 'inherited lease holder is no longer live'
    return
  }
  LIFECYCLE_LEASE_FD="${inherited_fd}"
}

lifecycle_lease_assert() {
  local status=0 had_directory_fd=false
  [[ "${LIFECYCLE_LEASE_DIRECTORY_FD}" =~ ^[0-9]{1,4}$ ]] &&
    had_directory_fd=true
  if lifecycle_lease_assert_internal; then
    status=0
  else
    status=$?
  fi
  [[ "${had_directory_fd}" == true ]] || lifecycle_lease_close_directory_fd
  ((status == 0)) && return 0
  ((status == LIFECYCLE_LEASE_BOUNDARY_STATUS)) && return "${status}"
  lifecycle_lease_fail 'lifecycle lease assertion failed at a trust boundary'
}

lifecycle_lease_abandon_open_lock() {
  local opened_fd="${LIFECYCLE_LEASE_FD}"
  exec {opened_fd}>&-
  LIFECYCLE_LEASE_FD=''
  lifecycle_lease_close_directory_fd
}

lifecycle_lease_open_root_lock() {
  local opened_fd path_before path_after status=0 access_lock
  access_lock="${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/lock"
  path_before="$(run_host_command stat -Lc '%d:%i' -- "${access_lock}")" || {
    status=$?
    lifecycle_lease_close_directory_fd
    return "${status}"
  }
  exec {opened_fd}<>"${access_lock}" || {
    lifecycle_lease_close_directory_fd
    lifecycle_lease_fail 'unable to open lease lock'
    return
  }
  LIFECYCLE_LEASE_FD="${opened_fd}"
  if ! lifecycle_lease_fd_identity "${opened_fd}"; then
    lifecycle_lease_abandon_open_lock
    return "${LIFECYCLE_LEASE_BOUNDARY_STATUS}"
  fi
  path_after="$(run_host_command stat -Lc '%d:%i' -- "${access_lock}")" || {
    status=$?
    lifecycle_lease_abandon_open_lock
    return "${status}"
  }
  if [[ "${path_before}" != "${path_after}" ]]; then
    lifecycle_lease_abandon_open_lock
    lifecycle_lease_fail 'lease lock changed while opening'
    return
  fi
  status=0
  run_host_command flock --exclusive --nonblock \
    --conflict-exit-code "${LIFECYCLE_LEASE_BUSY_STATUS}" \
    "${opened_fd}" || status=$?
  if ((status != 0)); then
    lifecycle_lease_abandon_open_lock
    if ((status == LIFECYCLE_LEASE_BUSY_STATUS)); then
      lifecycle_lease_busy
    else
      lifecycle_lease_fail 'kernel lease lock acquisition failed'
    fi
    return
  fi
  lifecycle_lease_cleanup_orphans || {
    status=$?
    lifecycle_lease_abandon_open_lock
    return "${status}"
  }
}

lifecycle_lease_validate_unlocked_holder() {
  local holder_state
  if [[ -e "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" ||
    -L "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" ]]; then
    lifecycle_lease_validate_holder || return
    holder_state="$(lifecycle_lease_holder_state)" || return
    if [[ "${holder_state}" == live ]]; then
      lifecycle_lease_fail 'live holder exists without its kernel lock'
      return
    fi
  fi
}

lifecycle_lease_current_starttime() {
  local current_pid="$1"
  local current_snapshot observed_pid observed_pgrp starttime kernel_state
  current_snapshot="$(linux_process_snapshot "${current_pid}")" || {
    lifecycle_lease_fail 'current process identity is unavailable'
    return
  }
  IFS=$'\t' builtin read -r observed_pid observed_pgrp starttime kernel_state \
    <<<"${current_snapshot}"
  if [[ "${observed_pid}" != "${current_pid}" ||
    ! "${observed_pgrp}" =~ ^[1-9][0-9]{0,9}$ ||
    ! "${starttime}" =~ ^[0-9]+$ ]] ||
    linux_process_terminal_kernel_state "${kernel_state}"; then
    lifecycle_lease_fail 'current process identity is malformed'
    return
  fi
  builtin printf '%s\n' "${starttime}"
}

lifecycle_lease_publish_root_ownership() {
  local action="$1" current_pid="$2" starttime="$3"
  local checkout_id token
  checkout_id="$(platform_checkout_identity)" || return
  token="$(lifecycle_lease_generate_token \
    "${current_pid}" "${starttime}" "${checkout_id}" "${action}")" || return
  lifecycle_lease_publish_holder \
    "${current_pid}" "${starttime}" "${checkout_id}" "${action}" "${token}" ||
    return

  LIFECYCLE_LEASE_ROOT_OWNER=true
  LIFECYCLE_LEASE_OWNER_PID="${current_pid}"
  LIFECYCLE_LEASE_OWNER_STARTTIME="${starttime}"
  PLATFORM_LIFECYCLE_LEASE_SCHEMA="${LIFECYCLE_LEASE_SCHEMA}"
  PLATFORM_LIFECYCLE_LEASE_TOKEN="${token}"
  PLATFORM_LIFECYCLE_LEASE_FD="${LIFECYCLE_LEASE_FD}"
  builtin export PLATFORM_LIFECYCLE_LEASE_SCHEMA \
    PLATFORM_LIFECYCLE_LEASE_TOKEN PLATFORM_LIFECYCLE_LEASE_FD
}

lifecycle_lease_acquire_root() {
  local action="$1" current_pid="$2" starttime status=0
  lifecycle_lease_ensure_directory || return
  lifecycle_lease_ensure_lock_file || return
  lifecycle_lease_open_root_lock || return
  if lifecycle_lease_validate_unlocked_holder; then
    status=0
  else
    status=$?
    lifecycle_lease_abandon_open_lock
    return "${status}"
  fi
  starttime="$(lifecycle_lease_current_starttime "${current_pid}")" || {
    status=$?
    lifecycle_lease_abandon_open_lock
    return "${status}"
  }
  lifecycle_lease_publish_root_ownership \
    "${action}" "${current_pid}" "${starttime}" || {
    status=$?
    lifecycle_lease_abandon_open_lock
    return "${status}"
  }
}

lifecycle_lease_acquire() {
  local action="${1:-}" current_pid="${BASHPID}" status=0
  if [[ $# -ne 1 ]] || ! lifecycle_lease_action_is_valid "${action}"; then
    lifecycle_lease_fail 'lifecycle action is invalid'
    return
  fi
  lifecycle_lease_configure_paths || return
  if [[ -v PLATFORM_LIFECYCLE_LEASE_SCHEMA ||
    -v PLATFORM_LIFECYCLE_LEASE_TOKEN ||
    -v PLATFORM_LIFECYCLE_LEASE_FD ]]; then
    lifecycle_lease_assert
    return
  fi
  if lifecycle_lease_acquire_root "${action}" "${current_pid}"; then
    return 0
  else
    status=$?
  fi
  lifecycle_lease_close_directory_fd
  case "${status}" in
    "${LIFECYCLE_LEASE_BUSY_STATUS}" | "${LIFECYCLE_LEASE_BOUNDARY_STATUS}")
      return "${status}"
      ;;
    *) lifecycle_lease_fail 'lifecycle lease acquisition failed at a trust boundary' ;;
  esac
}

lifecycle_lease_release() {
  local release_fd status=0 current_pid="${BASHPID}"
  if [[ "${LIFECYCLE_LEASE_ROOT_OWNER}" != true ]]; then
    lifecycle_lease_close_directory_fd
    return 0
  fi
  # A parenthesized Bash scope inherits ordinary variables and the open file
  # description.  It is a lease descendant, not the root release authority.
  [[ "${LIFECYCLE_LEASE_OWNER_PID}" == "${current_pid}" ]] || return 0
  lifecycle_lease_assert || status=$?
  if ((status == 0)); then
    if [[ "${LIFECYCLE_RECORD_PID}" != "${LIFECYCLE_LEASE_OWNER_PID}" ||
      "${LIFECYCLE_RECORD_STARTTIME}" != "${LIFECYCLE_LEASE_OWNER_STARTTIME}" ]]; then
      lifecycle_lease_fail 'lease release authority does not match the holder' ||
        status=$?
    fi
  fi
  if ((status == 0)); then
    run_host_command rm -f -- "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" || status=$?
  fi
  release_fd="${LIFECYCLE_LEASE_FD}"
  if [[ "${release_fd}" =~ ^[0-9]{1,4}$ ]]; then
    exec {release_fd}>&- || status="${LIFECYCLE_LEASE_BOUNDARY_STATUS}"
  else
    status="${LIFECYCLE_LEASE_BOUNDARY_STATUS}"
  fi
  lifecycle_lease_close_directory_fd
  LIFECYCLE_LEASE_ROOT_OWNER=false
  LIFECYCLE_LEASE_OWNER_PID=''
  LIFECYCLE_LEASE_OWNER_STARTTIME=''
  LIFECYCLE_LEASE_FD=''
  builtin unset PLATFORM_LIFECYCLE_LEASE_SCHEMA \
    PLATFORM_LIFECYCLE_LEASE_TOKEN PLATFORM_LIFECYCLE_LEASE_FD
  ((status == 0)) && return 0
  return "${LIFECYCLE_LEASE_BOUNDARY_STATUS}"
}
