#!/usr/bin/env bash
# Proof helpers deliberately isolate mutable fixtures in subshells.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/identity.sh"

PROOF_DIRECTORY=""
SHA_A="$(printf 'a%.0s' {1..64})"
SHA_B="$(printf 'b%.0s' {1..64})"

expect_identity_failure() {
  local label="$1" expected_status="$2" expected_output="$3"
  local output actual_status
  shift 3
  set +e
  output="$("$@" 2>&1)"
  actual_status=$?
  set -e
  if [[ "${actual_status}" -ne "${expected_status}" || "${output}" != "${expected_output}" ]]; then
    printf 'FAIL  runtime-red   %s status=%s output=%q\n' \
      "${label}" "${actual_status}" "${output}" >&2
    return 1
  fi
  printf 'PASS  runtime-red   %s exact_status=%s\n' "${label}" "${actual_status}"
}

write_build_env_fixture() {
  local target="$1"
  {
    printf 'SCHEMA=flare-platform-reference-build-v2\n'
    printf 'BUILD_SOURCE_COMMIT=%s\n' "$(printf '2%.0s' {1..40})"
    printf 'BUILD_SOURCE_TREE=%s\n' "$(printf '3%.0s' {1..40})"
    printf 'BUILD_SOURCE_SEMANTICS=git-commit-tree-snapshot\n'
    printf 'HOST_BINARY_SHA256=%s\n' "${SHA_A}"
    printf 'HOST_BINARY_SHA256_SECOND=%s\n' "${SHA_A}"
    printf 'HOST_BINARY_REPRODUCIBLE=true\n'
    printf 'HOST_BINARY_BYTES=7\n'
    printf 'CONTEXT_MANIFEST_PATH=.platform/reference/context.manifest.tsv\n'
    printf 'CONTEXT_MANIFEST_SHA256=%s\n' "$(printf 'c%.0s' {1..64})"
    printf 'BUILD_CONTEXT_ARCHIVE_SHA256=%s\n' "$(printf '4%.0s' {1..64})"
    printf 'BUILD_CONTEXT_STREAM_SHA256_FIRST=%s\n' "$(printf '4%.0s' {1..64})"
    printf 'BUILD_CONTEXT_STREAM_SHA256_SECOND=%s\n' "$(printf '4%.0s' {1..64})"
    printf 'BUILD_CONTEXT_STREAM_BYTES_FIRST=20\n'
    printf 'BUILD_CONTEXT_STREAM_BYTES_SECOND=20\n'
    printf 'BUILD_CONTEXT_INPUT_SEMANTICS=tee-captured-deterministic-tar\n'
    printf 'BUILD_CONTEXT_BYTES=20\n'
    printf 'BUILD_CONTEXT_CANARY_EXCLUDED=true\n'
    printf 'TEMP_IMAGE_TAG=flare-platform-reference:identity-first\n'
    printf 'FINAL_IMAGE_TAG=%s\n' "${PLATFORM_IMAGE}"
    printf 'DOCKER_CONFIG_ID_FIRST=sha256:%s\n' "$(printf 'd%.0s' {1..64})"
    printf 'DOCKER_CONFIG_ID_SECOND=sha256:%s\n' "$(printf 'e%.0s' {1..64})"
    printf 'DOCKER_CONFIG_IDENTICAL=false\n'
    printf 'DOCKER_REPO_DIGESTS=\n'
    printf 'DOCKER_IDENTITY_SEMANTICS=docker-config-digest\n'
    printf 'BUILD_LOG_FIRST_PATH=.platform/reference/docker-build-first.log\n'
    printf 'BUILD_LOG_FIRST_SHA256=%s\n' "$(printf 'f%.0s' {1..64})"
    printf 'BUILD_LOG_FIRST_RESULT_CONFIG_ID=sha256:%s\n' "$(printf 'd%.0s' {1..64})"
    printf 'BUILD_LOG_SECOND_PATH=.platform/reference/docker-build-second.log\n'
    printf 'BUILD_LOG_SECOND_SHA256=%s\n' "$(printf '1%.0s' {1..64})"
    printf 'BUILD_LOG_SECOND_RESULT_CONFIG_ID=sha256:%s\n' "$(printf 'e%.0s' {1..64})"
  } >"${target}"
}

prove_identity_response_reds() {
  local malformed="${PROOF_DIRECTORY}/malformed.response"
  local nul_health="${PROOF_DIRECTORY}/nul.health"
  local nul_identity="${PROOF_DIRECTORY}/nul.identity"
  printf '%s\n' "${SHA_A^^}" >"${malformed}"
  printf 'ok\0' >"${nul_health}"
  printf '%s\0' "${SHA_A}" >"${nul_identity}"
  expect_identity_failure mismatch "${RUNTIME_IDENTITY_MISMATCH_STATUS}" \
    'FAIL  runtime-id    running binary SHA-256 mismatch' \
    runtime_identity_compare "${SHA_A}" "${SHA_B}"
  expect_identity_failure malformed-response "${RUNTIME_IDENTITY_MALFORMED_STATUS}" \
    'FAIL  runtime-id    malformed identity response' \
    runtime_identity_parse_response "${malformed}"
  expect_identity_failure nul-health-terminator "${RUNTIME_IDENTITY_MALFORMED_STATUS}" \
    'FAIL  runtime-id    malformed health response' \
    runtime_identity_parse_health_response "${nul_health}"
  expect_identity_failure nul-identity-terminator "${RUNTIME_IDENTITY_MALFORMED_STATUS}" \
    'FAIL  runtime-id    malformed identity response' \
    runtime_identity_parse_response "${nul_identity}"
}

prove_build_env_contract() {
  local valid="${PROOF_DIRECTORY}/build.env"
  local nul_key="${PROOF_DIRECTORY}/nul-key.env"
  local unexpected="${PROOF_DIRECTORY}/unexpected.env"
  local repo_digest="${PROOF_DIRECTORY}/repo-digest.env"
  local canary="${PROOF_DIRECTORY}/canary.env"
  local result_mismatch="${PROOF_DIRECTORY}/result-mismatch.env"
  local stream_mismatch="${PROOF_DIRECTORY}/stream-mismatch.env"
  write_build_env_fixture "${valid}"
  runtime_identity_load_build_env "${valid}"
  {
    printf 'SC\0HEMA=flare-platform-reference-build-v2\n'
    tail -n +2 -- "${valid}"
  } >"${nul_key}"
  expect_identity_failure nul-build-key "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed build identity record' \
    runtime_identity_load_build_env "${nul_key}"
  sed 's/^SCHEMA=/UNEXPECTED_KEY=/' "${valid}" >"${unexpected}"
  expect_identity_failure unexpected-build-key "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    unexpected build identity key: UNEXPECTED_KEY' \
    runtime_identity_load_build_env "${unexpected}"
  sed "s|^DOCKER_REPO_DIGESTS=$|DOCKER_REPO_DIGESTS=local@sha256:${SHA_B}|" \
    "${valid}" >"${repo_digest}"
  expect_identity_failure nonempty-repo-digests "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed local Docker identity semantics' \
    runtime_identity_load_build_env "${repo_digest}"
  sed 's/^BUILD_CONTEXT_CANARY_EXCLUDED=true$/BUILD_CONTEXT_CANARY_EXCLUDED=false/' \
    "${valid}" >"${canary}"
  expect_identity_failure context-canary "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed build-context boundary identity' \
    runtime_identity_load_build_env "${canary}"
  sed "s|^BUILD_LOG_FIRST_RESULT_CONFIG_ID=.*$|BUILD_LOG_FIRST_RESULT_CONFIG_ID=sha256:${SHA_B}|" \
    "${valid}" >"${result_mismatch}"
  expect_identity_failure result-inspect-mismatch "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    Docker build result and inspect identity disagree' \
    runtime_identity_load_build_env "${result_mismatch}"
  sed "s/^BUILD_CONTEXT_STREAM_SHA256_SECOND=.*$/BUILD_CONTEXT_STREAM_SHA256_SECOND=${SHA_B}/" \
    "${valid}" >"${stream_mismatch}"
  expect_identity_failure stream-capture-mismatch "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed Docker input stream identity' \
    runtime_identity_load_build_env "${stream_mismatch}"
  runtime_identity_load_build_env "${valid}"
  runtime_identity_require_source \
    "$(printf '2%.0s' {1..40})" "$(printf '3%.0s' {1..40})"
  expect_identity_failure source-record-mismatch "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    build source differs from captured source revision' \
    runtime_identity_require_source "$(printf '9%.0s' {1..40})" "$(printf '3%.0s' {1..40})"
}

write_context_manifest_fixture() {
  local context="$1" manifest="$2"
  local dockerfile_sha server_sha
  dockerfile_sha="$(sha256sum -- "${context}/Dockerfile" | awk '{print $1}')" || return
  server_sha="$(sha256sum -- "${context}/server" | awk '{print $1}')" || return
  printf 'path\tmode\tsize\tsha256\n' >"${manifest}"
  printf 'Dockerfile\t0644\t%s\t%s\n' \
    "$(stat -c '%s' "${context}/Dockerfile")" "${dockerfile_sha}" >>"${manifest}"
  printf 'server\t0755\t%s\t%s\n' \
    "$(stat -c '%s' "${context}/server")" "${server_sha}" >>"${manifest}"
}

prove_context_file_hash_reds() (
  local context="${PROOF_DIRECTORY}/consumer-context"
  local manifest="${PROOF_DIRECTORY}/consumer-context.manifest.tsv"
  local dockerfile_bytes
  mkdir -p -- "${context}"
  printf 'FROM scratch\n' >"${context}/Dockerfile"
  printf 'server\n' >"${context}/server"
  chmod 0644 "${context}/Dockerfile"
  chmod 0755 "${context}/server"
  write_context_manifest_fixture "${context}" "${manifest}"
  RUNTIME_HOST_BINARY_SHA256="$(sha256sum -- "${context}/server" | awk '{print $1}')"
  RUNTIME_HOST_BINARY_BYTES="$(stat -c '%s' "${context}/server")"
  dockerfile_bytes="$(stat -c '%s' "${context}/Dockerfile")"
  RUNTIME_BUILD_CONTEXT_BYTES="$((dockerfile_bytes + RUNTIME_HOST_BINARY_BYTES))"
  RUNTIME_CONTEXT_MANIFEST_SHA256="$(sha256sum -- "${manifest}" | awk '{print $1}')"
  runtime_identity_verify_context_files "${context}" "${manifest}"

  printf 'SERVER\n' >"${context}/server"
  expect_identity_failure changed-server-same-size "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    build artifacts disagree with build identity record' \
    runtime_identity_verify_context_files "${context}" "${manifest}"
  printf 'server\n' >"${context}/server"
  printf 'FROM busybox\n' >"${context}/Dockerfile"
  expect_identity_failure changed-dockerfile-same-size "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    build artifacts disagree with build identity record' \
    runtime_identity_verify_context_files "${context}" "${manifest}"
)

prove_git_source_snapshot() (
  local expected="${PROOF_DIRECTORY}/expected-source"
  local snapshot="" source_root="${PROOF_DIRECTORY}/source-snapshot-root"
  local path
  source "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  REFERENCE_ROOT="${source_root}"
  mkdir -p -- "${REFERENCE_ROOT}"
  PLATFORM_REFERENCE_SOURCE_COMMIT="$(git -C "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{commit}')"
  PLATFORM_REFERENCE_SOURCE_TREE="$(git -C "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{tree}')"
  resolve_reference_source_identity
  snapshot="$(stage_reference_source_snapshot)"
  trap '[[ -z "${snapshot}" ]] || rm -rf -- "${snapshot}"' EXIT
  for path in kubernetes/reference/Dockerfile \
    kubernetes/reference/server/go.mod kubernetes/reference/server/main.go; do
    git -C "${PLATFORM_ROOT}" show "${REFERENCE_SOURCE_COMMIT}:${path}" >"${expected}"
    cmp --silent -- "${expected}" "${snapshot}/${path}"
  done
  PLATFORM_REFERENCE_SOURCE_TREE="$(printf 'f%.0s' {1..40})"
  expect_identity_failure source-tree-record-mismatch 1 \
    'FAIL  reference-build source commit/tree identity mismatch' \
    resolve_reference_source_identity
  printf 'PASS  runtime-id    build inputs materialized from captured Git commit/tree\n'
)

prove_docker_input_stream_red() (
  local archive="${PROOF_DIRECTORY}/context.tar"
  local consumed="${PROOF_DIRECTORY}/context.consumed.tar"
  local context="${PROOF_DIRECTORY}/archive-context" expected
  source "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  mkdir -p -- "${context}"
  printf 'FROM scratch\n' >"${context}/Dockerfile"
  printf 'server\n' >"${context}/server"
  chmod 0644 "${context}/Dockerfile"
  chmod 0755 "${context}/server"
  write_context_archive "${context}" "${archive}"
  expected="$(hash_file "${archive}")"
  tee "${consumed}" <"${archive}" >/dev/null
  [[ "$(verify_context_stream_identity "${archive}" "${consumed}" "${expected}")" == "${expected}" ]]
  printf X >>"${consumed}"
  expect_identity_failure changed-docker-input-stream 1 \
    'FAIL  reference-build Docker input stream bytes changed' \
    verify_context_stream_identity "${archive}" "${consumed}" "${expected}"
  printf 'PASS  runtime-id    exact tee-captured Docker input stream identity proved\n'
)

prove_reference_context_red() {
  local output
  output="$(bash "${PLATFORM_ROOT}/tools/kubernetes/reference-context.sh" prove)" || return
  if ! grep -Fqx 'PASS  reference-red coherent-context-change' <<<"${output}" ||
    ! grep -Fqx 'PASS  reference-red unexpected-file' <<<"${output}"; then
    printf 'FAIL  runtime-red   canonical unexpected-context RED was not proved\n' >&2
    return 1
  fi
  printf 'PASS  runtime-red   canonical TSV context verifier exact RED\n'
}

prove_dynamic_port_contract() {
  local log="${PROOF_DIRECTORY}/port-forward.log"
  local selected fixed_port='180''80'
  printf 'Forwarding from 127.0.0.1:43127 -> 8080\nHandling connection for 8080\n' >"${log}"
  selected="$(runtime_identity_parse_port "${log}")"
  if [[ "${selected}" != 43127 ]]; then
    printf 'FAIL  runtime-id    selected dynamic port was not parsed exactly\n' >&2
    return 1
  fi
  if grep -Fq "${fixed_port}" "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh" \
    "${PLATFORM_ROOT}/tools/kubernetes/identity.sh"; then
    printf 'FAIL  runtime-id    fixed probe port survived in runtime consumer\n' >&2
    return 1
  fi
  grep -Fq -- '--address=127.0.0.1' "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh"
  grep -Fq -- 'service/platform-reference :8080' "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh"
  printf 'PASS  runtime-id    dynamic IPv4 port selection and probe contract\n'
}

surviving_process_red_case() (
  runtime_identity_process_or_group_exists() { return 0; }
  runtime_identity_signal_group() { return 0; }
  runtime_identity_wait_tracked() { return 0; }
  runtime_identity_cleanup_pause() { :; }
  runtime_identity_stop_tracked 424242
)

prove_process_survival_red() {
  expect_identity_failure surviving-process "${RUNTIME_IDENTITY_PROCESS_STATUS}" \
    'FAIL  runtime-id    port-forward process survived cleanup' \
    surviving_process_red_case
}

force_cleanup_group() {
  local pid="$1"
  kill -KILL -- "-${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}

prove_real_process_group_cleanup() (
  local pid status attempt
  local kill_sent=false
  local ready="${PROOF_DIRECTORY}/term-resistant.ready"
  runtime_identity_signal_group() {
    local signal="$1" tracked="$2"
    [[ "${signal}" != KILL ]] || kill_sent=true
    kill -s "${signal}" -- "-${tracked}" 2>/dev/null
  }
  runtime_identity_begin_tracked_cleanup
  set -m
  (
    set +m
    # The ready path must expand inside the TERM-resistant fixture shell.
    # shellcheck disable=SC2016
    exec timeout --foreground --signal=TERM --kill-after=10s 20s \
      bash -c 'trap "" TERM; : >"$1"; sleep 20 & wait' _ "${ready}"
  ) >/dev/null 2>&1 &
  pid=$!
  set +m
  for ((attempt = 1; attempt <= 50; attempt++)); do
    [[ ! -f "${ready}" ]] || break
    runtime_identity_process_or_group_exists "${pid}" || break
    sleep 0.02
  done
  if [[ ! -f "${ready}" ]]; then
    force_cleanup_group "${pid}"
    printf 'FAIL  runtime-id    TERM-resistant cleanup fixture was not ready\n' >&2
    return 1
  fi
  if runtime_identity_stop_tracked "${pid}" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  rm -f -- "${ready}"
  if ((status != 0)); then
    force_cleanup_group "${pid}"
    printf 'FAIL  runtime-id    real tracked cleanup failed status=%s\n' "${status}" >&2
    return "${status}"
  fi
  if runtime_identity_process_or_group_exists "${pid}" ||
    [[ "${RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP}" != absent || "${kill_sent}" != true ]]; then
    force_cleanup_group "${pid}"
    printf 'FAIL  runtime-id    real cleanup did not prove KILL and group absence\n' >&2
    return 1
  fi
  printf 'PASS  runtime-id    TERM-resistant group reached KILL/reap and is absent\n'
)

assert_positive_key_set() {
  local evidence="$1" keys="${PROOF_DIRECTORY}/positive.keys"
  cut -d= -f1 "${evidence}" >"${keys}"
  diff -u - "${keys}" <<'EOF'
SCHEMA
SOURCE_COMMIT
SOURCE_TREE
SOURCE_WORKTREE_CLEAN
BUILD_SOURCE_COMMIT
BUILD_SOURCE_TREE
BUILD_SOURCE_SEMANTICS
HOST_BINARY_SHA256
HOST_BINARY_SHA256_SECOND
HOST_BINARY_REPRODUCIBLE
HOST_BINARY_BYTES
CONTEXT_MANIFEST_PATH
CONTEXT_MANIFEST_SHA256
BUILD_CONTEXT_ARCHIVE_SHA256
BUILD_CONTEXT_STREAM_SHA256_FIRST
BUILD_CONTEXT_STREAM_SHA256_SECOND
BUILD_CONTEXT_STREAM_BYTES_FIRST
BUILD_CONTEXT_STREAM_BYTES_SECOND
BUILD_CONTEXT_INPUT_SEMANTICS
BUILD_CONTEXT_BYTES
BUILD_CONTEXT_CANARY_EXCLUDED
DOCKER_CONFIG_ID_FIRST
DOCKER_CONFIG_ID_SECOND
DOCKER_CONFIG_IDENTICAL
DOCKER_REPO_DIGESTS
DOCKER_IDENTITY_SEMANTICS
BUILD_LOG_FIRST_SHA256
BUILD_LOG_FIRST_RESULT_CONFIG_ID
BUILD_LOG_SECOND_SHA256
BUILD_LOG_SECOND_RESULT_CONFIG_ID
POD_IMAGE_ID
POD_IMAGE_ID_SEMANTICS
DOCKER_VS_POD_COMPARABLE
RUNNING_EXECUTABLE_SHA256
HEALTH_RESPONSE
SELECTED_IPV4_PORT
PORT_FORWARD_CLEANUP
PORT_FORWARD_PID_ABSENT
NAMESPACE_ABSENT
CLUSTER_CLEANUP
EOF
}

prove_positive_rendering() {
  local evidence="${PROOF_DIRECTORY}/positive.env"
  local commit tree
  commit="$(printf '2%.0s' {1..40})"
  tree="$(printf '3%.0s' {1..40})"
  runtime_identity_begin_tracked_cleanup
  RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP=absent
  runtime_identity_validate_positive_arguments "${commit}" "${tree}" true \
    'containerd://sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    "${SHA_A}" ok 43127 true deferred-to-verify-runtime
  expect_identity_failure dirty-positive-evidence "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    refusing incomplete positive identity evidence' \
    runtime_identity_validate_positive_arguments "${commit}" "${tree}" false \
    'containerd://sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    "${SHA_A}" ok 43127 true deferred-to-verify-runtime
  runtime_identity_render_positive "${commit}" "${tree}" true \
    'containerd://sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    "${SHA_A}" ok 43127 deferred-to-verify-runtime >"${evidence}"
  assert_positive_key_set "${evidence}"
  grep -Fqx 'SOURCE_WORKTREE_CLEAN=true' "${evidence}"
  grep -Fqx "BUILD_SOURCE_COMMIT=${commit}" "${evidence}"
  grep -Fqx 'BUILD_SOURCE_SEMANTICS=git-commit-tree-snapshot' "${evidence}"
  grep -Fqx "BUILD_CONTEXT_ARCHIVE_SHA256=$(printf '4%.0s' {1..64})" "${evidence}"
  grep -Fqx 'BUILD_CONTEXT_INPUT_SEMANTICS=tee-captured-deterministic-tar' "${evidence}"
  grep -Fqx 'BUILD_CONTEXT_BYTES=20' "${evidence}"
  grep -Fqx 'BUILD_CONTEXT_CANARY_EXCLUDED=true' "${evidence}"
  grep -Fqx 'DOCKER_REPO_DIGESTS=' "${evidence}"
  grep -Fqx 'DOCKER_VS_POD_COMPARABLE=false' "${evidence}"
  grep -Fqx "BUILD_LOG_FIRST_RESULT_CONFIG_ID=sha256:$(printf 'd%.0s' {1..64})" \
    "${evidence}"
  [[ "$(wc -c <"${evidence}")" -le 8192 ]]
  printf 'PASS  runtime-id    bounded positive evidence carries exact identity semantics\n'
}

main() {
  reset_state_directory runtime-identity-proof || return
  PROOF_DIRECTORY="${PLATFORM_STATE_DIR}/runtime-identity-proof"
  trap 'rm -rf -- "${PROOF_DIRECTORY}"' EXIT
  prove_identity_response_reds
  prove_build_env_contract
  prove_context_file_hash_reds
  prove_git_source_snapshot
  prove_docker_input_stream_red
  prove_reference_context_red
  prove_dynamic_port_contract
  prove_process_survival_red
  prove_real_process_group_cleanup
  prove_positive_rendering
  trap - EXIT
  rm -rf -- "${PROOF_DIRECTORY}"
  printf 'PASS  runtime-id    pure runtime identity contracts proved\n'
}

main "$@"
