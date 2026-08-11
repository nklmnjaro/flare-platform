#!/bin/bash -p
set -euo pipefail

PROVE_LIFECYCLE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_LIFECYCLE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_LIFECYCLE_SOURCE_DIR=.
builtin source "${PROVE_LIFECYCLE_SOURCE_DIR}/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/process-state.sh"
builtin unset PROVE_LIFECYCLE_SOURCE_DIR
builtin export LC_ALL=C
builtin readonly LC_ALL

readonly LIFECYCLE_DRIVER="${PLATFORM_ROOT}/tests/fixtures/common/lifecycle-lease.sh"
readonly PROCESS_HELPER_SOURCE="${PLATFORM_ROOT}/tests/fixtures/go/process-state-helper.go"
readonly MANAGED_TOOL_RUNNER="${PLATFORM_ROOT}/tools/common/run-managed-tool.sh"
readonly PROOF_BUSY_STATUS=75
readonly PROOF_BOUNDARY_STATUS=76
readonly PROOF_RETAINED_STATUS=77

WORK_DIR=''
CASE_CLUSTER=''
CASE_ROOT=''
CAPTURED_STATUS=0
declare -a LEASE_ROOTS=()
declare -a PROOF_PIDS=()
declare -a PROOF_STARTTIMES=()
declare -A LEASE_ROOT_IDENTITIES=()
declare -A LEASE_LOCK_IDENTITIES=()
WORK_DIR_IDENTITY=''
WORK_OWNER_TOKEN=''
WORK_OWNER_IDENTITY=''
WORK_LOCK_IDENTITY=''
WORK_CLEANUP_READY=false

register_pid() {
  local pid="$1" supplied_starttime="${2:-}"
  local snapshot observed_pid _ starttime _
  if [[ -n "${supplied_starttime}" ]]; then
    starttime="${supplied_starttime}"
  else
    snapshot="$(linux_process_snapshot "${pid}")" || return
    IFS=$'\t' read -r observed_pid _ starttime _ <<<"${snapshot}"
    [[ "${observed_pid}" == "${pid}" && "${starttime}" =~ ^[0-9]+$ ]] ||
      return "${PROOF_BOUNDARY_STATUS}"
  fi
  PROOF_PIDS+=("${pid}")
  PROOF_STARTTIMES+=("${starttime}")
}

lease_path_identity() {
  run_host_command stat -c '%d:%i:%u:%a:%h:%s' -- "$1"
}

lease_inode_identity() {
  run_host_command stat -c '%d:%i:%u' -- "$1"
}

register_lease_root() {
  local root="$1" identity canonical existing
  [[ "${root}" =~ ^/tmp/flare-platform-lifecycle-lease-[0-9a-f]{64}$ ]] ||
    return "${PROOF_BOUNDARY_STATUS}"
  [[ -d "${root}" && ! -L "${root}" ]] || return "${PROOF_BOUNDARY_STATUS}"
  identity="$(lease_inode_identity "${root}")" || return
  [[ "${identity}" == *":${EUID}" ]] ||
    return "${PROOF_BOUNDARY_STATUS}"
  [[ "$(run_host_command stat -c '%a:%h' -- "${root}")" == 700:2 ]] ||
    return "${PROOF_BOUNDARY_STATUS}"
  canonical="$(run_host_command readlink -f -- "${root}")" || return
  [[ "${canonical}" == "${root}" ]] || return "${PROOF_BOUNDARY_STATUS}"
  existing="${LEASE_ROOT_IDENTITIES[${root}]:-}"
  [[ -z "${existing}" || "${existing}" == "${identity}" ]] ||
    return "${PROOF_BOUNDARY_STATUS}"
  LEASE_ROOT_IDENTITIES["${root}"]="${identity}"
}

register_lease_lock() {
  local root="$1" lock identity existing
  lock="${root}/lock"
  [[ -f "${lock}" && ! -L "${lock}" ]] || return "${PROOF_BOUNDARY_STATUS}"
  identity="$(lease_path_identity "${lock}")" || return
  [[ "${identity}" == *":${EUID}:600:1:0" ]] ||
    return "${PROOF_BOUNDARY_STATUS}"
  existing="${LEASE_LOCK_IDENTITIES[${root}]:-}"
  [[ -z "${existing}" || "${existing}" == "${identity}" ]] ||
    return "${PROOF_BOUNDARY_STATUS}"
  LEASE_LOCK_IDENTITIES["${root}"]="${identity}"
}

cleanup_registered_root() {
  local root="$1" root_identity lock_identity canonical entries
  local directory_fd lock_fd status=0
  root_identity="${LEASE_ROOT_IDENTITIES[${root}]:-}"
  lock_identity="${LEASE_LOCK_IDENTITIES[${root}]:-}"
  [[ -n "${root_identity}" && -n "${lock_identity}" ]] ||
    return "${PROOF_RETAINED_STATUS}"
  [[ -d "${root}" && ! -L "${root}" ]] || return "${PROOF_RETAINED_STATUS}"
  [[ "$(lease_inode_identity "${root}")" == "${root_identity}" &&
  "$(run_host_command stat -c '%a:%h' -- "${root}")" == 700:2 ]] ||
    return "${PROOF_RETAINED_STATUS}"
  canonical="$(run_host_command readlink -f -- "${root}")" ||
    return "${PROOF_RETAINED_STATUS}"
  [[ "${canonical}" == "${root}" ]] || return "${PROOF_RETAINED_STATUS}"
  exec {directory_fd}<"${root}" || return "${PROOF_RETAINED_STATUS}"
  [[ "$(run_host_command stat -Lc '%d:%i:%u' -- \
    "/proc/self/fd/${directory_fd}")" == "${root_identity}" ]] || status="${PROOF_RETAINED_STATUS}"
  if ((status == 0)); then
    [[ -f "/proc/self/fd/${directory_fd}/lock" &&
      ! -L "/proc/self/fd/${directory_fd}/lock" ]] ||
      status="${PROOF_RETAINED_STATUS}"
  fi
  if ((status == 0)); then
    [[ "$(lease_path_identity \
      "/proc/self/fd/${directory_fd}/lock")" == "${lock_identity}" ]] ||
      status="${PROOF_RETAINED_STATUS}"
  fi
  if ((status == 0)); then
    exec {lock_fd}<>"/proc/self/fd/${directory_fd}/lock" ||
      status="${PROOF_RETAINED_STATUS}"
  fi
  if ((status == 0)); then
    run_host_command flock --exclusive --nonblock \
      --conflict-exit-code "${PROOF_RETAINED_STATUS}" "${lock_fd}" || status=$?
    ((status == PROOF_RETAINED_STATUS)) || ((status == 0)) ||
      status="${PROOF_BOUNDARY_STATUS}"
  fi
  if ((status == 0)); then
    entries="$(run_host_command find -H "/proc/self/fd/${directory_fd}" \
      -mindepth 1 -maxdepth 1 -printf '%f\n' | run_host_command sort)" ||
      status="${PROOF_BOUNDARY_STATUS}"
    [[ "${entries}" == lock ]] || status="${PROOF_RETAINED_STATUS}"
  fi
  if [[ "${lock_fd:-}" =~ ^[0-9]{1,4}$ ]]; then
    { exec {lock_fd}>&-; } 2>/dev/null || status="${PROOF_BOUNDARY_STATUS}"
  fi
  if ((status == 0)); then
    [[ "$(lease_inode_identity "${root}")" == "${root_identity}" ]] ||
      status="${PROOF_RETAINED_STATUS}"
  fi
  { exec {directory_fd}<&-; } 2>/dev/null || status="${PROOF_BOUNDARY_STATUS}"
  ((status == 0)) || return "${status}"
  # Bash has no inode-conditional rmdir.  Keep the canonical shared rendezvous
  # as its production invariant (one free, empty lock) so a same-UID rename
  # race can never make proof cleanup unlink a replacement directory.
  assert_lock_only "${root}"
}

cleanup_work_directory() {
  local identity canonical owner_identity lock_identity entry relative
  local directory_fd lock_fd status=0
  local -a entries=()
  [[ -n "${WORK_DIR}" &&
    "${WORK_DIR}" == "${PLATFORM_STATE_DIR}"/lifecycle-lease-proof.* ]] || return 0
  [[ "${WORK_CLEANUP_READY}" == true ]] || return "${PROOF_RETAINED_STATUS}"
  [[ -d "${WORK_DIR}" && ! -L "${WORK_DIR}" ]] || return 0
  identity="$(lease_inode_identity "${WORK_DIR}")" || return
  canonical="$(run_host_command readlink -f -- "${WORK_DIR}")" || return
  [[ "${identity}" == "${WORK_DIR_IDENTITY}" &&
    "$(run_host_command stat -c '%a:%h' -- "${WORK_DIR}")" == 700:2 &&
    "${canonical}" == "${WORK_DIR}" ]] || return "${PROOF_RETAINED_STATUS}"
  owner_identity="$(lease_path_identity "${WORK_DIR}/.proof-owner")" || return
  lock_identity="$(lease_path_identity "${WORK_DIR}/.proof-lock")" || return
  [[ "${owner_identity}" == "${WORK_OWNER_IDENTITY}" &&
    "${lock_identity}" == "${WORK_LOCK_IDENTITY}" &&
    "$(run_host_command cat -- "${WORK_DIR}/.proof-owner")" == "${WORK_OWNER_TOKEN}" ]] ||
    return "${PROOF_RETAINED_STATUS}"
  exec {directory_fd}<"${WORK_DIR}" || return "${PROOF_RETAINED_STATUS}"
  exec {lock_fd}<>"/proc/self/fd/${directory_fd}/.proof-lock" || {
    exec {directory_fd}<&-
    return "${PROOF_RETAINED_STATUS}"
  }
  run_host_command flock --exclusive --nonblock \
    --conflict-exit-code "${PROOF_RETAINED_STATUS}" "${lock_fd}" || status=$?
  if ((status == 0)); then
    mapfile -d '' -t entries < <(run_host_command find -H \
      "/proc/self/fd/${directory_fd}" -mindepth 1 -depth -print0)
    for entry in "${entries[@]}"; do
      relative="${entry#"/proc/self/fd/${directory_fd}/"}"
      if [[ "${relative}" == .proof-lock ]]; then
        continue
      fi
      if [[ -L "${entry}" ]]; then
        status="${PROOF_RETAINED_STATUS}"
        break
      elif [[ -f "${entry}" ]]; then
        [[ "$(run_host_command stat -c '%u:%h' -- "${entry}")" == "${EUID}:1" ]] || {
          status="${PROOF_RETAINED_STATUS}"
          break
        }
        run_host_command rm -f -- "${entry}" || {
          status="${PROOF_BOUNDARY_STATUS}"
          break
        }
      elif [[ -d "${entry}" ]]; then
        run_host_command rm -d -- "${entry}" || {
          status="${PROOF_RETAINED_STATUS}"
          break
        }
      else
        status="${PROOF_RETAINED_STATUS}"
        break
      fi
    done
  fi
  if ((status == 0)); then
    run_host_command rm -f -- "/proc/self/fd/${directory_fd}/.proof-lock" ||
      status="${PROOF_BOUNDARY_STATUS}"
  fi
  { exec {lock_fd}>&-; } 2>/dev/null || status="${PROOF_BOUNDARY_STATUS}"
  { exec {directory_fd}<&-; } 2>/dev/null || status="${PROOF_BOUNDARY_STATUS}"
  ((status == 0)) || return "${status}"
  run_host_command rm -d -- "${WORK_DIR}"
}

cleanup_lifecycle_proof() {
  local status=$? index state root
  trap - EXIT
  for ((index = 0; index < ${#PROOF_PIDS[@]}; index++)); do
    state="$(linux_process_state \
      "${PROOF_PIDS[index]}" "${PROOF_STARTTIMES[index]}" 2>/dev/null || true)"
    if [[ "${state}" == live ]]; then
      builtin kill -KILL "${PROOF_PIDS[index]}" 2>/dev/null || true
    fi
    builtin wait "${PROOF_PIDS[index]}" 2>/dev/null || true
  done
  for root in "${LEASE_ROOTS[@]}"; do
    cleanup_registered_root "${root}" >/dev/null 2>&1 || true
  done
  cleanup_work_directory >/dev/null 2>&1 || true
  exit "${status}"
}

wait_for_file() {
  local path="$1" attempt
  for ((attempt = 1; attempt <= 500; attempt++)); do
    [[ ! -s "${path}" ]] || return 0
    run_host_command sleep 0.02
  done
  return 1
}

wait_for_process_nonlive() {
  local pid="$1" starttime="$2" state attempt
  for ((attempt = 1; attempt <= 500; attempt++)); do
    state="$(linux_process_state "${pid}" "${starttime}")" || return
    [[ "${state}" == live ]] || return 0
    run_host_command sleep 0.02
  done
  return 1
}

wait_for_process_absent_or_replaced() {
  local pid="$1" starttime="$2" state attempt
  for ((attempt = 1; attempt <= 500; attempt++)); do
    state="$(linux_process_state "${pid}" "${starttime}")" || return
    case "${state}" in
      absent | replaced) return 0 ;;
      live | terminal) run_host_command sleep 0.02 ;;
      *) return "${PROOF_BOUNDARY_STATUS}" ;;
    esac
  done
  return 1
}

prove_registered_processes_gone() {
  local index
  for ((index = 0; index < ${#PROOF_PIDS[@]}; index++)); do
    wait_for_process_absent_or_replaced \
      "${PROOF_PIDS[index]}" "${PROOF_STARTTIMES[index]}"
  done
  builtin printf \
    'PASS  lifecycle     every registered proof process identity is absent or replaced\n'
}

configure_case() {
  local label="$1" digest lease_digest
  digest="$({
    builtin printf 'flare-platform-lifecycle-proof-v2\0%s\0%s\0%s\0' \
      "${PLATFORM_ROOT}" "${EUID}" "${label}" | run_host_command sha256sum --
  })" || return
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]] || return 1
  CASE_CLUSTER="flare-lifecycle-proof-${BASH_REMATCH[1]:0:24}"
  lease_digest="$({
    builtin printf \
      'flare-platform-lifecycle-path-v1\0project=flare-platform\0cluster=%s\0' \
      "${CASE_CLUSTER}" | run_host_command sha256sum --
  })" || return
  [[ "${lease_digest}" =~ ^([0-9a-f]{64})\ \ -$ ]] || return 1
  CASE_ROOT="/tmp/flare-platform-lifecycle-lease-${BASH_REMATCH[1]}"
  if [[ -e "${CASE_ROOT}" || -L "${CASE_ROOT}" ]]; then
    assert_lock_only "${CASE_ROOT}"
    cleanup_registered_root "${CASE_ROOT}"
  else
    (umask 077 && run_host_command mkdir -- "${CASE_ROOT}")
    (umask 077 && : >"${CASE_ROOT}/lock")
    assert_lock_only "${CASE_ROOT}"
  fi
  LEASE_ROOTS+=("${CASE_ROOT}")
}

run_driver() {
  local cluster="$1"
  shift
  LIFECYCLE_PROOF_CLUSTER="${cluster}" \
    "${LIFECYCLE_DRIVER}" "${PLATFORM_ROOT}" "$@"
}

capture_driver() {
  local output="$1" cluster="$2"
  shift 2
  CAPTURED_STATUS=0
  run_driver "${cluster}" "$@" >"${output}" 2>&1 || CAPTURED_STATUS=$?
}

prepare_safe_root() {
  local root="$1"
  assert_lock_only "${root}"
}

prepare_safe_lock() {
  local root="$1"
  register_lease_lock "${root}"
}

finalize_attack_root() {
  local cluster="$1" root="$2"
  run_driver "${cluster}" once
  assert_lock_only "${root}"
  cleanup_registered_root "${root}"
}

remove_exact_path() {
  local path="$1" expected_identity="$2" identity
  [[ -e "${path}" || -L "${path}" ]] || return "${PROOF_BOUNDARY_STATUS}"
  identity="$(lease_path_identity "${path}")" || return
  [[ "${identity}" == "${expected_identity}" ]] ||
    return "${PROOF_BOUNDARY_STATUS}"
  if [[ -L "${path}" || -f "${path}" || -p "${path}" ]]; then
    run_host_command rm -f -- "${path}"
  elif [[ -d "${path}" ]]; then
    run_host_command rm -d -- "${path}"
  else
    return "${PROOF_BOUNDARY_STATUS}"
  fi
}

assert_lock_only() {
  local root="$1" entries identity canonical
  [[ -d "${root}" && ! -L "${root}" ]]
  canonical="$(run_host_command readlink -f -- "${root}")"
  [[ "${canonical}" == "${root}" ]]
  identity="$(run_host_command stat -Lc '%u:%a:%h' -- "${root}")"
  [[ "${identity}" == "${EUID}:700:2" ]]
  entries="$(run_host_command find "${root}" -mindepth 1 -maxdepth 1 \
    -printf '%f\n' | run_host_command sort)"
  [[ "${entries}" == lock ]]
  [[ -f "${root}/lock" && ! -L "${root}/lock" ]]
  canonical="$(run_host_command readlink -f -- "${root}/lock")"
  [[ "${canonical}" == "${root}/lock" ]]
  identity="$(run_host_command stat -Lc '%u:%a:%h:%s' -- "${root}/lock")"
  [[ "${identity}" == "${EUID}:600:1:0" ]]
  register_lease_root "${root}"
  register_lease_lock "${root}"
}

assert_markers_absent() {
  local prefix="$1" tool
  for tool in docker kind kubectl; do
    [[ ! -e "${prefix}.${tool}" && ! -L "${prefix}.${tool}" ]]
  done
}

assert_markers_present() {
  local prefix="$1"
  run_host_command grep -Fqx docker "${prefix}.docker"
  run_host_command grep -Fqx kind "${prefix}.kind"
  run_host_command grep -Fqx kubectl "${prefix}.kubectl"
}

expect_boundary_without_mutation() {
  local label="$1" cluster="$2" marker_prefix output
  marker_prefix="${WORK_DIR}/${label}.mutation"
  output="${WORK_DIR}/${label}.out"
  capture_driver "${output}" "${cluster}" once "${marker_prefix}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BOUNDARY_STATUS}" &&
    -s "${output}" ]]
  assert_markers_absent "${marker_prefix}"
}

expect_adapted_root_boundary() {
  local label="$1" cluster="$2" adapted_root="$3" expected="$4"
  local marker_prefix="${WORK_DIR}/${label}.mutation"
  capture_driver "${WORK_DIR}/${label}.driver.out" "${cluster}" \
    root-path-case "${adapted_root}" "${marker_prefix}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BOUNDARY_STATUS}" ]]
  assert_markers_absent "${marker_prefix}"
  run_host_command grep -Fqx "FAIL  lifecycle     ${expected}" \
    "${marker_prefix}.out"
}

prove_active_nested_and_release() {
  local cluster root ready release nested wrong identity output marker wrong_markers
  local holder_pid holder_starttime observed_pid observed_starttime status=0
  configure_case active
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  ready="${WORK_DIR}/active.ready"
  release="${WORK_DIR}/active.release"
  nested="${WORK_DIR}/nested.out"
  wrong="${WORK_DIR}/wrong-token.out"
  identity="${WORK_DIR}/holder.identity"
  wrong_markers="${WORK_DIR}/wrong-token.mutation"
  run_driver "${cluster}" hold \
    "${ready}" "${release}" "${nested}" "${wrong}" "${identity}" \
    "${wrong_markers}" \
    >"${WORK_DIR}/active.out" 2>&1 &
  holder_pid=$!
  register_pid "${holder_pid}"
  wait_for_file "${ready}"
  wait_for_file "${identity}"
  IFS=$'\t' read -r observed_pid observed_starttime <"${identity}"
  register_pid "${observed_pid}" "${observed_starttime}"
  holder_starttime="${observed_starttime}"
  [[ "${observed_starttime}" == "${holder_starttime}" ]]
  register_lease_root "${root}"
  run_host_command grep -Fqx "pid=${observed_pid}" "${root}/holder"
  run_host_command grep -Fqx "starttime=${observed_starttime}" "${root}/holder"
  run_host_command grep -Fqx 'action=verify-runtime' "${root}/holder"
  [[ ! -s "${nested}" ]]
  run_host_command grep -Fqx \
    'FAIL  lifecycle     inherited lease identity does not match the holder' \
    "${wrong}"
  assert_markers_absent "${wrong_markers}"
  marker="${WORK_DIR}/active.mutation"
  output="${WORK_DIR}/active-contender.out"
  capture_driver "${output}" "${cluster}" once "${marker}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BUSY_STATUS}" &&
    -s "${output}" ]]
  assert_markers_absent "${marker}"
  run_host_command grep -Fqx \
    'FAIL  lifecycle     another lifecycle action is active' "${output}"
  printf 'release\n' >"${release}"
  builtin wait "${holder_pid}" || status=$?
  [[ "${status}" -eq 0 ]]
  assert_lock_only "${root}"
  run_driver "${cluster}" fork-release
  assert_lock_only "${root}"
  builtin printf \
    'PASS  lifecycle     active owner, BASHPID/starttime, nested token, wrong token, and forked release\n'
}

prove_stale_and_zombie_recovery() {
  local cluster root zombie_binary zombie_pid_file zombie_parent zombie_pid
  local snapshot observed_pid _ zombie_starttime kernel_state state status=0
  configure_case process-state
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  run_driver "${cluster}" state-case terminal 0 "${WORK_DIR}/terminal.mutation"
  assert_markers_present "${WORK_DIR}/terminal.mutation"
  run_driver "${cluster}" state-case absent 0 "${WORK_DIR}/absent.mutation"
  assert_markers_present "${WORK_DIR}/absent.mutation"
  run_driver "${cluster}" state-case replaced 0 "${WORK_DIR}/replaced.mutation"
  assert_markers_present "${WORK_DIR}/replaced.mutation"
  run_driver "${cluster}" state-case live "${PROOF_BOUNDARY_STATUS}" \
    "${WORK_DIR}/live.mutation"
  assert_markers_absent "${WORK_DIR}/live.mutation"
  [[ -f "${root}/holder" ]]
  run_driver "${cluster}" once
  run_driver "${cluster}" state-case inspection-failure \
    "${PROOF_BOUNDARY_STATUS}" "${WORK_DIR}/inspection.mutation"
  assert_markers_absent "${WORK_DIR}/inspection.mutation"
  [[ -f "${root}/holder" ]]
  run_driver "${cluster}" once

  zombie_binary="${WORK_DIR}/process-state-helper"
  zombie_pid_file="${WORK_DIR}/zombie.pid"
  "${MANAGED_TOOL_RUNNER}" go build -trimpath -o "${zombie_binary}" \
    "${PROCESS_HELPER_SOURCE}"
  "${zombie_binary}" zombie "${zombie_pid_file}" &
  zombie_parent=$!
  register_pid "${zombie_parent}"
  wait_for_file "${zombie_pid_file}"
  IFS= read -r zombie_pid <"${zombie_pid_file}"
  for _ in {1..500}; do
    state="$(linux_process_state "${zombie_pid}")"
    [[ "${state}" == terminal ]] && break
    run_host_command sleep 0.02
  done
  [[ "${state}" == terminal ]]
  snapshot="$(linux_process_snapshot "${zombie_pid}")"
  IFS=$'\t' read -r observed_pid _ zombie_starttime kernel_state <<<"${snapshot}"
  [[ "${observed_pid}" == "${zombie_pid}" && "${kernel_state}" == Z ]]
  run_driver "${cluster}" external-holder "${zombie_pid}" "${zombie_starttime}"
  builtin kill -TERM "${zombie_parent}" 2>/dev/null || true
  builtin wait "${zombie_parent}" 2>/dev/null || status=$?
  [[ "${status}" -eq 0 || "${status}" -eq 143 ]]
  assert_lock_only "${root}"
  builtin printf \
    'PASS  lifecycle     absent, terminal zombie, PID replacement, live, and inspection failure classified\n'
}

prove_kill_before_publication_and_failure_release() {
  local cluster root ready wrapper_pid owner_identity holder_pid holder_starttime
  local status=0 marker nonce_count staging_count output attempt holder_identity
  configure_case prepublication
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  ready="${WORK_DIR}/prepublish.ready"
  owner_identity="${WORK_DIR}/prepublish.owner"
  run_driver "${cluster}" prepublish "${ready}" "${owner_identity}" \
    >"${WORK_DIR}/prepublish.out" 2>&1 &
  wrapper_pid=$!
  register_pid "${wrapper_pid}"
  wait_for_file "${ready}"
  wait_for_file "${owner_identity}"
  IFS=$'\t' read -r holder_pid holder_starttime <"${owner_identity}"
  register_pid "${holder_pid}" "${holder_starttime}"
  register_lease_root "${root}"
  [[ ! -e "${root}/holder" && ! -L "${root}/holder" ]]
  nonce_count="$(run_host_command find "${root}" -mindepth 1 -maxdepth 1 \
    -type f -name '.nonce.*' -printf x | run_host_command wc -c)"
  staging_count="$(run_host_command find "${root}" -mindepth 1 -maxdepth 1 \
    -type f -name '.holder.*' -printf x | run_host_command wc -c)"
  [[ "${nonce_count}" -eq 1 && "${staging_count}" -eq 1 ]]
  builtin kill -KILL "${holder_pid}"
  builtin wait "${wrapper_pid}" 2>/dev/null || status=$?
  [[ "${status}" -eq 137 ]]
  marker="${WORK_DIR}/prepublish-retry.mutation"
  output="${WORK_DIR}/prepublish-retry.out"
  for ((attempt = 1; attempt <= 100; attempt++)); do
    capture_driver "${output}" "${cluster}" once "${marker}"
    if [[ "${CAPTURED_STATUS}" -eq 0 ]]; then
      break
    fi
    [[ "${CAPTURED_STATUS}" -eq "${PROOF_BUSY_STATUS}" ]]
    assert_markers_absent "${marker}"
    run_host_command sleep 0.02
  done
  [[ "${CAPTURED_STATUS}" -eq 0 ]]
  assert_markers_present "${marker}"
  assert_lock_only "${root}"

  marker="${WORK_DIR}/publish-failure.marker"
  run_driver "${cluster}" publish-failure "${marker}" \
    "${WORK_DIR}/publish-failure.mutation"
  run_host_command grep -Fqx attempted "${marker}"
  assert_markers_absent "${WORK_DIR}/publish-failure.mutation"
  assert_lock_only "${root}"
  run_driver "${cluster}" postflock-failure \
    "${WORK_DIR}/postflock-failure.mutation"
  assert_markers_absent "${WORK_DIR}/postflock-failure.mutation"
  [[ -f "${root}/holder" ]]
  run_host_command grep -Fqx malformed "${root}/holder"
  holder_identity="$(lease_path_identity "${root}/holder")"
  remove_exact_path "${root}/holder" "${holder_identity}"
  assert_lock_only "${root}"
  builtin printf \
    'PASS  lifecycle     KILL before publication, orphan recovery, publish failure, and same-shell FD release\n'
}

prove_term_interruption() {
  local cluster="$1" root="$2"
  local ready descendant_ready descendant_release pid_record
  local sibling marker output wrapper_pid holder_pid holder_starttime owner_identity
  local descendant_pid descendant_starttime
  local status=0
  ready="${WORK_DIR}/term.ready"
  descendant_ready="${WORK_DIR}/term-descendant.ready"
  descendant_release="${WORK_DIR}/term-descendant.release"
  pid_record="${WORK_DIR}/term-descendant.pid"
  owner_identity="${WORK_DIR}/term-owner.pid"
  sibling="${WORK_DIR}/term-sibling.mutation"
  run_driver "${cluster}" term-parent "${ready}" "${descendant_ready}" \
    "${descendant_release}" "${sibling}" "${pid_record}" "${owner_identity}" \
    >"${WORK_DIR}/term.out" 2>&1 &
  wrapper_pid=$!
  register_pid "${wrapper_pid}"
  wait_for_file "${ready}"
  wait_for_file "${descendant_ready}"
  wait_for_file "${pid_record}"
  wait_for_file "${owner_identity}"
  IFS=$'\t' read -r holder_pid holder_starttime <"${owner_identity}"
  register_pid "${holder_pid}" "${holder_starttime}"
  register_lease_root "${root}"
  IFS=$'\t' read -r descendant_pid descendant_starttime <"${pid_record}"
  register_pid "${descendant_pid}" "${descendant_starttime}"
  builtin kill -TERM "${holder_pid}"
  builtin wait "${wrapper_pid}" 2>/dev/null || status=$?
  [[ "${status}" -eq 143 && ! -e "${sibling}" && ! -L "${sibling}" &&
    ! -e "${root}/holder" && ! -L "${root}/holder" ]]
  marker="${WORK_DIR}/term-retry.mutation"
  output="${WORK_DIR}/term-retry.out"
  capture_driver "${output}" "${cluster}" once "${marker}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BUSY_STATUS}" &&
    -s "${output}" ]]
  assert_markers_absent "${marker}"
  printf 'release\n' >"${descendant_release}"
  wait_for_process_nonlive "${descendant_pid}" "${descendant_starttime}"
  run_driver "${cluster}" once "${marker}"
  assert_markers_present "${marker}"
  assert_lock_only "${root}"
}

prove_kill_interruption() {
  local cluster="$1" root="$2"
  local ready descendant_ready descendant_release pid_record
  local marker output wrapper_pid holder_pid holder_starttime owner_identity
  local descendant_pid descendant_starttime
  local status=0
  ready="${WORK_DIR}/kill.ready"
  descendant_ready="${WORK_DIR}/kill-descendant.ready"
  descendant_release="${WORK_DIR}/kill-descendant.release"
  pid_record="${WORK_DIR}/kill-descendant.pid"
  owner_identity="${WORK_DIR}/kill-owner.pid"
  run_driver "${cluster}" kill-holder "${ready}" "${descendant_ready}" \
    "${descendant_release}" "${pid_record}" "${owner_identity}" \
    >"${WORK_DIR}/kill.out" 2>&1 &
  wrapper_pid=$!
  register_pid "${wrapper_pid}"
  wait_for_file "${ready}"
  wait_for_file "${descendant_ready}"
  wait_for_file "${pid_record}"
  wait_for_file "${owner_identity}"
  IFS=$'\t' read -r holder_pid holder_starttime <"${owner_identity}"
  register_pid "${holder_pid}" "${holder_starttime}"
  IFS=$'\t' read -r descendant_pid descendant_starttime <"${pid_record}"
  register_pid "${descendant_pid}" "${descendant_starttime}"
  status=0
  builtin kill -KILL "${holder_pid}"
  builtin wait "${wrapper_pid}" 2>/dev/null || status=$?
  [[ "${status}" -eq 137 && -f "${root}/holder" ]]
  marker="${WORK_DIR}/kill-retry.mutation"
  output="${WORK_DIR}/kill-retry.out"
  capture_driver "${output}" "${cluster}" once "${marker}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BUSY_STATUS}" &&
    -s "${output}" ]]
  assert_markers_absent "${marker}"
  printf 'release\n' >"${descendant_release}"
  wait_for_process_nonlive "${descendant_pid}" "${descendant_starttime}"
  run_driver "${cluster}" once "${marker}"
  assert_markers_present "${marker}"
  assert_lock_only "${root}"
}

prove_interruption_boundaries() {
  local cluster root
  configure_case interruption
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  prove_term_interruption "${cluster}" "${root}"
  prove_kill_interruption "${cluster}" "${root}"
  builtin printf \
    'PASS  lifecycle     TERM-before-mutation and KILL inherited-FD stay busy until descendants exit\n'
  builtin printf \
    'INFO  lifecycle     interruption after kind create remains fail-closed: no automatic adoption or delete\n'
}

prove_stale_contender_holder() {
  local cluster="$1" root="$2"
  local stale_ready stale_release stale_nested stale_wrong stale_identity
  local stale_pid stale_holder stale_starttime status=0
  stale_ready="${WORK_DIR}/stale.ready"
  stale_release="${WORK_DIR}/stale.release"
  stale_nested="${WORK_DIR}/stale-nested.out"
  stale_wrong="${WORK_DIR}/stale-wrong.out"
  stale_identity="${WORK_DIR}/stale.identity"
  run_driver "${cluster}" hold "${stale_ready}" "${stale_release}" \
    "${stale_nested}" "${stale_wrong}" "${stale_identity}" \
    "${WORK_DIR}/stale-wrong.mutation" \
    >"${WORK_DIR}/stale.out" 2>&1 &
  stale_pid=$!
  register_pid "${stale_pid}"
  wait_for_file "${stale_ready}"
  wait_for_file "${stale_identity}"
  assert_markers_absent "${WORK_DIR}/stale-wrong.mutation"
  IFS=$'\t' read -r stale_holder stale_starttime <"${stale_identity}"
  register_pid "${stale_holder}" "${stale_starttime}"
  register_lease_root "${root}"
  builtin kill -KILL "${stale_holder}"
  builtin wait "${stale_pid}" 2>/dev/null || status=$?
  [[ "${status}" -eq 137 && -f "${root}/holder" ]]
}

prove_competing_contenders() {
  local cluster="$1" root="$2"
  local ready_a ready_b go result_a result_b winner_a winner_b release
  local markers_a markers_b identity_a identity_b owner_pid owner_starttime
  local pid_a pid_b a b winner_count
  ready_a="${WORK_DIR}/contender-a.ready"
  ready_b="${WORK_DIR}/contender-b.ready"
  go="${WORK_DIR}/contenders.go"
  result_a="${WORK_DIR}/contender-a.result"
  result_b="${WORK_DIR}/contender-b.result"
  winner_a="${WORK_DIR}/contender-a.winner"
  winner_b="${WORK_DIR}/contender-b.winner"
  markers_a="${WORK_DIR}/contender-a.mutation"
  markers_b="${WORK_DIR}/contender-b.mutation"
  identity_a="${WORK_DIR}/contender-a.identity"
  identity_b="${WORK_DIR}/contender-b.identity"
  release="${WORK_DIR}/contenders.release"
  run_driver "${cluster}" contend \
    "${ready_a}" "${go}" "${result_a}" "${winner_a}" "${release}" \
    "${markers_a}" "${identity_a}" &
  pid_a=$!
  register_pid "${pid_a}"
  run_driver "${cluster}" contend \
    "${ready_b}" "${go}" "${result_b}" "${winner_b}" "${release}" \
    "${markers_b}" "${identity_b}" &
  pid_b=$!
  register_pid "${pid_b}"
  wait_for_file "${ready_a}"
  wait_for_file "${ready_b}"
  printf 'go\n' >"${go}"
  wait_for_file "${result_a}"
  wait_for_file "${result_b}"
  IFS= read -r a <"${result_a}"
  IFS= read -r b <"${result_b}"
  [[ ("${a}" -eq 0 && "${b}" -eq "${PROOF_BUSY_STATUS}") ||
    ("${b}" -eq 0 && "${a}" -eq "${PROOF_BUSY_STATUS}") ]]
  if [[ "${a}" -eq 0 ]]; then
    wait_for_file "${winner_a}"
  else
    wait_for_file "${winner_b}"
  fi
  winner_count=0
  [[ ! -s "${winner_a}" ]] || ((winner_count += 1))
  [[ ! -s "${winner_b}" ]] || ((winner_count += 1))
  [[ "${winner_count}" -eq 1 ]]
  if [[ "${a}" -eq 0 ]]; then
    assert_markers_present "${markers_a}"
    assert_markers_absent "${markers_b}"
    wait_for_file "${identity_a}"
    IFS=$'\t' read -r owner_pid owner_starttime <"${identity_a}"
  else
    assert_markers_absent "${markers_a}"
    assert_markers_present "${markers_b}"
    wait_for_file "${identity_b}"
    IFS=$'\t' read -r owner_pid owner_starttime <"${identity_b}"
  fi
  register_pid "${owner_pid}" "${owner_starttime}"
  printf 'release\n' >"${release}"
  builtin wait "${pid_a}"
  builtin wait "${pid_b}"
  assert_lock_only "${root}"
}

prove_contenders_and_release_mismatch() {
  local cluster root
  configure_case contenders
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  prove_stale_contender_holder "${cluster}" "${root}"
  prove_competing_contenders "${cluster}" "${root}"
  run_driver "${cluster}" release-mismatch
  [[ -f "${root}/holder" ]]
  run_driver "${cluster}" once
  assert_lock_only "${root}"
  builtin printf \
    'PASS  lifecycle     two contenders have one winner; ABA release mismatch retains the holder\n'
}

prove_record_format_reds() {
  local record_case cluster root marker_prefix output secret payload_secret
  local artifact identity diagnostic size
  local -a record_cases=(oversized nul missing-final-lf extra-field
    invalid-action invalid-token unexpected-orphan)
  for record_case in "${record_cases[@]}"; do
    configure_case "record-${record_case}"
    cluster="${CASE_CLUSTER}"
    root="${CASE_ROOT}"
    marker_prefix="${WORK_DIR}/record-${record_case}.mutation"
    output="${WORK_DIR}/record-${record_case}.out"
    secret='LEASE_SECRET_DO_NOT_ECHO'
    payload_secret="${secret}:${HOME}:${root}"
    capture_driver "${output}" "${cluster}" record-case "${record_case}" \
      "${marker_prefix}" "${payload_secret}"
    [[ "${CAPTURED_STATUS}" -eq "${PROOF_BOUNDARY_STATUS}" ]]
    assert_markers_absent "${marker_prefix}"
    size="$(run_host_command wc -c <"${output}")"
    [[ "${size}" =~ ^[0-9]+$ && "${size}" -le 256 ]]
    for diagnostic in "${secret}" "${HOME}" "${root}"; do
      if run_host_command grep -Fq -- "${diagnostic}" "${output}"; then
        builtin printf 'FAIL  lifecycle     record diagnostic leaked payload bytes\n' >&2
        return 1
      fi
    done
    case "${record_case}" in
      oversized)
        run_host_command grep -Fqx \
          'FAIL  lifecycle     lease holder size is malformed' "${output}"
        [[ "$(run_host_command stat -Lc '%s' -- "${root}/holder")" -eq 1025 ]]
        artifact="${root}/holder"
        ;;
      nul)
        run_host_command grep -Fqx \
          'FAIL  lifecycle     lease holder contains a forbidden byte' "${output}"
        artifact="${root}/holder"
        ;;
      missing-final-lf | extra-field)
        run_host_command grep -Fqx \
          'FAIL  lifecycle     lease holder framing is malformed' "${output}"
        artifact="${root}/holder"
        ;;
      invalid-action | invalid-token)
        run_host_command grep -Fqx \
          'FAIL  lifecycle     lease holder is malformed' "${output}"
        artifact="${root}/holder"
        ;;
      unexpected-orphan)
        run_host_command grep -Fqx \
          'FAIL  lifecycle     lease directory contains an unexpected entry' \
          "${output}"
        artifact="${root}/unexpected-proof-entry"
        ;;
    esac
    register_lease_root "${root}"
    register_lease_lock "${root}"
    identity="$(lease_path_identity "${artifact}")"
    remove_exact_path "${artifact}" "${identity}"
    assert_lock_only "${root}"
    cleanup_registered_root "${root}"
  done
  builtin printf \
    'PASS  lifecycle     holder byte bound, framing, grammar, orphan, and redaction REDs proved\n'
}

prove_directory_swap_red() {
  local cluster root original_root victim_root marker_prefix output status=0
  local root_link_identity original_identity rejected_link
  configure_case directory-swap
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  original_root="${WORK_DIR}/directory-swap.original"
  victim_root="${WORK_DIR}/directory-swap.victim"
  rejected_link="${WORK_DIR}/directory-swap.rejected-link"
  marker_prefix="${WORK_DIR}/directory-swap.mutation"
  output="${WORK_DIR}/directory-swap.out"
  run_host_command mkdir -- "${victim_root}"
  run_driver "${cluster}" root-swap "${original_root}" "${victim_root}" \
    "${marker_prefix}" >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${PROOF_BOUNDARY_STATUS}" ]]
  assert_markers_absent "${marker_prefix}"
  [[ -L "${root}" && -d "${original_root}" &&
    ! -e "${victim_root}/lock" && ! -L "${victim_root}/lock" ]]
  run_host_command grep -Fqx \
    'FAIL  lifecycle     lifecycle lease acquisition failed at a trust boundary' \
    "${output}"
  root_link_identity="$(lease_path_identity "${root}")"
  original_identity="$(lease_inode_identity "${original_root}")"
  run_host_command mv -T -- "${root}" "${rejected_link}"
  [[ "$(lease_path_identity "${rejected_link}")" == "${root_link_identity}" ]]
  run_host_command rm -d -- "${victim_root}"
  run_host_command mv -- "${original_root}" "${root}"
  [[ "$(lease_inode_identity "${root}")" == "${original_identity}" ]]
  remove_exact_path "${rejected_link}" "${root_link_identity}"
  assert_lock_only "${root}"
  cleanup_registered_root "${root}"
  builtin printf \
    'PASS  lifecycle     pinned directory rejected canonical root replacement without touching victim\n'
}

prove_cleanup_guards() {
  local cluster root original replacement_saved sentinel
  local status=0 sentinel_identity lock_identity replacement_identity lock_fd

  configure_case cleanup-replacement
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  original="${WORK_DIR}/cleanup-replacement.original"
  replacement_saved="${WORK_DIR}/cleanup-replacement.foreign"
  run_driver "${cluster}" once
  assert_lock_only "${root}"
  run_host_command mv -- "${root}" "${original}"
  (umask 077 && run_host_command mkdir -- "${root}")
  (umask 077 && : >"${root}/lock")
  sentinel="${root}/must-survive"
  printf 'preserve\n' >"${sentinel}"
  replacement_identity="$(lease_inode_identity "${root}")"
  status=0
  cleanup_registered_root "${root}" || status=$?
  [[ "${status}" -eq "${PROOF_RETAINED_STATUS}" ]]
  run_host_command grep -Fqx preserve "${sentinel}"
  run_host_command mv -- "${root}" "${replacement_saved}"
  [[ "$(lease_inode_identity "${replacement_saved}")" == "${replacement_identity}" ]]
  sentinel="${replacement_saved}/must-survive"
  sentinel_identity="$(lease_path_identity "${sentinel}")"
  remove_exact_path "${sentinel}" "${sentinel_identity}"
  lock_identity="$(lease_path_identity "${replacement_saved}/lock")"
  exec {lock_fd}<>"${replacement_saved}/lock"
  run_host_command flock --exclusive --nonblock \
    --conflict-exit-code "${PROOF_RETAINED_STATUS}" "${lock_fd}"
  remove_exact_path "${replacement_saved}/lock" "${lock_identity}"
  exec {lock_fd}>&-
  run_host_command rm -d -- "${replacement_saved}"
  run_host_command mv -- "${original}" "${root}"
  cleanup_registered_root "${root}"

  configure_case cleanup-locked
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  run_driver "${cluster}" once
  assert_lock_only "${root}"
  exec {lock_fd}<>"${root}/lock"
  run_host_command flock --exclusive --nonblock \
    --conflict-exit-code "${PROOF_RETAINED_STATUS}" "${lock_fd}"
  status=0
  cleanup_registered_root "${root}" || status=$?
  [[ "${status}" -eq "${PROOF_RETAINED_STATUS}" ]]
  assert_lock_only "${root}"
  exec {lock_fd}>&-
  cleanup_registered_root "${root}"
  builtin printf \
    'PASS  lifecycle     cleanup preserved replaced roots and independently locked inodes\n'
}

prove_root_path_attacks() {
  local cluster root target adapted marker identity marker_prefix output

  configure_case root-symlink
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  target="${WORK_DIR}/root-symlink-target"
  adapted="${WORK_DIR}/root-symlink-adapted"
  run_host_command mkdir -- "${target}"
  run_host_command ln -s -- "${target}" "${adapted}"
  identity="$(lease_path_identity "${adapted}")"
  expect_adapted_root_boundary root-symlink "${cluster}" "${adapted}" \
    'lease directory must not be a symlink'
  [[ ! -e "${target}/lock" && ! -L "${target}/lock" ]]
  remove_exact_path "${adapted}" "${identity}"
  run_host_command rm -d -- "${target}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case root-file
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  adapted="${WORK_DIR}/root-file-adapted"
  (umask 077 && : >"${adapted}")
  identity="$(lease_path_identity "${adapted}")"
  expect_adapted_root_boundary root-file "${cluster}" "${adapted}" \
    'lease path is not a directory'
  remove_exact_path "${adapted}" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case root-mode
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  adapted="${WORK_DIR}/root-mode-adapted"
  (umask 077 && run_host_command mkdir -- "${adapted}")
  run_host_command chmod 0755 "${adapted}"
  expect_adapted_root_boundary root-mode "${cluster}" "${adapted}" \
    'lease directory identity is unsafe'
  run_host_command chmod 0700 "${adapted}"
  identity="$(lease_path_identity "${adapted}")"
  remove_exact_path "${adapted}" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case root-nlink
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  adapted="${WORK_DIR}/root-nlink-adapted"
  (umask 077 && run_host_command mkdir -- "${adapted}")
  run_host_command mkdir -- "${adapted}/extra-directory"
  expect_adapted_root_boundary root-nlink "${cluster}" "${adapted}" \
    'lease directory identity is unsafe'
  identity="$(lease_path_identity "${adapted}/extra-directory")"
  remove_exact_path "${adapted}/extra-directory" "${identity}"
  identity="$(lease_path_identity "${adapted}")"
  remove_exact_path "${adapted}" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case root-owner
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  marker_prefix="${WORK_DIR}/root-owner.mutation"
  capture_driver "${WORK_DIR}/root-owner.driver.out" "${cluster}" \
    foreign-owner directory "${marker_prefix}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BOUNDARY_STATUS}" ]]
  assert_markers_absent "${marker_prefix}"
  output="${marker_prefix}.out"
  run_host_command grep -Fqx \
    'FAIL  lifecycle     lease directory identity is unsafe' "${output}"
  assert_lock_only "${root}"
  finalize_attack_root "${cluster}" "${root}"
  marker="${WORK_DIR}/root-paths.proved"
  printf 'proved\n' >"${marker}"
  builtin printf \
    'PASS  lifecycle     shared root rejects symlink, non-directory, mode, link count, and foreign owner\n'
}

prove_lock_attacks() {
  local cluster root adapted victim hardlink identity hardlink_identity
  local marker_prefix output

  configure_case lock-symlink
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  victim="${WORK_DIR}/lock-symlink.victim"
  adapted="${WORK_DIR}/lock-symlink-adapted"
  printf 'safe\n' >"${victim}"
  (umask 077 && run_host_command mkdir -- "${adapted}")
  run_host_command ln -s -- "${victim}" "${adapted}/lock"
  identity="$(lease_path_identity "${adapted}/lock")"
  expect_adapted_root_boundary lock-symlink "${cluster}" "${adapted}" \
    'lease lock must not be a symlink'
  run_host_command grep -Fqx safe "${victim}"
  remove_exact_path "${adapted}/lock" "${identity}"
  identity="$(lease_path_identity "${adapted}")"
  remove_exact_path "${adapted}" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case lock-fifo
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  adapted="${WORK_DIR}/lock-fifo-adapted"
  (umask 077 && run_host_command mkdir -- "${adapted}")
  run_host_command mkfifo -- "${adapted}/lock"
  run_host_command chmod 0600 "${adapted}/lock"
  identity="$(lease_path_identity "${adapted}/lock")"
  expect_adapted_root_boundary lock-fifo "${cluster}" "${adapted}" \
    'lease lock is not a regular file'
  remove_exact_path "${adapted}/lock" "${identity}"
  identity="$(lease_path_identity "${adapted}")"
  remove_exact_path "${adapted}" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case lock-mode
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  run_host_command chmod 0644 "${root}/lock"
  expect_boundary_without_mutation lock-mode "${cluster}"
  [[ "$(lease_inode_identity "${root}/lock")" == "${LEASE_LOCK_IDENTITIES[${root}]%%:600:1:0}" ]]
  run_host_command chmod 0600 "${root}/lock"
  finalize_attack_root "${cluster}" "${root}"

  configure_case lock-nlink
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  hardlink="${WORK_DIR}/lock-hardlink"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  run_host_command ln -- "${root}/lock" "${hardlink}"
  hardlink_identity="$(lease_path_identity "${hardlink}")"
  expect_boundary_without_mutation lock-nlink "${cluster}"
  remove_exact_path "${hardlink}" "${hardlink_identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case lock-owner
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  marker_prefix="${WORK_DIR}/lock-owner.mutation"
  capture_driver "${WORK_DIR}/lock-owner.driver.out" "${cluster}" \
    foreign-owner lock "${marker_prefix}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BOUNDARY_STATUS}" ]]
  assert_markers_absent "${marker_prefix}"
  output="${marker_prefix}.out"
  run_host_command grep -Fqx \
    'FAIL  lifecycle     lease lock identity is unsafe' "${output}"
  [[ -f "${root}/lock" && ! -e "${root}/holder" ]]
  assert_lock_only "${root}"
  cleanup_registered_root "${root}"
}

prove_holder_file_attacks() {
  local cluster root victim hardlink identity hardlink_identity
  configure_case holder-symlink
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  victim="${WORK_DIR}/holder-symlink.victim"
  printf 'safe\n' >"${victim}"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  run_host_command ln -s -- "${victim}" "${root}/holder"
  identity="$(lease_path_identity "${root}/holder")"
  expect_boundary_without_mutation holder-symlink "${cluster}"
  run_host_command grep -Fqx safe "${victim}"
  remove_exact_path "${root}/holder" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case holder-fifo
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  run_host_command mkfifo -- "${root}/holder"
  run_host_command chmod 0600 "${root}/holder"
  identity="$(lease_path_identity "${root}/holder")"
  expect_boundary_without_mutation holder-fifo "${cluster}"
  remove_exact_path "${root}/holder" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case holder-mode
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  printf 'malformed\n' >"${root}/holder"
  run_host_command chmod 0644 "${root}/holder"
  identity="$(lease_path_identity "${root}/holder")"
  expect_boundary_without_mutation holder-mode "${cluster}"
  remove_exact_path "${root}/holder" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case holder-nlink
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  hardlink="${WORK_DIR}/holder-hardlink"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  (umask 077 && printf 'malformed\n' >"${root}/holder")
  run_host_command ln -- "${root}/holder" "${hardlink}"
  hardlink_identity="$(lease_path_identity "${hardlink}")"
  expect_boundary_without_mutation holder-nlink "${cluster}"
  remove_exact_path "${hardlink}" "${hardlink_identity}"
  identity="$(lease_path_identity "${root}/holder")"
  remove_exact_path "${root}/holder" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case holder-malformed
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  (umask 077 && printf 'malformed\n' >"${root}/holder")
  identity="$(lease_path_identity "${root}/holder")"
  expect_boundary_without_mutation holder-malformed "${cluster}"
  remove_exact_path "${root}/holder" "${identity}"
  finalize_attack_root "${cluster}" "${root}"
}

prove_holder_owner_and_orphan_attacks() {
  local cluster root victim identity marker_prefix output
  configure_case holder-owner
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  marker_prefix="${WORK_DIR}/holder-owner.mutation"
  capture_driver "${WORK_DIR}/holder-owner.driver.out" "${cluster}" \
    foreign-owner holder "${marker_prefix}"
  [[ "${CAPTURED_STATUS}" -eq "${PROOF_BOUNDARY_STATUS}" ]]
  assert_markers_absent "${marker_prefix}"
  output="${marker_prefix}.out"
  run_host_command grep -Fqx \
    'FAIL  lifecycle     lease holder identity is unsafe' "${output}"
  [[ -f "${root}/holder" ]]
  register_lease_root "${root}"
  register_lease_lock "${root}"
  identity="$(lease_path_identity "${root}/holder")"
  remove_exact_path "${root}/holder" "${identity}"
  finalize_attack_root "${cluster}" "${root}"

  configure_case orphan-symlink
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  victim="${WORK_DIR}/orphan-symlink.victim"
  printf 'safe\n' >"${victim}"
  prepare_safe_root "${root}"
  prepare_safe_lock "${root}"
  run_host_command ln -s -- "${victim}" \
    "${root}/.nonce.AAAAAAAAAAAAAAAA"
  identity="$(lease_path_identity "${root}/.nonce.AAAAAAAAAAAAAAAA")"
  expect_boundary_without_mutation orphan-symlink "${cluster}"
  run_host_command grep -Fqx safe "${victim}"
  remove_exact_path "${root}/.nonce.AAAAAAAAAAAAAAAA" "${identity}"
  finalize_attack_root "${cluster}" "${root}"
}

prove_lock_and_holder_attacks() {
  prove_lock_attacks
  prove_holder_file_attacks
  prove_holder_owner_and_orphan_attacks
  builtin printf \
    'PASS  lifecycle     lock, holder, and orphan reject symlink, nonregular, mode, owner, link, and malformed state\n'
}

prove_final_hygiene() {
  local cluster root candidate
  configure_case final
  cluster="${CASE_CLUSTER}"
  root="${CASE_ROOT}"
  run_driver "${cluster}" once
  assert_lock_only "${root}"
  for candidate in "${!LEASE_ROOT_IDENTITIES[@]}"; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    cleanup_registered_root "${candidate}"
    assert_lock_only "${candidate}"
  done
  for candidate in "${LEASE_ROOTS[@]}"; do
    assert_lock_only "${candidate}"
  done
  builtin printf \
    'PASS  lifecycle     guarded cleanup retained every canonical root as exact free lock-only state\n'
}

main() {
  local digest
  WORK_DIR="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/lifecycle-lease-proof.XXXXXXXX")"
  run_host_command chmod 0700 "${WORK_DIR}"
  WORK_DIR_IDENTITY="$(lease_inode_identity "${WORK_DIR}")"
  digest="$({
    builtin printf 'flare-platform-lifecycle-proof-owner-v1\0%s\0%s\0' \
      "${WORK_DIR}" "${BASHPID}" | run_host_command sha256sum --
  })"
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]]
  WORK_OWNER_TOKEN="proof-sha256:${BASH_REMATCH[1]}"
  (umask 077 && printf '%s\n' "${WORK_OWNER_TOKEN}" >"${WORK_DIR}/.proof-owner")
  (umask 077 && : >"${WORK_DIR}/.proof-lock")
  WORK_OWNER_IDENTITY="$(lease_path_identity "${WORK_DIR}/.proof-owner")"
  WORK_LOCK_IDENTITY="$(lease_path_identity "${WORK_DIR}/.proof-lock")"
  WORK_CLEANUP_READY=true
  trap cleanup_lifecycle_proof EXIT
  prove_active_nested_and_release
  prove_stale_and_zombie_recovery
  prove_kill_before_publication_and_failure_release
  prove_interruption_boundaries
  prove_contenders_and_release_mismatch
  prove_record_format_reds
  prove_directory_swap_red
  prove_cleanup_guards
  prove_root_path_attacks
  prove_lock_and_holder_attacks
  prove_registered_processes_gone
  prove_final_hygiene
  cleanup_work_directory
  WORK_DIR=''
  trap - EXIT
  builtin printf \
    'PASS  lifecycle     deterministic no-Docker lifecycle lease matrix proved\n'
}

main "$@"
