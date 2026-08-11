#!/bin/bash -p
set -euo pipefail

ROOT="${1:?repository root is required}"
ACTION="${2:?fixture action is required}"
shift 2
builtin source "${ROOT}/tools/common/env.sh"
PLATFORM_CLUSTER_NAME="${LIFECYCLE_PROOF_CLUSTER:?}"
# Exported for the fixture's isolated nested Bash processes.
# shellcheck disable=SC2034
builtin export PLATFORM_CLUSTER_NAME
builtin source "${ROOT}/tools/common/lifecycle-lease.sh"

wait_for_release() {
  local path="$1" deadline=$((SECONDS + 10))
  while [[ ! -s "${path}" ]]; do
    ((SECONDS < deadline)) || return 124
    run_host_command sleep 0.02
  done
}

cleanup_owned_lease() {
  local status=$? lease_status=0
  trap - EXIT
  lifecycle_lease_clear_interrupt_traps
  lifecycle_lease_release || lease_status=$?
  ((status != 0)) || status="${lease_status}"
  exit "${status}"
}

record_mutations() {
  local prefix="$1"
  printf 'docker\n' >"${prefix}.docker"
  printf 'kind\n' >"${prefix}.kind"
  printf 'kubectl\n' >"${prefix}.kubectl"
}

write_current_identity() {
  local target="$1" current_pid="${BASHPID}" snapshot observed_pid _ starttime _
  snapshot="$(linux_process_snapshot "${current_pid}")"
  IFS=$'\t' read -r observed_pid _ starttime _ <<<"${snapshot}"
  [[ "${observed_pid}" == "${current_pid}" && "${starttime}" =~ ^[0-9]+$ ]]
  printf '%s\t%s\n' "${observed_pid}" "${starttime}" >"${target}"
}

case "${ACTION}" in
  once)
    marker_prefix="${1:-}"
    lifecycle_lease_acquire kind-down
    lifecycle_lease_assert
    [[ -z "${marker_prefix}" ]] || record_mutations "${marker_prefix}"
    old_fd="${PLATFORM_LIFECYCLE_LEASE_FD}"
    lifecycle_lease_release
    [[ ! -e "/proc/self/fd/${old_fd}" ]]
    exec {candidate_fd}<>"${LIFECYCLE_LEASE_LOCK_FILE}"
    run_host_command flock --exclusive --nonblock --conflict-exit-code 75 \
      "${candidate_fd}"
    exec {candidate_fd}>&-
    ;;
  hold)
    ready="$1"
    release="$2"
    nested_result="$3"
    wrong_result="$4"
    identity_result="$5"
    wrong_marker_prefix="$6"
    lifecycle_lease_acquire verify-runtime
    trap cleanup_owned_lease EXIT
    lifecycle_lease_install_interrupt_traps
    # Positional parameters expand only in the isolated child.
    # shellcheck disable=SC2016
    "$(host_command_path bash)" -p -c '
builtin source "$1/tools/common/env.sh"
PLATFORM_CLUSTER_NAME="${LIFECYCLE_PROOF_CLUSTER:?}"
builtin export PLATFORM_CLUSTER_NAME
builtin source "$1/tools/common/lifecycle-lease.sh"
lifecycle_lease_acquire kind-up
lifecycle_lease_assert
lifecycle_lease_release
' _ "${ROOT}" >"${nested_result}" 2>&1
    status=0
    # Positional parameters expand only in the isolated child.
    # shellcheck disable=SC2016
    PLATFORM_LIFECYCLE_LEASE_TOKEN='sha256:0000000000000000000000000000000000000000000000000000000000000000' \
      "$(host_command_path bash)" -p -c '
builtin source "$1/tools/common/env.sh"
PLATFORM_CLUSTER_NAME="${LIFECYCLE_PROOF_CLUSTER:?}"
builtin export PLATFORM_CLUSTER_NAME
builtin source "$1/tools/common/lifecycle-lease.sh"
lifecycle_lease_acquire kind-up
printf "docker\n" >"$2.docker"
printf "kind\n" >"$2.kind"
printf "kubectl\n" >"$2.kubectl"
' _ "${ROOT}" "${wrong_marker_prefix}" >"${wrong_result}" 2>&1 || status=$?
    [[ "${status}" -eq "${LIFECYCLE_LEASE_BOUNDARY_STATUS}" ]]
    current_pid="${BASHPID}"
    current_snapshot="$(linux_process_snapshot "${current_pid}")"
    IFS=$'\t' read -r observed_pid _ current_starttime _ \
      <<<"${current_snapshot}"
    [[ "${observed_pid}" == "${current_pid}" ]]
    printf '%s\t%s\n' "${current_pid}" "${current_starttime}" \
      >"${identity_result}"
    printf 'ready\n' >"${ready}"
    wait_for_release "${release}"
    lifecycle_lease_release
    trap - EXIT
    lifecycle_lease_clear_interrupt_traps
    ;;
  kill-holder)
    ready="$1"
    descendant_ready="$2"
    descendant_release="$3"
    pid_record="$4"
    owner_identity="$5"
    sleep_path="$(host_command_path sleep)"
    lifecycle_lease_acquire smoke
    trap cleanup_owned_lease EXIT
    write_current_identity "${owner_identity}"
    # Positional parameters expand only in the isolated child.
    # shellcheck disable=SC2016
    "$(host_command_path bash)" -p -c '
printf "ready\n" >"$1"
deadline=$((SECONDS + 10))
while [[ ! -s "$2" ]]; do
  ((SECONDS < deadline)) || exit 124
  "$3" 0.02
done
' _ "${descendant_ready}" "${descendant_release}" "${sleep_path}" &
    descendant_pid=$!
    descendant_snapshot="$(linux_process_snapshot "${descendant_pid}")"
    IFS=$'\t' read -r _ _ descendant_starttime _ <<<"${descendant_snapshot}"
    printf '%s\t%s\n' "${descendant_pid}" "${descendant_starttime}" >"${pid_record}"
    printf 'ready\n' >"${ready}"
    builtin wait "${descendant_pid}"
    ;;
  prepublish)
    ready="$1"
    owner_identity="$2"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory
    lifecycle_lease_ensure_lock_file
    exec {prepublish_fd}<>"${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/lock"
    # Read by lifecycle_lease_fd_identity and orphan cleanup below.
    # shellcheck disable=SC2034
    LIFECYCLE_LEASE_FD="${prepublish_fd}"
    lifecycle_lease_fd_identity "${prepublish_fd}"
    run_host_command flock --exclusive --nonblock --conflict-exit-code 75 \
      "${prepublish_fd}"
    run_host_command mktemp \
      "${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/.nonce.XXXXXXXXXXXXXXXX" >/dev/null
    run_host_command mktemp \
      "${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/.holder.XXXXXXXX" >/dev/null
    write_current_identity "${owner_identity}"
    printf 'ready\n' >"${ready}"
    while :; do run_host_command sleep 1; done
    ;;
  external-holder)
    holder_pid="$1"
    holder_starttime="$2"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory
    lifecycle_lease_ensure_lock_file
    checkout_id="$(platform_checkout_identity)"
    token='sha256:3333333333333333333333333333333333333333333333333333333333333333'
    lifecycle_lease_render_holder \
      "${holder_pid}" "${holder_starttime}" "${checkout_id}" smoke "${token}" \
      >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
    run_host_command chmod 0600 "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
    lifecycle_lease_acquire kind-up
    lifecycle_lease_release
    ;;
  state-case)
    state="$1"
    expected="$2"
    marker_prefix="$3"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory
    lifecycle_lease_ensure_lock_file
    current_pid="${BASHPID}"
    snapshot="$(linux_process_snapshot "${current_pid}")"
    IFS=$'\t' read -r observed_pid _ starttime kernel_state <<<"${snapshot}"
    [[ "${observed_pid}" == "${current_pid}" ]]
    ! linux_process_terminal_kernel_state "${kernel_state}"
    checkout_id="$(platform_checkout_identity)"
    token='sha256:1111111111111111111111111111111111111111111111111111111111111111'
    lifecycle_lease_render_holder \
      "${current_pid}" "${starttime}" "${checkout_id}" smoke "${token}" \
      >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
    run_host_command chmod 0600 "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
    mock_process_state="${state}"
    case "${state}" in
      inspection-failure)
        linux_process_state() { return "${PROCESS_STATE_INSPECTION_STATUS}"; }
        ;;
      *)
        linux_process_state() { printf '%s\n' "${mock_process_state}"; }
        ;;
    esac
    status=0
    lifecycle_lease_acquire kind-up >/dev/null 2>&1 || status=$?
    [[ "${status}" -eq "${expected}" ]]
    if [[ "${status}" -eq 0 ]]; then
      linux_process_state() {
        _linux_process_state_at "${1:-}" "${2:-}" "${PROCESS_STATE_PROC_ROOT}"
      }
      record_mutations "${marker_prefix}"
      lifecycle_lease_release
    else
      [[ -f "${LIFECYCLE_LEASE_HOLDER_FILE}" ]]
    fi
    ;;
  release-mismatch)
    lifecycle_lease_acquire smoke
    original_fd="${PLATFORM_LIFECYCLE_LEASE_FD}"
    lifecycle_lease_validate_holder
    replacement="$(run_host_command mktemp \
      "${LIFECYCLE_LEASE_DIRECTORY}/.holder.XXXXXXXX")"
    lifecycle_lease_render_holder \
      "${LIFECYCLE_RECORD_PID}" "${LIFECYCLE_RECORD_STARTTIME}" \
      "${LIFECYCLE_RECORD_CHECKOUT_ID}" "${LIFECYCLE_RECORD_ACTION}" \
      'sha256:2222222222222222222222222222222222222222222222222222222222222222' \
      >"${replacement}"
    run_host_command chmod 0600 "${replacement}"
    run_host_command mv -fT -- "${replacement}" \
      "${LIFECYCLE_LEASE_HOLDER_FILE}"
    status=0
    lifecycle_lease_release >/dev/null 2>&1 || status=$?
    [[ "${status}" -eq "${LIFECYCLE_LEASE_BOUNDARY_STATUS}" &&
      -f "${LIFECYCLE_LEASE_HOLDER_FILE}" &&
      ! -e "/proc/self/fd/${original_fd}" ]]
    ;;
  fork-release)
    lifecycle_lease_acquire verify
    (lifecycle_lease_release)
    [[ -f "${LIFECYCLE_LEASE_HOLDER_FILE}" ]]
    lifecycle_lease_assert
    lifecycle_lease_release
    ;;
  postflock-failure)
    marker_prefix="$1"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory
    lifecycle_lease_ensure_lock_file
    printf 'malformed\n' >"${LIFECYCLE_LEASE_HOLDER_FILE}"
    run_host_command chmod 0600 "${LIFECYCLE_LEASE_HOLDER_FILE}"
    status=0
    lifecycle_lease_acquire kind-up >/dev/null 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] || record_mutations "${marker_prefix}"
    [[ "${status}" -eq "${LIFECYCLE_LEASE_BOUNDARY_STATUS}" &&
      "${LIFECYCLE_LEASE_ROOT_OWNER}" == false &&
      -z "${LIFECYCLE_LEASE_FD}" &&
      ! -v PLATFORM_LIFECYCLE_LEASE_TOKEN ]]
    exec {candidate_fd}<>"${LIFECYCLE_LEASE_LOCK_FILE}"
    run_host_command flock --exclusive --nonblock --conflict-exit-code 75 \
      "${candidate_fd}"
    exec {candidate_fd}>&-
    ;;
  publish-failure)
    publish_marker="$1"
    marker_prefix="$2"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory
    lifecycle_lease_ensure_lock_file
    # Replaces the already-loaded host wrapper for this isolated publish RED.
    # shellcheck disable=SC2317,SC2329
    run_host_command() {
      local command_name="${1:-}"
      shift
      if [[ "${command_name}" == mv ]]; then
        printf 'attempted\n' >"${publish_marker}"
        return 88
      fi
      host_command_admit "${command_name}" || return
      "${HOST_COMMAND_PATH}" "$@"
    }
    status=0
    lifecycle_lease_acquire kind-up >/dev/null 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] || record_mutations "${marker_prefix}"
    [[ "${status}" -eq "${LIFECYCLE_LEASE_BOUNDARY_STATUS}" &&
      "${LIFECYCLE_LEASE_ROOT_OWNER}" == false &&
      -z "${LIFECYCLE_LEASE_FD}" &&
      ! -e "${LIFECYCLE_LEASE_HOLDER_FILE}" &&
      -s "${publish_marker}" ]]
    exec {candidate_fd}<>"${LIFECYCLE_LEASE_LOCK_FILE}"
    run_host_command flock --exclusive --nonblock --conflict-exit-code 75 \
      "${candidate_fd}"
    exec {candidate_fd}>&-
    ;;
  foreign-owner)
    foreign_target="$1"
    marker_prefix="$2"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory
    if [[ "${foreign_target}" != directory ]]; then
      lifecycle_lease_ensure_lock_file
    fi
    if [[ "${foreign_target}" == holder ]]; then
      printf 'malformed\n' >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
      run_host_command chmod 0600 "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
    fi
    case "${foreign_target}" in
      directory) foreign_path="${LIFECYCLE_LEASE_DIRECTORY}" ;;
      lock) foreign_path="${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/lock" ;;
      holder) foreign_path="${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}" ;;
      *) exit 2 ;;
    esac
    # Replaces the already-loaded host wrapper for this isolated ownership RED.
    # shellcheck disable=SC2317,SC2329
    run_host_command() {
      local command_name="${1:-}"
      shift
      if [[ "${command_name}" == stat && $# -eq 4 &&
        "$1" == -Lc && "$2" == '%u:%a:%h' && "$3" == -- &&
        "$4" == "${foreign_path}" ]]; then
        printf '99999:600:1\n'
        return 0
      fi
      host_command_admit "${command_name}" || return
      "${HOST_COMMAND_PATH}" "$@"
    }
    status=0
    lifecycle_lease_acquire kind-up >"${marker_prefix}.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] || record_mutations "${marker_prefix}"
    [[ "${status}" -eq "${LIFECYCLE_LEASE_BOUNDARY_STATUS}" &&
      "${LIFECYCLE_LEASE_ROOT_OWNER}" == false &&
      -z "${LIFECYCLE_LEASE_FD}" &&
      -z "${LIFECYCLE_LEASE_DIRECTORY_FD}" ]]
    exit "${status}"
    ;;
  root-path-case)
    adapted_root="$1"
    marker_prefix="$2"
    LIFECYCLE_LEASE_DIRECTORY="${adapted_root}"
    LIFECYCLE_LEASE_LOCK_FILE="${adapted_root}/lock"
    LIFECYCLE_LEASE_HOLDER_FILE="${adapted_root}/holder"
    LIFECYCLE_LEASE_ACCESS_DIRECTORY="${adapted_root}"
    LIFECYCLE_LEASE_ACCESS_HOLDER_FILE="${adapted_root}/holder"
    status=0
    lifecycle_lease_acquire kind-up >"${marker_prefix}.out" 2>&1 || status=$?
    [[ "${status}" -ne 0 ]] || record_mutations "${marker_prefix}"
    [[ "${status}" -eq "${LIFECYCLE_LEASE_BOUNDARY_STATUS}" &&
      "${LIFECYCLE_LEASE_ROOT_OWNER}" == false &&
      -z "${LIFECYCLE_LEASE_FD}" &&
      -z "${LIFECYCLE_LEASE_DIRECTORY_FD}" ]]
    exit "${status}"
    ;;
  record-case)
    record_case="$1"
    marker_prefix="$2"
    secret="$3"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory
    lifecycle_lease_ensure_lock_file
    checkout_id="$(platform_checkout_identity)"
    case "${record_case}" in
      oversized)
        for ((index = 0; index < 1025; index++)); do
          printf x
        done >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        ;;
      nul)
        printf 'schema=%s\npid=1\nstarttime=1\ncheckout_id=%s\n' \
          "${LIFECYCLE_LEASE_SCHEMA}" "${checkout_id}" \
          >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        printf 'action=kind-up\0forbidden\ntoken=sha256:%064d\n' 0 \
          >>"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        ;;
      missing-final-lf)
        lifecycle_lease_render_holder 1 1 "${checkout_id}" kind-up \
          'sha256:1111111111111111111111111111111111111111111111111111111111111111' |
          run_host_command head -c -1 -- \
            >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        ;;
      extra-field)
        lifecycle_lease_render_holder 1 1 "${checkout_id}" kind-up \
          'sha256:1111111111111111111111111111111111111111111111111111111111111111' \
          >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        printf 'extra=field\n' >>"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        ;;
      invalid-action)
        lifecycle_lease_render_holder 1 1 "${checkout_id}" destroy-everything \
          'sha256:1111111111111111111111111111111111111111111111111111111111111111' \
          >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        ;;
      invalid-token)
        lifecycle_lease_render_holder 1 1 "${checkout_id}" kind-up "${secret}" \
          >"${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
        ;;
      unexpected-orphan)
        printf '%s\n' "${secret}" \
          >"${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/unexpected-proof-entry"
        run_host_command chmod 0600 \
          "${LIFECYCLE_LEASE_ACCESS_DIRECTORY}/unexpected-proof-entry"
        ;;
      *) exit 2 ;;
    esac
    if [[ "${record_case}" != unexpected-orphan ]]; then
      run_host_command chmod 0600 "${LIFECYCLE_LEASE_ACCESS_HOLDER_FILE}"
    fi
    lifecycle_lease_close_directory_fd
    lifecycle_lease_acquire kind-up
    lifecycle_lease_assert
    record_mutations "${marker_prefix}"
    lifecycle_lease_release
    ;;
  root-swap)
    original_root="$1"
    victim_root="$2"
    marker_prefix="$3"
    lifecycle_lease_configure_paths
    lifecycle_lease_ensure_directory_original() {
      local ensure_status=0
      if lifecycle_lease_validate_directory; then
        return 0
      else
        ensure_status=$?
      fi
      ((ensure_status == 1)) || return "${ensure_status}"
      if (umask 077 && run_host_command mkdir -- \
        "${LIFECYCLE_LEASE_DIRECTORY}") 2>/dev/null; then
        :
      fi
      lifecycle_lease_validate_directory
    }
    lifecycle_lease_ensure_directory() {
      lifecycle_lease_ensure_directory_original || return
      lifecycle_lease_pin_directory || return
      run_host_command mv -- "${LIFECYCLE_LEASE_DIRECTORY}" "${original_root}"
      run_host_command ln -s -- "${victim_root}" \
        "${LIFECYCLE_LEASE_DIRECTORY}"
    }
    lifecycle_lease_acquire kind-up
    lifecycle_lease_assert
    record_mutations "${marker_prefix}"
    lifecycle_lease_release
    ;;
  term-parent)
    ready="$1"
    descendant_ready="$2"
    descendant_release="$3"
    sibling_mutation="$4"
    pid_record="$5"
    owner_identity="$6"
    sleep_path="$(host_command_path sleep)"
    # Invoked indirectly by the EXIT trap below.
    # shellcheck disable=SC2317,SC2329
    term_cleanup() {
      local status=$? lease_status=0
      trap - EXIT
      lifecycle_lease_clear_interrupt_traps
      if [[ "${LIFECYCLE_LEASE_INTERRUPTED}" != true ]]; then
        printf 'mutated\n' >"${sibling_mutation}"
      fi
      lifecycle_lease_release || lease_status=$?
      ((status != 0)) || status="${lease_status}"
      exit "${status}"
    }
    lifecycle_lease_acquire verify
    trap term_cleanup EXIT
    lifecycle_lease_install_interrupt_traps
    write_current_identity "${owner_identity}"
    # Positional parameters expand only in the isolated child.
    # shellcheck disable=SC2016
    "$(host_command_path bash)" -p -c '
printf "ready\n" >"$1"
deadline=$((SECONDS + 10))
while [[ ! -s "$2" ]]; do
  ((SECONDS < deadline)) || exit 124
  "$3" 0.02
done
' _ "${descendant_ready}" "${descendant_release}" "${sleep_path}" &
    descendant_pid=$!
    descendant_snapshot="$(linux_process_snapshot "${descendant_pid}")"
    IFS=$'\t' read -r _ _ descendant_starttime _ <<<"${descendant_snapshot}"
    printf '%s\t%s\n' "${descendant_pid}" "${descendant_starttime}" \
      >"${pid_record}"
    printf 'ready\n' >"${ready}"
    builtin wait "${descendant_pid}"
    ;;
  contend)
    ready="$1"
    go="$2"
    result="$3"
    winner="$4"
    release="$5"
    marker_prefix="$6"
    owner_identity="$7"
    printf 'ready\n' >"${ready}"
    wait_for_release "${go}"
    status=0
    lifecycle_lease_acquire kind-up >/dev/null 2>&1 || status=$?
    printf '%s\n' "${status}" >"${result}"
    if [[ "${status}" -eq 0 ]]; then
      write_current_identity "${owner_identity}"
      record_mutations "${marker_prefix}"
      printf 'winner\n' >"${winner}"
      wait_for_release "${release}"
      lifecycle_lease_release
    fi
    ;;
  *)
    printf 'unknown lifecycle lease fixture action: %s\n' "${ACTION}" >&2
    exit 2
    ;;
esac
