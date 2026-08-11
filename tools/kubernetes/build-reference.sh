#!/bin/bash -p
set -euo pipefail

BUILD_REFERENCE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${BUILD_REFERENCE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  BUILD_REFERENCE_SOURCE_DIR=.

# shellcheck source=../common/env.sh
builtin source "${BUILD_REFERENCE_SOURCE_DIR}/../common/env.sh" || exit 1
# shellcheck source=../common/tooling.sh
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh" || exit 1
builtin source "${PLATFORM_ROOT}/tools/common/lifecycle-lease.sh" || exit 1
# shellcheck source=runtime.sh
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh" || exit 1
# shellcheck source=reference-context.sh
builtin source "${PLATFORM_ROOT}/tools/kubernetes/reference-context.sh" || exit 1
# shellcheck source=buildkit-result.sh
builtin source "${PLATFORM_ROOT}/tools/kubernetes/buildkit-result.sh" || exit 1
unset BUILD_REFERENCE_SOURCE_DIR

export LC_ALL=C

REFERENCE_ROOT="${PLATFORM_STATE_DIR}/reference"
REFERENCE_CONTEXT="${REFERENCE_ROOT}/context"
REFERENCE_MANIFEST="${REFERENCE_ROOT}/context.manifest.tsv"
REFERENCE_CANARY_NAME="CONTEXT_CANARY_NOT_SENT"
TEMP_IMAGE_TAG="flare-platform-reference:identity-first"
MAX_BUILD_LOG_BYTES=131072
BUILD_LOG_PATH=""
BUILD_RESULT_CONFIG_ID=""
BUILD_CONTEXT_ARCHIVE_SHA256_CURRENT=""
BUILD_CONTEXT_STREAM_SHA256_CURRENT=""
BUILD_CONTEXT_STREAM_BYTES_CURRENT=""
REFERENCE_SOURCE_COMMIT=""
REFERENCE_SOURCE_TREE=""

hash_file() {
  local path="$1"
  local digest
  # awk program is intentionally literal.
  # shellcheck disable=SC2016
  digest="$(run_host_command sha256sum -- "${path}" |
    run_host_command awk '{print $1}')" || return
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "${digest}" || return
}

verify_canonical_context_identity() {
  assert_context_identity "${REFERENCE_CONTEXT}" "${REFERENCE_MANIFEST}" \
    "${CONTEXT_MANIFEST_SHA256:-}" || return
}

resolve_reference_source_identity() {
  local requested_commit="${PLATFORM_REFERENCE_SOURCE_COMMIT:-}"
  local requested_tree="${PLATFORM_REFERENCE_SOURCE_TREE:-}"
  local resolved_commit resolved_tree
  if [[ (-n "${requested_commit}" && -z "${requested_tree}") ||
    (-z "${requested_commit}" && -n "${requested_tree}") ]]; then
    printf 'FAIL  reference-build source commit/tree must be supplied together\n' >&2 || return
    return 1
  fi
  if [[ -z "${requested_commit}" ]]; then
    requested_commit="$(run_host_command git -C "${PLATFORM_ROOT}" \
      rev-parse --verify 'HEAD^{commit}')" || return
    requested_tree="$(run_host_command git -C "${PLATFORM_ROOT}" \
      rev-parse --verify 'HEAD^{tree}')" || return
  fi
  if [[ ! "${requested_commit}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${requested_tree}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    printf 'FAIL  reference-build malformed source commit/tree identity\n' >&2 || return
    return 1
  fi
  resolved_commit="$(run_host_command git -C "${PLATFORM_ROOT}" \
    rev-parse --verify "${requested_commit}^{commit}")" || return
  resolved_tree="$(run_host_command git -C "${PLATFORM_ROOT}" \
    rev-parse --verify "${resolved_commit}^{tree}")" || return
  if [[ "${resolved_commit}" != "${requested_commit}" || "${resolved_tree}" != "${requested_tree}" ]]; then
    printf 'FAIL  reference-build source commit/tree identity mismatch\n' >&2 || return
    return 1
  fi
  REFERENCE_SOURCE_COMMIT="${resolved_commit}"
  REFERENCE_SOURCE_TREE="${resolved_tree}"
}

stage_reference_source_snapshot() {
  local archive snapshot archive_bytes
  local -a unsafe=()
  snapshot="$(run_host_command mktemp -d "${REFERENCE_ROOT}/.source.XXXXXXXX")" || return
  archive="$(run_host_command mktemp "${REFERENCE_ROOT}/.source-archive.XXXXXXXX")" || {
    run_host_command rm -rf -- "${snapshot}" || return
    return 1
  }
  if ! run_host_command git -C "${PLATFORM_ROOT}" archive \
    --format=tar --output="${archive}" \
    "${REFERENCE_SOURCE_COMMIT}" -- kubernetes/reference/Dockerfile \
    kubernetes/reference/server; then
    run_host_command rm -rf -- "${snapshot}" || return
    run_host_command rm -f -- "${archive}" || return
    return 1
  fi
  archive_bytes="$(run_host_command stat -c '%s' "${archive}")" || {
    run_host_command rm -rf -- "${snapshot}" || return
    run_host_command rm -f -- "${archive}" || return
    return 1
  }
  if ((archive_bytes < 1 || archive_bytes > 1048576)) ||
    ! run_host_command tar -xf "${archive}" -C "${snapshot}" \
      --no-same-owner --no-same-permissions; then
    run_host_command rm -rf -- "${snapshot}" || return
    run_host_command rm -f -- "${archive}" || return
    printf 'FAIL  reference-build guarded source snapshot is invalid\n' >&2 || return
    return 1
  fi
  run_host_command rm -f -- "${archive}" || return
  mapfile -t unsafe < <(run_host_command find "${snapshot}" -mindepth 1 \
    \( -type l -o \( ! -type d ! -type f \) \) -print)
  if ((${#unsafe[@]})) ||
    [[ ! -f "${snapshot}/kubernetes/reference/Dockerfile" ||
      ! -f "${snapshot}/kubernetes/reference/server/go.mod" ||
      ! -f "${snapshot}/kubernetes/reference/server/main.go" ]]; then
    run_host_command rm -rf -- "${snapshot}" || return
    printf 'FAIL  reference-build guarded source snapshot is unsafe\n' >&2 || return
    return 1
  fi
  printf '%s\n' "${snapshot}" || return
}

build_host_binary() {
  local output="$1"
  local cache_relative="$2"
  local source_directory="$3"
  local cache="${PLATFORM_STATE_DIR}/${cache_relative}"
  reset_state_directory "${cache_relative}" || return
  run_host_command rm -f -- "${output}" || return
  (
    builtin cd -- "${source_directory}" || exit 1
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      GOCACHE="${cache}" GOTOOLCHAIN=local GOPROXY=off \
      run_managed_tool_bounded 90s go build -buildvcs=false -trimpath \
      -ldflags='-s -w -buildid=' \
      -o "${output}" . || exit $?
  ) || return
  if [[ -L "${output}" || ! -f "${output}" || ! -x "${output}" ]]; then
    printf 'FAIL  reference-build host output is not a regular executable\n' >&2 || return
    return 1
  fi
}

prove_host_binary_reproducibility() {
  local first="$1"
  local second="$2"
  local first_sha second_sha
  first_sha="$(hash_file "${first}")" || return
  second_sha="$(hash_file "${second}")" || return
  if ! run_host_command cmp --silent -- "${first}" "${second}" ||
    [[ "${first_sha}" != "${second_sha}" ]]; then
    printf 'FAIL  reference-build fresh host binaries differ\n' >&2 || return
    return 1
  fi
  HOST_BINARY_SHA256="${first_sha}"
  HOST_BINARY_SHA256_SECOND="${second_sha}"
  HOST_BINARY_BYTES="$(run_host_command stat -c '%s' "${first}")" || return
  printf 'PASS  reference-build reproducible_host_sha256=%s\n' "${first_sha}" || return
}

extract_result_config_id() {
  local log="$1"
  local result
  if ! result="$(buildkit_result_config_id "${log}")"; then
    printf 'FAIL  reference-build expected exactly one BuildKit result config identity\n' >&2 || return
    return 1
  fi
  printf '%s\n' "${result}" || return
}

write_context_archive() {
  local snapshot="$1" archive="$2" entries
  run_host_command tar --sort=name --format=ustar --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner -cf "${archive}" \
    -C "${snapshot}" Dockerfile server || return
  entries="$(run_host_command tar -tf "${archive}")" || return
  if [[ "${entries}" != $'Dockerfile\nserver' ]]; then
    printf 'FAIL  reference-build deterministic context archive entries are not exact\n' \
      >&2 || return
    return 1
  fi
}

verify_context_stream_identity() {
  local archive="$1" consumed="$2" expected="$3"
  local archive_sha consumed_sha
  archive_sha="$(hash_file "${archive}")" || return
  consumed_sha="$(hash_file "${consumed}")" || return
  if [[ "${archive_sha}" != "${expected}" || "${consumed_sha}" != "${expected}" ]] ||
    ! run_host_command cmp --silent -- "${archive}" "${consumed}"; then
    printf 'FAIL  reference-build Docker input stream bytes changed\n' >&2 || return
    return 1
  fi
  printf '%s\n' "${consumed_sha}" || return
}

capture_image_build_snapshot() (
  local tag="$1"
  local log_relative="$2"
  local archive="" archive_bytes archive_sha consumed="" consumed_sha
  local bash_path docker_path head_path tee_path
  local log snapshot="" snapshot_manifest="" temporary="" size
  local -a pipeline_status=()
  trap '[[ -z "${snapshot}" ]] || run_host_command rm -rf -- "${snapshot}";
    [[ -z "${snapshot_manifest}" ]] || run_host_command rm -f -- "${snapshot_manifest}";
    [[ -z "${archive}" ]] || run_host_command rm -f -- "${archive}";
    [[ -z "${consumed}" ]] || run_host_command rm -f -- "${consumed}";
    [[ -z "${temporary}" ]] || run_host_command rm -f -- "${temporary}"' EXIT
  verify_canonical_context_identity || return
  snapshot="$(run_host_command mktemp -d \
    "${REFERENCE_ROOT}/.docker-context.XXXXXXXX")" || return
  snapshot_manifest="$(run_host_command mktemp \
    "${REFERENCE_ROOT}/.docker-context-manifest.XXXXXXXX")" || return
  stage_context_snapshot "${REFERENCE_CONTEXT}" "${REFERENCE_MANIFEST}" \
    "${snapshot}" "${snapshot_manifest}" "${CONTEXT_MANIFEST_SHA256}" || return
  archive="$(run_host_command mktemp \
    "${REFERENCE_ROOT}/.docker-context.XXXXXXXX.tar")" || return
  consumed="$(run_host_command mktemp \
    "${REFERENCE_ROOT}/.docker-consumed.XXXXXXXX.tar")" || return
  write_context_archive "${snapshot}" "${archive}" || return
  archive_bytes="$(run_host_command stat -c '%s' "${archive}")" || return
  if [[ ! "${archive_bytes}" =~ ^[1-9][0-9]{0,8}$ ]]; then
    printf 'FAIL  reference-build Docker input stream size is malformed\n' >&2 || return
    return 1
  fi
  archive_sha="$(hash_file "${archive}")" || return
  log="$(prepare_state_file "${log_relative}")" || return
  temporary="$(run_host_command mktemp \
    "${REFERENCE_ROOT}/.docker-build.XXXXXXXX")" || return
  docker_target_ensure || return
  bash_path="$(host_command_path bash)" || return
  docker_path="${DOCKER_TARGET_DOCKER_PATH}"
  head_path="$(host_command_path head)" || return
  tee_path="$(host_command_path tee)" || return
  set +e
  # This foreground pipeline waits for both sides. head closes at MAX+1, and
  # run_bounded still provides a hard deadline if a producer ignores SIGPIPE.
  # tee captures the exact tar byte stream delivered to Docker stdin.
  # shellcheck disable=SC2016
  docker_target_run_bounded 180s "${bash_path}" -p -c '
set -o pipefail
"$1" "$2" <"$3" |
  "$4" build --builder default \
    --network=none --pull=false --no-cache --progress=plain \
    --file Dockerfile --tag "$5" -
' _ "${tee_path}" "${consumed}" "${archive}" "${docker_path}" \
    "${tag}" 2>&1 |
    "${head_path}" -c "$((MAX_BUILD_LOG_BYTES + 1))" >"${temporary}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  consumed_sha="$(verify_context_stream_identity \
    "${archive}" "${consumed}" "${archive_sha}")" || return
  if ! assert_context_identity "${snapshot}" "${snapshot_manifest}" \
    "${CONTEXT_MANIFEST_SHA256}" || ! verify_canonical_context_identity; then
    printf 'FAIL  reference-build guarded context changed during Docker build\n' >&2 || return
    return 1
  fi
  size="$(run_host_command wc -c <"${temporary}")" || {
    return 1
  }
  if [[ "${pipeline_status[1]}" -ne 0 || "${size}" -gt "${MAX_BUILD_LOG_BYTES}" ]]; then
    printf 'FAIL  reference-build Docker build log exceeded its capture boundary\n' >&2 || return
    return 1
  fi
  if [[ "${pipeline_status[0]}" -ne 0 ]]; then
    run_host_command sed -n '1,160p' "${temporary}" >&2 || return
    printf 'FAIL  reference-build Docker build failed with status %s\n' \
      "${pipeline_status[0]}" >&2 || return
    return 1
  fi
  log="$(prepare_state_file "${log_relative}")" || {
    return 1
  }
  if ! run_host_command mv -fT -- "${temporary}" "${log}"; then
    return 1
  fi
  temporary=""
  printf '%s %s %s\n' "${archive_sha}" "${consumed_sha}" "${archive_bytes}" || return
)

capture_image_build() {
  local tag="$1" log_relative="$2" log input_identity extra
  input_identity="$(capture_image_build_snapshot "${tag}" "${log_relative}")" || return
  read -r BUILD_CONTEXT_ARCHIVE_SHA256_CURRENT \
    BUILD_CONTEXT_STREAM_SHA256_CURRENT BUILD_CONTEXT_STREAM_BYTES_CURRENT \
    extra <<<"${input_identity}" || return
  if ! [[ "${BUILD_CONTEXT_ARCHIVE_SHA256_CURRENT}" =~ ^[0-9a-f]{64}$ &&
    "${BUILD_CONTEXT_STREAM_SHA256_CURRENT}" == "${BUILD_CONTEXT_ARCHIVE_SHA256_CURRENT}" &&
    "${BUILD_CONTEXT_STREAM_BYTES_CURRENT}" =~ ^[1-9][0-9]{0,8}$ &&
    -z "${extra}" ]]; then
    printf 'FAIL  reference-build malformed Docker input stream identity\n' >&2 || return
    return 1
  fi
  log="$(prepare_state_file "${log_relative}")" || return
  BUILD_LOG_PATH="${log}"
  BUILD_RESULT_CONFIG_ID="$(extract_result_config_id "${log}")" || return
}

require_result_matches_inspect() {
  local label="$1" result_config_id="$2" inspect_config_id="$3"
  if [[ "${result_config_id}" != "${inspect_config_id}" ]]; then
    printf 'FAIL  reference-build %s BuildKit result differs from inspected config identity\n' \
      "${label}" >&2 || return
    return 1
  fi
}

inspect_config_id() {
  local tag="$1"
  local identity
  identity="$(docker_command 20s image inspect --format '{{.Id}}' "${tag}")" || return
  if [[ ! "${identity}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'FAIL  reference-build malformed Docker config identity\n' >&2 || return
    return 1
  fi
  printf '%s\n' "${identity}" || return
}

inspect_repo_digests() {
  local tag="$1"
  local digests
  digests="$(docker_command 20s image inspect --format '{{join .RepoDigests ","}}' \
    "${tag}")" || return
  if [[ "${digests}" == *$'\n'* || "${digests}" == *$'\r'* || "${digests}" == *$'\t'* ]]; then
    printf 'FAIL  reference-build malformed RepoDigests evidence\n' >&2 || return
    return 1
  fi
  printf '%s\n' "${digests}" || return
}

measure_context_payload() {
  local dockerfile_bytes server_bytes
  dockerfile_bytes="$(run_host_command stat -c '%s' \
    "${REFERENCE_CONTEXT}/Dockerfile")" || return
  server_bytes="$(run_host_command stat -c '%s' \
    "${REFERENCE_CONTEXT}/server")" || return
  printf '%s\n' "$((dockerfile_bytes + server_bytes))" || return
}

prove_canary_exclusion() {
  local grep_status
  if [[ -e "${REFERENCE_CONTEXT}/${REFERENCE_CANARY_NAME}" ]]; then
    printf 'FAIL  reference-build outside-context canary entered the context contract\n' >&2 || return
    return 1
  fi
  if run_host_command grep -Fq "${REFERENCE_CANARY_NAME}" \
    "${REFERENCE_MANIFEST}"; then
    printf 'FAIL  reference-build outside-context canary entered the context contract\n' >&2 || return
    return 1
  else
    grep_status=$?
  fi
  if [[ "${grep_status}" -ne 1 ]]; then
    printf 'FAIL  reference-build unable to inspect context manifest for canary\n' >&2 || return
    return 1
  fi
  BUILD_CONTEXT_CANARY_EXCLUDED=true
}

write_build_environment() {
  local target temporary
  verify_canonical_context_identity || return
  target="$(prepare_state_file "reference/build.env")" || return
  temporary="$(run_host_command mktemp \
    "${REFERENCE_ROOT}/.build-env.XXXXXXXX")" || return
  printf '%s\n' \
    'SCHEMA=flare-platform-reference-build-v2' \
    "BUILD_SOURCE_COMMIT=${REFERENCE_SOURCE_COMMIT}" \
    "BUILD_SOURCE_TREE=${REFERENCE_SOURCE_TREE}" \
    'BUILD_SOURCE_SEMANTICS=git-commit-tree-snapshot' \
    "HOST_BINARY_SHA256=${HOST_BINARY_SHA256}" \
    "HOST_BINARY_SHA256_SECOND=${HOST_BINARY_SHA256_SECOND}" \
    'HOST_BINARY_REPRODUCIBLE=true' \
    "HOST_BINARY_BYTES=${HOST_BINARY_BYTES}" \
    "BUILD_CONTEXT_BYTES=${BUILD_CONTEXT_BYTES}" \
    "BUILD_CONTEXT_CANARY_EXCLUDED=${BUILD_CONTEXT_CANARY_EXCLUDED}" \
    'CONTEXT_MANIFEST_PATH=.platform/reference/context.manifest.tsv' \
    "CONTEXT_MANIFEST_SHA256=${CONTEXT_MANIFEST_SHA256}" \
    "BUILD_CONTEXT_ARCHIVE_SHA256=${BUILD_CONTEXT_ARCHIVE_SHA256}" \
    "BUILD_CONTEXT_STREAM_SHA256_FIRST=${BUILD_CONTEXT_STREAM_SHA256_FIRST}" \
    "BUILD_CONTEXT_STREAM_SHA256_SECOND=${BUILD_CONTEXT_STREAM_SHA256_SECOND}" \
    "BUILD_CONTEXT_STREAM_BYTES_FIRST=${BUILD_CONTEXT_STREAM_BYTES_FIRST}" \
    "BUILD_CONTEXT_STREAM_BYTES_SECOND=${BUILD_CONTEXT_STREAM_BYTES_SECOND}" \
    'BUILD_CONTEXT_INPUT_SEMANTICS=tee-captured-deterministic-tar' \
    "TEMP_IMAGE_TAG=${TEMP_IMAGE_TAG}" \
    "FINAL_IMAGE_TAG=${PLATFORM_IMAGE}" \
    "DOCKER_CONFIG_ID_FIRST=${DOCKER_CONFIG_ID_FIRST}" \
    "DOCKER_CONFIG_ID_SECOND=${DOCKER_CONFIG_ID_SECOND}" \
    "DOCKER_CONFIG_IDENTICAL=${DOCKER_CONFIG_IDENTICAL}" \
    "DOCKER_REPO_DIGESTS=${DOCKER_REPO_DIGESTS}" \
    'DOCKER_IDENTITY_SEMANTICS=docker-config-digest' \
    'BUILD_LOG_FIRST_PATH=.platform/reference/docker-build-first.log' \
    "BUILD_LOG_FIRST_SHA256=${BUILD_LOG_FIRST_SHA256}" \
    "BUILD_LOG_FIRST_RESULT_CONFIG_ID=${BUILD_LOG_FIRST_RESULT_CONFIG_ID}" \
    'BUILD_LOG_SECOND_PATH=.platform/reference/docker-build-second.log' \
    "BUILD_LOG_SECOND_SHA256=${BUILD_LOG_SECOND_SHA256}" \
    "BUILD_LOG_SECOND_RESULT_CONFIG_ID=${BUILD_LOG_SECOND_RESULT_CONFIG_ID}" \
    >"${temporary}" || {
    run_host_command rm -f -- "${temporary}" || return
    return 1
  }
  local environment_bytes
  environment_bytes="$(run_host_command wc -c <"${temporary}")" || {
    run_host_command rm -f -- "${temporary}" || return
    return 1
  }
  if [[ "${environment_bytes}" -gt 8192 ]]; then
    run_host_command rm -f -- "${temporary}" || return
    printf 'FAIL  reference-build build.env exceeded 8192 bytes\n' >&2 || return
    return 1
  fi
  if ! verify_canonical_context_identity; then
    run_host_command rm -f -- "${temporary}" || return
    printf 'FAIL  reference-build context changed before build evidence publication\n' \
      >&2 || return
    return 1
  fi
  target="$(prepare_state_file "reference/build.env")" || {
    run_host_command rm -f -- "${temporary}" || return
    return 1
  }
  if ! run_host_command mv -fT -- "${temporary}" "${target}"; then
    run_host_command rm -f -- "${temporary}" || return
    return 1
  fi
}

main() (
  local canary first_binary second_binary source_snapshot="" source_directory
  trap '[[ -z "${source_snapshot}" ]] || run_host_command rm -rf -- "${source_snapshot}"' EXIT
  lifecycle_lease_assert || return
  docker_target_ensure || return
  host_command_path git >/dev/null || return
  host_command_path tar >/dev/null || return
  resolve_reference_source_identity || return
  reset_state_directory "reference" || return
  source_snapshot="$(stage_reference_source_snapshot)" || return
  source_directory="${source_snapshot}/kubernetes/reference/server"
  # Consumed by the sourced reference-context module.
  # shellcheck disable=SC2034
  REFERENCE_DOCKERFILE="${source_snapshot}/kubernetes/reference/Dockerfile"
  printf 'INFO  reference-build source_commit=%s source_tree=%s\n' \
    "${REFERENCE_SOURCE_COMMIT}" "${REFERENCE_SOURCE_TREE}" || return
  canary="$(prepare_state_file "reference/${REFERENCE_CANARY_NAME}")" || return
  printf 'this file must remain outside the Docker build context\n' >"${canary}" || return
  first_binary="$(prepare_state_file "reference/server-first")" || return
  second_binary="$(prepare_state_file "reference/server-second")" || return
  build_host_binary "${first_binary}" "reference/go-cache-first" "${source_directory}" || return
  build_host_binary "${second_binary}" "reference/go-cache-second" "${source_directory}" || return
  prove_host_binary_reproducibility "${first_binary}" "${second_binary}" || return
  stage_context "${first_binary}" || return
  CONTEXT_MANIFEST_SHA256="$(context_identity_sha256 \
    "${REFERENCE_CONTEXT}" "${REFERENCE_MANIFEST}")" || return
  prove_canary_exclusion || return
  BUILD_CONTEXT_BYTES="$(measure_context_payload)" || return

  capture_image_build "${TEMP_IMAGE_TAG}" "reference/docker-build-first.log" || return
  BUILD_CONTEXT_ARCHIVE_SHA256="${BUILD_CONTEXT_ARCHIVE_SHA256_CURRENT}"
  BUILD_CONTEXT_STREAM_SHA256_FIRST="${BUILD_CONTEXT_STREAM_SHA256_CURRENT}"
  BUILD_CONTEXT_STREAM_BYTES_FIRST="${BUILD_CONTEXT_STREAM_BYTES_CURRENT}"
  BUILD_LOG_FIRST_SHA256="$(hash_file "${BUILD_LOG_PATH}")" || return
  BUILD_LOG_FIRST_RESULT_CONFIG_ID="${BUILD_RESULT_CONFIG_ID}"
  DOCKER_CONFIG_ID_FIRST="$(inspect_config_id "${TEMP_IMAGE_TAG}")" || return
  require_result_matches_inspect first "${BUILD_LOG_FIRST_RESULT_CONFIG_ID}" \
    "${DOCKER_CONFIG_ID_FIRST}" || return

  verify_canonical_context_identity || return
  capture_image_build "${PLATFORM_IMAGE}" "reference/docker-build-second.log" || return
  BUILD_CONTEXT_STREAM_SHA256_SECOND="${BUILD_CONTEXT_STREAM_SHA256_CURRENT}"
  BUILD_CONTEXT_STREAM_BYTES_SECOND="${BUILD_CONTEXT_STREAM_BYTES_CURRENT}"
  if [[ "${BUILD_CONTEXT_ARCHIVE_SHA256_CURRENT}" != "${BUILD_CONTEXT_ARCHIVE_SHA256}" ||
    "${BUILD_CONTEXT_STREAM_SHA256_SECOND}" != "${BUILD_CONTEXT_ARCHIVE_SHA256}" ]]; then
    printf 'FAIL  reference-build Docker input streams are not reproducible\n' >&2 || return
    return 1
  fi
  BUILD_LOG_SECOND_SHA256="$(hash_file "${BUILD_LOG_PATH}")" || return
  BUILD_LOG_SECOND_RESULT_CONFIG_ID="${BUILD_RESULT_CONFIG_ID}"
  DOCKER_CONFIG_ID_SECOND="$(inspect_config_id "${PLATFORM_IMAGE}")" || return
  require_result_matches_inspect second "${BUILD_LOG_SECOND_RESULT_CONFIG_ID}" \
    "${DOCKER_CONFIG_ID_SECOND}" || return
  DOCKER_REPO_DIGESTS="$(inspect_repo_digests "${PLATFORM_IMAGE}")" || return
  if [[ "${DOCKER_CONFIG_ID_FIRST}" == "${DOCKER_CONFIG_ID_SECOND}" ]]; then
    DOCKER_CONFIG_IDENTICAL=true
  else
    DOCKER_CONFIG_IDENTICAL=false
  fi
  write_build_environment || return
  docker_command 20s image rm "${TEMP_IMAGE_TAG}" >/dev/null || return
  printf 'PASS  image         %s binary_sha256=%s config_identical=%s\n' \
    "${PLATFORM_IMAGE}" "${HOST_BINARY_SHA256}" "${DOCKER_CONFIG_IDENTICAL}" || return
  printf 'INFO  image         context_stream_first=%sB context_stream_second=%sB\n' \
    "${BUILD_CONTEXT_STREAM_BYTES_FIRST}" "${BUILD_CONTEXT_STREAM_BYTES_SECOND}" || return
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit $?
fi
