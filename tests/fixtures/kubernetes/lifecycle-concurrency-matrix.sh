#!/bin/bash -p
set -euo pipefail

SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || SOURCE_DIR=.
REPOSITORY_ROOT="$(builtin cd -P -- "${SOURCE_DIR}/../../.." && builtin pwd -P)"
builtin source "${REPOSITORY_ROOT}/tools/common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/process-state.sh"

WORK_DIR="$(run_host_command mktemp -d \
  '/tmp/flare-platform-lifecycle-concurrency.XXXXXXXX')"
readonly REPOSITORY_ROOT WORK_DIR
declare -a CASE_DIRS=()
declare -a LEASE_ROOTS=()
declare -a PROOF_PIDS=()
declare -a PROOF_STARTTIMES=()
declare -a PROOF_ACTIVE=()
declare -A LEASE_ROOT_IDENTITIES=()
declare -A LEASE_LOCK_IDENTITIES=()
CASE_TARGET=''
CASE_SHARED=''
CASE_CLUSTER=''
CASE_LEASE_ROOT=''
ACTION_STATUS=0
BACKGROUND_PID=''
WORK_DIR_IDENTITY=''
WORK_OWNER_TOKEN=''
WORK_OWNER_IDENTITY=''
WORK_LOCK_IDENTITY=''
WORK_CLEANUP_READY=false

lease_digest_for_cluster() {
  local cluster="$1" digest
  digest="$({
    builtin printf \
      'flare-platform-lifecycle-path-v1\0project=flare-platform\0cluster=%s\0' \
      "${cluster}" | run_host_command sha256sum --
  })"
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]]
  builtin printf '%s\n' "${BASH_REMATCH[1]}"
}

register_pid() {
  local pid="$1" snapshot observed_pid observed_pgrp starttime kernel_state
  snapshot="$(linux_process_snapshot "${pid}")"
  IFS=$'\t' builtin read -r \
    observed_pid observed_pgrp starttime kernel_state <<<"${snapshot}"
  [[ "${observed_pid}" == "${pid}" && "${observed_pgrp}" =~ ^[0-9]+$ &&
    "${starttime}" =~ ^[0-9]+$ && -n "${kernel_state}" ]]
  PROOF_PIDS+=("${pid}")
  PROOF_STARTTIMES+=("${starttime}")
  PROOF_ACTIVE+=(true)
}

forget_pid() {
  local pid="$1" index
  for ((index = 0; index < ${#PROOF_PIDS[@]}; index++)); do
    if [[ "${PROOF_PIDS[index]}" == "${pid}" ]]; then
      PROOF_ACTIVE[index]=false
      return 0
    fi
  done
  return 1
}

path_identity() {
  run_host_command stat -c '%d:%i:%u:%a:%h:%s' -- "$1"
}

inode_identity() {
  run_host_command stat -c '%d:%i:%F:%u' -- "$1"
}

pinned_inode_identity() {
  run_host_command stat -Lc '%d:%i:%F:%u' -- "$1"
}

register_lease_root() {
  local root="$1" root_identity lock_identity canonical
  [[ "${root}" =~ ^/tmp/flare-platform-lifecycle-lease-[0-9a-f]{64}$ ]]
  [[ -d "${root}" && ! -L "${root}" ]]
  root_identity="$(inode_identity "${root}")"
  [[ "${root_identity}" == *":directory:${EUID}" ]]
  [[ "$(run_host_command stat -c '%a:%h' -- "${root}")" == 700:2 ]]
  canonical="$(run_host_command readlink -f -- "${root}")"
  [[ "${canonical}" == "${root}" ]]
  [[ -f "${root}/lock" && ! -L "${root}/lock" ]]
  lock_identity="$(path_identity "${root}/lock")"
  [[ "${lock_identity}" == *":${EUID}:600:1:0" ]]
  LEASE_ROOT_IDENTITIES["${root}"]="${root_identity}"
  LEASE_LOCK_IDENTITIES["${root}"]="${lock_identity}"
}

cleanup_lease_root() {
  local root="$1" root_identity lock_identity canonical entries
  local directory_fd lock_fd status=0
  root_identity="${LEASE_ROOT_IDENTITIES[${root}]:-}"
  lock_identity="${LEASE_LOCK_IDENTITIES[${root}]:-}"
  [[ -n "${root_identity}" && -n "${lock_identity}" ]]
  [[ -d "${root}" && ! -L "${root}" ]]
  [[ "$(inode_identity "${root}")" == "${root_identity}" ]]
  [[ "$(run_host_command stat -c '%a:%h' -- "${root}")" == 700:2 ]]
  canonical="$(run_host_command readlink -f -- "${root}")"
  [[ "${canonical}" == "${root}" ]]
  exec {directory_fd}<"${root}"
  [[ "$(pinned_inode_identity "/proc/self/fd/${directory_fd}")" == "${root_identity}" ]]
  [[ "$(path_identity "/proc/self/fd/${directory_fd}/lock")" == "${lock_identity}" ]]
  exec {lock_fd}<>"/proc/self/fd/${directory_fd}/lock"
  run_host_command flock --exclusive --nonblock --conflict-exit-code 77 \
    "${lock_fd}" || status=$?
  if ((status == 0)); then
    entries="$(run_host_command find -H "/proc/self/fd/${directory_fd}" \
      -mindepth 1 -maxdepth 1 -printf '%f\n' | run_host_command sort)" || status=$?
    [[ "${entries}" == lock ]] || status=1
  fi
  { exec {lock_fd}>&-; } 2>/dev/null || status=1
  [[ "$(inode_identity "${root}")" == "${root_identity}" ]] || status=1
  { exec {directory_fd}<&-; } 2>/dev/null || status=1
  ((status == 0))
  [[ "$(path_identity "${root}/lock")" == "${lock_identity}" ]]
}

initialize_work_guard() {
  local digest
  [[ -d "${WORK_DIR}" && ! -L "${WORK_DIR}" ]]
  [[ "$(run_host_command stat -c '%u:%a:%h' -- "${WORK_DIR}")" == "${EUID}:700:2" ]]
  digest="$({
    builtin printf 'flare-lifecycle-matrix-owner-v1\0%s\0%s\0' \
      "${WORK_DIR}" "${BASHPID}" | run_host_command sha256sum --
  })"
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]]
  WORK_OWNER_TOKEN="sha256:${BASH_REMATCH[1]}"
  (umask 077 && builtin printf '%s\n' "${WORK_OWNER_TOKEN}" \
    >"${WORK_DIR}/.proof-owner" && : >"${WORK_DIR}/.proof-lock")
  WORK_DIR_IDENTITY="$(inode_identity "${WORK_DIR}")"
  WORK_OWNER_IDENTITY="$(path_identity "${WORK_DIR}/.proof-owner")"
  WORK_LOCK_IDENTITY="$(path_identity "${WORK_DIR}/.proof-lock")"
  [[ -f "${WORK_DIR}/.proof-owner" && ! -L "${WORK_DIR}/.proof-owner" &&
    "${WORK_OWNER_IDENTITY}" == *":${EUID}:600:1:"* ]]
  [[ -f "${WORK_DIR}/.proof-lock" && ! -L "${WORK_DIR}/.proof-lock" &&
    "${WORK_LOCK_IDENTITY}" == *":${EUID}:600:1:0" ]]
  WORK_CLEANUP_READY=true
}

cleanup_work_directory() {
  local canonical owner_identity lock_identity entry relative
  local directory_fd lock_fd status=0
  local -a entries=()
  [[ "${WORK_CLEANUP_READY}" == true ]]
  [[ -d "${WORK_DIR}" && ! -L "${WORK_DIR}" ]]
  [[ "$(inode_identity "${WORK_DIR}")" == "${WORK_DIR_IDENTITY}" ]]
  [[ "$(run_host_command stat -c '%u:%a' -- "${WORK_DIR}")" == "${EUID}:700" ]]
  canonical="$(run_host_command readlink -f -- "${WORK_DIR}")"
  [[ "${canonical}" == "${WORK_DIR}" ]]
  [[ -f "${WORK_DIR}/.proof-owner" && ! -L "${WORK_DIR}/.proof-owner" ]]
  [[ -f "${WORK_DIR}/.proof-lock" && ! -L "${WORK_DIR}/.proof-lock" ]]
  owner_identity="$(path_identity "${WORK_DIR}/.proof-owner")"
  lock_identity="$(path_identity "${WORK_DIR}/.proof-lock")"
  [[ "${owner_identity}" == "${WORK_OWNER_IDENTITY}" &&
    "${lock_identity}" == "${WORK_LOCK_IDENTITY}" ]]
  [[ "$(<"${WORK_DIR}/.proof-owner")" == "${WORK_OWNER_TOKEN}" ]]
  exec {directory_fd}<"${WORK_DIR}"
  [[ "$(pinned_inode_identity "/proc/self/fd/${directory_fd}")" == "${WORK_DIR_IDENTITY}" ]]
  exec {lock_fd}<>"/proc/self/fd/${directory_fd}/.proof-lock"
  run_host_command flock --exclusive --nonblock --conflict-exit-code 77 \
    "${lock_fd}" || status=$?
  if ((status == 0)); then
    mapfile -d '' -t entries < <(run_host_command find -H \
      "/proc/self/fd/${directory_fd}" -mindepth 1 -depth -print0)
    for entry in "${entries[@]}"; do
      relative="${entry#/proc/self/fd/"${directory_fd}"/}"
      case "${relative}" in
        .proof-owner | .proof-lock) continue ;;
      esac
      if [[ -L "${entry}" ]]; then
        status=1
        break
      elif [[ -f "${entry}" ]]; then
        [[ "$(run_host_command stat -c '%u:%h' -- "${entry}")" == "${EUID}:1" ]] || {
          status=1
          break
        }
        run_host_command rm -f -- "${entry}" || {
          status=1
          break
        }
      elif [[ -d "${entry}" ]]; then
        run_host_command rm -d -- "${entry}" || {
          status=1
          break
        }
      else
        status=1
        break
      fi
    done
  fi
  if ((status == 0)); then
    [[ "$(run_host_command stat -Lc '%u:%a:%h' -- \
      "/proc/self/fd/${directory_fd}")" == "${EUID}:700:2" ]] || status=1
  fi
  if ((status == 0)); then
    [[ "$(path_identity "/proc/self/fd/${directory_fd}/.proof-owner")" == "${WORK_OWNER_IDENTITY}" ]] || status=1
    [[ "$(<"/proc/self/fd/${directory_fd}/.proof-owner")" == "${WORK_OWNER_TOKEN}" ]] || status=1
  fi
  if ((status == 0)); then
    run_host_command rm -f -- "/proc/self/fd/${directory_fd}/.proof-owner" || status=1
    run_host_command rm -f -- "/proc/self/fd/${directory_fd}/.proof-lock" || status=1
  fi
  { exec {lock_fd}>&-; } 2>/dev/null || status=1
  { exec {directory_fd}<&-; } 2>/dev/null || status=1
  ((status == 0))
  run_host_command rm -d -- "${WORK_DIR}"
}

cleanup() {
  local status=$? index pid state root
  trap - EXIT
  set +e
  for ((index = 0; index < ${#PROOF_PIDS[@]}; index++)); do
    pid="${PROOF_PIDS[index]}"
    [[ "${PROOF_ACTIVE[index]}" == true ]] || continue
    state="$(linux_process_state \
      "${pid}" "${PROOF_STARTTIMES[index]}" 2>/dev/null || true)"
    [[ "${state}" != live ]] || builtin kill -KILL "${pid}" 2>/dev/null
    builtin wait "${pid}" 2>/dev/null
  done
  for root in "${LEASE_ROOTS[@]}"; do
    [[ ! -e "${root}" && ! -L "${root}" ]] ||
      cleanup_lease_root "${root}" || status=1
  done
  [[ ! -e "${WORK_DIR}" && ! -L "${WORK_DIR}" ]] ||
    cleanup_work_directory || status=1
  exit "${status}"
}

write_fixture_env() {
  local target="$1"
  run_host_command cat >"${target}/tools/common/env.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
PLATFORM_CALLER_HOST_PATH="${PATH-}"
builtin export -n PLATFORM_CALLER_HOST_PATH
builtin unset BASH_ENV ENV TAR_OPTIONS GZIP POSIXLY_CORRECT
source_dir="${BASH_SOURCE[0]%/*}"
[[ "${source_dir}" != "${BASH_SOURCE[0]}" ]] || source_dir=.
PLATFORM_ROOT="$(builtin cd -P -- "${source_dir}/../.." && builtin pwd -P)"
export PLATFORM_ROOT PLATFORM_STATE_DIR="${PLATFORM_ROOT}/.platform"
export KUBECONFIG="${PLATFORM_STATE_DIR}/kubeconfig"
export PLATFORM_CLUSTER_NAME="${FIXTURE_CLUSTER:?}"
export PLATFORM_CONTEXT="kind-${PLATFORM_CLUSTER_NAME}"
export PLATFORM_NAMESPACE=flare-platform-reference
builtin source "${PLATFORM_ROOT}/tools/common/host-commands.sh"
host_command_initialize
builtin source "${PLATFORM_ROOT}/tools/common/state.sh"
FIXTURE
  run_host_command cat >"${target}/tools/common/tooling.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
require_tool() { :; }
FIXTURE
}

write_fixture_adapter() {
  local target="$1"
  run_host_command cat >"${target}/tools/common/fixture-adapter.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail

fixture_log() {
  local tool="$1" operation="$2"
  builtin printf '%s\n' "${operation}" >>\
    "${FIXTURE_SHARED_DIR:?}/logs/${FIXTURE_ATTEMPT:?}.${tool}.log"
  builtin printf '%s:%s:%s\n' \
    "${FIXTURE_ATTEMPT}" "${tool}" "${operation}" >>\
    "${FIXTURE_SHARED_DIR}/events"
}

fixture_mutation() {
  builtin printf '%s:%s\n' "$1" "$2" >>\
    "${FIXTURE_SHARED_DIR:?}/logs/${FIXTURE_ATTEMPT:?}.mutations.log"
}

fixture_gate() {
  local label="$1" attempt release_path
  release_path="${FIXTURE_SHARED_DIR:?}/barriers/${FIXTURE_ATTEMPT:?}.${label}.release"
  builtin printf 'ready\n' >\
    "${FIXTURE_SHARED_DIR}/barriers/${FIXTURE_ATTEMPT}.${label}.ready"
  fixture_log control "gate-ready-${label}"
  for ((attempt = 1; attempt <= 500; attempt++)); do
    if [[ -f "${release_path}" && ! -L "${release_path}" ]] &&
      [[ "$(<"${release_path}")" == release ]]; then
      fixture_log control "gate-released-${label}"
      return 0
    fi
    run_host_command sleep 0.02
  done
  builtin printf 'FAIL  fixture       gate timed out: %s\n' "${label}" >&2
  return 124
}
FIXTURE
}

write_fixture_runtime() {
  local target="$1"
  run_host_command cat >"${target}/tools/kubernetes/runtime.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
builtin source "${PLATFORM_ROOT}/tools/common/fixture-adapter.sh"

docker_target_ensure() {
  fixture_log docker target-ensure
  if [[ "${FIXTURE_INJECTION:-none}" == before-mutation ]]; then
    fixture_gate before-mutation
  fi
}

docker_command() {
  local duration="$1"
  shift
  [[ "${duration}" == 20s && "$*" == info ]]
  fixture_log docker info
}

prepare_kubeconfig_output() {
  ensure_state_directory ""
  run_host_command rm -f -- "${KUBECONFIG}"
}

fixture_write_kubeconfig() {
  local argument
  while (($#)); do
    argument="$1"
    shift
    if [[ "${argument}" == --kubeconfig ]]; then
      (($#)) || return 2
      builtin printf 'fixture\n' >"$1"
      return 0
    fi
  done
  return 2
}
FIXTURE
}

append_fixture_kind_adapter() {
  local target="$1"
  run_host_command cat >>"${target}/tools/kubernetes/runtime.sh" <<'FIXTURE'
kind_command() {
  local duration="$1" operation
  shift
  case "$*" in
    'get clusters')
      operation=get
      fixture_log kind "${operation}"
      [[ "$(<"${FIXTURE_SHARED_DIR}/cluster")" != present ]] ||
        builtin printf '%s\n' "${PLATFORM_CLUSTER_NAME}"
      ;;
    'export kubeconfig '*)
      operation=export
      fixture_log kind "${operation}"
      fixture_write_kubeconfig "$@"
      ;;
    'create cluster '*)
      operation=create
      fixture_log kind "${operation}"
      fixture_write_kubeconfig "$@"
      fixture_mutation kind create
      builtin printf 'present\n' >"${FIXTURE_SHARED_DIR}/cluster"
      if [[ "${FIXTURE_INJECTION:-none}" == after-create ]]; then
        fixture_gate after-create
      fi
      ;;
    'delete cluster '*)
      operation=delete
      fixture_log kind "${operation}"
      fixture_mutation kind delete
      builtin printf 'absent\n' >"${FIXTURE_SHARED_DIR}/cluster"
      builtin printf 'absent\n' >"${FIXTURE_SHARED_DIR}/namespace"
      run_host_command rm -f -- "${FIXTURE_SHARED_DIR}/marker"
      if [[ "${FIXTURE_INJECTION:-none}" == after-delete ]]; then
        fixture_gate after-delete
      fi
      ;;
    *)
      builtin printf 'FAIL  fixture       unexpected kind command: %s %s\n' \
        "${duration}" "$*" >&2
      return 2
      ;;
  esac
}
FIXTURE
}

append_fixture_kubectl_adapter() {
  local target="$1"
  run_host_command cat >>"${target}/tools/kubernetes/runtime.sh" <<'FIXTURE'
fixture_snapshot() {
  local checkout_id
  checkout_id="$(platform_checkout_identity)"
  builtin printf 'api_version=v1\nkind=ConfigMap\nnamespace=kube-system\n'
  builtin printf 'name=flare-platform-ownership\nuid=fixture-uid\n'
  builtin printf 'resource_version=1\ndata_count=4\nbinary_data_count=0\n'
  builtin printf 'contract_version=checkout-v1\nowner=flare-platform-infra\n'
  builtin printf 'cluster_name=%s\ncheckout_id=%s\n' \
    "${PLATFORM_CLUSTER_NAME}" "${checkout_id}"
}

kubectl_command() {
  local duration="$1" count=0 count_path
  shift
  case "$*" in
    *' get configmap flare-platform-ownership '*)
      count_path="${FIXTURE_SHARED_DIR}/logs/${FIXTURE_ATTEMPT}.ownership-count"
      [[ ! -s "${count_path}" ]] || IFS= builtin read -r count <"${count_path}"
      ((count += 1))
      builtin printf '%s\n' "${count}" >"${count_path}"
      fixture_log kubectl "ownership-get-${count}"
      [[ -f "${FIXTURE_SHARED_DIR}/marker" &&
        "$(<"${FIXTURE_SHARED_DIR}/marker")" == present ]] || return 1
      fixture_snapshot
      ;;
    *' create configmap flare-platform-ownership '*)
      fixture_log kubectl ownership-create
      fixture_mutation kubectl ownership-create
      builtin printf 'present\n' >"${FIXTURE_SHARED_DIR}/marker"
      ;;
    'wait '*) fixture_log kubectl nodes-wait ;;
    *)
      builtin printf 'FAIL  fixture       unexpected kubectl command: %s %s\n' \
        "${duration}" "$*" >&2
      return 2
      ;;
  esac
}

cluster_presence() {
  local clusters
  clusters="$(kind_command 20s get clusters)"
  if [[ "${clusters}" == "${PLATFORM_CLUSTER_NAME}" ]]; then
    builtin printf 'present\n'
  elif [[ -z "${clusters}" ]]; then
    builtin printf 'absent\n'
  else
    return 1
  fi
}
FIXTURE
}

write_fixture_support() {
  local target="$1" script
  run_host_command cat >"${target}/tools/kubernetes/guard-context.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
[[ -f "${KUBECONFIG:?}" && ! -L "${KUBECONFIG}" ]]
FIXTURE
  run_host_command cat >"${target}/tools/bootstrap/doctor.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
builtin source "${BASH_SOURCE[0]%/*}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/fixture-adapter.sh"
fixture_log control doctor
if [[ "${FIXTURE_INJECTION:-none}" == doctor-gate ]]; then
  fixture_gate doctor
fi
FIXTURE
  for script in prove-identity identity-negative-smoke smoke negative-smoke; do
    run_host_command cat >"${target}/tools/kubernetes/${script}.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
builtin source "${BASH_SOURCE[0]%/*}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/fixture-adapter.sh"
fixture_log control "${0##*/}"
FIXTURE
  done
  run_host_command cat > \
    "${target}/tools/kubernetes/publish-runtime-evidence.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
builtin source "${BASH_SOURCE[0]%/*}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/fixture-adapter.sh"
[[ "$*" == 'absent absent' ]]
fixture_log control publish-runtime-evidence
FIXTURE
}

copy_production_scripts() {
  local target="$1" script
  for script in host-commands state process-state checkout-identity \
    lifecycle-lease; do
    run_host_command cp -- "${REPOSITORY_ROOT}/tools/common/${script}.sh" \
      "${target}/tools/common/${script}.sh"
  done
  for script in kind-up kind-down ownership verify; do
    run_host_command cp -- "${REPOSITORY_ROOT}/tools/kubernetes/${script}.sh" \
      "${target}/tools/kubernetes/${script}.sh"
  done
}

prepare_case() {
  local label="$1" cluster_state="$2" marker_state="$3" digest
  CASE_TARGET="${WORK_DIR}/${label}"
  CASE_SHARED="${CASE_TARGET}/shared"
  digest="$({
    builtin printf 'flare-lifecycle-concurrency-v2\0%s\0%s\0%s\0' \
      "${REPOSITORY_ROOT}" "${EUID}" "${label}" |
      run_host_command sha256sum --
  })"
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]]
  CASE_CLUSTER="flare-matrix-${BASH_REMATCH[1]:0:24}"
  CASE_LEASE_ROOT="/tmp/flare-platform-lifecycle-lease-$(
    lease_digest_for_cluster "${CASE_CLUSTER}"
  )"
  if [[ -e "${CASE_LEASE_ROOT}" || -L "${CASE_LEASE_ROOT}" ]]; then
    register_lease_root "${CASE_LEASE_ROOT}"
    cleanup_lease_root "${CASE_LEASE_ROOT}"
  fi
  CASE_DIRS+=("${CASE_SHARED}")
  LEASE_ROOTS+=("${CASE_LEASE_ROOT}")
  run_host_command mkdir -p -- "${CASE_TARGET}/tools/common" \
    "${CASE_TARGET}/tools/kubernetes" "${CASE_TARGET}/tools/bootstrap" \
    "${CASE_TARGET}/clusters/kind" "${CASE_TARGET}/.platform" \
    "${CASE_SHARED}/logs" "${CASE_SHARED}/barriers"
  builtin printf '%s\n' "${cluster_state}" >"${CASE_SHARED}/cluster"
  builtin printf 'absent\n' >"${CASE_SHARED}/namespace"
  : >"${CASE_SHARED}/events"
  [[ "${marker_state}" != present ]] ||
    builtin printf 'present\n' >"${CASE_SHARED}/marker"
  copy_production_scripts "${CASE_TARGET}"
  write_fixture_env "${CASE_TARGET}"
  write_fixture_adapter "${CASE_TARGET}"
  write_fixture_runtime "${CASE_TARGET}"
  append_fixture_kind_adapter "${CASE_TARGET}"
  append_fixture_kubectl_adapter "${CASE_TARGET}"
  write_fixture_support "${CASE_TARGET}"
  run_host_command chmod 0755 "${CASE_TARGET}/tools/kubernetes/"*.sh \
    "${CASE_TARGET}/tools/bootstrap/doctor.sh"
}

prepare_attempt_logs() {
  local shared="$1" attempt="$2" tool
  for tool in docker kind kubectl mutations; do
    : >"${shared}/logs/${attempt}.${tool}.log"
  done
  : >"${shared}/logs/${attempt}.out"
}

start_action() {
  local target="$1" shared="$2" cluster="$3" role="$4" attempt="$5"
  local injection="$6" script="$7"
  shift 7
  FIXTURE_SHARED_DIR="${shared}" FIXTURE_CLUSTER="${cluster}" \
    FIXTURE_ROLE="${role}" FIXTURE_ATTEMPT="${attempt}" \
    FIXTURE_INJECTION="${injection}" \
    "${target}/${script}" "$@" >"${shared}/logs/${attempt}.out" 2>&1 &
  BACKGROUND_PID=$!
  register_pid "${BACKGROUND_PID}"
}

capture_action() {
  local target="$1" shared="$2" cluster="$3" role="$4" attempt="$5"
  local injection="$6" script="$7"
  shift 7
  ACTION_STATUS=0
  FIXTURE_SHARED_DIR="${shared}" FIXTURE_CLUSTER="${cluster}" \
    FIXTURE_ROLE="${role}" FIXTURE_ATTEMPT="${attempt}" \
    FIXTURE_INJECTION="${injection}" \
    "${target}/${script}" "$@" >"${shared}/logs/${attempt}.out" 2>&1 ||
    ACTION_STATUS=$?
}

wait_action() {
  local pid="$1" expected="$2" status=0
  set +e
  builtin wait "${pid}"
  status=$?
  set -e
  forget_pid "${pid}"
  [[ "${status}" -eq "${expected}" ]]
}

wait_for_ready() {
  local shared="$1" attempt="$2" label="$3" count path
  path="${shared}/barriers/${attempt}.${label}.ready"
  for ((count = 1; count <= 500; count++)); do
    if [[ -f "${path}" && ! -L "${path}" && "$(<"${path}")" == ready ]]; then
      return 0
    fi
    run_host_command sleep 0.02
  done
  return 1
}

release_gate() {
  local shared="$1" attempt="$2" label="$3"
  builtin printf 'release\n' > \
    "${shared}/barriers/${attempt}.${label}.release"
}

record_event() {
  builtin printf '%s\n' "$2" >>"$1/events"
}

assert_empty_tool_logs() {
  local shared="$1" attempt="$2" tool
  for tool in docker kind kubectl mutations; do
    [[ ! -s "${shared}/logs/${attempt}.${tool}.log" ]]
  done
}

event_line() {
  local events="$1" event="$2" match
  match="$(run_host_command grep -nFx "${event}" "${events}")"
  [[ "${match}" != *$'\n'* ]]
  builtin printf '%s\n' "${match%%:*}"
}

assert_event_order() {
  local events="$1"
  shift
  local event line previous=0
  for event in "$@"; do
    line="$(event_line "${events}" "${event}")"
    ((line > previous))
    previous="${line}"
  done
}

cleanup_owned_cluster() {
  local target="$1" shared="$2" cluster="$3" attempt="$4"
  prepare_attempt_logs "${shared}" "${attempt}"
  capture_action "${target}" "${shared}" "${cluster}" cleanup \
    "${attempt}" none tools/kubernetes/kind-down.sh --if-present
  [[ "${ACTION_STATUS}" -eq 0 && "$(<"${shared}/cluster")" == absent &&
  "$(<"${shared}/namespace")" == absent ]]
}

prove_same_checkout_kind_up() {
  local target shared cluster active_pid
  prepare_case same-up absent absent
  target="${CASE_TARGET}" shared="${CASE_SHARED}" cluster="${CASE_CLUSTER}"
  prepare_attempt_logs "${shared}" active
  prepare_attempt_logs "${shared}" contender
  start_action "${target}" "${shared}" "${cluster}" active active \
    before-mutation tools/kubernetes/kind-up.sh
  active_pid="${BACKGROUND_PID}"
  wait_for_ready "${shared}" active before-mutation
  register_lease_root "${CASE_LEASE_ROOT}"
  [[ "$(<"${shared}/cluster")" == absent &&
  ! -s "${shared}/logs/active.mutations.log" ]]
  capture_action "${target}" "${shared}" "${cluster}" contender contender \
    none tools/kubernetes/kind-up.sh
  [[ "${ACTION_STATUS}" -eq 75 ]]
  assert_empty_tool_logs "${shared}" contender
  run_host_command grep -Fqx \
    'FAIL  lifecycle     another lifecycle action is active' \
    "${shared}/logs/contender.out"
  record_event "${shared}" controller:active-release
  release_gate "${shared}" active before-mutation
  wait_action "${active_pid}" 0
  [[ "$(<"${shared}/cluster")" == present && -f "${shared}/marker" ]]
  assert_event_order "${shared}/events" controller:active-release \
    active:control:gate-released-before-mutation active:kind:create \
    active:kubectl:ownership-create active:kubectl:ownership-get-1 \
    active:kubectl:nodes-wait active:kubectl:ownership-get-2
  [[ "$(<"${shared}/logs/active.mutations.log")" == $'kind:create\nkubectl:ownership-create' ]]
  cleanup_owned_cluster "${target}" "${shared}" "${cluster}" cleanup
  builtin printf 'PASS  lifecycle-matrix same-checkout kind-up contender=75\n'
}

prove_verify_vs_kind_down() {
  local target shared cluster verify_pid
  prepare_case verify-down present present
  target="${CASE_TARGET}" shared="${CASE_SHARED}" cluster="${CASE_CLUSTER}"
  prepare_attempt_logs "${shared}" verify
  prepare_attempt_logs "${shared}" contender
  prepare_attempt_logs "${shared}" retry
  start_action "${target}" "${shared}" "${cluster}" verify verify \
    doctor-gate tools/kubernetes/verify.sh
  verify_pid="${BACKGROUND_PID}"
  wait_for_ready "${shared}" verify doctor
  register_lease_root "${CASE_LEASE_ROOT}"
  capture_action "${target}" "${shared}" "${cluster}" contender contender \
    none tools/kubernetes/kind-down.sh --if-present
  [[ "${ACTION_STATUS}" -eq 75 ]]
  assert_empty_tool_logs "${shared}" contender
  record_event "${shared}" controller:verify-release
  release_gate "${shared}" verify doctor
  wait_action "${verify_pid}" 0
  record_event "${shared}" controller:verify-returned
  capture_action "${target}" "${shared}" "${cluster}" retry retry \
    none tools/kubernetes/kind-down.sh --if-present
  [[ "${ACTION_STATUS}" -eq 0 && ! -s "${shared}/logs/retry.mutations.log" ]]
  assert_event_order "${shared}/events" controller:verify-release \
    verify:control:gate-released-doctor verify:kind:delete \
    controller:verify-returned retry:kind:get
  [[ "$(<"${shared}/cluster")" == absent ]]
  builtin printf 'PASS  lifecycle-matrix verify/down contender=75 ordered retry\n'
}

prove_pre_mutation_retry() {
  local target shared cluster first_pid
  prepare_case pre-interrupt absent absent
  target="${CASE_TARGET}" shared="${CASE_SHARED}" cluster="${CASE_CLUSTER}"
  prepare_attempt_logs "${shared}" first
  prepare_attempt_logs "${shared}" retry
  start_action "${target}" "${shared}" "${cluster}" first first \
    before-mutation tools/kubernetes/kind-up.sh
  first_pid="${BACKGROUND_PID}"
  wait_for_ready "${shared}" first before-mutation
  register_lease_root "${CASE_LEASE_ROOT}"
  [[ "$(<"${shared}/cluster")" == absent &&
  ! -s "${shared}/logs/first.mutations.log" ]]
  builtin kill -TERM "${first_pid}"
  wait_action "${first_pid}" 143
  capture_action "${target}" "${shared}" "${cluster}" retry retry \
    none tools/kubernetes/kind-up.sh
  [[ "${ACTION_STATUS}" -eq 0 && "$(<"${shared}/cluster")" == present &&
  "$(<"${shared}/marker")" == present ]]
  [[ "$(<"${shared}/logs/retry.mutations.log")" == $'kind:create\nkubectl:ownership-create' ]]
  assert_event_order "${shared}/events" retry:kind:create \
    retry:kubectl:ownership-create retry:kubectl:ownership-get-1 \
    retry:kubectl:nodes-wait retry:kubectl:ownership-get-2
  run_host_command grep -Fqx \
    'WARN  kind-up       interrupted operation preserved without sibling mutation' \
    "${shared}/logs/first.out"
  cleanup_owned_cluster "${target}" "${shared}" "${cluster}" cleanup
  builtin printf 'PASS  lifecycle-matrix pre-mutation TERM retry succeeded\n'
}

prove_post_create_rejection() {
  local target shared cluster first_pid
  prepare_case post-create absent absent
  target="${CASE_TARGET}" shared="${CASE_SHARED}" cluster="${CASE_CLUSTER}"
  prepare_attempt_logs "${shared}" first
  prepare_attempt_logs "${shared}" retry
  start_action "${target}" "${shared}" "${cluster}" first first \
    after-create tools/kubernetes/kind-up.sh
  first_pid="${BACKGROUND_PID}"
  wait_for_ready "${shared}" first after-create
  register_lease_root "${CASE_LEASE_ROOT}"
  [[ "$(<"${shared}/cluster")" == present && ! -e "${shared}/marker" ]]
  run_host_command grep -Fqx kind:create \
    "${shared}/logs/first.mutations.log"
  builtin kill -TERM "${first_pid}"
  wait_action "${first_pid}" 143
  capture_action "${target}" "${shared}" "${cluster}" retry retry \
    none tools/kubernetes/kind-up.sh
  [[ "${ACTION_STATUS}" -eq 1 && "$(<"${shared}/cluster")" == present &&
  ! -e "${shared}/marker" && ! -s "${shared}/logs/retry.mutations.log" ]]
  [[ "$(<"${shared}/logs/retry.docker.log")" == $'target-ensure\ninfo' ]]
  [[ "$(<"${shared}/logs/retry.kind.log")" == $'get\nexport' ]]
  [[ "$(<"${shared}/logs/retry.kubectl.log")" == ownership-get-1 ]]
  run_host_command grep -Fqx \
    'FAIL  ownership     ownership marker is unreadable' \
    "${shared}/logs/retry.out"
  builtin printf 'operator_action=validate and remove unowned fixture cluster %s\n' \
    "${cluster}"
  record_event "${shared}" controller:operator-remove-unowned
  builtin printf 'absent\n' >"${shared}/cluster"
  builtin printf 'absent\n' >"${shared}/namespace"
  run_host_command rm -f -- "${target}/.platform/kubeconfig"
  builtin printf 'PASS  lifecycle-matrix post-create retry fail-closed mutations=0\n'
}

prove_delete_interruption_retry() {
  local target shared cluster first_pid
  prepare_case delete-interrupt present present
  target="${CASE_TARGET}" shared="${CASE_SHARED}" cluster="${CASE_CLUSTER}"
  prepare_attempt_logs "${shared}" first
  prepare_attempt_logs "${shared}" retry
  start_action "${target}" "${shared}" "${cluster}" first first \
    after-delete tools/kubernetes/kind-down.sh --if-present
  first_pid="${BACKGROUND_PID}"
  wait_for_ready "${shared}" first after-delete
  register_lease_root "${CASE_LEASE_ROOT}"
  [[ "$(<"${shared}/cluster")" == absent &&
  "$(<"${shared}/namespace")" == absent && ! -e "${shared}/marker" ]]
  [[ "$(<"${shared}/logs/first.mutations.log")" == kind:delete ]]
  record_event "${shared}" controller:delete-term
  builtin kill -TERM "${first_pid}"
  wait_action "${first_pid}" 143
  capture_action "${target}" "${shared}" "${cluster}" retry retry \
    none tools/kubernetes/kind-down.sh --if-present
  [[ "${ACTION_STATUS}" -eq 0 && "$(<"${shared}/cluster")" == absent &&
  "$(<"${shared}/namespace")" == absent ]]
  [[ ! -s "${shared}/logs/retry.mutations.log" ]]
  run_host_command grep -Fqx \
    'PASS  kind-down     cluster already absent' "${shared}/logs/retry.out"
  assert_event_order "${shared}/events" first:kubectl:ownership-get-1 \
    first:kubectl:ownership-get-2 first:kind:delete \
    first:control:gate-ready-after-delete controller:delete-term retry:kind:get
  builtin printf 'PASS  lifecycle-matrix interrupted delete guarded retry absent\n'
}

assert_final_absence() {
  local shared index pid state
  for ((index = 0; index < ${#PROOF_PIDS[@]}; index++)); do
    pid="${PROOF_PIDS[index]}"
    state="$(linux_process_state "${pid}" "${PROOF_STARTTIMES[index]}")"
    [[ "${state}" == absent || "${state}" == replaced ]]
  done
  for shared in "${CASE_DIRS[@]}"; do
    [[ "$(<"${shared}/cluster")" == absent &&
    "$(<"${shared}/namespace")" == absent ]]
    [[ ! -e "${shared}/marker" && ! -L "${shared}/marker" ]]
    [[ ! -e "${shared%/shared}/.platform/kubeconfig" &&
      ! -L "${shared%/shared}/.platform/kubeconfig" ]]
  done
}

finalize_fixture_cleanup() {
  local root
  assert_final_absence
  for root in "${LEASE_ROOTS[@]}"; do
    cleanup_lease_root "${root}"
    register_lease_root "${root}"
  done
  cleanup_work_directory
  [[ ! -e "${WORK_DIR}" && ! -L "${WORK_DIR}" ]]
  builtin printf \
    'PASS  lifecycle-matrix cleanup=success processes=0 clusters=0 namespaces=0 lease_roots_lock_only=%s\n' \
    "${#LEASE_ROOTS[@]}"
}

main() {
  trap cleanup EXIT
  initialize_work_guard
  prove_same_checkout_kind_up
  prove_verify_vs_kind_down
  prove_pre_mutation_retry
  prove_post_create_rejection
  prove_delete_interruption_retry
  finalize_fixture_cleanup
}

main "$@"
