#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/identity.sh"

PORT_FORWARD_PID=""
PORT_FORWARD_LOG_FILE=""
HEALTH_RESPONSE_FILE=""
IDENTITY_RESPONSE_FILE=""
SELECTED_IPV4_PORT=""
HEALTH_RESPONSE=""
RUNNING_EXECUTABLE_SHA256=""
POD_IMAGE_ID=""
NAMESPACE_ABSENT=false
SOURCE_COMMIT=""
SOURCE_TREE=""
SOURCE_WORKTREE_CLEAN=false

remove_probe_files() {
  local file status=0
  for file in "${PORT_FORWARD_LOG_FILE}" "${HEALTH_RESPONSE_FILE}" \
    "${IDENTITY_RESPONSE_FILE}"; do
    if [[ -n "${file}" ]] && ! rm -f -- "${file}"; then
      status=1
    fi
  done
  if ((status == 0)); then
    PORT_FORWARD_LOG_FILE=""
    HEALTH_RESPONSE_FILE=""
    IDENTITY_RESPONSE_FILE=""
  fi
  return "${status}"
}

stop_probe() {
  local status=0
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    if runtime_identity_stop_tracked "${PORT_FORWARD_PID}"; then
      PORT_FORWARD_PID=""
    else
      status=$?
    fi
  fi
  remove_probe_files || status=1
  return "${status}"
}

emergency_cleanup() {
  local original_status=$?
  local cleanup_status=0
  stop_probe || cleanup_status=$?
  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" >/dev/null 2>&1 || cleanup_status=1
  fi
  if ((original_status != 0)); then
    return "${original_status}"
  fi
  return "${cleanup_status}"
}

invalidate_positive_evidence() {
  local evidence
  evidence="$(prepare_state_file 'runtime-identity/positive.env')" || return
  rm -f -- "${evidence}"
}

capture_initial_source_state() {
  local worktree_state
  SOURCE_COMMIT="$(git -C "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{commit}')" || return
  SOURCE_TREE="$(git -C "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{tree}')" || return
  worktree_state="$(git -C "${PLATFORM_ROOT}" status --porcelain=v1 --untracked-files=all)" || return
  require_exact_source_state "${SOURCE_COMMIT}" "${SOURCE_TREE}" \
    "${SOURCE_COMMIT}" "${SOURCE_TREE}" "${worktree_state}" || return
  SOURCE_WORKTREE_CLEAN=true
}

require_exact_source_state() {
  local expected_commit="$1" expected_tree="$2" actual_commit="$3" actual_tree="$4"
  local worktree_state="$5"
  if [[ ! "${expected_commit}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${expected_tree}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${actual_commit}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${actual_tree}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    printf 'FAIL  runtime-id    malformed source revision identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ "${actual_commit}" != "${expected_commit}" ||
    "${actual_tree}" != "${expected_tree}" ]]; then
    printf 'FAIL  runtime-id    source revision changed during runtime verification\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ -n "${worktree_state}" ]]; then
    printf 'FAIL  runtime-id    source worktree is not clean for exact runtime build\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

load_reference_image() {
  local build_env="${PLATFORM_STATE_DIR}/reference/build.env"
  local context="${PLATFORM_STATE_DIR}/reference/context"
  local live_config_id
  local manifest="${PLATFORM_STATE_DIR}/reference/context.manifest.tsv"
  PLATFORM_REFERENCE_SOURCE_COMMIT="${SOURCE_COMMIT}" \
    PLATFORM_REFERENCE_SOURCE_TREE="${SOURCE_TREE}" \
    "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh" || return
  runtime_identity_load_build_env "${build_env}" || return
  runtime_identity_require_source "${SOURCE_COMMIT}" "${SOURCE_TREE}" || return
  "${PLATFORM_ROOT}/tools/kubernetes/reference-context.sh" verify || return
  runtime_identity_verify_build_artifacts "${context}" "${manifest}" || return
  live_config_id="$(docker_command 20s image inspect --format '{{.Id}}' \
    "${PLATFORM_IMAGE}")" || return
  if [[ ! "${live_config_id}" =~ ^sha256:[0-9a-f]{64}$ ||
    "${live_config_id}" != "${RUNTIME_DOCKER_CONFIG_ID_SECOND}" ]]; then
    printf 'FAIL  runtime-id    local image config changed before kind load\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  kind_command 120s load docker-image "${PLATFORM_IMAGE}" \
    --name "${PLATFORM_CLUSTER_NAME}"
}

apply_reference() {
  local manifest
  for manifest in namespace deployment service; do
    kubectl_command 30s apply -f \
      "${PLATFORM_ROOT}/kubernetes/reference/${manifest}.yaml" || return 1
  done
}

capture_pod_image_id() {
  local output
  output="$(kubectl_command 20s -n "${PLATFORM_NAMESPACE}" get pods \
    --selector=app.kubernetes.io/name=platform-reference \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="reference")].imageID}{"\n"}{end}')" ||
    return
  if [[ ! "${output}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ]]; then
    printf 'FAIL  runtime-id    expected exactly one CRI-reported Pod imageID\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  POD_IMAGE_ID="${output}"
  printf 'INFO  kind-smoke    pod_image_id=%s semantics=cri-reported-non-comparable\n' \
    "${POD_IMAGE_ID}"
}

confirm_pod_image_id_stable() {
  local before_probe="${POD_IMAGE_ID}"
  capture_pod_image_id || return
  if [[ "${POD_IMAGE_ID}" != "${before_probe}" ]]; then
    printf 'FAIL  runtime-id    Pod imageID changed across exact endpoint probe\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  printf 'INFO  kind-smoke    pod_image_id_stable_across_probe=true\n'
}

create_probe_files() {
  ensure_state_directory runtime-identity || return
  PORT_FORWARD_LOG_FILE="$(mktemp \
    "${PLATFORM_STATE_DIR}/runtime-identity/.port-forward.XXXXXXXX")" || return
  HEALTH_RESPONSE_FILE="$(mktemp \
    "${PLATFORM_STATE_DIR}/runtime-identity/.health-response.XXXXXXXX")" || return
  IDENTITY_RESPONSE_FILE="$(mktemp \
    "${PLATFORM_STATE_DIR}/runtime-identity/.identity-response.XXXXXXXX")" || return
}

start_port_forward() {
  runtime_identity_begin_tracked_cleanup
  set -m
  (
    set +m
    ulimit -c 0
    ulimit -f 64
    exec timeout --foreground --signal=TERM --kill-after=5s 35s \
      kubectl --request-timeout=0 port-forward --address=127.0.0.1 \
      -n "${PLATFORM_NAMESPACE}" service/platform-reference :8080
  ) >>"${PORT_FORWARD_LOG_FILE}" 2>&1 &
  PORT_FORWARD_PID=$!
  set +m
  if [[ ! "${PORT_FORWARD_PID}" =~ ^[0-9]+$ ]] ||
    ! runtime_identity_process_or_group_exists "${PORT_FORWARD_PID}"; then
    printf 'FAIL  runtime-id    unable to start tracked dynamic port-forward\n' >&2
    return "${RUNTIME_IDENTITY_PROCESS_STATUS}"
  fi
}

wait_for_selected_port() {
  local attempt selected
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if selected="$(runtime_identity_parse_port "${PORT_FORWARD_LOG_FILE}" 2>/dev/null)"; then
      SELECTED_IPV4_PORT="${selected}"
      printf 'INFO  kind-smoke    selected_ipv4_port=%s\n' "${SELECTED_IPV4_PORT}"
      return 0
    fi
    runtime_identity_process_or_group_exists "${PORT_FORWARD_PID}" || break
    sleep 0.2
  done
  printf 'FAIL  runtime-id    dynamic IPv4 port selection was not observed\n' >&2
  return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
}

curl_probe() {
  local path="$1" maximum_bytes="$2" output="$3"
  curl --fail --silent --show-error --proto '=http' --connect-timeout 1 \
    --max-time 2 --max-filesize "${maximum_bytes}" --output "${output}" \
    "http://127.0.0.1:${SELECTED_IPV4_PORT}${path}"
}

probe_exact_endpoints() {
  local attempt
  for ((attempt = 1; attempt <= 10; attempt++)); do
    if curl_probe /healthz 16 "${HEALTH_RESPONSE_FILE}"; then
      if HEALTH_RESPONSE="$(runtime_identity_parse_health_response \
        "${HEALTH_RESPONSE_FILE}")"; then
        :
      else
        return $?
      fi
      if curl_probe /identity 80 "${IDENTITY_RESPONSE_FILE}"; then
        if RUNNING_EXECUTABLE_SHA256="$(runtime_identity_parse_response \
          "${IDENTITY_RESPONSE_FILE}")"; then
          if runtime_identity_compare "${RUNTIME_HOST_BINARY_SHA256}" \
            "${RUNNING_EXECUTABLE_SHA256}"; then
            return 0
          else
            return $?
          fi
        else
          return $?
        fi
      fi
    fi
    runtime_identity_process_or_group_exists "${PORT_FORWARD_PID}" || break
    sleep 0.5
  done
  printf 'FAIL  runtime-id    bounded exact HTTP probes did not succeed\n' >&2
  return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
}

probe() {
  local status=0 cleanup_status=0
  create_probe_files || status=$?
  if ((status == 0)); then start_port_forward || status=$?; fi
  if ((status == 0)); then wait_for_selected_port || status=$?; fi
  if ((status == 0)); then probe_exact_endpoints || status=$?; fi
  stop_probe || cleanup_status=$?
  if ((status == 0 && cleanup_status != 0)); then status="${cleanup_status}"; fi
  if ((status == 0)); then
    printf 'INFO  kind-smoke    health_response="%s" identity_sha256=%s\n' \
      "${HEALTH_RESPONSE}" "${RUNNING_EXECUTABLE_SHA256}"
  fi
  return "${status}"
}

capture_failure() {
  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh" || true
  fi
}

delete_runtime_namespace() {
  if [[ ! -f "${KUBECONFIG}" ]]; then
    printf 'FAIL  kind-smoke    kubeconfig absent before namespace cleanup\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" || return
  NAMESPACE_ABSENT=true
}

publish_runtime_evidence() {
  local source_commit source_tree worktree_state
  source_commit="$(git -C "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{commit}')" || return
  source_tree="$(git -C "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{tree}')" || return
  worktree_state="$(git -C "${PLATFORM_ROOT}" status --porcelain=v1 --untracked-files=all)" || return
  require_exact_source_state "${SOURCE_COMMIT}" "${SOURCE_TREE}" \
    "${source_commit}" "${source_tree}" "${worktree_state}" || return
  runtime_identity_publish_positive "${SOURCE_COMMIT}" "${SOURCE_TREE}" "${SOURCE_WORKTREE_CLEAN}" \
    "${POD_IMAGE_ID}" "${RUNNING_EXECUTABLE_SHA256}" "${HEALTH_RESPONSE}" \
    "${SELECTED_IPV4_PORT}" "${NAMESPACE_ABSENT}" deferred-to-verify-runtime
}

prove_source_state_guard() (
  local commit_a commit_b status tree
  commit_a="$(printf 'a%.0s' {1..40})"
  commit_b="$(printf 'b%.0s' {1..40})"
  tree="$(printf 'c%.0s' {1..40})"
  require_exact_source_state "${commit_a}" "${tree}" "${commit_a}" "${tree}" ""
  if require_exact_source_state "${commit_a}" "${tree}" \
    "${commit_a}" "${tree}" ' M kubernetes/reference/server/main.go' >/dev/null 2>&1; then
    printf 'FAIL  runtime-red   dirty source worktree was accepted\n' >&2
    return 1
  else
    status=$?
  fi
  [[ "${status}" -eq "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" ]] || return 1
  if require_exact_source_state "${commit_a}" "${tree}" \
    "${commit_b}" "${tree}" "" >/dev/null 2>&1; then
    printf 'FAIL  runtime-red   changed source revision was accepted\n' >&2
    return 1
  else
    status=$?
  fi
  [[ "${status}" -eq "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" ]] || return 1
  printf 'PASS  runtime-red   exact clean source revision guard proved\n'
)

prove_probe_cleanup_failure() (
  local status
  PORT_FORWARD_LOG_FILE=/tmp/flare-probe-cleanup-log
  HEALTH_RESPONSE_FILE=/tmp/flare-probe-cleanup-health
  IDENTITY_RESPONSE_FILE=/tmp/flare-probe-cleanup-identity
  rm() { return 1; }
  if remove_probe_files >/dev/null 2>&1; then
    printf 'FAIL  runtime-red   probe-file cleanup failure was accepted\n' >&2
    return 1
  else
    status=$?
  fi
  if [[ "${status}" -ne 1 || -z "${PORT_FORWARD_LOG_FILE}" ||
    -z "${HEALTH_RESPONSE_FILE}" || -z "${IDENTITY_RESPONSE_FILE}" ]]; then
    printf 'FAIL  runtime-red   failed probe cleanup discarded retry state\n' >&2
    return 1
  fi
  printf 'PASS  runtime-red   probe-file cleanup failure retained retry state\n'
)

main() {
  local status=0 cleanup_status=0
  if [[ "${1:-}" == --self-check ]]; then
    [[ $# -eq 1 ]] || return 2
    prove_source_state_guard
    prove_probe_cleanup_failure
    return
  fi
  if (($#)); then
    printf 'FAIL  kind-smoke    usage: smoke.sh [--self-check]\n' >&2
    return 2
  fi
  trap emergency_cleanup EXIT
  invalidate_positive_evidence || status=$?
  if ((status == 0)); then capture_initial_source_state || status=$?; fi
  if ((status == 0)); then "${PLATFORM_ROOT}/tools/kubernetes/kind-up.sh" || status=$?; fi
  if ((status == 0)); then load_reference_image || status=$?; fi
  if ((status == 0)); then apply_reference || status=$?; fi
  if ((status == 0)); then
    kubectl_command 75s -n "${PLATFORM_NAMESPACE}" rollout status \
      deployment/platform-reference --timeout=60s || status=$?
  fi
  if ((status == 0)); then capture_pod_image_id || status=$?; fi
  if ((status == 0)); then probe || status=$?; fi
  if ((status == 0)); then confirm_pod_image_id_stable || status=$?; fi
  if ((status != 0)); then capture_failure; fi
  delete_runtime_namespace || cleanup_status=$?
  if ((status == 0 && cleanup_status != 0)); then status="${cleanup_status}"; fi
  if ((status == 0)); then publish_runtime_evidence || status=$?; fi
  if ((status != 0)); then
    printf 'FAIL  kind-smoke    reference workload identity verification failed\n' >&2
    return "${status}"
  fi
  printf 'PASS  kind-smoke    build -> load -> rollout -> exact identity -> cleanup\n'
  trap - EXIT
}

main "$@"
