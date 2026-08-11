#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/process-state.sh"

RUNTIME_IDENTITY_BOUNDARY_STATUS=73
RUNTIME_IDENTITY_MISMATCH_STATUS=74
RUNTIME_IDENTITY_MALFORMED_STATUS=75
RUNTIME_IDENTITY_PROCESS_STATUS=77
RUNTIME_IDENTITY_MAX_BUILD_ENV_BYTES=16384
RUNTIME_IDENTITY_MAX_PORT_LOG_BYTES=32768

runtime_identity_is_sha256() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

runtime_identity_hex_bytes() {
  od -An -v -tx1 -- "$1" | tr -d '[:space:]'
}

# Stable API: print the SHA from an exact 64-lowercase-hex plus LF response.
runtime_identity_parse_response() {
  local response_file="$1"
  local bytes encoded value
  if [[ -L "${response_file}" || ! -f "${response_file}" ]]; then
    printf 'FAIL  runtime-id    malformed identity response\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  bytes="$(wc -c <"${response_file}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if [[ "${bytes}" -ne 65 ]]; then
    printf 'FAIL  runtime-id    malformed identity response\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  encoded="$(runtime_identity_hex_bytes "${response_file}")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if [[ ! "${encoded}" =~ ^(3[0-9]|6[1-6]){64}0a$ ]]; then
    printf 'FAIL  runtime-id    malformed identity response\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  IFS= read -r value <"${response_file}" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  printf '%s\n' "${value}"
}

runtime_identity_parse_health_response() {
  local response_file="$1"
  local bytes encoded
  if [[ -L "${response_file}" || ! -f "${response_file}" ]]; then
    printf 'FAIL  runtime-id    malformed health response\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  bytes="$(wc -c <"${response_file}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if [[ "${bytes}" -ne 3 ]]; then
    printf 'FAIL  runtime-id    malformed health response\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  encoded="$(runtime_identity_hex_bytes "${response_file}")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if [[ "${encoded}" != 6f6b0a ]]; then
    printf 'FAIL  runtime-id    malformed health response\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  printf 'ok\n'
}

# Stable API: compare already-normalized expected and running executable SHAs.
runtime_identity_compare() {
  local expected="$1"
  local actual="$2"
  if ! runtime_identity_is_sha256 "${expected}"; then
    printf 'FAIL  runtime-id    invalid expected binary SHA-256\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if ! runtime_identity_is_sha256 "${actual}"; then
    printf 'FAIL  runtime-id    malformed identity response\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  if [[ "${expected}" != "${actual}" ]]; then
    printf 'FAIL  runtime-id    running binary SHA-256 mismatch\n' >&2
    return "${RUNTIME_IDENTITY_MISMATCH_STATUS}"
  fi
}

# Stable API: print the one IPv4 port selected by kubectl for local port zero.
runtime_identity_parse_port() {
  local log_file="$1"
  local line port="" bytes
  local pattern='^Forwarding from 127\.0\.0\.1:([0-9]{1,5}) -> 8080$'
  if [[ -L "${log_file}" || ! -f "${log_file}" ]]; then
    printf 'FAIL  runtime-id    malformed port-forward selection log\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  bytes="$(wc -c <"${log_file}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if ((bytes > RUNTIME_IDENTITY_MAX_PORT_LOG_BYTES)); then
    printf 'FAIL  runtime-id    malformed port-forward selection log\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == 'Forwarding from '* ]] || continue
    if [[ ! "${line}" =~ ${pattern} || -n "${port}" ]]; then
      printf 'FAIL  runtime-id    malformed port-forward selection log\n' >&2
      return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
    fi
    port="${BASH_REMATCH[1]}"
  done <"${log_file}"
  if [[ -z "${port}" ]] || ((10#${port} < 1 || 10#${port} > 65535)); then
    printf 'FAIL  runtime-id    malformed port-forward selection log\n' >&2
    return "${RUNTIME_IDENTITY_MALFORMED_STATUS}"
  fi
  printf '%s\n' "$((10#${port}))"
}

runtime_identity_reset_build_fields() {
  RUNTIME_BUILD_SCHEMA=""
  RUNTIME_BUILD_SOURCE_COMMIT=""
  RUNTIME_BUILD_SOURCE_TREE=""
  RUNTIME_BUILD_SOURCE_SEMANTICS=""
  RUNTIME_HOST_BINARY_SHA256=""
  RUNTIME_HOST_BINARY_SHA256_SECOND=""
  RUNTIME_HOST_BINARY_REPRODUCIBLE=""
  RUNTIME_HOST_BINARY_BYTES=""
  RUNTIME_CONTEXT_MANIFEST_PATH=""
  RUNTIME_CONTEXT_MANIFEST_SHA256=""
  RUNTIME_BUILD_CONTEXT_ARCHIVE_SHA256=""
  RUNTIME_BUILD_CONTEXT_STREAM_SHA256_FIRST=""
  RUNTIME_BUILD_CONTEXT_STREAM_SHA256_SECOND=""
  RUNTIME_BUILD_CONTEXT_STREAM_BYTES_FIRST=""
  RUNTIME_BUILD_CONTEXT_STREAM_BYTES_SECOND=""
  RUNTIME_BUILD_CONTEXT_INPUT_SEMANTICS=""
  RUNTIME_BUILD_CONTEXT_BYTES=""
  RUNTIME_BUILD_CONTEXT_CANARY_EXCLUDED=""
  RUNTIME_TEMP_IMAGE_TAG=""
  RUNTIME_FINAL_IMAGE_TAG=""
  RUNTIME_DOCKER_CONFIG_ID_FIRST=""
  RUNTIME_DOCKER_CONFIG_ID_SECOND=""
  RUNTIME_DOCKER_CONFIG_IDENTICAL=""
  RUNTIME_DOCKER_REPO_DIGESTS=""
  RUNTIME_DOCKER_IDENTITY_SEMANTICS=""
  RUNTIME_BUILD_LOG_FIRST_PATH=""
  RUNTIME_BUILD_LOG_FIRST_SHA256=""
  RUNTIME_BUILD_LOG_FIRST_RESULT_CONFIG_ID=""
  RUNTIME_BUILD_LOG_SECOND_PATH=""
  RUNTIME_BUILD_LOG_SECOND_SHA256=""
  RUNTIME_BUILD_LOG_SECOND_RESULT_CONFIG_ID=""
}

runtime_identity_assign_build_field() {
  local key="$1" value="$2"
  case "${key}" in
    SCHEMA) RUNTIME_BUILD_SCHEMA="${value}" ;;
    BUILD_SOURCE_COMMIT) RUNTIME_BUILD_SOURCE_COMMIT="${value}" ;;
    BUILD_SOURCE_TREE) RUNTIME_BUILD_SOURCE_TREE="${value}" ;;
    BUILD_SOURCE_SEMANTICS) RUNTIME_BUILD_SOURCE_SEMANTICS="${value}" ;;
    HOST_BINARY_SHA256) RUNTIME_HOST_BINARY_SHA256="${value}" ;;
    HOST_BINARY_SHA256_SECOND) RUNTIME_HOST_BINARY_SHA256_SECOND="${value}" ;;
    HOST_BINARY_REPRODUCIBLE) RUNTIME_HOST_BINARY_REPRODUCIBLE="${value}" ;;
    HOST_BINARY_BYTES) RUNTIME_HOST_BINARY_BYTES="${value}" ;;
    CONTEXT_MANIFEST_PATH) RUNTIME_CONTEXT_MANIFEST_PATH="${value}" ;;
    CONTEXT_MANIFEST_SHA256) RUNTIME_CONTEXT_MANIFEST_SHA256="${value}" ;;
    BUILD_CONTEXT_ARCHIVE_SHA256) RUNTIME_BUILD_CONTEXT_ARCHIVE_SHA256="${value}" ;;
    BUILD_CONTEXT_STREAM_SHA256_FIRST) RUNTIME_BUILD_CONTEXT_STREAM_SHA256_FIRST="${value}" ;;
    BUILD_CONTEXT_STREAM_SHA256_SECOND) RUNTIME_BUILD_CONTEXT_STREAM_SHA256_SECOND="${value}" ;;
    BUILD_CONTEXT_STREAM_BYTES_FIRST) RUNTIME_BUILD_CONTEXT_STREAM_BYTES_FIRST="${value}" ;;
    BUILD_CONTEXT_STREAM_BYTES_SECOND) RUNTIME_BUILD_CONTEXT_STREAM_BYTES_SECOND="${value}" ;;
    BUILD_CONTEXT_INPUT_SEMANTICS) RUNTIME_BUILD_CONTEXT_INPUT_SEMANTICS="${value}" ;;
    BUILD_CONTEXT_BYTES) RUNTIME_BUILD_CONTEXT_BYTES="${value}" ;;
    BUILD_CONTEXT_CANARY_EXCLUDED) RUNTIME_BUILD_CONTEXT_CANARY_EXCLUDED="${value}" ;;
    TEMP_IMAGE_TAG) RUNTIME_TEMP_IMAGE_TAG="${value}" ;;
    FINAL_IMAGE_TAG) RUNTIME_FINAL_IMAGE_TAG="${value}" ;;
    DOCKER_CONFIG_ID_FIRST) RUNTIME_DOCKER_CONFIG_ID_FIRST="${value}" ;;
    DOCKER_CONFIG_ID_SECOND) RUNTIME_DOCKER_CONFIG_ID_SECOND="${value}" ;;
    DOCKER_CONFIG_IDENTICAL) RUNTIME_DOCKER_CONFIG_IDENTICAL="${value}" ;;
    DOCKER_REPO_DIGESTS) RUNTIME_DOCKER_REPO_DIGESTS="${value}" ;;
    DOCKER_IDENTITY_SEMANTICS) RUNTIME_DOCKER_IDENTITY_SEMANTICS="${value}" ;;
    BUILD_LOG_FIRST_PATH) RUNTIME_BUILD_LOG_FIRST_PATH="${value}" ;;
    BUILD_LOG_FIRST_SHA256) RUNTIME_BUILD_LOG_FIRST_SHA256="${value}" ;;
    BUILD_LOG_FIRST_RESULT_CONFIG_ID) RUNTIME_BUILD_LOG_FIRST_RESULT_CONFIG_ID="${value}" ;;
    BUILD_LOG_SECOND_PATH) RUNTIME_BUILD_LOG_SECOND_PATH="${value}" ;;
    BUILD_LOG_SECOND_SHA256) RUNTIME_BUILD_LOG_SECOND_SHA256="${value}" ;;
    BUILD_LOG_SECOND_RESULT_CONFIG_ID) RUNTIME_BUILD_LOG_SECOND_RESULT_CONFIG_ID="${value}" ;;
    *)
      printf 'FAIL  runtime-id    unexpected build identity key: %s\n' "${key}" >&2
      return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
      ;;
  esac
}

runtime_identity_load_build_env() {
  local build_env="$1"
  local line key value bytes encoded line_count=0 record_count=0
  local -A seen=()
  runtime_identity_reset_build_fields
  if [[ -L "${build_env}" || ! -f "${build_env}" ]]; then
    printf 'FAIL  runtime-id    build identity record is missing or unsafe\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  bytes="$(wc -c <"${build_env}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  line_count="$(wc -l <"${build_env}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if ((bytes < 1 || bytes > RUNTIME_IDENTITY_MAX_BUILD_ENV_BYTES || line_count != 31)); then
    printf 'FAIL  runtime-id    malformed build identity record\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  encoded="$(runtime_identity_hex_bytes "${build_env}")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if [[ "${encoded}" =~ ^([0-9a-f]{2})*00([0-9a-f]{2})*$ ]]; then
    printf 'FAIL  runtime-id    malformed build identity record\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ ! "${line}" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      printf 'FAIL  runtime-id    malformed build identity record\n' >&2
      return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -n "${seen[${key}]:-}" || "${value}" == *$'\r'* || "${value}" == *$'\t'* ]]; then
      printf 'FAIL  runtime-id    malformed build identity record\n' >&2
      return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
    fi
    seen["${key}"]=true
    ((record_count += 1))
    runtime_identity_assign_build_field "${key}" "${value}" || return
  done <"${build_env}"
  if ((record_count != 31)); then
    printf 'FAIL  runtime-id    malformed build identity record\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  runtime_identity_validate_build_env
}

runtime_identity_validate_source_fields() {
  if [[ ! "${RUNTIME_BUILD_SOURCE_COMMIT}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${RUNTIME_BUILD_SOURCE_TREE}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    "${RUNTIME_BUILD_SOURCE_SEMANTICS}" != git-commit-tree-snapshot ]]; then
    printf 'FAIL  runtime-id    malformed build source identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_require_source() {
  local expected_commit="$1" expected_tree="$2"
  runtime_identity_validate_source_fields || return
  if [[ "${RUNTIME_BUILD_SOURCE_COMMIT}" != "${expected_commit}" ||
    "${RUNTIME_BUILD_SOURCE_TREE}" != "${expected_tree}" ]]; then
    printf 'FAIL  runtime-id    build source differs from captured source revision\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_validate_context_input() {
  if ! runtime_identity_is_sha256 "${RUNTIME_BUILD_CONTEXT_ARCHIVE_SHA256}" ||
    ! runtime_identity_is_sha256 "${RUNTIME_BUILD_CONTEXT_STREAM_SHA256_FIRST}" ||
    ! runtime_identity_is_sha256 "${RUNTIME_BUILD_CONTEXT_STREAM_SHA256_SECOND}"; then
    printf 'FAIL  runtime-id    malformed Docker input stream identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ "${RUNTIME_BUILD_CONTEXT_ARCHIVE_SHA256}" == "${RUNTIME_BUILD_CONTEXT_STREAM_SHA256_FIRST}" &&
    "${RUNTIME_BUILD_CONTEXT_ARCHIVE_SHA256}" == "${RUNTIME_BUILD_CONTEXT_STREAM_SHA256_SECOND}" &&
    "${RUNTIME_BUILD_CONTEXT_STREAM_BYTES_FIRST}" =~ ^[1-9][0-9]{0,8}$ &&
    "${RUNTIME_BUILD_CONTEXT_STREAM_BYTES_FIRST}" == "${RUNTIME_BUILD_CONTEXT_STREAM_BYTES_SECOND}" &&
    "${RUNTIME_BUILD_CONTEXT_INPUT_SEMANTICS}" == tee-captured-deterministic-tar ]]; then
    return 0
  else
    printf 'FAIL  runtime-id    malformed Docker input stream identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_validate_host_context() {
  if [[ "${RUNTIME_BUILD_SCHEMA}" != flare-platform-reference-build-v2 ]] ||
    ! runtime_identity_is_sha256 "${RUNTIME_HOST_BINARY_SHA256}" ||
    ! runtime_identity_is_sha256 "${RUNTIME_HOST_BINARY_SHA256_SECOND}" ||
    ! runtime_identity_is_sha256 "${RUNTIME_CONTEXT_MANIFEST_SHA256}"; then
    printf 'FAIL  runtime-id    malformed host build identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ "${RUNTIME_HOST_BINARY_REPRODUCIBLE}" != true ||
    "${RUNTIME_HOST_BINARY_SHA256}" != "${RUNTIME_HOST_BINARY_SHA256_SECOND}" ]]; then
    printf 'FAIL  runtime-id    host binary reproducibility contract failed\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ ! "${RUNTIME_HOST_BINARY_BYTES}" =~ ^[1-9][0-9]{0,8}$ ||
    ! "${RUNTIME_BUILD_CONTEXT_BYTES}" =~ ^[1-9][0-9]{0,8}$ ]] ||
    ((10#${RUNTIME_HOST_BINARY_BYTES} >= 10#${RUNTIME_BUILD_CONTEXT_BYTES})); then
    printf 'FAIL  runtime-id    malformed build-context byte identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ "${RUNTIME_CONTEXT_MANIFEST_PATH}" != .platform/reference/context.manifest.tsv ||
    "${RUNTIME_BUILD_CONTEXT_CANARY_EXCLUDED}" != true ]]; then
    printf 'FAIL  runtime-id    malformed build-context boundary identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ ! "${RUNTIME_TEMP_IMAGE_TAG}" =~ ^[a-z0-9._/-]+:[a-z0-9._-]+$ ||
    "${RUNTIME_TEMP_IMAGE_TAG}" == "${RUNTIME_FINAL_IMAGE_TAG}" ||
    "${RUNTIME_FINAL_IMAGE_TAG}" != "${PLATFORM_IMAGE}" ]]; then
    printf 'FAIL  runtime-id    malformed image tag identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_validate_docker_fields() {
  if [[ ! "${RUNTIME_DOCKER_CONFIG_ID_FIRST}" =~ ^sha256:[0-9a-f]{64}$ ||
    ! "${RUNTIME_DOCKER_CONFIG_ID_SECOND}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'FAIL  runtime-id    malformed local Docker config identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ ! "${RUNTIME_DOCKER_CONFIG_IDENTICAL}" =~ ^(true|false)$ ||
    "${RUNTIME_DOCKER_IDENTITY_SEMANTICS}" != docker-config-digest ||
    -n "${RUNTIME_DOCKER_REPO_DIGESTS}" ]]; then
    printf 'FAIL  runtime-id    malformed local Docker identity semantics\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ "${RUNTIME_DOCKER_CONFIG_IDENTICAL}" == true &&
    "${RUNTIME_DOCKER_CONFIG_ID_FIRST}" != "${RUNTIME_DOCKER_CONFIG_ID_SECOND}" ]] ||
    [[ "${RUNTIME_DOCKER_CONFIG_IDENTICAL}" == false &&
      "${RUNTIME_DOCKER_CONFIG_ID_FIRST}" == "${RUNTIME_DOCKER_CONFIG_ID_SECOND}" ]]; then
    printf 'FAIL  runtime-id    inconsistent Docker determinism record\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_validate_build_logs() {
  if [[ "${RUNTIME_BUILD_LOG_FIRST_PATH}" != .platform/reference/docker-build-first.log ||
    "${RUNTIME_BUILD_LOG_SECOND_PATH}" != .platform/reference/docker-build-second.log ||
    ! "${RUNTIME_BUILD_LOG_FIRST_SHA256}" =~ ^[0-9a-f]{64}$ ||
    ! "${RUNTIME_BUILD_LOG_SECOND_SHA256}" =~ ^[0-9a-f]{64}$ ||
    ! "${RUNTIME_BUILD_LOG_FIRST_RESULT_CONFIG_ID}" =~ ^sha256:[0-9a-f]{64}$ ||
    ! "${RUNTIME_BUILD_LOG_SECOND_RESULT_CONFIG_ID}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'FAIL  runtime-id    malformed bounded build-log identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if [[ "${RUNTIME_BUILD_LOG_FIRST_RESULT_CONFIG_ID}" != "${RUNTIME_DOCKER_CONFIG_ID_FIRST}" ||
    "${RUNTIME_BUILD_LOG_SECOND_RESULT_CONFIG_ID}" != "${RUNTIME_DOCKER_CONFIG_ID_SECOND}" ]]; then
    printf 'FAIL  runtime-id    Docker build result and inspect identity disagree\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_validate_build_env() {
  runtime_identity_validate_source_fields || return
  runtime_identity_validate_host_context || return
  runtime_identity_validate_context_input || return
  runtime_identity_validate_docker_fields || return
  runtime_identity_validate_build_logs
}

runtime_identity_verify_context_files() {
  local context="$1" manifest="$2"
  local dockerfile_bytes dockerfile_line dockerfile_mode dockerfile_sha
  local manifest_bytes manifest_lines manifest_sha server_bytes server_line server_mode server_sha
  local -a lines=()
  if [[ -L "${context}" || ! -d "${context}" || -L "${manifest}" || ! -f "${manifest}" ||
    -L "${context}/Dockerfile" || ! -f "${context}/Dockerfile" ||
    -L "${context}/server" || ! -f "${context}/server" ]]; then
    printf 'FAIL  runtime-id    build artifacts are missing or unsafe\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  manifest_sha="$(sha256sum -- "${manifest}" | awk '{print $1}')" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  manifest_bytes="$(wc -c <"${manifest}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  manifest_lines="$(wc -l <"${manifest}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  mapfile -t lines <"${manifest}" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  dockerfile_bytes="$(stat -c '%s' "${context}/Dockerfile")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  server_bytes="$(stat -c '%s' "${context}/server")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  dockerfile_mode="$(stat -c '%a' "${context}/Dockerfile")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  server_mode="$(stat -c '%a' "${context}/server")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  dockerfile_sha="$(sha256sum -- "${context}/Dockerfile" | awk '{print $1}')" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  server_sha="$(sha256sum -- "${context}/server" | awk '{print $1}')" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  printf -v dockerfile_line 'Dockerfile\t0%s\t%s\t%s' \
    "${dockerfile_mode}" "${dockerfile_bytes}" "${dockerfile_sha}"
  printf -v server_line 'server\t0%s\t%s\t%s' \
    "${server_mode}" "${server_bytes}" "${server_sha}"
  if ((manifest_bytes < 1 || manifest_bytes > 1024 || manifest_lines != 3 || ${#lines[@]} != 3)) ||
    [[ "${lines[0]:-}" != $'path\tmode\tsize\tsha256' ||
      "${lines[1]:-}" != "${dockerfile_line}" || "${lines[2]:-}" != "${server_line}" ||
      "${manifest_sha}" != "${RUNTIME_CONTEXT_MANIFEST_SHA256}" ||
      "${server_sha}" != "${RUNTIME_HOST_BINARY_SHA256}" ||
      "${server_bytes}" != "${RUNTIME_HOST_BINARY_BYTES}" ]] ||
    ((dockerfile_bytes + server_bytes != RUNTIME_BUILD_CONTEXT_BYTES)); then
    printf 'FAIL  runtime-id    build artifacts disagree with build identity record\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_verify_context_archive() (
  local context="$1" archive="" archive_bytes archive_sha entries
  ensure_state_directory reference || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  archive="$(mktemp "${PLATFORM_STATE_DIR}/reference/.context-verify.XXXXXXXX.tar")" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  trap 'rm -f -- "${archive}"' EXIT
  tar --sort=name --format=ustar --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner -cf "${archive}" \
    -C "${context}" Dockerfile server || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  entries="$(tar -tf "${archive}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  archive_bytes="$(stat -c '%s' "${archive}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  archive_sha="$(sha256sum -- "${archive}" | awk '{print $1}')" ||
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if [[ "${entries}" != $'Dockerfile\nserver' ||
    "${archive_sha}" != "${RUNTIME_BUILD_CONTEXT_ARCHIVE_SHA256}" ||
    "${archive_bytes}" != "${RUNTIME_BUILD_CONTEXT_STREAM_BYTES_FIRST}" ]]; then
    printf 'FAIL  runtime-id    deterministic context archive disagrees with build identity record\n' \
      >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
)

runtime_identity_verify_build_artifacts() {
  local context="$1" manifest="$2"
  runtime_identity_verify_context_files "${context}" "${manifest}" || return
  runtime_identity_verify_context_archive "${context}" || return
  runtime_identity_verify_build_log_files
}

runtime_identity_verify_build_log_files() {
  local first="${PLATFORM_ROOT}/${RUNTIME_BUILD_LOG_FIRST_PATH}"
  local second="${PLATFORM_ROOT}/${RUNTIME_BUILD_LOG_SECOND_PATH}"
  local first_bytes second_bytes first_sha second_sha
  local first_result second_result
  if [[ -L "${first}" || ! -f "${first}" || -L "${second}" || ! -f "${second}" ]]; then
    printf 'FAIL  runtime-id    build logs are missing or unsafe\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  first_bytes="$(stat -c '%s' "${first}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  second_bytes="$(stat -c '%s' "${second}")" || return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  if ((first_bytes < 1 || first_bytes > 131072 || second_bytes < 1 || second_bytes > 131072)); then
    printf 'FAIL  runtime-id    build logs exceeded their evidence boundary\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  first_sha="$(sha256sum -- "${first}" | awk '{print $1}')" || return
  second_sha="$(sha256sum -- "${second}" | awk '{print $1}')" || return
  first_result="$(runtime_identity_extract_build_result_id "${first}")" || return
  second_result="$(runtime_identity_extract_build_result_id "${second}")" || return
  if [[ "${first_sha}" != "${RUNTIME_BUILD_LOG_FIRST_SHA256}" ||
    "${second_sha}" != "${RUNTIME_BUILD_LOG_SECOND_SHA256}" ||
    "${first_result}" != "${RUNTIME_BUILD_LOG_FIRST_RESULT_CONFIG_ID}" ||
    "${second_result}" != "${RUNTIME_BUILD_LOG_SECOND_RESULT_CONFIG_ID}" ]]; then
    printf 'FAIL  runtime-id    build logs disagree with build identity record\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
}

runtime_identity_extract_build_result_id() {
  local log="$1"
  local -a results=()
  mapfile -t results < <(sed -n \
    's/^.*writing image \(sha256:[0-9a-f]\{64\}\) done$/\1/p' "${log}")
  if [[ "${#results[@]}" -ne 1 ||
    ! "${results[0]:-}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'FAIL  runtime-id    malformed Docker build result identity\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  printf '%s\n' "${results[0]}"
}

runtime_identity_process_or_group_exists() {
  local pid="$1"
  linux_process_or_group_is_live "${pid}"
}

runtime_identity_signal_group() {
  local signal="$1" pid="$2"
  kill -s "${signal}" -- "-${pid}" 2>/dev/null
}

runtime_identity_wait_tracked() {
  wait "$1" 2>/dev/null
}

runtime_identity_cleanup_pause() {
  sleep 0.1
}

runtime_identity_begin_tracked_cleanup() {
  RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP=""
}

runtime_identity_poll_absence() {
  local pid="$1" attempt
  for ((attempt = 1; attempt <= 10; attempt++)); do
    runtime_identity_process_or_group_exists "${pid}" || return 0
    runtime_identity_cleanup_pause
  done
  ! runtime_identity_process_or_group_exists "${pid}"
}

# Stable API: bounded TERM/KILL/reap and explicit PID/process-group absence.
# The tracked PID must also be the process-group ID created by the caller.
runtime_identity_stop_tracked() {
  local pid="$1"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]] || ((pid <= 1)); then
    printf 'FAIL  runtime-id    invalid tracked port-forward PID\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if runtime_identity_process_or_group_exists "${pid}"; then
    runtime_identity_signal_group TERM "${pid}" || true
    runtime_identity_poll_absence "${pid}" || true
  fi
  if runtime_identity_process_or_group_exists "${pid}"; then
    runtime_identity_signal_group KILL "${pid}" || true
    runtime_identity_poll_absence "${pid}" || true
  fi
  if runtime_identity_process_or_group_exists "${pid}"; then
    printf 'FAIL  runtime-id    port-forward process survived cleanup\n' >&2
    return "${RUNTIME_IDENTITY_PROCESS_STATUS}"
  fi
  runtime_identity_wait_tracked "${pid}" || true
  if runtime_identity_process_or_group_exists "${pid}"; then
    printf 'FAIL  runtime-id    port-forward process survived cleanup\n' >&2
    return "${RUNTIME_IDENTITY_PROCESS_STATUS}"
  fi
  RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP=absent
}

runtime_identity_validate_positive_arguments() {
  local source_commit="$1" source_tree="$2" worktree_clean="$3" pod_image_id="$4"
  local running_sha="$5" health="$6" selected_port="$7"
  local namespace_absent="$8" cluster_cleanup="$9"
  runtime_identity_validate_build_env || return
  if [[ ! "${source_commit}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${source_tree}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    "${source_commit}" != "${RUNTIME_BUILD_SOURCE_COMMIT}" ||
    "${source_tree}" != "${RUNTIME_BUILD_SOURCE_TREE}" ||
    "${worktree_clean}" != true ||
    ! "${pod_image_id}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ||
    "${health}" != ok || "${namespace_absent}" != true ||
    ! "${selected_port}" =~ ^[0-9]{1,5}$ ||
    "${cluster_cleanup}" != deferred-to-verify-runtime ||
    "${RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP:-}" != absent ]]; then
    printf 'FAIL  runtime-id    refusing incomplete positive identity evidence\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  if ((10#${selected_port} < 1 || 10#${selected_port} > 65535)); then
    printf 'FAIL  runtime-id    refusing incomplete positive identity evidence\n' >&2
    return "${RUNTIME_IDENTITY_BOUNDARY_STATUS}"
  fi
  runtime_identity_compare "${RUNTIME_HOST_BINARY_SHA256}" "${running_sha}"
}

runtime_identity_render_positive() {
  local source_commit="$1" source_tree="$2" worktree_clean="$3" pod_image_id="$4"
  local running_sha="$5" health="$6" selected_port="$7"
  local cluster_cleanup="$8"
  printf 'SCHEMA=flare-platform-runtime-identity-positive-v2\n'
  printf 'SOURCE_COMMIT=%s\nSOURCE_TREE=%s\n' "${source_commit}" "${source_tree}"
  printf 'SOURCE_WORKTREE_CLEAN=%s\n' "${worktree_clean}"
  printf 'BUILD_SOURCE_COMMIT=%s\n' "${RUNTIME_BUILD_SOURCE_COMMIT}"
  printf 'BUILD_SOURCE_TREE=%s\n' "${RUNTIME_BUILD_SOURCE_TREE}"
  printf 'BUILD_SOURCE_SEMANTICS=%s\n' "${RUNTIME_BUILD_SOURCE_SEMANTICS}"
  printf 'HOST_BINARY_SHA256=%s\n' "${RUNTIME_HOST_BINARY_SHA256}"
  printf 'HOST_BINARY_SHA256_SECOND=%s\n' "${RUNTIME_HOST_BINARY_SHA256_SECOND}"
  printf 'HOST_BINARY_REPRODUCIBLE=%s\n' "${RUNTIME_HOST_BINARY_REPRODUCIBLE}"
  printf 'HOST_BINARY_BYTES=%s\n' "${RUNTIME_HOST_BINARY_BYTES}"
  printf 'CONTEXT_MANIFEST_PATH=%s\n' "${RUNTIME_CONTEXT_MANIFEST_PATH}"
  printf 'CONTEXT_MANIFEST_SHA256=%s\n' "${RUNTIME_CONTEXT_MANIFEST_SHA256}"
  printf 'BUILD_CONTEXT_ARCHIVE_SHA256=%s\n' "${RUNTIME_BUILD_CONTEXT_ARCHIVE_SHA256}"
  printf 'BUILD_CONTEXT_STREAM_SHA256_FIRST=%s\n' \
    "${RUNTIME_BUILD_CONTEXT_STREAM_SHA256_FIRST}"
  printf 'BUILD_CONTEXT_STREAM_SHA256_SECOND=%s\n' \
    "${RUNTIME_BUILD_CONTEXT_STREAM_SHA256_SECOND}"
  printf 'BUILD_CONTEXT_STREAM_BYTES_FIRST=%s\n' \
    "${RUNTIME_BUILD_CONTEXT_STREAM_BYTES_FIRST}"
  printf 'BUILD_CONTEXT_STREAM_BYTES_SECOND=%s\n' \
    "${RUNTIME_BUILD_CONTEXT_STREAM_BYTES_SECOND}"
  printf 'BUILD_CONTEXT_INPUT_SEMANTICS=%s\n' "${RUNTIME_BUILD_CONTEXT_INPUT_SEMANTICS}"
  printf 'BUILD_CONTEXT_BYTES=%s\n' "${RUNTIME_BUILD_CONTEXT_BYTES}"
  printf 'BUILD_CONTEXT_CANARY_EXCLUDED=%s\n' "${RUNTIME_BUILD_CONTEXT_CANARY_EXCLUDED}"
  printf 'DOCKER_CONFIG_ID_FIRST=%s\n' "${RUNTIME_DOCKER_CONFIG_ID_FIRST}"
  printf 'DOCKER_CONFIG_ID_SECOND=%s\n' "${RUNTIME_DOCKER_CONFIG_ID_SECOND}"
  printf 'DOCKER_CONFIG_IDENTICAL=%s\n' "${RUNTIME_DOCKER_CONFIG_IDENTICAL}"
  printf 'DOCKER_REPO_DIGESTS=%s\n' "${RUNTIME_DOCKER_REPO_DIGESTS}"
  printf 'DOCKER_IDENTITY_SEMANTICS=%s\n' "${RUNTIME_DOCKER_IDENTITY_SEMANTICS}"
  printf 'BUILD_LOG_FIRST_SHA256=%s\n' "${RUNTIME_BUILD_LOG_FIRST_SHA256}"
  printf 'BUILD_LOG_FIRST_RESULT_CONFIG_ID=%s\n' "${RUNTIME_BUILD_LOG_FIRST_RESULT_CONFIG_ID}"
  printf 'BUILD_LOG_SECOND_SHA256=%s\n' "${RUNTIME_BUILD_LOG_SECOND_SHA256}"
  printf 'BUILD_LOG_SECOND_RESULT_CONFIG_ID=%s\n' "${RUNTIME_BUILD_LOG_SECOND_RESULT_CONFIG_ID}"
  printf 'POD_IMAGE_ID=%s\n' "${pod_image_id}"
  printf 'POD_IMAGE_ID_SEMANTICS=cri-reported-non-comparable-to-local-config-id\n'
  printf 'DOCKER_VS_POD_COMPARABLE=false\n'
  printf 'RUNNING_EXECUTABLE_SHA256=%s\nHEALTH_RESPONSE=%s\n' "${running_sha}" "${health}"
  printf 'SELECTED_IPV4_PORT=%s\nPORT_FORWARD_CLEANUP=absent\n' "${selected_port}"
  printf 'PORT_FORWARD_PID_ABSENT=true\nNAMESPACE_ABSENT=true\n'
  printf 'CLUSTER_CLEANUP=%s\n' "${cluster_cleanup}"
}

runtime_identity_publish_positive() {
  local source_commit="$1" source_tree="$2" worktree_clean="$3" pod_image_id="$4"
  local running_sha="$5" health="$6" selected_port="$7"
  local namespace_absent="$8" cluster_cleanup="$9"
  local target temporary status=0
  runtime_identity_validate_positive_arguments "$@" || return
  target="$(prepare_state_file 'runtime-identity/positive.env')" || return
  temporary="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.positive.XXXXXXXX")" || return
  runtime_identity_render_positive "${source_commit}" "${source_tree}" "${worktree_clean}" "${pod_image_id}" \
    "${running_sha}" "${health}" "${selected_port}" "${cluster_cleanup}" \
    >"${temporary}" || status=$?
  prepare_state_file 'runtime-identity/positive.env' >/dev/null || status=$?
  if ((status == 0)); then
    mv -fT -- "${temporary}" "${target}" || status=$?
  fi
  [[ "${status}" -eq 0 ]] || rm -f -- "${temporary}"
  return "${status}"
}
