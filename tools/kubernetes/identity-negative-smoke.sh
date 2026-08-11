#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/identity.sh"
# This helper guards its CLI entry point and is safe to source.
source "$(dirname -- "${BASH_SOURCE[0]}")/reference-context.sh"

STALE_EVIDENCE_SCHEMA="flare-platform-runtime-identity-stale-v1"
STALE_EVIDENCE_RELATIVE="runtime-identity/stale.env"
STALE_CONTEXT_RELATIVE="runtime-identity/stale-context"
STALE_CONTEXT="${PLATFORM_STATE_DIR}/${STALE_CONTEXT_RELATIVE}"
STALE_MANIFEST="${PLATFORM_STATE_DIR}/runtime-identity/stale-context.manifest.tsv"
STALE_BUILD_LOG_RELATIVE="runtime-identity/stale-docker-build.log"
STALE_EXEC_LOG_RELATIVE="runtime-identity/stale-executable.log"
STALE_MAX_BUILD_LOG_BYTES=131072
STALE_MAX_EXEC_LOG_BYTES=4096
STALE_STARTUP_MARKER="intentional startup failure requested"
STALE_MISMATCH_REASON="FAIL  runtime-id    running binary SHA-256 mismatch"
STALE_ORDER_PROOF="canonical-a-build,canonical-a-load,stale-b-derive,stale-b-exec,"
STALE_ORDER_PROOF+="invalidate-a-build-record,stale-b-build-local-only,deploy-loaded-a"

PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""
HEALTH_RESPONSE_FILE=""
IDENTITY_RESPONSE_FILE=""

HOST_BINARY_SHA256_A=""
HOST_BINARY_SHA256_B=""
CONTEXT_MANIFEST_SHA256_A=""
CONTEXT_MANIFEST_SHA256_B=""
DOCKER_CONFIG_ID_A=""
DOCKER_CONFIG_ID_B=""
B_EXECUTABLE_STATUS=""
B_STARTUP_MARKER=""
CANONICAL_BUILD_ENV_ABSENT=""
RUNNING_EXECUTABLE_SHA256=""
EXPECTED_EXECUTABLE_SHA256=""
MISMATCH=""
MISMATCH_STATUS=""
MISMATCH_REASON=""
POD_IMAGE_ID=""
HEALTH_RESPONSE=""
SELECTED_IPV4_PORT=""
PORT_FORWARD_CLEANUP=""
PORT_FORWARD_PORT_ABSENT=""
PORT_FORWARD_PID_ABSENT=""
NAMESPACE_ABSENT=""

hash_regular_file() {
  local path="$1"
  local digest
  if [[ -L "${path}" || ! -f "${path}" ]]; then
    printf 'FAIL  runtime-stale hash source is not a regular file: %s\n' "${path}" >&2
    return 1
  fi
  digest="$(sha256sum -- "${path}" | awk '{print $1}')" || return
  if ! runtime_identity_is_sha256 "${digest}"; then
    printf 'FAIL  runtime-stale malformed SHA-256 for: %s\n' "${path}" >&2
    return 1
  fi
  printf '%s\n' "${digest}"
}

remove_probe_files() {
  local path
  for path in "${PORT_FORWARD_LOG}" "${HEALTH_RESPONSE_FILE}" \
    "${IDENTITY_RESPONSE_FILE}"; do
    [[ -z "${path}" ]] || rm -f -- "${path}"
  done
  PORT_FORWARD_LOG=""
  HEALTH_RESPONSE_FILE=""
  IDENTITY_RESPONSE_FILE=""
}

emergency_cleanup() {
  local status=$?
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    runtime_identity_stop_tracked "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    PORT_FORWARD_PID=""
  fi
  remove_probe_files
  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" >/dev/null 2>&1 || true
  fi
  return "${status}"
}

retain_canonical_a() {
  local actual_manifest_sha actual_server_sha build_env
  build_env="${PLATFORM_STATE_DIR}/reference/build.env"
  runtime_identity_load_build_env "${build_env}" || return
  verify_context "${REFERENCE_CONTEXT}" "${REFERENCE_MANIFEST}" || return
  runtime_identity_verify_build_artifacts \
    "${REFERENCE_CONTEXT}" "${REFERENCE_MANIFEST}" || return
  actual_server_sha="$(hash_regular_file "${REFERENCE_CONTEXT}/server")" || return
  actual_manifest_sha="$(hash_regular_file "${REFERENCE_MANIFEST}")" || return
  if [[ "${actual_server_sha}" != "${RUNTIME_HOST_BINARY_SHA256}" ||
    "${actual_manifest_sha}" != "${RUNTIME_CONTEXT_MANIFEST_SHA256}" ]]; then
    printf 'FAIL  runtime-stale canonical A build record does not match context\n' >&2
    return 1
  fi
  HOST_BINARY_SHA256_A="${RUNTIME_HOST_BINARY_SHA256}"
  CONTEXT_MANIFEST_SHA256_A="${RUNTIME_CONTEXT_MANIFEST_SHA256}"
  DOCKER_CONFIG_ID_A="${RUNTIME_DOCKER_CONFIG_ID_SECOND}"
}

load_canonical_a() {
  local live_config_id
  "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh" || return
  retain_canonical_a || return
  live_config_id="$(docker_command 20s image inspect --format '{{.Id}}' \
    "${PLATFORM_IMAGE}")" || return
  if [[ "${live_config_id}" != "${DOCKER_CONFIG_ID_A}" ]]; then
    printf 'FAIL  runtime-stale local tag changed before canonical A load\n' >&2
    return 1
  fi
  printf 'INFO  runtime-stale order=01 canonical_a_built=true host_sha256=%s config_id=%s\n' \
    "${HOST_BINARY_SHA256_A}" "${DOCKER_CONFIG_ID_A}"
  kind_command 120s load docker-image "${PLATFORM_IMAGE}" \
    --name "${PLATFORM_CLUSTER_NAME}" || return
  printf 'INFO  runtime-stale order=02 canonical_a_loaded_into_kind=true\n'
}

stage_stale_b_context() {
  local after_bytes before_bytes dockerfile manifest prepared server temporary
  reset_state_directory "${STALE_CONTEXT_RELATIVE}" || return
  dockerfile="$(prepare_state_file "${STALE_CONTEXT_RELATIVE}/Dockerfile")" || return
  server="$(prepare_state_file "${STALE_CONTEXT_RELATIVE}/server")" || return
  manifest="$(prepare_state_file 'runtime-identity/stale-context.manifest.tsv')" || return
  rm -f -- "${manifest}"
  cp -- "${REFERENCE_CONTEXT}/Dockerfile" "${dockerfile}" || return
  cp -- "${REFERENCE_CONTEXT}/server" "${server}" || return
  chmod 0644 "${dockerfile}" || return
  chmod 0755 "${server}" || return
  before_bytes="$(stat -c '%s' "${server}")" || return
  printf 'X' >>"${server}" || return
  after_bytes="$(stat -c '%s' "${server}")" || return
  if ((after_bytes != before_bytes + 1)); then
    printf 'FAIL  runtime-stale stale B did not gain exactly one trailing byte\n' >&2
    return 1
  fi
  temporary="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.stale-manifest.XXXXXXXX")" || return
  if ! write_manifest "${STALE_CONTEXT}" "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  prepared="$(prepare_state_file 'runtime-identity/stale-context.manifest.tsv')" || {
    rm -f -- "${temporary}"
    return 1
  }
  if [[ "${prepared}" != "${manifest}" ]] || ! mv -fT -- "${temporary}" "${manifest}"; then
    rm -f -- "${temporary}"
    printf 'FAIL  runtime-stale unable to publish stale context manifest\n' >&2
    return 1
  fi
  verify_context "${STALE_CONTEXT}" "${STALE_MANIFEST}" || return
  HOST_BINARY_SHA256_B="$(hash_regular_file "${server}")" || return
  CONTEXT_MANIFEST_SHA256_B="$(hash_regular_file "${manifest}")" || return
  if [[ "${HOST_BINARY_SHA256_A}" == "${HOST_BINARY_SHA256_B}" ||
    "${CONTEXT_MANIFEST_SHA256_A}" == "${CONTEXT_MANIFEST_SHA256_B}" ]]; then
    printf 'FAIL  runtime-stale trailing-byte fixture did not change identity\n' >&2
    return 1
  fi
  printf 'INFO  runtime-stale order=03 stale_b_derived=true host_sha256=%s\n' \
    "${HOST_BINARY_SHA256_B}"
}

prove_stale_b_executable() {
  local line log prepared size status temporary
  local -a lines=()
  log="$(prepare_state_file "${STALE_EXEC_LOG_RELATIVE}")" || return
  temporary="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.stale-exec.XXXXXXXX")" || return
  set +e
  # The positional arguments expand only in the bounded child shell.
  # shellcheck disable=SC2016
  run_bounded 10s bash -c '
ulimit -c 0 || exit "$2"
ulimit -f 4 || exit "$2"
exec env PLATFORM_FAIL_STARTUP=1 "$1"
' _ "${STALE_CONTEXT}/server" "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    >"${temporary}" 2>&1
  status=$?
  set -e
  size="$(wc -c <"${temporary}")" || {
    rm -f -- "${temporary}"
    return 1
  }
  mapfile -t lines <"${temporary}" || {
    rm -f -- "${temporary}"
    return 1
  }
  line="${lines[0]:-}"
  if [[ "${status}" -ne 42 || "${size}" -gt "${STALE_MAX_EXEC_LOG_BYTES}" ||
    "${#lines[@]}" -ne 1 ]] ||
    [[ "${line}" != "${STALE_STARTUP_MARKER}" &&
      "${line}" != *" ${STALE_STARTUP_MARKER}" ]]; then
    head -c "${STALE_MAX_EXEC_LOG_BYTES}" "${temporary}" >&2 || true
    rm -f -- "${temporary}"
    printf 'FAIL  runtime-stale B executable status/marker proof failed status=%s\n' \
      "${status}" >&2
    return 1
  fi
  prepared="$(prepare_state_file "${STALE_EXEC_LOG_RELATIVE}")" || {
    rm -f -- "${temporary}"
    return 1
  }
  if [[ "${prepared}" != "${log}" ]] || ! mv -fT -- "${temporary}" "${log}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  B_EXECUTABLE_STATUS=42
  B_STARTUP_MARKER="${STALE_STARTUP_MARKER}"
  printf 'INFO  runtime-stale order=04 stale_b_executable_status=42 startup_marker=%q\n' \
    "${B_STARTUP_MARKER}"
}

invalidate_canonical_a_build_record() {
  local expected="${PLATFORM_STATE_DIR}/reference/build.env"
  local prepared
  prepared="$(prepare_state_file 'reference/build.env')" || return
  if [[ "${prepared}" != "${expected}" ]]; then
    printf 'FAIL  runtime-stale state helper returned unexpected build record path\n' >&2
    return 1
  fi
  rm -f -- "${prepared}" || return
  if [[ -e "${prepared}" || -L "${prepared}" ]]; then
    printf 'FAIL  runtime-stale canonical A build record survived invalidation\n' >&2
    return 1
  fi
  CANONICAL_BUILD_ENV_ABSENT=true
  printf 'INFO  runtime-stale order=05 canonical_a_build_record_invalidated_before_b_tag=true\n'
}

capture_stale_b_build() {
  local log prepared size temporary
  local -a pipeline_status=()
  verify_context "${STALE_CONTEXT}" "${STALE_MANIFEST}" || return
  log="$(prepare_state_file "${STALE_BUILD_LOG_RELATIVE}")" || return
  temporary="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.stale-build.XXXXXXXX")" || return
  set +e
  run_bounded 180s env DOCKER_BUILDKIT=1 docker build \
    --network=none --pull=false --no-cache --progress=plain \
    --file "${STALE_CONTEXT}/Dockerfile" --tag "${PLATFORM_IMAGE}" \
    "${STALE_CONTEXT}" 2>&1 |
    head -c "$((STALE_MAX_BUILD_LOG_BYTES + 1))" >"${temporary}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  size="$(wc -c <"${temporary}")" || {
    rm -f -- "${temporary}"
    return 1
  }
  if [[ "${pipeline_status[1]}" -ne 0 || "${size}" -gt "${STALE_MAX_BUILD_LOG_BYTES}" ]]; then
    rm -f -- "${temporary}"
    printf 'FAIL  runtime-stale B Docker build log exceeded its boundary\n' >&2
    return 1
  fi
  if [[ "${pipeline_status[0]}" -ne 0 ]]; then
    head -c "${STALE_MAX_BUILD_LOG_BYTES}" "${temporary}" >&2 || true
    rm -f -- "${temporary}"
    printf 'FAIL  runtime-stale B Docker build failed with status %s\n' \
      "${pipeline_status[0]}" >&2
    return 1
  fi
  prepared="$(prepare_state_file "${STALE_BUILD_LOG_RELATIVE}")" || {
    rm -f -- "${temporary}"
    return 1
  }
  if [[ "${prepared}" != "${log}" ]] || ! mv -fT -- "${temporary}" "${log}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  DOCKER_CONFIG_ID_B="$(docker_command 20s image inspect --format '{{.Id}}' \
    "${PLATFORM_IMAGE}")" || return
  if [[ ! "${DOCKER_CONFIG_ID_B}" =~ ^sha256:[0-9a-f]{64}$ ||
    "${DOCKER_CONFIG_ID_B}" == "${DOCKER_CONFIG_ID_A}" ]]; then
    printf 'FAIL  runtime-stale B Docker config identity is malformed or unchanged\n' >&2
    return 1
  fi
  printf 'INFO  runtime-stale order=06 stale_b_built_same_tag=true kind_load_b=false config_id=%s\n' \
    "${DOCKER_CONFIG_ID_B}"
}

capture_exact_running_reference_pod_image_id() {
  local pod_image_id
  pod_image_id="$(kubectl_command 20s -n "${PLATFORM_NAMESPACE}" get pods \
    --selector=app.kubernetes.io/name=platform-reference \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="reference")].imageID}{"\n"}{end}')" ||
    return
  if [[ ! "${pod_image_id}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ]]; then
    printf 'FAIL  runtime-stale expected exactly one CRI-reported Pod imageID\n' >&2
    return 1
  fi
  printf '%s\n' "${pod_image_id}"
}

require_stable_pod_image_id() {
  local expected="$1" observed="$2"
  if [[ ! "${expected}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ||
    ! "${observed}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ||
    "${observed}" != "${expected}" ]]; then
    printf 'FAIL  runtime-stale Pod imageID changed across exact runtime probes\n' >&2
    return 1
  fi
}

apply_reference() {
  local manifest
  for manifest in namespace deployment service; do
    kubectl_command 30s apply -f \
      "${PLATFORM_ROOT}/kubernetes/reference/${manifest}.yaml" || return
  done
  kubectl_command 75s -n "${PLATFORM_NAMESPACE}" rollout status \
    deployment/platform-reference --timeout=60s || return
  POD_IMAGE_ID="$(capture_exact_running_reference_pod_image_id)" || return
  printf 'INFO  runtime-stale order=07 loaded_a_deployment_ready=true pod_image_id=%s\n' \
    "${POD_IMAGE_ID}"
}

start_dynamic_port_forward() {
  local attempt pgid port kubectl_path
  kubectl_path="$(managed_tool_path kubectl)" || return
  PORT_FORWARD_LOG="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.stale-port-forward.XXXXXXXX")" || return
  runtime_identity_begin_tracked_cleanup
  set -m
  (
    set +m
    ulimit -c 0 || exit "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
    ulimit -f 64 || exit "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
    exec timeout --foreground --signal=TERM --kill-after=5s 35s \
      "${kubectl_path}" --request-timeout=0 port-forward --address=127.0.0.1 \
      -n "${PLATFORM_NAMESPACE}" service/platform-reference :8080
  ) >"${PORT_FORWARD_LOG}" 2>&1 &
  PORT_FORWARD_PID=$!
  set +m
  pgid="$(linux_process_read_stat "${PORT_FORWARD_PID}")" || return
  pgid="${pgid#* }"
  if [[ "${pgid}" != "${PORT_FORWARD_PID}" ]]; then
    printf 'FAIL  runtime-stale port-forward PID is not its process-group ID\n' >&2
    return 1
  fi
  for ((attempt = 1; attempt <= 40; attempt++)); do
    if port="$(runtime_identity_parse_port "${PORT_FORWARD_LOG}" 2>/dev/null)"; then
      SELECTED_IPV4_PORT="${port}"
      printf 'INFO  runtime-stale order=08 dynamic_port_selected=%s pid_equals_pgid=true\n' \
        "${SELECTED_IPV4_PORT}"
      return 0
    fi
    runtime_identity_process_or_group_exists "${PORT_FORWARD_PID}" || break
    sleep 0.25
  done
  head -c "${RUNTIME_IDENTITY_MAX_PORT_LOG_BYTES}" "${PORT_FORWARD_LOG}" >&2 || true
  printf 'FAIL  runtime-stale dynamic port-forward did not become ready\n' >&2
  return 1
}

fetch_endpoint() {
  local max_bytes="$1" path="$2" output="$3"
  local attempt
  for ((attempt = 1; attempt <= 10; attempt++)); do
    : >"${output}"
    if curl --fail --silent --show-error --proto '=http' --connect-timeout 1 \
      --max-time 2 --max-filesize "${max_bytes}" \
      --output "${output}" \
      "http://127.0.0.1:${SELECTED_IPV4_PORT}${path}" 2>/dev/null; then
      return 0
    fi
    runtime_identity_process_or_group_exists "${PORT_FORWARD_PID}" || break
    sleep 0.25
  done
  printf 'FAIL  runtime-stale endpoint fetch failed: %s\n' "${path}" >&2
  return 1
}

prove_loaded_a_and_stale_b_mismatch() {
  local status
  HEALTH_RESPONSE_FILE="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.stale-health.XXXXXXXX")" || return
  IDENTITY_RESPONSE_FILE="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.stale-identity.XXXXXXXX")" || return
  fetch_endpoint 4 /healthz "${HEALTH_RESPONSE_FILE}" || return
  HEALTH_RESPONSE="$(runtime_identity_parse_health_response "${HEALTH_RESPONSE_FILE}")" || return
  fetch_endpoint 66 /identity "${IDENTITY_RESPONSE_FILE}" || return
  RUNNING_EXECUTABLE_SHA256="$(runtime_identity_parse_response \
    "${IDENTITY_RESPONSE_FILE}")" || return
  runtime_identity_compare "${HOST_BINARY_SHA256_A}" \
    "${RUNNING_EXECUTABLE_SHA256}" || return
  EXPECTED_EXECUTABLE_SHA256="${HOST_BINARY_SHA256_B}"
  set +e
  MISMATCH_REASON="$(runtime_identity_compare "${EXPECTED_EXECUTABLE_SHA256}" \
    "${RUNNING_EXECUTABLE_SHA256}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne "${RUNTIME_IDENTITY_MISMATCH_STATUS}" ||
    "${MISMATCH_REASON}" != "${STALE_MISMATCH_REASON}" ]]; then
    printf 'FAIL  runtime-stale mismatch returned status=%s reason=%q\n' \
      "${status}" "${MISMATCH_REASON}" >&2
    return 1
  fi
  MISMATCH=true
  MISMATCH_STATUS="${status}"
  printf 'INFO  runtime-stale order=09 running_sha_equals_a=true mismatch_status=%s mismatch_reason=%q\n' \
    "${MISMATCH_STATUS}" "${MISMATCH_REASON}"
}

prove_pod_image_id_stable_after_probes() {
  local observed
  observed="$(capture_exact_running_reference_pod_image_id)" || return
  require_stable_pod_image_id "${POD_IMAGE_ID}" "${observed}" || return
  printf 'INFO  runtime-stale post_probe_pod_image_id_stable=true pod_image_id=%s\n' \
    "${observed}"
}

stop_dynamic_port_forward() {
  if [[ -z "${PORT_FORWARD_PID}" ]]; then
    printf 'FAIL  runtime-stale missing tracked port-forward PID\n' >&2
    return 1
  fi
  runtime_identity_stop_tracked "${PORT_FORWARD_PID}" || return
  PORT_FORWARD_PID=""
  if [[ "${RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP:-}" != absent ]]; then
    printf 'FAIL  runtime-stale process-group cleanup was not proved\n' >&2
    return 1
  fi
  if curl --fail --silent --proto '=http' --connect-timeout 1 --max-time 1 \
    "http://127.0.0.1:${SELECTED_IPV4_PORT}/healthz" >/dev/null 2>&1; then
    printf 'FAIL  runtime-stale selected port remained reachable after cleanup\n' >&2
    return 1
  fi
  if [[ "$(wc -c <"${PORT_FORWARD_LOG}")" -gt "${RUNTIME_IDENTITY_MAX_PORT_LOG_BYTES}" ]]; then
    printf 'FAIL  runtime-stale port-forward log exceeded its boundary\n' >&2
    return 1
  fi
  PORT_FORWARD_CLEANUP=absent
  PORT_FORWARD_PORT_ABSENT=true
  PORT_FORWARD_PID_ABSENT=true
  remove_probe_files
  printf 'INFO  runtime-stale order=10 dynamic_port_absent=true pid_group_absent=true\n'
}

validate_stale_evidence_inputs() {
  runtime_identity_is_sha256 "${HOST_BINARY_SHA256_A}" || return 1
  runtime_identity_is_sha256 "${HOST_BINARY_SHA256_B}" || return 1
  runtime_identity_is_sha256 "${CONTEXT_MANIFEST_SHA256_A}" || return 1
  runtime_identity_is_sha256 "${CONTEXT_MANIFEST_SHA256_B}" || return 1
  runtime_identity_is_sha256 "${RUNNING_EXECUTABLE_SHA256}" || return 1
  runtime_identity_is_sha256 "${EXPECTED_EXECUTABLE_SHA256}" || return 1
  if [[ ! "${SELECTED_IPV4_PORT}" =~ ^[0-9]{1,5}$ ]] ||
    ((10#${SELECTED_IPV4_PORT} < 1 || 10#${SELECTED_IPV4_PORT} > 65535)); then
    printf 'FAIL  runtime-stale selected IPv4 port is out of range\n' >&2
    return 1
  fi
  if [[ "${HOST_BINARY_SHA256_A}" == "${HOST_BINARY_SHA256_B}" ||
    "${CONTEXT_MANIFEST_SHA256_A}" == "${CONTEXT_MANIFEST_SHA256_B}" ||
    "${RUNNING_EXECUTABLE_SHA256}" != "${HOST_BINARY_SHA256_A}" ||
    "${EXPECTED_EXECUTABLE_SHA256}" != "${HOST_BINARY_SHA256_B}" ||
    ! "${DOCKER_CONFIG_ID_A}" =~ ^sha256:[0-9a-f]{64}$ ||
    ! "${DOCKER_CONFIG_ID_B}" =~ ^sha256:[0-9a-f]{64}$ ||
    "${DOCKER_CONFIG_ID_A}" == "${DOCKER_CONFIG_ID_B}" ||
    ! "${POD_IMAGE_ID}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ||
    "${B_EXECUTABLE_STATUS}" != 42 ||
    "${B_STARTUP_MARKER}" != "${STALE_STARTUP_MARKER}" ||
    "${CANONICAL_BUILD_ENV_ABSENT}" != true ||
    "${MISMATCH}" != true ||
    "${MISMATCH_STATUS}" != "${RUNTIME_IDENTITY_MISMATCH_STATUS}" ||
    "${MISMATCH_REASON}" != "${STALE_MISMATCH_REASON}" ||
    "${HEALTH_RESPONSE}" != ok ||
    "${PORT_FORWARD_CLEANUP}" != absent ||
    "${PORT_FORWARD_PORT_ABSENT}" != true ||
    "${PORT_FORWARD_PID_ABSENT}" != true ||
    "${NAMESPACE_ABSENT}" != true ]]; then
    printf 'FAIL  runtime-stale refusing incomplete stale identity evidence\n' >&2
    return 1
  fi
}

render_stale_evidence() {
  printf 'SCHEMA=%s\n' "${STALE_EVIDENCE_SCHEMA}"
  printf 'HOST_BINARY_SHA256_A=%s\nHOST_BINARY_SHA256_B=%s\n' \
    "${HOST_BINARY_SHA256_A}" "${HOST_BINARY_SHA256_B}"
  printf 'CONTEXT_MANIFEST_SHA256_A=%s\nCONTEXT_MANIFEST_SHA256_B=%s\n' \
    "${CONTEXT_MANIFEST_SHA256_A}" "${CONTEXT_MANIFEST_SHA256_B}"
  printf 'DOCKER_CONFIG_ID_A=%s\nDOCKER_CONFIG_ID_B=%s\n' \
    "${DOCKER_CONFIG_ID_A}" "${DOCKER_CONFIG_ID_B}"
  printf 'B_EXECUTABLE_STATUS=42\nB_STARTUP_MARKER=%q\n' "${B_STARTUP_MARKER}"
  printf 'RUNNING_EXECUTABLE_SHA256=%s\nEXPECTED_EXECUTABLE_SHA256=%s\n' \
    "${RUNNING_EXECUTABLE_SHA256}" "${EXPECTED_EXECUTABLE_SHA256}"
  printf 'MISMATCH=true\nMISMATCH_STATUS=%s\nMISMATCH_REASON=%q\n' \
    "${MISMATCH_STATUS}" "${MISMATCH_REASON}"
  printf 'POD_IMAGE_ID=%q\n' "${POD_IMAGE_ID}"
  printf 'POD_IMAGE_ID_SEMANTICS=cri-reported-non-comparable-to-local-config-id\n'
  printf 'DOCKER_VS_POD_COMPARABLE=false\n'
  printf 'HEALTH_RESPONSE=ok\nSELECTED_IPV4_PORT=%s\n' "${SELECTED_IPV4_PORT}"
  printf 'PORT_FORWARD_CLEANUP=absent\nPORT_FORWARD_PORT_ABSENT=true\n'
  printf 'PORT_FORWARD_PID_ABSENT=true\nNAMESPACE_ABSENT=true\n'
  printf 'ORDER_PROOF=%s\n' "${STALE_ORDER_PROOF}"
}

stale_evidence_is_exact() {
  local file="$1"
  local actual="" expected=""
  if [[ -L "${file}" || ! -f "${file}" || "$(wc -c <"${file}")" -gt 8192 ]]; then
    printf 'FAIL  runtime-stale evidence staging file is unsafe or oversized\n' >&2
    return 1
  fi
  bash -n "${file}" || return
  IFS= read -r -d '' actual <"${file}" || true
  IFS= read -r -d '' expected < <(render_stale_evidence) || true
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL  runtime-stale evidence staging content is not exact\n' >&2
    return 1
  fi
}

publish_stale_evidence() {
  local prepared target temporary
  validate_stale_evidence_inputs || return
  if [[ -e "${PLATFORM_STATE_DIR}/reference/build.env" ||
    -L "${PLATFORM_STATE_DIR}/reference/build.env" ]]; then
    printf 'FAIL  runtime-stale stale canonical build record reappeared\n' >&2
    return 1
  fi
  target="$(prepare_state_file "${STALE_EVIDENCE_RELATIVE}")" || return
  temporary="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.stale.XXXXXXXX")" || return
  if ! render_stale_evidence >"${temporary}" ||
    ! stale_evidence_is_exact "${temporary}"; then
    rm -f -- "${temporary}"
    return 1
  fi
  prepared="$(prepare_state_file "${STALE_EVIDENCE_RELATIVE}")" || {
    rm -f -- "${temporary}"
    return 1
  }
  if [[ "${prepared}" != "${target}" ]] || ! mv -fT -- "${temporary}" "${target}"; then
    rm -f -- "${temporary}"
    printf 'FAIL  runtime-stale unable to publish stale evidence atomically\n' >&2
    return 1
  fi
}

prove_stale_evidence_contract() (
  local mismatch_output other_pod_image_id status temporary
  HOST_BINARY_SHA256_A="$(printf 'a%.0s' {1..64})"
  HOST_BINARY_SHA256_B="$(printf 'b%.0s' {1..64})"
  CONTEXT_MANIFEST_SHA256_A="$(printf 'c%.0s' {1..64})"
  CONTEXT_MANIFEST_SHA256_B="$(printf 'd%.0s' {1..64})"
  DOCKER_CONFIG_ID_A="sha256:$(printf 'e%.0s' {1..64})"
  DOCKER_CONFIG_ID_B="sha256:$(printf 'f%.0s' {1..64})"
  B_EXECUTABLE_STATUS=42
  B_STARTUP_MARKER="${STALE_STARTUP_MARKER}"
  CANONICAL_BUILD_ENV_ABSENT=true
  RUNNING_EXECUTABLE_SHA256="${HOST_BINARY_SHA256_A}"
  EXPECTED_EXECUTABLE_SHA256="${HOST_BINARY_SHA256_B}"
  MISMATCH=true
  set +e
  mismatch_output="$(runtime_identity_compare "${HOST_BINARY_SHA256_B}" \
    "${HOST_BINARY_SHA256_A}" 2>&1)"
  status=$?
  set -e
  MISMATCH_STATUS="${status}"
  MISMATCH_REASON="${mismatch_output}"
  POD_IMAGE_ID="containerd://sha256:$(printf '1%.0s' {1..64})"
  other_pod_image_id="containerd://sha256:$(printf '2%.0s' {1..64})"
  require_stable_pod_image_id "${POD_IMAGE_ID}" "${POD_IMAGE_ID}"
  if require_stable_pod_image_id \
    "${POD_IMAGE_ID}" "${other_pod_image_id}" >/dev/null 2>&1; then
    printf 'FAIL  runtime-stale changed post-probe Pod imageID was accepted\n' >&2
    return 1
  fi
  if require_stable_pod_image_id \
    "${POD_IMAGE_ID}" "${POD_IMAGE_ID}"$'\n'"${POD_IMAGE_ID}" >/dev/null 2>&1; then
    printf 'FAIL  runtime-stale multiple Running Pod imageIDs were accepted\n' >&2
    return 1
  fi
  HEALTH_RESPONSE=ok
  SELECTED_IPV4_PORT=12345
  PORT_FORWARD_CLEANUP=absent
  PORT_FORWARD_PORT_ABSENT=true
  PORT_FORWARD_PID_ABSENT=true
  NAMESPACE_ABSENT=true
  validate_stale_evidence_inputs
  temporary="$(mktemp)"
  trap 'rm -f -- "${temporary}"' EXIT
  render_stale_evidence >"${temporary}"
  stale_evidence_is_exact "${temporary}"
  printf 'UNEXPECTED=true\n' >>"${temporary}"
  if stale_evidence_is_exact "${temporary}" >/dev/null 2>&1; then
    printf 'FAIL  runtime-stale altered evidence was accepted\n' >&2
    return 1
  fi
  HOST_BINARY_SHA256_B="${HOST_BINARY_SHA256_A}"
  if validate_stale_evidence_inputs >/dev/null 2>&1; then
    printf 'FAIL  runtime-stale identical A/B hashes were accepted\n' >&2
    return 1
  fi
  printf 'PASS  runtime-stale pure evidence and exact mismatch self-check\n'
)

main() {
  local evidence
  if [[ "${1:-}" == --self-check ]]; then
    prove_stale_evidence_contract
    return
  fi
  if (($#)); then
    printf 'FAIL  runtime-stale usage: identity-negative-smoke.sh [--self-check]\n' >&2
    return 2
  fi

  trap emergency_cleanup EXIT
  evidence="$(prepare_state_file "${STALE_EVIDENCE_RELATIVE}")" || return
  rm -f -- "${evidence}"

  "${PLATFORM_ROOT}/tools/kubernetes/kind-up.sh" || return
  "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" >/dev/null || return
  load_canonical_a || return
  stage_stale_b_context || return
  prove_stale_b_executable || return
  invalidate_canonical_a_build_record || return
  capture_stale_b_build || return
  apply_reference || return
  start_dynamic_port_forward || return
  prove_loaded_a_and_stale_b_mismatch || return
  prove_pod_image_id_stable_after_probes || return
  stop_dynamic_port_forward || return
  "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" || return
  NAMESPACE_ABSENT=true
  printf 'INFO  runtime-stale order=11 namespace_absent=true\n'
  publish_stale_evidence || return
  printf 'INFO  runtime-stale order=12 stale_evidence_published=true\n'

  trap - EXIT
  printf 'PASS  runtime-stale loaded A rejected stale same-tag expectation B\n'
}

main "$@"
