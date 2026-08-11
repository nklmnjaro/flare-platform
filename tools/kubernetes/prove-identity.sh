#!/bin/bash -p
# Embedded awk programs intentionally use awk fields.
# shellcheck disable=SC2016
# Proof helpers deliberately isolate mutable fixtures in subshells.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2329
set -euo pipefail

PROVE_IDENTITY_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_IDENTITY_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_IDENTITY_SOURCE_DIR=.
builtin source "${PROVE_IDENTITY_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/identity.sh"
builtin unset PROVE_IDENTITY_SOURCE_DIR

PROOF_DIRECTORY=""
PROCESS_FIXTURE_BINARY=""
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
    run_host_command tail -n +2 -- "${valid}"
  } >"${nul_key}"
  expect_identity_failure nul-build-key "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed build identity record' \
    runtime_identity_load_build_env "${nul_key}"
  run_host_command sed 's/^SCHEMA=/UNEXPECTED_KEY=/' \
    "${valid}" >"${unexpected}"
  expect_identity_failure unexpected-build-key "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    unexpected build identity key: UNEXPECTED_KEY' \
    runtime_identity_load_build_env "${unexpected}"
  run_host_command sed \
    "s|^DOCKER_REPO_DIGESTS=$|DOCKER_REPO_DIGESTS=local@sha256:${SHA_B}|" \
    "${valid}" >"${repo_digest}"
  expect_identity_failure nonempty-repo-digests "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed local Docker identity semantics' \
    runtime_identity_load_build_env "${repo_digest}"
  run_host_command sed \
    's/^BUILD_CONTEXT_CANARY_EXCLUDED=true$/BUILD_CONTEXT_CANARY_EXCLUDED=false/' \
    "${valid}" >"${canary}"
  expect_identity_failure context-canary "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed build-context boundary identity' \
    runtime_identity_load_build_env "${canary}"
  run_host_command sed \
    "s|^BUILD_LOG_FIRST_RESULT_CONFIG_ID=.*$|BUILD_LOG_FIRST_RESULT_CONFIG_ID=sha256:${SHA_B}|" \
    "${valid}" >"${result_mismatch}"
  expect_identity_failure result-inspect-mismatch "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    Docker build result and inspect identity disagree' \
    runtime_identity_load_build_env "${result_mismatch}"
  run_host_command sed \
    "s/^BUILD_CONTEXT_STREAM_SHA256_SECOND=.*$/BUILD_CONTEXT_STREAM_SHA256_SECOND=${SHA_B}/" \
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

prove_buildkit_result_contract() {
  local valid="${PROOF_DIRECTORY}/buildkit-valid.log"
  local empty="${PROOF_DIRECTORY}/buildkit-empty.log"
  local duplicate="${PROOF_DIRECTORY}/buildkit-duplicate.log"
  local uppercase="${PROOF_DIRECTORY}/buildkit-uppercase.log"
  local wrong_prefix="${PROOF_DIRECTORY}/buildkit-wrong-prefix.log"
  local wrong_suffix="${PROOF_DIRECTORY}/buildkit-wrong-suffix.log"
  local result="sha256:${SHA_A}"
  printf '#1 preparing build\n#12 writing image %s done\n' "${result}" >"${valid}"
  printf '#1 preparing build\n' >"${empty}"
  printf '#12 writing image %s done\n#13 writing image %s done\n' \
    "${result}" "${result}" >"${duplicate}"
  printf '#12 writing image sha256:%s done\n' "${SHA_A^^}" >"${uppercase}"
  printf 'prefix #12 writing image %s done\n' "${result}" >"${wrong_prefix}"
  printf '#12 writing image %s done suffix\n' "${result}" >"${wrong_suffix}"

  if [[ "$(buildkit_result_config_id "${valid}")" != "${result}" ||
  "$(runtime_identity_extract_build_result_id "${valid}")" != "${result}" ]]; then
    printf 'FAIL  runtime-id    canonical BuildKit result was not consumed exactly\n' >&2
    return 1
  fi
  expect_identity_failure missing-buildkit-result "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed Docker build result identity' \
    runtime_identity_extract_build_result_id "${empty}"
  expect_identity_failure duplicate-buildkit-result "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed Docker build result identity' \
    runtime_identity_extract_build_result_id "${duplicate}"
  expect_identity_failure uppercase-buildkit-result "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed Docker build result identity' \
    runtime_identity_extract_build_result_id "${uppercase}"
  expect_identity_failure prefixed-buildkit-result "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed Docker build result identity' \
    runtime_identity_extract_build_result_id "${wrong_prefix}"
  expect_identity_failure suffixed-buildkit-result "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    malformed Docker build result identity' \
    runtime_identity_extract_build_result_id "${wrong_suffix}"
  printf 'PASS  runtime-id    exact shared BuildKit result grammar proved\n'
}

prove_reference_buildkit_result_contract() (
  local valid="${PROOF_DIRECTORY}/reference-buildkit-valid.log"
  local duplicate="${PROOF_DIRECTORY}/reference-buildkit-duplicate.log"
  local result="sha256:${SHA_A}"
  builtin source "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  printf '#12 writing image %s done\n' "${result}" >"${valid}"
  printf '#12 writing image %s done\n#13 writing image %s done\n' \
    "${result}" "${result}" >"${duplicate}"
  if [[ "$(extract_result_config_id "${valid}")" != "${result}" ]]; then
    printf 'FAIL  reference-build canonical BuildKit result was not consumed exactly\n' >&2
    return 1
  fi
  expect_identity_failure duplicate-reference-buildkit-result 1 \
    'FAIL  reference-build expected exactly one BuildKit result config identity' \
    extract_result_config_id "${duplicate}"
  expect_identity_failure buildkit-inspect-mismatch 1 \
    'FAIL  reference-build proof BuildKit result differs from inspected config identity' \
    require_result_matches_inspect proof "${result}" "sha256:${SHA_B}"
  printf 'PASS  reference-build shared BuildKit parser and inspect comparison proved\n'
)

write_context_manifest_fixture() {
  local context="$1" manifest="$2"
  local dockerfile_sha server_sha
  dockerfile_sha="$(run_host_command sha256sum -- "${context}/Dockerfile" |
    run_host_command awk '{print $1}')" || return
  server_sha="$(run_host_command sha256sum -- "${context}/server" |
    run_host_command awk '{print $1}')" || return
  printf 'path\tmode\tsize\tsha256\n' >"${manifest}"
  printf 'Dockerfile\t0644\t%s\t%s\n' \
    "$(run_host_command stat -c '%s' "${context}/Dockerfile")" \
    "${dockerfile_sha}" >>"${manifest}"
  printf 'server\t0755\t%s\t%s\n' \
    "$(run_host_command stat -c '%s' "${context}/server")" \
    "${server_sha}" >>"${manifest}"
}

prove_context_file_hash_reds() (
  local context="${PROOF_DIRECTORY}/consumer-context"
  local manifest="${PROOF_DIRECTORY}/consumer-context.manifest.tsv"
  local dockerfile_bytes
  run_host_command mkdir -p -- "${context}"
  printf 'FROM scratch\n' >"${context}/Dockerfile"
  printf 'server\n' >"${context}/server"
  run_host_command chmod 0644 "${context}/Dockerfile"
  run_host_command chmod 0755 "${context}/server"
  write_context_manifest_fixture "${context}" "${manifest}"
  RUNTIME_HOST_BINARY_SHA256="$(run_host_command sha256sum -- \
    "${context}/server" | run_host_command awk '{print $1}')"
  RUNTIME_HOST_BINARY_BYTES="$(run_host_command stat -c '%s' \
    "${context}/server")"
  dockerfile_bytes="$(run_host_command stat -c '%s' "${context}/Dockerfile")"
  RUNTIME_BUILD_CONTEXT_BYTES="$((dockerfile_bytes + RUNTIME_HOST_BINARY_BYTES))"
  RUNTIME_CONTEXT_MANIFEST_SHA256="$(run_host_command sha256sum -- \
    "${manifest}" | run_host_command awk '{print $1}')"
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
  builtin source "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  REFERENCE_ROOT="${source_root}"
  run_host_command mkdir -p -- "${REFERENCE_ROOT}"
  PLATFORM_REFERENCE_SOURCE_COMMIT="$(run_host_command git -C \
    "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{commit}')"
  PLATFORM_REFERENCE_SOURCE_TREE="$(run_host_command git -C \
    "${PLATFORM_ROOT}" rev-parse --verify 'HEAD^{tree}')"
  resolve_reference_source_identity
  snapshot="$(stage_reference_source_snapshot)"
  trap '[[ -z "${snapshot}" ]] || run_host_command rm -rf -- "${snapshot}"' EXIT
  for path in kubernetes/reference/Dockerfile \
    kubernetes/reference/server/go.mod kubernetes/reference/server/main.go; do
    run_host_command git -C "${PLATFORM_ROOT}" \
      show "${REFERENCE_SOURCE_COMMIT}:${path}" >"${expected}"
    run_host_command cmp --silent -- "${expected}" "${snapshot}/${path}"
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
  builtin source "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  run_host_command mkdir -p -- "${context}"
  printf 'FROM scratch\n' >"${context}/Dockerfile"
  printf 'server\n' >"${context}/server"
  run_host_command chmod 0644 "${context}/Dockerfile"
  run_host_command chmod 0755 "${context}/server"
  write_context_archive "${context}" "${archive}"
  expected="$(hash_file "${archive}")"
  run_host_command tee "${consumed}" <"${archive}" >/dev/null
  [[ "$(verify_context_stream_identity "${archive}" "${consumed}" "${expected}")" == "${expected}" ]]
  printf X >>"${consumed}"
  expect_identity_failure changed-docker-input-stream 1 \
    'FAIL  reference-build Docker input stream bytes changed' \
    verify_context_stream_identity "${archive}" "${consumed}" "${expected}"
  printf 'PASS  runtime-id    exact tee-captured Docker input stream identity proved\n'
)

prove_reference_context_red() {
  local output
  output="$("${PLATFORM_ROOT}/tools/kubernetes/reference-context.sh" prove)" || return
  if ! run_host_command grep -Fqx \
    'PASS  reference-red coherent-context-change' <<<"${output}" ||
    ! run_host_command grep -Fqx \
      'PASS  reference-red unexpected-file' <<<"${output}"; then
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
  if run_host_command grep -Fq "${fixed_port}" \
    "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh" \
    "${PLATFORM_ROOT}/tools/kubernetes/identity.sh"; then
    printf 'FAIL  runtime-id    fixed probe port survived in runtime consumer\n' >&2
    return 1
  fi
  run_host_command grep -Fq -- '--address=127.0.0.1' \
    "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh"
  run_host_command grep -Fq -- 'service/platform-reference :8080' \
    "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh"
  printf 'PASS  runtime-id    dynamic IPv4 port selection and probe contract\n'
}

prove_reachable_404_port_red() (
  local port_file="${PROOF_DIRECTORY}/reachable-404.port" pid port output status=0
  "${PROCESS_FIXTURE_BINARY}" http-404 "${port_file}" &
  pid=$!
  builtin trap \
    'builtin kill -KILL "${pid}" 2>/dev/null || true; builtin wait "${pid}" 2>/dev/null || true' \
    EXIT
  for _ in {1..250}; do
    [[ ! -s "${port_file}" ]] || break
    run_host_command sleep 0.02
  done
  IFS= builtin read -r port <"${port_file}" || return
  output="$(runtime_identity_require_selected_port_absent \
    "${port}" 2>&1)" || status=$?
  builtin wait "${pid}"
  builtin trap - EXIT
  if [[ "${status}" -ne "${RUNTIME_IDENTITY_PROCESS_STATUS}" ||
    "${output}" != 'FAIL  runtime-id    selected port remained reachable after port-forward cleanup' ]]; then
    printf 'FAIL  runtime-red   reachable HTTP 404 listener was accepted as absent\n' >&2
    return 1
  fi
  printf 'PASS  runtime-red   reachable HTTP 404 listener fails port cleanup proof\n'
)

surviving_process_red_case() (
  linux_process_group_state() { printf 'live\n'; }
  runtime_identity_signal_group() { return 0; }
  runtime_identity_wait_tracked() { return 0; }
  runtime_identity_cleanup_pause() { :; }
  runtime_identity_stop_tracked 424242 12345
)

prove_process_survival_red() {
  expect_identity_failure surviving-process "${RUNTIME_IDENTITY_PROCESS_STATUS}" \
    'FAIL  runtime-id    port-forward process survived cleanup' \
    surviving_process_red_case
}

process_inspection_red_case() (
  linux_process_group_state() { return "${PROCESS_STATE_INSPECTION_STATUS}"; }
  runtime_identity_stop_tracked 424242 12345
)

unreaped_process_red_case() (
  linux_process_group_state() { printf 'absent\n'; }
  runtime_identity_wait_tracked() { return 1; }
  runtime_identity_stop_tracked 424242 12345
)

prove_process_boundary_reds() {
  expect_identity_failure process-inspection "${RUNTIME_IDENTITY_BOUNDARY_STATUS}" \
    'FAIL  runtime-id    unable to prove port-forward process-group state' \
    process_inspection_red_case
  expect_identity_failure unreaped-child "${RUNTIME_IDENTITY_PROCESS_STATUS}" \
    'FAIL  runtime-id    tracked port-forward child was not reaped' \
    unreaped_process_red_case
}

prove_replaced_identity_no_signal() (
  local marker="${PROOF_DIRECTORY}/replaced.signal"
  linux_process_group_state() { printf 'replaced\n'; }
  linux_process_state() { printf 'replaced\n'; }
  runtime_identity_signal_group() { : >"${marker}"; }
  runtime_identity_wait_tracked() { return 0; }
  runtime_identity_cleanup_pause() { :; }
  runtime_identity_begin_tracked_cleanup
  runtime_identity_stop_tracked 424242 12345
  [[ "${RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP}" == no-live-members &&
    ! -e "${marker}" ]]
  printf 'PASS  runtime-id    replaced leader identity is never signalled\n'
)

prove_two_sample_race() (
  local sample="${PROOF_DIRECTORY}/group.sample"
  linux_process_group_state() {
    if [[ ! -e "${sample}" ]]; then
      : >"${sample}"
      printf 'absent\n'
    else
      printf 'live\n'
    fi
  }
  runtime_identity_cleanup_pause() { :; }
  if runtime_identity_confirm_group_nonlive 424242 12345; then
    printf 'FAIL  runtime-id    nonlive-then-live process group was accepted\n' >&2
    return 1
  fi
  printf 'PASS  runtime-id    nonlive-then-live process group fails confirmation\n'
)

prove_exit_127_child_reaped() (
  local pid starttime="" state kernel_state snapshot
  local observed_pid observed_pgrp observed_starttime attempt
  runtime_identity_begin_tracked_cleanup
  set -m
  (
    builtin kill -STOP "${BASHPID}"
    builtin exit 127
  ) &
  pid=$!
  set +m
  builtin trap \
    'builtin kill -KILL "${pid}" 2>/dev/null || true; builtin wait "${pid}" 2>/dev/null || true' \
    EXIT
  for ((attempt = 1; attempt <= 100; attempt++)); do
    if snapshot="$(linux_process_snapshot "${pid}")"; then
      IFS=$'\t' builtin read -r \
        observed_pid observed_pgrp observed_starttime kernel_state <<<"${snapshot}"
      if [[ "${observed_pid}" == "${pid}" && "${observed_pgrp}" == "${pid}" ]] &&
        [[ "${kernel_state}" == T || "${kernel_state}" == t ]]; then
        starttime="${observed_starttime}"
        break
      fi
    fi
    run_host_command sleep 0.01
  done
  [[ -n "${starttime}" ]] || return 1
  builtin kill -CONT "${pid}"
  for ((attempt = 1; attempt <= 100; attempt++)); do
    state="$(linux_process_state "${pid}" "${starttime}")" || return
    [[ "${state}" != live ]] && break
    run_host_command sleep 0.01
  done
  [[ "${state}" != live ]] || return 1
  runtime_identity_stop_tracked "${pid}" "${starttime}"
  state="$(linux_process_state "${pid}" "${starttime}")" || return
  [[ "${state}" == absent || "${state}" == replaced ]] || return 1
  [[ "${RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP}" == no-live-members ]] || return 1
  builtin trap - EXIT
  printf 'PASS  runtime-id    direct child exit 127 is reaped by post-wait identity\n'
)

force_cleanup_group() {
  local pid="$1"
  builtin kill -KILL -- "-${pid}" 2>/dev/null || true
  builtin wait "${pid}" 2>/dev/null || true
}

prove_real_process_group_cleanup() (
  local pid starttime status attempt state
  local bash_path sleep_path timeout_path
  local kill_sent=false
  local ready="${PROOF_DIRECTORY}/term-resistant.ready"
  bash_path="$(host_command_path bash)" || return
  sleep_path="$(host_command_path sleep)" || return
  timeout_path="$(host_command_path timeout)" || return
  runtime_identity_signal_group() {
    local signal="$1" tracked="$2" expected_starttime="$3"
    [[ "${signal}" != KILL ]] || kill_sent=true
    runtime_identity_read_group_state "${tracked}" "${expected_starttime}" || return
    [[ "${RUNTIME_IDENTITY_GROUP_STATE}" == live ]] || return 0
    builtin kill -s "${signal}" -- "-${tracked}" 2>/dev/null
  }
  runtime_identity_begin_tracked_cleanup
  set -m
  (
    set +m
    # The ready path must expand inside the TERM-resistant fixture shell.
    # shellcheck disable=SC2016
    builtin exec "${timeout_path}" --foreground --signal=TERM --kill-after=10s 20s \
      "${bash_path}" -p -c \
      'builtin trap "" TERM; : >"$1"; "$2" 20 & builtin wait' \
      _ "${ready}" "${sleep_path}"
  ) >/dev/null 2>&1 &
  pid=$!
  set +m
  starttime="$(runtime_identity_capture_group_starttime "${pid}")" || {
    force_cleanup_group "${pid}"
    return 1
  }
  for ((attempt = 1; attempt <= 50; attempt++)); do
    [[ ! -f "${ready}" ]] || break
    runtime_identity_read_group_state "${pid}" "${starttime}" || break
    [[ "${RUNTIME_IDENTITY_GROUP_STATE}" == live ]] || break
    run_host_command sleep 0.02
  done
  if [[ ! -f "${ready}" ]]; then
    force_cleanup_group "${pid}"
    printf 'FAIL  runtime-id    TERM-resistant cleanup fixture was not ready\n' >&2
    return 1
  fi
  if runtime_identity_stop_tracked "${pid}" "${starttime}" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  run_host_command rm -f -- "${ready}"
  if ((status != 0)); then
    force_cleanup_group "${pid}"
    printf 'FAIL  runtime-id    real tracked cleanup failed status=%s\n' "${status}" >&2
    return "${status}"
  fi
  state="$(linux_process_group_state "${pid}" "${starttime}")" || return
  if [[ "${state}" == live ||
    "${RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP}" != no-live-members ||
    "${kill_sent}" != true ]]; then
    force_cleanup_group "${pid}"
    printf 'FAIL  runtime-id    real cleanup did not prove KILL and group absence\n' >&2
    return 1
  fi
  printf \
    'PASS  runtime-id    TERM-resistant group reached KILL/reap and has no live members\n'
)

assert_positive_key_set() {
  local evidence="$1" keys="${PROOF_DIRECTORY}/positive.keys"
  run_host_command cut -d= -f1 "${evidence}" >"${keys}"
  run_host_command diff -u - "${keys}" <<'EOF'
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
PORT_FORWARD_PORT_ABSENT
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
  RUNTIME_IDENTITY_PORT_FORWARD_CLEANUP=no-live-members
  RUNTIME_IDENTITY_PORT_FORWARD_PORT_ABSENT=true
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
  run_host_command grep -Fqx \
    'SCHEMA=flare-platform-runtime-identity-positive-v3' "${evidence}"
  run_host_command grep -Fqx 'SOURCE_WORKTREE_CLEAN=true' "${evidence}"
  run_host_command grep -Fqx "BUILD_SOURCE_COMMIT=${commit}" "${evidence}"
  run_host_command grep -Fqx \
    'BUILD_SOURCE_SEMANTICS=git-commit-tree-snapshot' "${evidence}"
  run_host_command grep -Fqx \
    "BUILD_CONTEXT_ARCHIVE_SHA256=$(printf '4%.0s' {1..64})" "${evidence}"
  run_host_command grep -Fqx \
    'BUILD_CONTEXT_INPUT_SEMANTICS=tee-captured-deterministic-tar' "${evidence}"
  run_host_command grep -Fqx 'BUILD_CONTEXT_BYTES=20' "${evidence}"
  run_host_command grep -Fqx 'BUILD_CONTEXT_CANARY_EXCLUDED=true' "${evidence}"
  run_host_command grep -Fqx 'DOCKER_REPO_DIGESTS=' "${evidence}"
  run_host_command grep -Fqx 'DOCKER_VS_POD_COMPARABLE=false' "${evidence}"
  run_host_command grep -Fqx \
    'PORT_FORWARD_CLEANUP=no-live-members' "${evidence}"
  run_host_command grep -Fqx 'PORT_FORWARD_PORT_ABSENT=true' "${evidence}"
  run_host_command grep -Fqx \
    "BUILD_LOG_FIRST_RESULT_CONFIG_ID=sha256:$(printf 'd%.0s' {1..64})" \
    "${evidence}"
  [[ "$(run_host_command wc -c <"${evidence}")" -le 8192 ]]
  printf 'PASS  runtime-id    bounded positive evidence carries exact identity semantics\n'
}

main() {
  reset_state_directory runtime-identity-proof || return
  PROOF_DIRECTORY="${PLATFORM_STATE_DIR}/runtime-identity-proof"
  PROCESS_FIXTURE_BINARY="${PROOF_DIRECTORY}/process-state-helper"
  trap 'run_host_command rm -rf -- "${PROOF_DIRECTORY}"' EXIT
  "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" go build -trimpath \
    -o "${PROCESS_FIXTURE_BINARY}" \
    "${PLATFORM_ROOT}/tests/fixtures/go/process-state-helper.go"
  prove_identity_response_reds
  prove_build_env_contract
  prove_buildkit_result_contract
  prove_reference_buildkit_result_contract
  prove_context_file_hash_reds
  prove_git_source_snapshot
  prove_docker_input_stream_red
  prove_reference_context_red
  prove_dynamic_port_contract
  prove_reachable_404_port_red
  prove_process_survival_red
  prove_process_boundary_reds
  prove_replaced_identity_no_signal
  prove_two_sample_race
  prove_exit_127_child_reaped
  prove_real_process_group_cleanup
  prove_positive_rendering
  trap - EXIT
  run_host_command rm -rf -- "${PROOF_DIRECTORY}"
  printf 'PASS  runtime-id    pure runtime identity contracts proved\n'
}

main "$@"
