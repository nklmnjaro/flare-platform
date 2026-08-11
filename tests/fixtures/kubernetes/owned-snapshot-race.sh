#!/bin/bash -p
set -euo pipefail

SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || SOURCE_DIR=.
REPOSITORY_ROOT="$(builtin cd -P -- "${SOURCE_DIR}/../../.." && builtin pwd -P)"
builtin source "${REPOSITORY_ROOT}/tools/common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
BASH_PATH="$(host_command_path bash)"
TIMEOUT_PATH="$(host_command_path timeout)"
WORK_DIR="$(run_host_command mktemp -d \
  '/tmp/flare-platform-concurrency-red.XXXXXXXX')"
readonly REPOSITORY_ROOT BASH_PATH TIMEOUT_PATH WORK_DIR
UP_PID=''

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ -n "${UP_PID}" ]]; then
    if builtin kill -0 "${UP_PID}" 2>/dev/null; then
      builtin kill -TERM "${UP_PID}" 2>/dev/null || :
      builtin kill -KILL "${UP_PID}" 2>/dev/null || :
    fi
    builtin wait "${UP_PID}" 2>/dev/null || :
  fi
  case "${WORK_DIR}" in
    /tmp/flare-platform-concurrency-red.*)
      run_host_command rm -rf -- "${WORK_DIR}" || status=1
      ;;
    *) status=1 ;;
  esac
  exit "${status}"
}

fifo_read() {
  local fifo="$1"
  # The quoted program expands only in the bounded child.
  # shellcheck disable=SC2016
  "${TIMEOUT_PATH}" --signal=TERM --kill-after=1s 10s \
    "${BASH_PATH}" -p -c \
    'IFS= read -r value <"$1"; printf "%s\n" "${value}"' _ "${fifo}"
}

fifo_write() {
  local fifo="$1" value="$2"
  # The quoted program expands only in the bounded child.
  # shellcheck disable=SC2016
  "${TIMEOUT_PATH}" --signal=TERM --kill-after=1s 10s \
    "${BASH_PATH}" -p -c 'printf "%s\n" "$2" >"$1"' _ \
    "${fifo}" "${value}"
}

write_fixture_env() {
  local target="$1"
  run_host_command cat >"${target}/tools/common/env.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
source_dir="${BASH_SOURCE[0]%/*}"
[[ "${source_dir}" != "${BASH_SOURCE[0]}" ]] || source_dir=.
PLATFORM_ROOT="$(builtin cd -P -- "${source_dir}/../.." && builtin pwd -P)"
export PLATFORM_ROOT PLATFORM_STATE_DIR="${PLATFORM_ROOT}/.platform"
export KUBECONFIG="${PLATFORM_ROOT}/.platform/kubeconfig"
export PLATFORM_CLUSTER_NAME=flare-platform-dev
export PLATFORM_CONTEXT=kind-flare-platform-dev
export PLATFORM_NAMESPACE=flare-platform-reference
run_host_command() { command "$@"; }
host_command_path() { builtin type -P "$1"; }
ensure_state_directory() { command mkdir -p -- "${PLATFORM_STATE_DIR}"; }
FIXTURE
  run_host_command cat >"${target}/tools/common/tooling.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
require_tool() { :; }
FIXTURE
}

write_fixture_runtime() {
  local target="$1"
  run_host_command cat >"${target}/tools/kubernetes/runtime.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail

fixture_event() {
  printf '%s:%s\n' "${FIXTURE_ROLE:?}" "$1" >>"${FIXTURE_SHARED_DIR:?}/events"
}

fixture_snapshot_count() {
  local path="${FIXTURE_SHARED_DIR:?}/${FIXTURE_ROLE:?}.snapshot-count" count=0
  [[ ! -s "${path}" ]] || IFS= read -r count <"${path}"
  ((count += 1))
  printf '%s\n' "${count}" >"${path}"
  printf '%s\n' "${count}"
}

fixture_snapshot() {
  local count snapshot sentinel=$'\036'
  [[ "$(<"${FIXTURE_SHARED_DIR:?}/cluster")" == present ]]
  count="$(fixture_snapshot_count)"
  snapshot="$({
    printf 'api_version=v1\nkind=ConfigMap\nnamespace=kube-system\n'
    printf 'name=flare-platform-ownership\nuid=fixture-uid\nresource_version=1\n'
    printf 'data_count=4\nbinary_data_count=0\ncontract_version=checkout-v1\n'
    printf 'owner=flare-platform-infra\ncluster_name=flare-platform-dev\n'
    printf 'checkout_id=%s\n%s' "${FIXTURE_CHECKOUT_ID:?}" "${sentinel}"
  })"
  [[ "${snapshot: -1}" == "${sentinel}" ]]
  snapshot="${snapshot::-1}"
  fixture_event "snapshot-captured-${count}"
  if [[ "${FIXTURE_ROLE}" == up && "${count}" == 2 ]]; then
    # The quoted program expands only in the bounded child.
    # shellcheck disable=SC2016
    "${FIXTURE_TIMEOUT_PATH:?}" --signal=TERM --kill-after=1s 10s \
      "${FIXTURE_BASH_PATH:?}" -p -c \
      'printf "ready\n" >"$1"
       IFS= read -r release <"$2"
       [[ "${release}" == release ]]' _ \
      "${FIXTURE_SHARED_DIR}/up.snapshot-ready" \
      "${FIXTURE_SHARED_DIR}/up.snapshot-release"
  fi
  fixture_event "snapshot-returned-${count}"
  printf '%s' "${snapshot}"
}

docker_target_ensure() { :; }
docker_command() { :; }

prepare_kubeconfig_output() {
  command mkdir -p -- "${PLATFORM_STATE_DIR}"
  command rm -f -- "${KUBECONFIG}"
}

kind_command() {
  local duration="$1" arguments
  shift
  arguments="$*"
  case "${arguments}" in
    'get clusters')
      fixture_event kind-read
      [[ "$(<"${FIXTURE_SHARED_DIR}/cluster")" != present ]] ||
        printf '%s\n' "${PLATFORM_CLUSTER_NAME}"
      ;;
    'export kubeconfig '*)
      fixture_event kind-export
      while (($#)); do
        if [[ "$1" == --kubeconfig ]]; then
          shift
          printf 'fixture\n' >"$1"
          return 0
        fi
        shift
      done
      return 2
      ;;
    'delete cluster '*)
      fixture_event kind-delete
      printf 'absent\n' >"${FIXTURE_SHARED_DIR}/cluster"
      ;;
    *) printf 'unexpected kind command: %s %s\n' "${duration}" "${arguments}" >&2; return 2 ;;
  esac
}

kubectl_command() {
  local duration="$1" arguments
  shift
  arguments="$*"
  case "${arguments}" in
    *'get configmap flare-platform-ownership'*) fixture_snapshot ;;
    'wait '*) fixture_event nodes-ready ;;
    *) printf 'unexpected kubectl command: %s %s\n' "${duration}" "${arguments}" >&2; return 2 ;;
  esac
}

cluster_presence() {
  local clusters
  clusters="$(kind_command 20s get clusters)" || return
  if [[ "${clusters}" == "${PLATFORM_CLUSTER_NAME}" ]]; then
    printf 'present\n'
  elif [[ -z "${clusters}" ]]; then
    printf 'absent\n'
  else
    return 1
  fi
}
FIXTURE
}

write_guard_context() {
  local target="$1"
  run_host_command cat >"${target}/tools/kubernetes/guard-context.sh" <<'FIXTURE'
#!/bin/bash -p
set -euo pipefail
[[ -f "${KUBECONFIG:?}" && ! -L "${KUBECONFIG}" ]]
FIXTURE
}

write_noop_lease_adapter() {
  local target="$1"
  run_host_command cat >"${target}/tools/common/lifecycle-lease.sh" <<'FIXTURE'
#!/bin/bash -p
LIFECYCLE_LEASE_INTERRUPTED=false
lifecycle_lease_acquire() { :; }
lifecycle_lease_assert() { :; }
lifecycle_lease_release() { :; }
lifecycle_lease_install_interrupt_traps() { :; }
lifecycle_lease_clear_interrupt_traps() { :; }
FIXTURE
}

prepare_fixture() {
  local target="$1" lease_mode="$2" script
  run_host_command mkdir -p -- \
    "${target}/tools/common" "${target}/tools/kubernetes" \
    "${target}/.platform" "${target}/shared"
  for script in kind-up kind-down ownership; do
    run_host_command cp -- "${REPOSITORY_ROOT}/tools/kubernetes/${script}.sh" \
      "${target}/tools/kubernetes/${script}.sh"
  done
  run_host_command cp -- "${REPOSITORY_ROOT}/tools/common/process-state.sh" \
    "${target}/tools/common/process-state.sh"
  run_host_command cp -- "${REPOSITORY_ROOT}/tools/common/checkout-identity.sh" \
    "${target}/tools/common/checkout-identity.sh"
  run_host_command cp -- "${REPOSITORY_ROOT}/tools/common/lifecycle-lease.sh" \
    "${target}/tools/common/lifecycle-lease.sh"
  [[ "${lease_mode}" != no-lease ]] || write_noop_lease_adapter "${target}"
  write_fixture_env "${target}"
  write_fixture_runtime "${target}"
  write_guard_context "${target}"
  run_host_command chmod 0755 "${target}/tools/kubernetes/"*.sh
  printf 'present\n' >"${target}/shared/cluster"
  run_host_command mkfifo -- "${target}/shared/up.snapshot-ready" \
    "${target}/shared/up.snapshot-release"
}

checkout_id() {
  local target="$1"
  (
    builtin cd -- "${target}"
    builtin source tools/kubernetes/ownership.sh
    platform_checkout_identity
  )
}

assert_green_order() {
  local events="$1" capture delete returned
  capture="$(run_host_command grep -nFx \
    'up:snapshot-captured-2' "${events}")"
  delete="$(run_host_command grep -nFx 'down:kind-delete' "${events}")"
  returned="$(run_host_command grep -nFx \
    'up:snapshot-returned-2' "${events}")"
  capture="${capture%%:*}"
  delete="${delete%%:*}"
  returned="${returned%%:*}"
  ((capture < returned && returned < delete))
}

assert_red_order() {
  local events="$1" capture delete returned
  capture="$(run_host_command grep -nFx \
    'up:snapshot-captured-2' "${events}")"
  delete="$(run_host_command grep -nFx 'down:kind-delete' "${events}")"
  returned="$(run_host_command grep -nFx \
    'up:snapshot-returned-2' "${events}")"
  capture="${capture%%:*}"
  delete="${delete%%:*}"
  returned="${returned%%:*}"
  ((capture < delete && delete < returned))
}

prepare_role_environment() {
  local target="$1"
  export FIXTURE_SHARED_DIR="${target}/shared"
  export FIXTURE_BASH_PATH="${BASH_PATH}"
  export FIXTURE_TIMEOUT_PATH="${TIMEOUT_PATH}"
  FIXTURE_CHECKOUT_ID="$(checkout_id "${target}")"
  export FIXTURE_CHECKOUT_ID
}

prove_prelease_race() {
  local target="${WORK_DIR}/red-checkout" output up_pid ready status down_status=0
  prepare_fixture "${target}" no-lease
  output="${target}/up.out"
  prepare_role_environment "${target}"

  FIXTURE_ROLE=up "${target}/tools/kubernetes/kind-up.sh" \
    >"${output}" 2>&1 &
  up_pid=$!
  UP_PID="${up_pid}"
  ready="$(fifo_read "${target}/shared/up.snapshot-ready")"
  [[ "${ready}" == ready ]]

  set +e
  FIXTURE_ROLE=down "${target}/tools/kubernetes/kind-down.sh" \
    --if-present >"${target}/down.out" 2>&1
  down_status=$?
  set -e
  [[ "${down_status}" -eq 0 && "$(<"${target}/shared/cluster")" == absent ]]
  fifo_write "${target}/shared/up.snapshot-release" release
  set +e
  wait "${up_pid}"
  status=$?
  set -e
  UP_PID=''

  [[ "${status}" == 0 ]]
  run_host_command grep -Fqx \
    'PASS  kind-up       flare-platform-dev' "${output}"
  assert_red_order "${target}/shared/events"
  printf 'PASS  concurrency-red stale owned snapshot crossed cluster deletion\n'
  printf 'order=up:snapshot-captured-2 > down:kind-delete > up:snapshot-returned-2\n'
  printf 'kind_up_status=%s final_cluster=%s\n' \
    "${status}" "$(<"${target}/shared/cluster")"
}

prove_leased_order() {
  local target="${WORK_DIR}/green-checkout" output up_pid ready status down_status=0
  prepare_fixture "${target}" production
  output="${target}/up.out"
  prepare_role_environment "${target}"

  FIXTURE_ROLE=up "${target}/tools/kubernetes/kind-up.sh" \
    >"${output}" 2>&1 &
  up_pid=$!
  UP_PID="${up_pid}"
  ready="$(fifo_read "${target}/shared/up.snapshot-ready")"
  [[ "${ready}" == ready ]]

  set +e
  FIXTURE_ROLE=down "${target}/tools/kubernetes/kind-down.sh" \
    --if-present >"${target}/down-busy.out" 2>&1
  down_status=$?
  set -e
  [[ "${down_status}" -eq 75 ]]
  run_host_command grep -Fqx \
    'FAIL  lifecycle     another lifecycle action is active' \
    "${target}/down-busy.out"
  [[ "$(<"${target}/shared/cluster")" == present ]]
  if run_host_command grep -Fq 'down:kind-delete' "${target}/shared/events"; then
    printf 'FAIL  concurrency   cluster deletion crossed the active lease\n' >&2
    return 1
  fi
  fifo_write "${target}/shared/up.snapshot-release" release
  set +e
  wait "${up_pid}"
  status=$?
  set -e
  UP_PID=''

  [[ "${status}" == 0 ]]
  run_host_command grep -Fqx \
    'PASS  kind-up       flare-platform-dev' "${output}"
  FIXTURE_ROLE=down "${target}/tools/kubernetes/kind-down.sh" \
    --if-present >"${target}/down.out" 2>&1
  [[ "$(<"${target}/shared/cluster")" == absent ]]
  assert_green_order "${target}/shared/events"
  printf 'PASS  concurrency-green active lifecycle lease serialized deletion\n'
  printf 'order=up:snapshot-captured-2 > up:snapshot-returned-2 > down:kind-delete\n'
  printf 'busy_status=%s kind_up_status=%s final_cluster=%s\n' \
    "${down_status}" "${status}" "$(<"${target}/shared/cluster")"
}

main() {
  trap cleanup EXIT
  prove_prelease_race
  prove_leased_order
}

main "$@"
