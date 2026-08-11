#!/bin/bash -p
set -euo pipefail

PROVE_SAFETY_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_SAFETY_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_SAFETY_SOURCE_DIR=.
builtin source "${PROVE_SAFETY_SOURCE_DIR}/../common/env.sh"
unset PROVE_SAFETY_SOURCE_DIR

WORK_DIR=""
DOCKER_TEST_CONTRACT="flare-platform-docker-target-fixture-v1"
DOCKER_TEST_TOKEN="flare-platform-runtime-proof-owner-v1"
RUNTIME_TEST_CONTRACT="flare-platform-runtime-fixture-v1"
RUNTIME_TEST_TOKEN="flare-platform-managed-proof-owner-v1"
EXPECTED_CONTEXT_INSPECT='context inspect --format {{.Name}}|'
EXPECTED_CONTEXT_INSPECT+='{{(index .Endpoints "docker").Host}}|'
EXPECTED_CONTEXT_INSPECT+='{{(index .Endpoints "docker").SkipTLSVerify}} fixture-local'

# Fixture controls are owned by individual proof invocations, never callers.
unset PLATFORM_DOCKER_TEST_CONTRACT PLATFORM_DOCKER_TEST_ROOT
unset PLATFORM_DOCKER_TEST_TOKEN PLATFORM_RUNTIME_TEST_CONTRACT
unset PLATFORM_RUNTIME_TEST_ROOT PLATFORM_RUNTIME_TEST_TOKEN
unset DOCKER_PROBE_ALLOW_LOCAL DOCKER_PROBE_CALLER_PATH
unset DOCKER_PROBE_DISCOVERY_LOG DOCKER_PROBE_LOCAL_SOCKET
unset DOCKER_PROBE_MUTATION_MARKER DOCKER_PROBE_PRINT_TARGET
unset ADAPTER_PROBE_MODE FIXTURE_ASSERT_DOCKER_LOOKUP
unset FIXTURE_CLUSTER_STATE FIXTURE_CLUSTER_STATE_FILE
unset FIXTURE_DELETED_MARKER FIXTURE_DOCKER_ENV_LOG
unset FIXTURE_KIND_CREATE_STATUS FIXTURE_KIND_LOG
unset FIXTURE_NAMESPACE_QUERY_FAIL FIXTURE_NAMESPACE_STATE
unset FIXTURE_NODE_WAIT_STATUS

copy_runtime_files() {
  local target="$1"
  local script
  run_host_command mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/kubernetes" "${target}/.platform/bootstrap" \
    "${target}/.platform/aqua/bin" "${target}/.platform/aqua/test-fixtures" \
    "${target}/.platform-test/docker-target"
  run_host_command cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/env.sh" \
    "${target}/tools/common/env.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${target}/tools/common/host-commands.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/state.sh" \
    "${target}/tools/common/state.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/process-state.sh" \
    "${target}/tools/common/process-state.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/evidence-capture.sh" \
    "${target}/tools/common/evidence-capture.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/tooling.sh" \
    "${target}/tools/common/tooling-production.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/managed-tool-fixture.sh" \
    "${target}/tools/common/tooling.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/docker-target.sh" \
    "${target}/tools/common/docker-target-production.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/docker-target-fixture.sh" \
    "${target}/tools/common/docker-target.sh"
  for script in runtime guard-context guard-ownership kind-up kind-down delete-namespace diagnostics; do
    run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/${script}.sh" \
      "${target}/tools/kubernetes/${script}.sh"
  done
  printf '%s\n' "${DOCKER_TEST_TOKEN}" \
    >"${target}/.platform-test/docker-target/.docker-target-owner"
  printf '%s\n' "${RUNTIME_TEST_TOKEN}" \
    >"${target}/.platform/aqua/test-fixtures/.runtime-fixture-owner"
  write_docker_mock "${target}"
}

run_runtime_fixture() (
  local target="$1"
  shift
  builtin cd "${target}" || return
  export PLATFORM_DOCKER_TEST_CONTRACT="${DOCKER_TEST_CONTRACT}"
  export PLATFORM_DOCKER_TEST_ROOT="${target}/.platform-test/docker-target"
  export PLATFORM_DOCKER_TEST_TOKEN="${DOCKER_TEST_TOKEN}"
  export PLATFORM_RUNTIME_TEST_CONTRACT="${RUNTIME_TEST_CONTRACT}"
  export PLATFORM_RUNTIME_TEST_ROOT="${target}/.platform/aqua/test-fixtures"
  export PLATFORM_RUNTIME_TEST_TOKEN="${RUNTIME_TEST_TOKEN}"
  "$@"
)

publish_managed_mock() {
  local target="$1" command_name="$2"
  run_host_command chmod 0755 \
    "${target}/.platform/aqua/test-fixtures/${command_name}"
}

write_kind_mock() {
  local target="$1"
  run_host_command cat >"${target}/.platform/aqua/test-fixtures/kind" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
[[ "${HOME:?}" == /nonexistent ]]
[[ "${DOCKER_CONFIG:?}" == /tmp/flare-platform-docker-child.*/docker ]]
[[ "${BUILDX_CONFIG:?}" == /tmp/flare-platform-docker-child.*/buildx ]]
[[ -d "${DOCKER_CONFIG}" && -d "${BUILDX_CONFIG}" ]]
for control in KIND_EXPERIMENTAL_PROVIDER KIND_EXPERIMENTAL_DOCKER_NETWORK \
  KIND_EXPERIMENTAL_PODMAN_NETWORK KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER \
  KIND_CLUSTER_NAME KIND_DNS_SEARCH; do
  [[ ! -v "${control}" ]]
done
[[ -z "${FIXTURE_KIND_LOG:-}" ]] || printf '%s\n' "$*" >>"${FIXTURE_KIND_LOG}"
if [[ -n "${FIXTURE_DOCKER_ENV_LOG:-}" ]]; then
  printf 'kind|%s|%s|%s|%s|%s|%s\n' \
    "${DOCKER_HOST-<unset>}" "${DOCKER_CONTEXT-<unset>}" \
    "${BUILDX_BUILDER-<unset>}" "${DOCKER_BUILDKIT-<unset>}" \
    "${DOCKER_TARGET_DOCKER_PATH-<unset>}" \
    "${DOCKER_TARGET_FINGERPRINT-<unset>}" >>"${FIXTURE_DOCKER_ENV_LOG}"
fi
if [[ "${FIXTURE_ASSERT_DOCKER_LOOKUP:-false}" == true ]]; then
  docker_lookup="$(builtin type -P docker)"
  [[ "${docker_lookup}" == "${DOCKER_TARGET_DOCKER_PATH:?}" ]]
  printf 'kind-docker-lookup|%s\n' "${docker_lookup}" \
    >>"${FIXTURE_DOCKER_ENV_LOG:?}"
  docker version --format \
    '{{.Client.Version}}|{{.Server.Version}}|{{.Server.Os}}|{{.Server.Arch}}' \
    >/dev/null
fi
cluster_state() {
  if [[ -n "${FIXTURE_CLUSTER_STATE_FILE:-}" ]]; then
    IFS= read -r fixture_cluster_state <"${FIXTURE_CLUSTER_STATE_FILE}"
    printf '%s\n' "${fixture_cluster_state}"
  else
    printf '%s\n' "${FIXTURE_CLUSTER_STATE:-present}"
  fi
}
case "${1:-} ${2:-}" in
  "get clusters")
    if [[ "$(cluster_state)" == present ]]; then
      printf 'flare-platform-dev\n'
    fi
    ;;
  "export kubeconfig")
    while (($#)); do
      if [[ "$1" == --kubeconfig ]]; then
        shift
        printf 'fixture\n' >"$1"
        exit 0
      fi
      shift
    done
    exit 2
    ;;
  "create cluster")
    while (($#)); do
      if [[ "$1" == --kubeconfig ]]; then
        shift
        printf 'fixture\n' >"$1"
      fi
      shift
    done
    if [[ -n "${FIXTURE_CLUSTER_STATE_FILE:-}" ]]; then
      printf 'present\n' >"${FIXTURE_CLUSTER_STATE_FILE}"
    fi
    exit "${FIXTURE_KIND_CREATE_STATUS:-0}"
    ;;
  "delete cluster")
    : >"${FIXTURE_DELETED_MARKER:?}"
    if [[ -n "${FIXTURE_CLUSTER_STATE_FILE:-}" ]]; then
      printf 'absent\n' >"${FIXTURE_CLUSTER_STATE_FILE}"
    fi
    ;;
  *) exit 2 ;;
esac
MOCK
  publish_managed_mock "${target}" kind
}

write_docker_mock() {
  local target="$1"
  run_host_command cat >"${target}/.platform-test/docker-target/docker" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
[[ "${HOME:?}" == /nonexistent ]]
[[ "${DOCKER_CONFIG:?}" == /tmp/flare-platform-docker-child.*/docker ]]
[[ "${BUILDX_CONFIG:?}" == /tmp/flare-platform-docker-child.*/buildx ]]
[[ -d "${DOCKER_CONFIG}" && -d "${BUILDX_CONFIG}" ]]
if [[ -n "${FIXTURE_DOCKER_ENV_LOG:-}" ]]; then
  printf 'docker|%s|%s|%s|%s|%s|%s\n' \
    "${DOCKER_HOST-<unset>}" "${DOCKER_CONTEXT-<unset>}" \
    "${BUILDX_BUILDER-<unset>}" "${DOCKER_BUILDKIT-<unset>}" \
    "${DOCKER_TARGET_DOCKER_PATH-<unset>}" \
    "${DOCKER_TARGET_FINGERPRINT-<unset>}" >>"${FIXTURE_DOCKER_ENV_LOG}"
fi
[[ "${1:-}" == info ]] || exit 2
MOCK
  run_host_command chmod +x "${target}/.platform-test/docker-target/docker"
}

write_production_boundary_docker_mock() {
  local target="$1"
  run_host_command cat >"${target}" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
case "${1:-} ${2:-}" in
  "context inspect")
    printf '%s\n' "$*" >>"${DOCKER_PROBE_DISCOVERY_LOG:?}"
    context="${!#}"
    if [[ "${DOCKER_PROBE_ALLOW_LOCAL:-false}" == true ]]; then
      if [[ "${DOCKER_PROBE_MALFORMED_CONTEXT:-false}" == true ]]; then
        printf '%s|unix://%s|false||\n' \
          "${context}" "${DOCKER_PROBE_LOCAL_SOCKET:?}"
      else
        printf '%s|unix://%s|false\n' \
          "${context}" "${DOCKER_PROBE_LOCAL_SOCKET:?}"
      fi
    else
      printf '%s|tcp://127.0.0.1:2375|false\n' "${context}"
    fi
    ;;
  "context show")
    printf '%s\n' "$*" >>"${DOCKER_PROBE_DISCOVERY_LOG:?}"
    printf 'remote\n'
    ;;
  "version --format")
    [[ "${DOCKER_PROBE_ALLOW_LOCAL:-false}" == true ]] || exit 97
    [[ "${HOME:?}" == /nonexistent ]]
    [[ "${DOCKER_CONFIG:?}" == /tmp/flare-platform-docker-child.*/docker ]]
    [[ "${BUILDX_CONFIG:?}" == /tmp/flare-platform-docker-child.*/buildx ]]
    printf '%s\n' "$*" >>"${DOCKER_PROBE_DISCOVERY_LOG:?}"
    if [[ "${DOCKER_PROBE_MALFORMED_IDENTITY:-false}" == true ]]; then
      printf '29.7.2|29.7.2|linux|amd64||\n'
    else
      printf '29.7.2|29.7.2|linux|amd64\n'
    fi
    ;;
  *)
    printf 'executed:%s\n' "$*" >"${DOCKER_PROBE_MUTATION_MARKER:?}"
    exit 97
    ;;
esac
MOCK
  run_host_command chmod 0755 "${target}"
}

prepare_production_docker_boundary_fixture() {
  local target="$1" host_bin="${WORK_DIR}/host-bin"
  copy_runtime_files "${target}"
  run_host_command cp "${target}/tools/common/docker-target-production.sh" \
    "${target}/tools/common/docker-target.sh"
  run_host_command mkdir -p "${host_bin}"
  write_production_boundary_docker_mock "${host_bin}/docker"
}

run_production_docker_probe() {
  local target="$1" output="$2" discovery_log="$3" mutation_marker="$4"
  local bash_path caller_path status
  shift 4
  bash_path="$(host_command_path bash)" || return
  caller_path="${DOCKER_PROBE_CALLER_PATH:-${WORK_DIR}/host-bin:${PLATFORM_CALLER_HOST_PATH}}"
  set +e
  # Child script expands only variables passed into its environment.
  # shellcheck disable=SC2016
  run_host_command env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_CONFIG \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    -u DOCKER_BUILDKIT -u BUILDX_BUILDER -u BUILDKIT_HOST -u BUILDX_CONFIG \
    -u DOCKER_API_VERSION -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u BUILDX_NO_DEFAULT_LOAD -u EXPERIMENTAL_BUILDKIT_SOURCE_POLICY \
    -u DOCKER_TARGET_ADMITTED -u DOCKER_TARGET_DOCKER_PATH \
    -u DOCKER_TARGET_ENDPOINT -u DOCKER_TARGET_SOCKET_PATH \
    -u DOCKER_TARGET_SOCKET_DEVICE -u DOCKER_TARGET_SOCKET_INODE \
    -u DOCKER_TARGET_FINGERPRINT -u DOCKER_TARGET_DISCOVERY \
    -u DOCKER_TARGET_EXPECTED_FINGERPRINT \
    -u DOCKER_PROBE_MALFORMED_CONTEXT -u DOCKER_PROBE_MALFORMED_IDENTITY \
    PATH="${caller_path}" \
    DOCKER_PROBE_DISCOVERY_LOG="${discovery_log}" \
    DOCKER_PROBE_MUTATION_MARKER="${mutation_marker}" "$@" \
    "${bash_path}" -p -c '
set -euo pipefail
root=$1
builtin source "${root}/tools/common/env.sh"
builtin source "${root}/tools/common/docker-target.sh"
docker_target_ensure
if [[ "${DOCKER_PROBE_PRINT_TARGET:-false}" == true ]]; then
  printf "TARGET|%s|%s|%s|%s|%s|%s\\n" \
    "${DOCKER_TARGET_DOCKER_PATH}" "${DOCKER_TARGET_ENDPOINT}" \
    "${DOCKER_TARGET_SOCKET_DEVICE}" "${DOCKER_TARGET_SOCKET_INODE}" \
    "${DOCKER_TARGET_FINGERPRINT}" "${DOCKER_TARGET_DISCOVERY}"
fi
' docker-boundary "${target}" >"${output}" 2>&1
  status=$?
  set -e
  printf '%s\n' "${status}"
}

require_boundary_failure() {
  local label="$1" status="$2" expected_status="$3" reason="$4" output="$5"
  if [[ "${status}" -ne "${expected_status}" ]] ||
    ! run_host_command grep -Fq -- "${reason}" "${output}"; then
    run_host_command sed -n '1,12p' "${output}" >&2 || true
    printf 'FAIL  docker-red     %s missed status=%s reason=%s\n' \
      "${label}" "${expected_status}" "${reason}" >&2
    return 1
  fi
}

select_available_local_docker_socket() {
  local candidate
  local -a candidates=(/run/docker.sock /var/run/docker.sock)
  [[ -z "${XDG_RUNTIME_DIR:-}" ]] ||
    candidates+=("${XDG_RUNTIME_DIR}/docker.sock")
  [[ -z "${HOME:-}" ]] || candidates+=(
    "${HOME}/.docker/run/docker.sock"
    "${HOME}/.docker/desktop/docker.sock"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -S "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

prove_production_docker_boundary_reds() {
  local target="${WORK_DIR}/docker-production-boundary"
  local discovery_log="${target}/discovery.log" marker="${target}/mutation.marker"
  local output status actual_docker
  prepare_production_docker_boundary_fixture "${target}"

  write_production_boundary_docker_mock "${target}/.platform/bootstrap/docker"
  output="${target}/project-docker.out"
  status="$(DOCKER_PROBE_CALLER_PATH="${target}/.platform/bootstrap:${PLATFORM_CALLER_HOST_PATH}" \
    run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}")"
  require_boundary_failure project-docker "${status}" 69 \
    'lookup location is inside repository or generated command state' "${output}"
  [[ ! -e "${discovery_log}" && ! -e "${marker}" ]]

  actual_docker="${WORK_DIR}/external-docker/docker-real"
  run_host_command mkdir -p -- "${actual_docker%/*}"
  write_production_boundary_docker_mock "${actual_docker}"
  run_host_command rm -f -- "${WORK_DIR}/host-bin/docker"
  run_host_command ln -s -- "${actual_docker}" "${WORK_DIR}/host-bin/docker"
  output="${target}/symlink-docker.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}")"
  require_boundary_failure symlink-docker "${status}" 77 \
    'Docker PATH lookup is not a canonical direct executable' "${output}"
  [[ ! -e "${discovery_log}" && ! -e "${marker}" ]]
  run_host_command rm -f -- "${WORK_DIR}/host-bin/docker"
  run_host_command cp -pT -- "${actual_docker}" "${WORK_DIR}/host-bin/docker"

  output="${target}/remote-host.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}" DOCKER_HOST=tcp://127.0.0.1:2375)"
  require_boundary_failure remote-host "${status}" 77 \
    'remote or non-Unix Docker endpoint is unsupported' "${output}"
  [[ ! -e "${discovery_log}" && ! -e "${marker}" ]]

  output="${target}/remote-context.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}" DOCKER_CONTEXT=remote)"
  require_boundary_failure remote-context "${status}" 77 \
    'remote or non-Unix Docker endpoint is unsupported' "${output}"
  [[ ! -e "${marker}" ]]
  [[ "$(run_host_command wc -l <"${discovery_log}")" -eq 1 ]]
  run_host_command grep -Fq -- 'context inspect --format' "${discovery_log}"

  run_host_command rm -f -- "${discovery_log}" "${marker}"
  output="${target}/buildx-builder.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}" BUILDX_BUILDER=remote-builder)"
  require_boundary_failure buildx-builder "${status}" 77 \
    'inherited BUILDX_BUILDER is unsupported for local verification' "${output}"
  [[ ! -e "${discovery_log}" && ! -e "${marker}" ]]

  output="${target}/buildkit-host.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}" BUILDKIT_HOST=tcp://127.0.0.1:1234)"
  require_boundary_failure buildkit-host "${status}" 77 \
    'inherited BUILDKIT_HOST is unsupported for local verification' "${output}"
  [[ ! -e "${discovery_log}" && ! -e "${marker}" ]]
  printf 'PASS  docker-red     remote host/context and builder controls fail before mutation\n'
}

prove_production_docker_response_grammar() {
  local target="${WORK_DIR}/docker-response-grammar"
  local log="${target}/discovery.log" marker="${target}/mutation.marker"
  local output status socket
  prepare_production_docker_boundary_fixture "${target}"
  socket="$(select_available_local_docker_socket)" || return
  output="${target}/context.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${log}" "${marker}" DOCKER_CONTEXT=fixture-local \
    DOCKER_PROBE_ALLOW_LOCAL=true DOCKER_PROBE_LOCAL_SOCKET="${socket}" \
    DOCKER_PROBE_MALFORMED_CONTEXT=true)"
  require_boundary_failure malformed-context "${status}" 77 \
    'effective Docker context response is malformed' "${output}"
  [[ ! -e "${marker}" ]]
  run_host_command rm -f -- "${log}"
  output="${target}/identity.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${log}" "${marker}" DOCKER_HOST="unix://${socket}" \
    DOCKER_PROBE_ALLOW_LOCAL=true DOCKER_PROBE_MALFORMED_IDENTITY=true)"
  require_boundary_failure malformed-identity "${status}" 77 \
    'local Docker daemon identity is malformed' "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  docker-red     context and identity reject trailing fields\n'
}

prove_docker_plugin_discovery_is_sealed() {
  local target="${WORK_DIR}/docker-plugin-seal" home plugin marker output
  local docker_path bash_path status=0 leftovers child_program
  home="${target}/home"
  plugin="${home}/.docker/cli-plugins/docker-buildx"
  marker="${target}/ambient-plugin.marker"
  output="${target}/sealed.out"
  run_host_command mkdir -p -- "${plugin%/*}"
  run_host_command cat >"${plugin}" <<'PLUGIN'
#!/bin/bash -p
if [[ "${1:-}" == docker-cli-plugin-metadata ]]; then
  builtin printf '%s\n' \
    '{"SchemaVersion":"0.1.0","Vendor":"fixture","Version":"0.0.1","ShortDescription":"fixture"}'
  exit 0
fi
builtin printf 'executed:%s\n' "$*" >"${AMBIENT_PLUGIN_MARKER:?}"
exit 96
PLUGIN
  run_host_command chmod 0755 -- "${plugin}"
  docker_path="$(host_command_path docker)" || return
  bash_path="$(host_command_path bash)" || return
  if run_host_command env -u DOCKER_CONFIG -u BUILDX_CONFIG \
    HOME="${home}" AMBIENT_PLUGIN_MARKER="${marker}" \
    "${docker_path}" build --builder default --help >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq 96 && -f "${marker}" ]]
  run_host_command rm -f -- "${marker}"
  status=0
  # The child expands only the explicitly supplied root and Docker path.
  # shellcheck disable=SC2016
  child_program='root=$1; docker_path=$2; '
  # shellcheck disable=SC2016
  child_program+='builtin source "${root}/tools/common/env.sh"; '
  # shellcheck disable=SC2016
  child_program+='builtin source "${root}/tools/common/docker-target.sh"; '
  child_program+='DOCKER_TARGET_ENDPOINT=unix:///run/docker.sock; '
  # shellcheck disable=SC2016
  child_program+='docker_target_run_child "${docker_path}" build '
  child_program+='--builder default --help'
  if run_host_command env HOME="${home}" AMBIENT_PLUGIN_MARKER="${marker}" \
    "${bash_path}" -p -c "${child_program}" \
    plugin-seal "${PLATFORM_ROOT}" "${docker_path}" >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq 0 && ! -e "${marker}" && ! -L "${marker}" ]]
  leftovers="$(run_host_command find /tmp -maxdepth 1 \
    -name 'flare-platform-docker-child.*' -print -quit)"
  [[ -z "${leftovers}" ]]
  printf 'PASS  docker-red     ambient buildx plugin bypassed by owned child state\n'
}

prove_parent_target_drift() {
  local target="$1" discovery_log="$2" marker="$3" socket="$4"
  local output="${target}/parent-drift.out" status
  run_host_command rm -f -- "${discovery_log}" "${marker}"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}" \
    DOCKER_HOST="unix://${socket}" DOCKER_PROBE_ALLOW_LOCAL=true \
    DOCKER_TARGET_EXPECTED_FINGERPRINT=0000000000000000000000000000000000000000000000000000000000000000)"
  require_boundary_failure parent-target-drift "${status}" 77 \
    'local Docker target changed from the parent invocation' "${output}"
  [[ ! -e "${discovery_log}" && ! -e "${marker}" ]]
  printf 'PASS  docker-red     parent target drift rejected before daemon probe\n'
}

prove_production_local_docker_target() {
  local target="${WORK_DIR}/docker-production-local"
  local discovery_log="${target}/discovery.log"
  local marker="${target}/mutation.marker" output status socket canonical
  local socket_link
  local docker_path record path endpoint device inode fingerprint discovery extra
  prepare_production_docker_boundary_fixture "${target}"
  socket="$(select_available_local_docker_socket)" || {
    printf 'FAIL  docker-red     no local Unix Docker socket is available\n' >&2
    return 1
  }
  canonical="$(run_host_command readlink -f -- "${socket}")"
  docker_path="$(run_host_command readlink -f -- "${WORK_DIR}/host-bin/docker")"
  output="${target}/local-target.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}" \
    DOCKER_HOST="unix://${socket}" DOCKER_PROBE_ALLOW_LOCAL=true \
    DOCKER_PROBE_PRINT_TARGET=true)"
  if [[ "${status}" -ne 0 ]]; then
    run_host_command sed -n '1,12p' "${output}" >&2
    printf 'FAIL  docker-red     valid local Unix target was rejected\n' >&2
    return 1
  fi
  record="$(run_host_command grep -F 'TARGET|' "${output}")"
  IFS='|' read -r _ path endpoint device inode fingerprint discovery extra \
    <<<"${record}"
  if [[ "${path}" != "${docker_path}" ||
    "${endpoint}" != "unix://${canonical}" ||
    ! "${device}" =~ ^[0-9]+$ || ! "${inode}" =~ ^[0-9]+$ ||
    ! "${fingerprint}" =~ ^[0-9a-f]{64}$ ||
    "${discovery}" != host_override || -n "${extra}" ]]; then
    printf 'FAIL  docker-red     local target evidence is malformed\n' >&2
    return 1
  fi
  [[ "$(run_host_command wc -l <"${discovery_log}")" -eq 1 ]]
  run_host_command grep -Fqx \
    'version --format {{.Client.Version}}|{{.Server.Version}}|{{.Server.Os}}|{{.Server.Arch}}' \
    "${discovery_log}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]

  run_host_command rm -f -- "${discovery_log}" "${marker}"
  socket_link="${WORK_DIR}/external-local-docker.sock"
  run_host_command ln -s -- "${canonical}" "${socket_link}"
  output="${target}/explicit-context.out"
  status="$(run_production_docker_probe "${target}" "${output}" \
    "${discovery_log}" "${marker}" DOCKER_CONTEXT=fixture-local \
    DOCKER_PROBE_ALLOW_LOCAL=true DOCKER_PROBE_LOCAL_SOCKET="${socket_link}" \
    DOCKER_PROBE_PRINT_TARGET=true)"
  if [[ "${status}" -ne 0 ]]; then
    run_host_command sed -n '1,12p' "${output}" >&2
    printf 'FAIL  docker-red     explicit local Docker context was rejected\n' >&2
    return 1
  fi
  record="$(run_host_command grep -F 'TARGET|' "${output}")"
  IFS='|' read -r _ path endpoint device inode fingerprint discovery extra \
    <<<"${record}"
  [[ "${path}" == "${docker_path}" &&
    "${endpoint}" == "unix://${canonical}" &&
    "${device}" =~ ^[0-9]+$ && "${inode}" =~ ^[0-9]+$ &&
    "${fingerprint}" =~ ^[0-9a-f]{64}$ &&
    "${discovery}" == explicit_context && -z "${extra}" ]]
  [[ "$(run_host_command wc -l <"${discovery_log}")" -eq 2 ]]
  run_host_command grep -Fqx "${EXPECTED_CONTEXT_INSPECT}" "${discovery_log}"
  run_host_command grep -Fqx \
    'version --format {{.Client.Version}}|{{.Server.Version}}|{{.Server.Os}}|{{.Server.Arch}}' \
    "${discovery_log}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]

  printf 'PASS  docker-target  production local Unix target admitted and frozen\n'
  printf 'PASS  docker-target  explicit context canonicalized external Unix socket\n'
  prove_parent_target_drift "${target}" "${discovery_log}" "${marker}" "${socket}"
}

prove_kind_uses_admitted_docker_path() {
  local target="${WORK_DIR}/kind-production-docker" docker_log env_log
  docker_log="${target}/docker.log" env_log="${target}/kind-env.log"
  local marker="${target}/mutation.marker" output="${target}/kind.out"
  local socket canonical docker_path bash_path status=0 record path endpoint device inode fingerprint discovery extra
  prepare_production_docker_boundary_fixture "${target}"
  write_kind_mock "${target}"
  socket="$(select_available_local_docker_socket)" || {
    printf 'FAIL  docker-red     no local Unix Docker socket is available\n' >&2
    return 1
  }
  canonical="$(run_host_command readlink -f -- "${socket}")"
  docker_path="$(run_host_command readlink -f -- "${WORK_DIR}/host-bin/docker")"
  bash_path="$(host_command_path bash)" || return
  # The command body is intentionally expanded only by the child Bash.
  # shellcheck disable=SC2016
  if run_host_command env -u DOCKER_CONTEXT -u DOCKER_CONFIG \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    -u DOCKER_BUILDKIT \
    -u BUILDX_BUILDER -u BUILDKIT_HOST -u BUILDX_CONFIG \
    -u DOCKER_API_VERSION -u DOCKER_CUSTOM_HEADERS \
    -u DOCKER_DEFAULT_PLATFORM -u BUILDX_NO_DEFAULT_LOAD \
    -u EXPERIMENTAL_BUILDKIT_SOURCE_POLICY \
    -u DOCKER_TARGET_ADMITTED -u DOCKER_TARGET_DOCKER_PATH \
    -u DOCKER_TARGET_ENDPOINT -u DOCKER_TARGET_SOCKET_PATH \
    -u DOCKER_TARGET_SOCKET_DEVICE -u DOCKER_TARGET_SOCKET_INODE \
    -u DOCKER_TARGET_FINGERPRINT -u DOCKER_TARGET_DISCOVERY \
    -u DOCKER_TARGET_EXPECTED_FINGERPRINT \
    PATH="${WORK_DIR}/host-bin:${PLATFORM_CALLER_HOST_PATH}" \
    DOCKER_HOST="unix://${socket}" DOCKER_PROBE_ALLOW_LOCAL=true \
    DOCKER_PROBE_DISCOVERY_LOG="${docker_log}" \
    DOCKER_PROBE_MUTATION_MARKER="${marker}" \
    PLATFORM_RUNTIME_TEST_CONTRACT="${RUNTIME_TEST_CONTRACT}" \
    PLATFORM_RUNTIME_TEST_ROOT="${target}/.platform/aqua/test-fixtures" \
    PLATFORM_RUNTIME_TEST_TOKEN="${RUNTIME_TEST_TOKEN}" \
    FIXTURE_ASSERT_DOCKER_LOOKUP=true FIXTURE_CLUSTER_STATE=absent \
    FIXTURE_DOCKER_ENV_LOG="${env_log}" \
    "${bash_path}" -p -c '
set -euo pipefail
root=$1
builtin cd -P -- "${root}"
builtin source tools/common/env.sh
builtin source tools/common/tooling.sh
builtin source tools/kubernetes/runtime.sh
kind_command 10s get clusters >/dev/null
printf "TARGET|%s|%s|%s|%s|%s|%s\\n" \
  "${DOCKER_TARGET_DOCKER_PATH}" "${DOCKER_TARGET_ENDPOINT}" \
  "${DOCKER_TARGET_SOCKET_DEVICE}" "${DOCKER_TARGET_SOCKET_INODE}" \
  "${DOCKER_TARGET_FINGERPRINT}" "${DOCKER_TARGET_DISCOVERY}"
' kind-docker-path "${target}" >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if ((status != 0)); then
    run_host_command sed -n '1,20p' "${output}" >&2
    printf 'FAIL  docker-red     kind did not retain admitted Docker path\n' >&2
    return 1
  fi
  record="$(run_host_command grep -F 'TARGET|' "${output}")"
  IFS='|' read -r _ path endpoint device inode fingerprint discovery extra \
    <<<"${record}"
  [[ "${path}" == "${docker_path}" &&
    "${endpoint}" == "unix://${canonical}" &&
    "${device}" =~ ^[0-9]+$ && "${inode}" =~ ^[0-9]+$ &&
    "${fingerprint}" =~ ^[0-9a-f]{64}$ &&
    "${discovery}" == host_override && -z "${extra}" ]]
  [[ "$(run_host_command wc -l <"${docker_log}")" -eq 2 ]]
  [[ "$(run_host_command grep -Fxc \
    'version --format {{.Client.Version}}|{{.Server.Version}}|{{.Server.Os}}|{{.Server.Arch}}' \
    "${docker_log}")" -eq 2 ]]
  [[ "$(run_host_command wc -l <"${env_log}")" -eq 2 ]]
  run_host_command grep -Fqx \
    "kind|unix://${canonical}|<unset>|<unset>|1|${docker_path}|${fingerprint}" \
    "${env_log}"
  run_host_command grep -Fqx \
    "kind-docker-lookup|${docker_path}" "${env_log}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  printf 'PASS  docker-target  kind resolved and executed admitted Docker path\n'
}

run_adapter_docker_probe() {
  local target="$1" mode="$2" output="$3" marker="$4" bash_path status
  local -a contract_environment=()
  bash_path="$(host_command_path bash)" || return
  if [[ "${mode}" != missing ]]; then
    contract_environment+=(
      "PLATFORM_DOCKER_TEST_CONTRACT=${DOCKER_TEST_CONTRACT}"
    )
  fi
  set +e
  # Child script expands only variables passed into its environment.
  # shellcheck disable=SC2016
  run_host_command env -u DOCKER_HOST -u DOCKER_CONTEXT \
    -u DOCKER_TARGET_ADMITTED -u DOCKER_TARGET_DISCOVERY \
    PLATFORM_DOCKER_TEST_ROOT="${target}/.platform-test/docker-target" \
    PLATFORM_DOCKER_TEST_TOKEN="${DOCKER_TEST_TOKEN}" \
    FIXTURE_DOCKER_ENV_LOG="${marker}" ADAPTER_PROBE_MODE="${mode}" \
    "${contract_environment[@]}" \
    "${bash_path}" -p -c '
set -euo pipefail
root=$1
builtin source "${root}/tools/common/env.sh"
builtin source "${root}/tools/common/docker-target.sh"
case "${ADAPTER_PROBE_MODE}" in
  missing) docker_target_ensure ;;
  escape)
    PLATFORM_DOCKER_TEST_ROOT="${root}/.platform-test/escape"
    export PLATFORM_DOCKER_TEST_ROOT
    docker_target_ensure
    ;;
  drift)
    docker_target_ensure
    DOCKER_HOST=unix:///tmp/forged-docker.sock
    export DOCKER_HOST
    docker_target_assert_frozen
    ;;
  *) exit 64 ;;
esac
' docker-adapter "${target}" >"${output}" 2>&1
  status=$?
  set -e
  printf '%s\n' "${status}"
}

prove_docker_adapter_reds() {
  local target="${WORK_DIR}/docker-adapter-boundary" marker output status
  copy_runtime_files "${target}"
  marker="${target}/adapter-docker-executed.log"

  output="${target}/missing-contract.out"
  status="$(run_adapter_docker_probe "${target}" missing "${output}" "${marker}")"
  require_boundary_failure adapter-contract "${status}" 78 \
    'exact fixture contract is absent' "${output}"
  [[ ! -e "${marker}" ]]

  output="${target}/root-escape.out"
  status="$(run_adapter_docker_probe "${target}" escape "${output}" "${marker}")"
  require_boundary_failure adapter-root "${status}" 78 \
    'fixture root or ownership token is unsafe' "${output}"
  [[ ! -e "${marker}" ]]

  output="${target}/endpoint-drift.out"
  status="$(run_adapter_docker_probe "${target}" drift "${output}" "${marker}")"
  require_boundary_failure endpoint-drift "${status}" 78 \
    'fixture Docker environment drifted' "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  docker-red     adapter contract, root escape, and endpoint drift rejected\n'
}

write_ownership_kubectl_mock() {
  local target="$1"
  run_host_command cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"jsonpath={.data.owner}"* ]]; then
  printf 'not-flare\n'
elif [[ "${arguments}" == *"jsonpath={.data.cluster-name}"* ]]; then
  printf 'flare-platform-dev\n'
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

write_create_kubectl_mock() {
  local target="$1"
  run_host_command cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
if [[ -n "${FIXTURE_DOCKER_ENV_LOG:-}" ]]; then
  printf 'kubectl|%s|%s|%s|%s|%s|%s\n' \
    "${DOCKER_HOST-<unset>}" "${DOCKER_CONTEXT-<unset>}" \
    "${BUILDX_BUILDER-<unset>}" "${DOCKER_BUILDKIT-<unset>}" \
    "${DOCKER_TARGET_DOCKER_PATH-<unset>}" \
    "${DOCKER_TARGET_FINGERPRINT-<unset>}" >>"${FIXTURE_DOCKER_ENV_LOG}"
fi
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"jsonpath={.data.owner}"* ]]; then
  printf 'flare-platform-infra\n'
elif [[ "${arguments}" == *"jsonpath={.data.cluster-name}"* ]]; then
  printf 'flare-platform-dev\n'
elif [[ "${arguments}" == *" apply "* ]]; then
  exit 0
elif [[ "${arguments}" == *" wait "* ]]; then
  exit "${FIXTURE_NODE_WAIT_STATUS:-0}"
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_post_create_failure_is_cleaned() {
  local target="${WORK_DIR}/post-create-failure"
  local marker="${target}/deleted"
  local state="${target}/cluster-state"
  local docker_env_log="${target}/docker-environment.log"
  local kind_log="${target}/kind.log"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_docker_mock "${target}"
  write_create_kubectl_mock "${target}"
  printf 'absent\n' >"${state}"
  if FIXTURE_CLUSTER_STATE_FILE="${state}" \
    FIXTURE_DELETED_MARKER="${marker}" FIXTURE_NODE_WAIT_STATUS=7 \
    FIXTURE_DOCKER_ENV_LOG="${docker_env_log}" FIXTURE_KIND_LOG="${kind_log}" \
    run_runtime_fixture "${target}" \
    tools/kubernetes/kind-up.sh >"${target}/kind-up.out" 2>&1; then
    printf 'FAIL  kube-red       post-create readiness failure passed\n' >&2
    return 1
  fi
  if [[ ! -e "${marker}" ]]; then
    run_host_command sed -n '1,20p' "${target}/kind-up.out" >&2
    run_host_command sed -n '1,20p' "${kind_log}" >&2 || true
    printf 'FAIL  kube-red       incomplete owned cluster was not cleaned\n' >&2
    return 1
  fi
  run_host_command grep -Fqx absent "${state}"
  [[ ! -e "${target}/.platform/kubeconfig" ]]
  # awk program is intentionally literal.
  # shellcheck disable=SC2016
  if ! run_host_command awk -F '|' \
    -v endpoint="unix://${target}/.platform-test/docker-target/docker.sock" \
    -v docker_path="${target}/.platform-test/docker-target/docker" '
      BEGIN { seen_docker = 0; seen_kind = 0; seen_kubectl = 0; fingerprint = "" }
      $1 == "docker" { seen_docker = 1 }
      $1 == "kind" { seen_kind = 1 }
      $1 == "kubectl" { seen_kubectl = 1 }
      $2 != endpoint || $3 != "<unset>" || $4 != "<unset>" ||
        $5 != "1" || $6 != docker_path || $7 !~ /^[0-9a-f]{64}$/ { exit 1 }
      fingerprint == "" { fingerprint = $7; next }
      $7 != fingerprint { exit 1 }
      END { if (!seen_docker || !seen_kind || !seen_kubectl) exit 1 }
    ' "${docker_env_log}"; then
    printf 'FAIL  kube-red       Docker target was not frozen into Docker/kind children\n' >&2
    return 1
  fi
  printf 'PASS  kube-red       owned incomplete creation was cleaned\n'
  printf 'PASS  docker-target  exact frozen environment reached Docker and kind\n'
}

prove_create_failure_stops_without_blind_delete() {
  local target="${WORK_DIR}/create-failure"
  local marker="${target}/deleted"
  local state="${target}/cluster-state"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_docker_mock "${target}"
  write_create_kubectl_mock "${target}"
  printf 'absent\n' >"${state}"
  if FIXTURE_CLUSTER_STATE_FILE="${state}" \
    FIXTURE_DELETED_MARKER="${marker}" FIXTURE_KIND_CREATE_STATUS=8 \
    run_runtime_fixture "${target}" \
    tools/kubernetes/kind-up.sh >/dev/null 2>&1; then
    printf 'FAIL  kube-red       failing create unexpectedly passed\n' >&2
    return 1
  fi
  [[ ! -e "${marker}" ]]
  run_host_command grep -Fqx present "${state}"
  [[ ! -e "${target}/.platform/kubeconfig" ]]
  printf 'PASS  kube-red       unowned partial creation was not blindly deleted\n'
}

prove_unowned_cluster_is_not_deleted() {
  local target="${WORK_DIR}/unowned"
  local marker="${target}/deleted"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_ownership_kubectl_mock "${target}"
  if FIXTURE_DELETED_MARKER="${marker}" run_runtime_fixture "${target}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null 2>&1; then
    printf 'FAIL  kube-red       unowned cluster was accepted\n' >&2
    return 1
  fi
  [[ ! -e "${marker}" ]]
  printf 'PASS  kube-red       unowned same-name cluster was not deleted\n'
}

write_owned_kubectl_mock() {
  local target="$1"
  run_host_command cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"jsonpath={.data.owner}"* ]]; then
  printf 'flare-platform-infra\n'
elif [[ "${arguments}" == *"jsonpath={.data.cluster-name}"* ]]; then
  printf 'flare-platform-dev\n'
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_owned_cluster_is_deleted() {
  local target="${WORK_DIR}/owned"
  local marker="${target}/deleted"
  local state="${target}/cluster-state"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_owned_kubectl_mock "${target}"
  printf 'present\n' >"${state}"
  FIXTURE_CLUSTER_STATE_FILE="${state}" \
    FIXTURE_DELETED_MARKER="${marker}" \
    run_runtime_fixture "${target}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null
  [[ -e "${marker}" ]]
  run_host_command grep -Fqx absent "${state}"
  [[ ! -e "${target}/.platform/kubeconfig" ]]
  printf 'PASS  kube-green     owned cluster deletion reached proven absence\n'
}

prove_absent_destroy_is_idempotent() {
  local target="${WORK_DIR}/absent"
  local marker="${target}/deleted"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  FIXTURE_CLUSTER_STATE=absent FIXTURE_DELETED_MARKER="${marker}" \
    run_runtime_fixture "${target}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null
  FIXTURE_CLUSTER_STATE=absent FIXTURE_DELETED_MARKER="${marker}" \
    run_runtime_fixture "${target}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null
  [[ ! -e "${marker}" ]]
  printf 'PASS  kube-green     absent cluster destroy is idempotent\n'
}

write_namespace_kubectl_mock() {
  local target="$1"
  run_host_command cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"delete namespace"* ]]; then
  printf 'absent\n' >"${FIXTURE_NAMESPACE_STATE:?}"
elif [[ "${arguments}" == *"get namespace"* ]]; then
  if [[ "${FIXTURE_NAMESPACE_QUERY_FAIL:-false}" == true ]]; then
    exit 7
  fi
  [[ "$(cat "${FIXTURE_NAMESPACE_STATE:?}")" == absent ]] || \
    printf 'namespace/flare-platform-reference\n'
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_namespace_cleanup() {
  local target="${WORK_DIR}/namespace"
  local state="${target}/namespace-state"
  copy_runtime_files "${target}"
  write_namespace_kubectl_mock "${target}"
  printf 'fixture\n' >"${target}/.platform/kubeconfig"
  printf 'present\n' >"${state}"
  FIXTURE_NAMESPACE_STATE="${state}" run_runtime_fixture "${target}" \
    tools/kubernetes/delete-namespace.sh >/dev/null
  run_host_command grep -Fqx absent "${state}"
  printf 'PASS  kube-green     namespace cleanup reached proven absence\n'
}

prove_namespace_query_failure_is_not_absence() {
  local target="${WORK_DIR}/namespace-query-failure"
  local state="${target}/namespace-state"
  copy_runtime_files "${target}"
  write_namespace_kubectl_mock "${target}"
  printf 'fixture\n' >"${target}/.platform/kubeconfig"
  printf 'present\n' >"${state}"
  if FIXTURE_NAMESPACE_STATE="${state}" \
    FIXTURE_NAMESPACE_QUERY_FAIL=true \
    run_runtime_fixture "${target}" \
    tools/kubernetes/delete-namespace.sh >/dev/null 2>&1; then
    printf 'FAIL  kube-red       API failure was mistaken for namespace absence\n' >&2
    return 1
  fi
  printf 'PASS  kube-red       API failure was not mistaken for cleanup\n'
}

prove_kubeconfig_symlink_is_rejected() {
  local target="${WORK_DIR}/kubeconfig-symlink"
  local marker="${target}/deleted"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_owned_kubectl_mock "${target}"
  printf 'outside-sentinel\n' >"${target}/outside-kubeconfig"
  run_host_command ln -s "${target}/outside-kubeconfig" \
    "${target}/.platform/kubeconfig"
  if FIXTURE_DELETED_MARKER="${marker}" run_runtime_fixture "${target}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null 2>&1; then
    printf 'FAIL  kube-red       kubeconfig symlink was accepted before export\n' >&2
    return 1
  fi
  run_host_command grep -Fqx outside-sentinel "${target}/outside-kubeconfig"
  [[ ! -e "${marker}" ]]
  printf 'PASS  kube-red       kubeconfig symlink was rejected before export\n'
}

write_noisy_kubectl_mock() {
  local target="$1"
  run_host_command cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/bin/bash -p
set -euo pipefail
if [[ "$*" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
else
  printf '%*s' 200000 '' | while IFS= read -r -N 4096 chunk; do
    printf '%s' "${chunk// /x}"
  done
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_diagnostics_are_bounded() {
  local target="${WORK_DIR}/diagnostics"
  local oversized
  copy_runtime_files "${target}"
  write_noisy_kubectl_mock "${target}"
  printf 'fixture\n' >"${target}/.platform/kubeconfig"
  run_runtime_fixture "${target}" tools/kubernetes/diagnostics.sh >/dev/null
  oversized="$(run_host_command find "${target}/.platform/diagnostics" \
    -type f -size +132000c -print -quit)"
  [[ -z "${oversized}" ]]
  if run_host_command find "${target}/.platform/diagnostics" \
    -name '.capture.*' -print -quit | run_host_command grep -q .; then
    printf 'FAIL  kube-red       temporary diagnostic capture leaked\n' >&2
    return 1
  fi
  run_host_command grep -Fqx 'truncated=true' \
    "${target}/.platform/diagnostics/raw/kubernetes/nodes.txt"
  printf 'PASS  kube-green     failure diagnostics remain stream-bounded\n'
}

main() {
  WORK_DIR="$(run_host_command mktemp -d)"
  trap 'run_host_command rm -rf -- "${WORK_DIR}"' EXIT
  prove_production_docker_boundary_reds
  prove_production_docker_response_grammar
  prove_docker_plugin_discovery_is_sealed
  prove_production_local_docker_target
  prove_kind_uses_admitted_docker_path
  prove_docker_adapter_reds
  prove_post_create_failure_is_cleaned
  prove_create_failure_stops_without_blind_delete
  prove_unowned_cluster_is_not_deleted
  prove_owned_cluster_is_deleted
  prove_absent_destroy_is_idempotent
  prove_namespace_cleanup
  prove_namespace_query_failure_is_not_absence
  prove_kubeconfig_symlink_is_rejected
  prove_diagnostics_are_bounded
}

main "$@"
