#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/identity.sh"

POSITIVE_KEYS=(
  SCHEMA SOURCE_COMMIT SOURCE_TREE SOURCE_WORKTREE_CLEAN
  HOST_BINARY_SHA256 HOST_BINARY_SHA256_SECOND HOST_BINARY_REPRODUCIBLE
  HOST_BINARY_BYTES CONTEXT_MANIFEST_PATH CONTEXT_MANIFEST_SHA256
  BUILD_CONTEXT_BYTES BUILD_CONTEXT_CANARY_EXCLUDED
  DOCKER_CONFIG_ID_FIRST DOCKER_CONFIG_ID_SECOND DOCKER_CONFIG_IDENTICAL
  DOCKER_REPO_DIGESTS DOCKER_IDENTITY_SEMANTICS
  BUILD_LOG_FIRST_SHA256 BUILD_LOG_FIRST_RESULT_CONFIG_ID BUILD_LOG_FIRST_CONTEXT_TRANSFER
  BUILD_LOG_SECOND_SHA256 BUILD_LOG_SECOND_RESULT_CONFIG_ID BUILD_LOG_SECOND_CONTEXT_TRANSFER
  POD_IMAGE_ID POD_IMAGE_ID_SEMANTICS DOCKER_VS_POD_COMPARABLE
  RUNNING_EXECUTABLE_SHA256 HEALTH_RESPONSE SELECTED_IPV4_PORT
  PORT_FORWARD_CLEANUP PORT_FORWARD_PID_ABSENT NAMESPACE_ABSENT CLUSTER_CLEANUP
)
STALE_KEYS=(
  SCHEMA HOST_BINARY_SHA256_A HOST_BINARY_SHA256_B
  CONTEXT_MANIFEST_SHA256_A CONTEXT_MANIFEST_SHA256_B
  DOCKER_CONFIG_ID_A DOCKER_CONFIG_ID_B B_EXECUTABLE_STATUS B_STARTUP_MARKER
  RUNNING_EXECUTABLE_SHA256 EXPECTED_EXECUTABLE_SHA256
  MISMATCH MISMATCH_STATUS MISMATCH_REASON POD_IMAGE_ID POD_IMAGE_ID_SEMANTICS
  DOCKER_VS_POD_COMPARABLE HEALTH_RESPONSE SELECTED_IPV4_PORT
  PORT_FORWARD_CLEANUP PORT_FORWARD_PORT_ABSENT PORT_FORWARD_PID_ABSENT
  NAMESPACE_ABSENT ORDER_PROOF
)
NEGATIVE_KEYS=(SCHEMA STARTUP_MARKER NAMESPACE_ABSENT)
EXPECTED_STALE_ORDER='canonical-a-build,canonical-a-load,stale-b-derive,stale-b-exec,'
EXPECTED_STALE_ORDER+='invalidate-a-build-record,stale-b-build-local-only,deploy-loaded-a'

evidence_failure() {
  printf 'FAIL  runtime-proof %s\n' "$1" >&2
  return 1
}

assert_no_nul_bytes() {
  local file="$1" bytes="$2" dump compact
  dump="$(od -An -v -tx1 -- "${file}")" || return
  compact="$(printf '%s' "${dump}" | tr -d '[:space:]')" || return
  if [[ "${dump}" =~ (^|[[:space:]])00([[:space:]]|$) ]] ||
    ((${#compact} != bytes * 2)); then
    evidence_failure 'journey evidence contains unsupported binary bytes' || return
  fi
}

assert_key_order() {
  local file="$1" schema="$2" maximum="$3"
  local bytes expected_count index line_count
  local -a actual=()
  shift 3
  expected_count=$#
  if [[ -L "${file}" || ! -f "${file}" ]]; then
    evidence_failure 'required journey evidence is missing or unsafe' || return
  fi
  bytes="$(wc -c <"${file}")" || return
  line_count="$(wc -l <"${file}")" || return
  if ((bytes < 1 || bytes > maximum || line_count != expected_count)); then
    evidence_failure 'journey evidence exceeds its exact record boundary' || return
  fi
  assert_no_nul_bytes "${file}" "${bytes}" || return
  mapfile -t actual < <(cut -d= -f1 -- "${file}") || return
  if ((${#actual[@]} != expected_count)); then
    evidence_failure 'journey evidence key count is not exact' || return
  fi
  for ((index = 0; index < expected_count; index++)); do
    if [[ "${actual[${index}]}" != "${1}" ]]; then
      evidence_failure 'journey evidence key order is not exact' || return
    fi
    shift
  done
  if [[ "$(sed -n '1p' -- "${file}")" != "SCHEMA=${schema}" ]] ||
    ! bash -n "${file}"; then
    evidence_failure 'journey evidence schema or shell encoding is invalid' || return
  fi
}

evidence_value() {
  local file="$1" requested="$2" line key
  while IFS= read -r line; do
    key="${line%%=*}"
    if [[ "${key}" == "${requested}" ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"${file}"
  evidence_failure "missing evidence key: ${requested}" || return
}

assert_positive_formats() {
  local file="$1" source_commit source_tree source_clean manifest_sha manifest_path
  local log_first_sha log_second_sha transfer_first transfer_second pod_image_id
  local transfer_pattern='^[0-9]+([.][0-9]+)?[kMGT]?B$'
  source_commit="$(evidence_value "${file}" SOURCE_COMMIT)" || return
  source_tree="$(evidence_value "${file}" SOURCE_TREE)" || return
  source_clean="$(evidence_value "${file}" SOURCE_WORKTREE_CLEAN)" || return
  manifest_path="$(evidence_value "${file}" CONTEXT_MANIFEST_PATH)" || return
  manifest_sha="$(evidence_value "${file}" CONTEXT_MANIFEST_SHA256)" || return
  log_first_sha="$(evidence_value "${file}" BUILD_LOG_FIRST_SHA256)" || return
  log_second_sha="$(evidence_value "${file}" BUILD_LOG_SECOND_SHA256)" || return
  transfer_first="$(evidence_value "${file}" BUILD_LOG_FIRST_CONTEXT_TRANSFER)" || return
  transfer_second="$(evidence_value "${file}" BUILD_LOG_SECOND_CONTEXT_TRANSFER)" || return
  pod_image_id="$(evidence_value "${file}" POD_IMAGE_ID)" || return
  if [[ ! "${source_commit}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${source_tree}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${source_clean}" =~ ^(true|false)$ ||
    "${manifest_path}" != .platform/reference/context.manifest.tsv ||
    ! "${manifest_sha}" =~ ^[0-9a-f]{64}$ ||
    ! "${log_first_sha}" =~ ^[0-9a-f]{64}$ ||
    ! "${log_second_sha}" =~ ^[0-9a-f]{64}$ ||
    ! "${transfer_first}" =~ ${transfer_pattern} ||
    ! "${transfer_second}" =~ ${transfer_pattern} ||
    ! "${pod_image_id}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ]]; then
    evidence_failure 'positive journey field encoding is unsafe or malformed' || return
  fi
}

assert_positive_semantics() {
  local file="$1" first second running identical port host_bytes context_bytes
  local docker_first docker_second
  local build_result_first build_result_second
  assert_positive_formats "${file}" || return
  first="$(evidence_value "${file}" HOST_BINARY_SHA256)" || return
  second="$(evidence_value "${file}" HOST_BINARY_SHA256_SECOND)" || return
  running="$(evidence_value "${file}" RUNNING_EXECUTABLE_SHA256)" || return
  identical="$(evidence_value "${file}" DOCKER_CONFIG_IDENTICAL)" || return
  host_bytes="$(evidence_value "${file}" HOST_BINARY_BYTES)" || return
  context_bytes="$(evidence_value "${file}" BUILD_CONTEXT_BYTES)" || return
  port="$(evidence_value "${file}" SELECTED_IPV4_PORT)" || return
  docker_first="$(evidence_value "${file}" DOCKER_CONFIG_ID_FIRST)" || return
  docker_second="$(evidence_value "${file}" DOCKER_CONFIG_ID_SECOND)" || return
  build_result_first="$(evidence_value "${file}" BUILD_LOG_FIRST_RESULT_CONFIG_ID)" || return
  build_result_second="$(evidence_value "${file}" BUILD_LOG_SECOND_RESULT_CONFIG_ID)" || return
  runtime_identity_is_sha256 "${first}" || return 1
  if [[ "${first}" != "${second}" ]] || [[ "${first}" != "${running}" ||
    ! "${docker_first}" =~ ^sha256:[0-9a-f]{64}$ ||
    ! "${docker_second}" =~ ^sha256:[0-9a-f]{64}$ ||
    "${build_result_first}" != "${docker_first}" ||
    "${build_result_second}" != "${docker_second}" ||
    "$(evidence_value "${file}" HOST_BINARY_REPRODUCIBLE)" != true ||
    "$(evidence_value "${file}" BUILD_CONTEXT_CANARY_EXCLUDED)" != true ||
    "$(evidence_value "${file}" DOCKER_REPO_DIGESTS)" != "" ||
    "$(evidence_value "${file}" DOCKER_IDENTITY_SEMANTICS)" != docker-config-digest ||
    "$(evidence_value "${file}" POD_IMAGE_ID_SEMANTICS)" != cri-reported-non-comparable-to-local-config-id ||
    "$(evidence_value "${file}" DOCKER_VS_POD_COMPARABLE)" != false ||
    "$(evidence_value "${file}" HEALTH_RESPONSE)" != ok ||
    "$(evidence_value "${file}" PORT_FORWARD_CLEANUP)" != absent ||
    "$(evidence_value "${file}" PORT_FORWARD_PID_ABSENT)" != true ||
    "$(evidence_value "${file}" NAMESPACE_ABSENT)" != true ||
    "$(evidence_value "${file}" CLUSTER_CLEANUP)" != deferred-to-verify-runtime ]]; then
    evidence_failure 'positive journey semantics are inconsistent' || return
  fi
  if [[ "${identical}" == true && "${docker_first}" != "${docker_second}" ]] ||
    [[ "${identical}" == false && "${docker_first}" == "${docker_second}" ]]; then
    evidence_failure 'positive Docker determinism evidence is inconsistent' || return
  fi
  if [[ ! "${identical}" =~ ^(true|false)$ || ! "${port}" =~ ^[0-9]{1,5}$ ||
    ! "${host_bytes}" =~ ^[1-9][0-9]{0,8}$ ||
    ! "${context_bytes}" =~ ^[1-9][0-9]{0,8}$ ]] ||
    ((10#${port} < 1 || 10#${port} > 65535 || host_bytes >= context_bytes)); then
    evidence_failure 'positive numeric evidence is inconsistent' || return
  fi
}

assert_stale_formats() {
  local file="$1" config_a config_b pod_image_id port order manifest_a manifest_b
  config_a="$(evidence_value "${file}" DOCKER_CONFIG_ID_A)" || return
  config_b="$(evidence_value "${file}" DOCKER_CONFIG_ID_B)" || return
  pod_image_id="$(evidence_value "${file}" POD_IMAGE_ID)" || return
  port="$(evidence_value "${file}" SELECTED_IPV4_PORT)" || return
  order="$(evidence_value "${file}" ORDER_PROOF)" || return
  manifest_a="$(evidence_value "${file}" CONTEXT_MANIFEST_SHA256_A)" || return
  manifest_b="$(evidence_value "${file}" CONTEXT_MANIFEST_SHA256_B)" || return
  if [[ ! "${config_a}" =~ ^sha256:[0-9a-f]{64}$ ||
    ! "${config_b}" =~ ^sha256:[0-9a-f]{64}$ || "${config_a}" == "${config_b}" ||
    ! "${pod_image_id}" =~ ^[A-Za-z0-9._:/@+-]{1,512}$ ||
    ! "${port}" =~ ^[0-9]{1,5}$ || "${manifest_a}" == "${manifest_b}" ||
    "$(evidence_value "${file}" POD_IMAGE_ID_SEMANTICS)" != cri-reported-non-comparable-to-local-config-id ||
    "${order}" != "${EXPECTED_STALE_ORDER}" ]]; then
    evidence_failure 'stale mutable-tag field encoding is unsafe or malformed' || return
  fi
  if ((10#${port} < 1 || 10#${port} > 65535)); then
    evidence_failure 'stale mutable-tag selected port is out of range' || return
  fi
}

assert_stale_semantics() {
  local file="$1" actual expected mismatch_reason startup_marker manifest_a manifest_b
  assert_stale_formats "${file}" || return
  actual="$(evidence_value "${file}" RUNNING_EXECUTABLE_SHA256)" || return
  expected="$(evidence_value "${file}" EXPECTED_EXECUTABLE_SHA256)" || return
  manifest_a="$(evidence_value "${file}" CONTEXT_MANIFEST_SHA256_A)" || return
  manifest_b="$(evidence_value "${file}" CONTEXT_MANIFEST_SHA256_B)" || return
  printf -v mismatch_reason '%q' 'FAIL  runtime-id    running binary SHA-256 mismatch'
  printf -v startup_marker '%q' 'intentional startup failure requested'
  runtime_identity_is_sha256 "${actual}" || return 1
  runtime_identity_is_sha256 "${expected}" || return 1
  runtime_identity_is_sha256 "${manifest_a}" || return 1
  runtime_identity_is_sha256 "${manifest_b}" || return 1
  if [[ "${actual}" != "$(evidence_value "${file}" HOST_BINARY_SHA256_A)" ||
  "${expected}" != "$(evidence_value "${file}" HOST_BINARY_SHA256_B)" ||
  "${actual}" == "${expected}" ||
  "$(evidence_value "${file}" B_EXECUTABLE_STATUS)" != 42 ||
  "$(evidence_value "${file}" B_STARTUP_MARKER)" != "${startup_marker}" ||
  "$(evidence_value "${file}" MISMATCH)" != true ||
  "$(evidence_value "${file}" MISMATCH_STATUS)" != 74 ||
  "$(evidence_value "${file}" MISMATCH_REASON)" != "${mismatch_reason}" ||
  "$(evidence_value "${file}" DOCKER_VS_POD_COMPARABLE)" != false ||
  "$(evidence_value "${file}" HEALTH_RESPONSE)" != ok ||
  "$(evidence_value "${file}" PORT_FORWARD_CLEANUP)" != absent ||
  "$(evidence_value "${file}" PORT_FORWARD_PORT_ABSENT)" != true ||
  "$(evidence_value "${file}" PORT_FORWARD_PID_ABSENT)" != true ||
  "$(evidence_value "${file}" NAMESPACE_ABSENT)" != true ]]; then
    evidence_failure 'stale mutable-tag RED semantics are inconsistent' || return
  fi
}

snapshot_evidence() {
  local source="$1" label="$2" maximum="$3" bytes snapshot
  if [[ -L "${source}" || ! -f "${source}" ]]; then
    evidence_failure 'required journey evidence is missing or unsafe' || return
  fi
  bytes="$(stat -c '%s' "${source}")" || return
  if ((bytes < 1 || bytes > maximum)); then
    evidence_failure 'journey evidence exceeds its snapshot boundary' || return
  fi
  snapshot="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.${label}.XXXXXXXX")" || return
  if ! timeout --signal=TERM --kill-after=1s 5s \
    head -c "$((maximum + 1))" -- "${source}" >"${snapshot}"; then
    rm -f -- "${snapshot}" || return
    evidence_failure 'unable to snapshot journey evidence' || return
  fi
  bytes="$(stat -c '%s' "${snapshot}")" || {
    rm -f -- "${snapshot}" || return
    return 1
  }
  if ((bytes < 1 || bytes > maximum)); then
    rm -f -- "${snapshot}" || return
    evidence_failure 'journey evidence changed while being snapshotted' || return
  fi
  printf '%s\n' "${snapshot}"
}

assert_source_matches_snapshot() {
  local source="$1" snapshot="$2"
  if [[ -L "${source}" || ! -f "${source}" ]] ||
    ! timeout --signal=TERM --kill-after=1s 5s cmp --silent -- "${source}" "${snapshot}"; then
    evidence_failure 'journey evidence changed during aggregate publication' || return
  fi
}

assert_negative_semantics() {
  local file="$1" startup_marker
  printf -v startup_marker '%q' 'intentional startup failure requested'
  if [[ "$(evidence_value "${file}" STARTUP_MARKER)" != "${startup_marker}" ||
  "$(evidence_value "${file}" NAMESPACE_ABSENT)" != true ]]; then
    evidence_failure 'negative startup journey semantics are inconsistent' || return
  fi
}

prefix_evidence() {
  local prefix="$1" file="$2" line
  while IFS= read -r line; do
    printf '%s%s\n' "${prefix}" "${line}" || return
  done <"${file}"
}

render_aggregate() {
  local positive="$1" stale="$2" negative="$3" final_state="$4" repeated_state="$5"
  local positive_sha stale_sha negative_sha
  positive_sha="$(sha256sum -- "${positive}" | awk '{print $1}')" || return
  stale_sha="$(sha256sum -- "${stale}" | awk '{print $1}')" || return
  negative_sha="$(sha256sum -- "${negative}" | awk '{print $1}')" || return
  printf 'SCHEMA=flare-platform-runtime-identity-evidence-v1\n'
  printf 'POSITIVE_EVIDENCE_SHA256=%s\nSTALE_EVIDENCE_SHA256=%s\n' \
    "${positive_sha}" "${stale_sha}"
  printf 'NEGATIVE_EVIDENCE_SHA256=%s\n' "${negative_sha}"
  printf 'CLUSTER_AFTER_FINAL_TEARDOWN=%s\n' "${final_state}"
  printf 'CLUSTER_AFTER_IDEMPOTENT_TEARDOWN=%s\n' "${repeated_state}"
  prefix_evidence POSITIVE_ "${positive}" || return
  prefix_evidence STALE_ "${stale}" || return
  prefix_evidence NEGATIVE_ "${negative}" || return
}

publish_aggregate() (
  local final_state="$1" repeated_state="$2"
  local positive="${PLATFORM_STATE_DIR}/runtime-identity/positive.env"
  local stale="${PLATFORM_STATE_DIR}/runtime-identity/stale.env"
  local negative="${PLATFORM_STATE_DIR}/runtime-identity/negative.env"
  local positive_snapshot="" stale_snapshot="" negative_snapshot=""
  local target temporary="" bytes prepared
  trap 'rm -f -- "${positive_snapshot}" "${stale_snapshot}" "${negative_snapshot}" "${temporary}"' EXIT
  positive_snapshot="$(snapshot_evidence "${positive}" positive-snapshot 8192)" || return
  stale_snapshot="$(snapshot_evidence "${stale}" stale-snapshot 8192)" || return
  negative_snapshot="$(snapshot_evidence "${negative}" negative-snapshot 1024)" || return
  assert_key_order "${positive_snapshot}" flare-platform-runtime-identity-positive-v1 8192 \
    "${POSITIVE_KEYS[@]}" || return
  assert_key_order "${stale_snapshot}" flare-platform-runtime-identity-stale-v1 8192 \
    "${STALE_KEYS[@]}" || return
  assert_key_order "${negative_snapshot}" flare-platform-runtime-identity-negative-v1 1024 \
    "${NEGATIVE_KEYS[@]}" || return
  assert_positive_semantics "${positive_snapshot}" || return
  assert_stale_semantics "${stale_snapshot}" || return
  assert_negative_semantics "${negative_snapshot}" || return
  target="$(prepare_state_file 'runtime-identity/evidence.env')" || return
  temporary="$(mktemp "${PLATFORM_STATE_DIR}/runtime-identity/.evidence.XXXXXXXX")" || return
  if ! render_aggregate "${positive_snapshot}" "${stale_snapshot}" "${negative_snapshot}" \
    "${final_state}" "${repeated_state}" >"${temporary}"; then
    rm -f -- "${temporary}" || return
    return 1
  fi
  bytes="$(wc -c <"${temporary}")" || {
    rm -f -- "${temporary}" || return
    return 1
  }
  if ((bytes > 32768)) || ! bash -n "${temporary}"; then
    rm -f -- "${temporary}" || return
    evidence_failure 'aggregate runtime evidence is unsafe or oversized' || return
  fi
  assert_source_matches_snapshot "${positive}" "${positive_snapshot}" || return
  assert_source_matches_snapshot "${stale}" "${stale_snapshot}" || return
  assert_source_matches_snapshot "${negative}" "${negative_snapshot}" || return
  prepared="$(prepare_state_file 'runtime-identity/evidence.env')" || {
    rm -f -- "${temporary}" || return
    return 1
  }
  if [[ "${prepared}" != "${target}" ]] || ! mv -fT -- "${temporary}" "${target}"; then
    rm -f -- "${temporary}" || return
    evidence_failure 'unable to publish aggregate runtime evidence atomically' || return
  fi
  temporary=""
  printf 'PASS  runtime-proof aggregate_evidence=%s bytes=%s\n' "${target}" "${bytes}"
)

main() {
  if [[ $# -ne 2 || "$1" != absent || "$2" != absent ]]; then
    evidence_failure 'usage: publish-runtime-evidence.sh absent absent' || return
  fi
  publish_aggregate "$1" "$2"
}

main "$@"
