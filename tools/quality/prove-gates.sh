#!/bin/bash -p
set -euo pipefail

PROVE_GATES_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_GATES_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_GATES_SOURCE_DIR=.
builtin source "${PROVE_GATES_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
unset PROVE_GATES_SOURCE_DIR

PROVE_GATES_BASH_PATH="$(host_command_path bash)" || exit
PROVE_GATES_ENV_PATH="$(host_command_path env)" || exit
PROVE_GATES_SLEEP_PATH="$(host_command_path sleep)" || exit
readonly PROVE_GATES_BASH_PATH PROVE_GATES_ENV_PATH PROVE_GATES_SLEEP_PATH

KUBE_CONTEXT_DOCKER_CONTRACT=flare-platform-docker-target-fixture-v1
KUBE_CONTEXT_DOCKER_TOKEN=prove-gates-docker-owner-v1
KUBE_CONTEXT_RUNTIME_CONTRACT=flare-platform-runtime-fixture-v1
KUBE_CONTEXT_RUNTIME_TOKEN=prove-gates-runtime-owner-v1

prove_commit_policy() {
  local directory="${PLATFORM_STATE_DIR}/commit-policy"
  local message
  reset_state_directory "commit-policy" || return

  printf 'feat(platform): add context guard\n' >"${directory}/valid-title.txt"
  printf 'fix: reject unsafe context\n\nExplain the bounded fix.\n' >"${directory}/valid-body.txt"
  expect_success commit-title "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/valid-title.txt"
  expect_success commit-body "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/valid-body.txt"

  printf 'feature: invalid type\n' >"${directory}/invalid-type.txt"
  printf 'feat!: breaking marker\n' >"${directory}/invalid-bang.txt"
  printf 'fix: title\nbody without blank line' >"${directory}/invalid-separator.txt"
  printf 'fix: title\n\nline with a hard\ttab\n' >"${directory}/invalid-tab.txt"
  printf 'fix: title \n' >"${directory}/invalid-trailing.txt"
  message="${directory}/invalid-long-body.txt"
  printf 'fix: title\n\n' >"${message}"
  for _ in {1..73}; do printf x >>"${message}"; done
  printf '\n' >>"${message}"
  message="${directory}/invalid-long-title.txt"
  printf 'feat: ' >"${message}"
  for _ in {1..67}; do printf x >>"${message}"; done
  printf '\n' >>"${message}"

  expect_failure commit-type "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/invalid-type.txt"
  expect_failure commit-bang "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/invalid-bang.txt"
  expect_failure commit-separator "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/invalid-separator.txt"
  expect_failure commit-tab "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/invalid-tab.txt"
  expect_failure commit-trailing "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/invalid-trailing.txt"
  expect_failure commit-title-length "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/invalid-long-title.txt"
  expect_failure commit-body-length "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
    "${directory}/invalid-long-body.txt"
}

prove_unlocked_ci() {
  local directory="${PLATFORM_STATE_DIR}/aqua-ci-unlocked"
  reset_state_directory "aqua-ci-unlocked" || return
  run_host_command mkdir -p \
    "${directory}/tools/bootstrap" "${directory}/tools/common"
  run_host_command cp "${PLATFORM_ROOT}/tools/bootstrap/bootstrap.sh" \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" "${directory}/tools/bootstrap/"
  run_host_command cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${PLATFORM_ROOT}/tools/bootstrap/environment-profile.sh" \
    "${directory}/tools/bootstrap/"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/docker-target.sh" \
    "${PLATFORM_ROOT}/tools/common/env.sh" \
    "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${PLATFORM_ROOT}/tools/common/process-state.sh" \
    "${PLATFORM_ROOT}/tools/common/state.sh" \
    "${PLATFORM_ROOT}/tools/common/tooling.sh" "${directory}/tools/common/"
  run_host_command sed 's/^  require_checksum: true$/  require_checksum: false/' \
    "${PLATFORM_ROOT}/aqua.yaml" >"${directory}/aqua.yaml"
  run_host_command grep -Fqx '  require_checksum: false' "${directory}/aqua.yaml"
  expect_failure_with_marker aqua-ci-unlocked 1 \
    'CI requires committed Aqua checksums.' 30s \
    "${PROVE_GATES_ENV_PATH}" CI=true \
    "${directory}/tools/bootstrap/bootstrap.sh"
}

copy_kube_context_fixture() {
  local target="$1"
  run_host_command mkdir -p \
    "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/kubernetes" "${target}/.platform/bootstrap" \
    "${target}/.platform/aqua/bin" \
    "${target}/.platform/aqua/test-fixtures" \
    "${target}/.platform-test/docker-target"
  run_host_command cp "${PLATFORM_ROOT}/aqua.yaml" \
    "${PLATFORM_ROOT}/aqua-checksums.json" "${target}/"
  run_host_command cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/env.sh" \
    "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${PLATFORM_ROOT}/tools/common/process-state.sh" \
    "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/tooling.sh" \
    "${target}/tools/common/tooling-production.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/managed-tool-fixture.sh" \
    "${target}/tools/common/tooling.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/common/docker-target.sh" \
    "${target}/tools/common/docker-target-production.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/docker-target-fixture.sh" \
    "${target}/tools/common/docker-target.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh" \
    "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" \
    "${target}/tools/kubernetes/"
  printf '%s\n' "${KUBE_CONTEXT_DOCKER_TOKEN}" \
    >"${target}/.platform-test/docker-target/.docker-target-owner"
  printf '%s\n' "${KUBE_CONTEXT_RUNTIME_TOKEN}" \
    >"${target}/.platform/aqua/test-fixtures/.runtime-fixture-owner"
  printf 'fixture\n' >"${target}/.platform/kubeconfig"
}

write_kube_context_fixture_commands() {
  local target="$1"
  run_host_command tee "${target}/.platform-test/docker-target/docker" \
    >/dev/null <<'MOCK'
#!/bin/bash -p
set -euo pipefail
printf 'executed:%s\n' "$*" >"${KUBE_CONTEXT_DOCKER_MARKER:?}"
exit 97
MOCK
  run_host_command tee "${target}/.platform/aqua/test-fixtures/kubectl" \
    >/dev/null <<'MOCK'
#!/bin/bash -p
set -euo pipefail
printf '%s\n' "$*" >>"${KUBE_CONTEXT_KUBECTL_LOG:?}"
if [[ "$*" == *"config current-context"* ]]; then
  printf 'kind-unrelated\n'
  exit 0
fi
exit 2
MOCK
  run_host_command chmod 0755 \
    "${target}/.platform-test/docker-target/docker" \
    "${target}/.platform/aqua/test-fixtures/kubectl"
}

prove_kube_context_guard() {
  local target="${PLATFORM_STATE_DIR}/kube-context-proof"
  local docker_marker="${target}/docker.executed"
  local kubectl_log="${target}/kubectl.log"
  local output="${target}/guard.out" status
  reset_state_directory kube-context-proof || return
  copy_kube_context_fixture "${target}" || return
  write_kube_context_fixture_commands "${target}" || return
  if run_host_command env \
    PLATFORM_DOCKER_TEST_CONTRACT="${KUBE_CONTEXT_DOCKER_CONTRACT}" \
    PLATFORM_DOCKER_TEST_ROOT="${target}/.platform-test/docker-target" \
    PLATFORM_DOCKER_TEST_TOKEN="${KUBE_CONTEXT_DOCKER_TOKEN}" \
    PLATFORM_RUNTIME_TEST_CONTRACT="${KUBE_CONTEXT_RUNTIME_CONTRACT}" \
    PLATFORM_RUNTIME_TEST_ROOT="${target}/.platform/aqua/test-fixtures" \
    PLATFORM_RUNTIME_TEST_TOKEN="${KUBE_CONTEXT_RUNTIME_TOKEN}" \
    PLATFORM_TEST_CURRENT_CONTEXT=kind-flare-platform-dev \
    KUBE_CONTEXT_DOCKER_MARKER="${docker_marker}" \
    KUBE_CONTEXT_KUBECTL_LOG="${kubectl_log}" \
    "${target}/tools/kubernetes/guard-context.sh" >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "${status}" -ne 1 ]] || ! run_host_command grep -Fqx \
    'FAIL  kube-guard    expected kind-flare-platform-dev, got kind-unrelated' \
    "${output}" || ! run_host_command grep -Fq -- 'config current-context' \
    "${kubectl_log}" || [[ -e "${docker_marker}" ]]; then
    run_host_command sed -n '1,20p' "${output}" >&2 || true
    printf 'FAIL  kube-red       isolated current-context guard proof failed\n' >&2
    return 1
  fi
  printf 'PASS  kube-red       production context override is absent\n'
}

expect_helper_status() {
  local label="$1" expected="$2" status
  shift 2
  if "$@" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "${status}" -ne "${expected}" ]]; then
    printf 'FAIL  red-marker    %s returned %s, expected %s\n' \
      "${label}" "${status}" "${expected}" >&2
    return 1
  fi
}

assert_evidence_hygiene() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local file size
  if run_host_command find "${evidence_dir}" -maxdepth 1 \
    \( -name '.*.raw' -o -name '.*.render.*' -o -name '.*.bound.*' -o \
    -name '.*.status.*' \) \
    -print -quit | run_host_command grep -q .; then
    printf 'FAIL  red-marker    transient evidence file survived\n' >&2
    return 1
  fi
  while IFS= read -r file; do
    size="$(run_host_command wc -c <"${file}")"
    if ((size > EVIDENCE_MAX_FILE_BYTES)); then
      printf 'FAIL  red-marker    oversized durable evidence: %s\n' "${file}" >&2
      return 1
    fi
  done < <(run_host_command find \
    "${evidence_dir}" -maxdepth 1 -type f -name '*.txt' -print)
}

prove_marker_semantics() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  expect_helper_status missing-marker "${EVIDENCE_MISSING_MARKER}" \
    expect_failure_with_marker marker-guard 7 expected-marker 5s \
    "${PROVE_GATES_BASH_PATH}" -p -c \
    'printf "unrelated-output\n"; exit 7'
  expect_helper_status wrong-status "${EVIDENCE_WRONG_STATUS}" \
    expect_failure_with_marker status-guard 7 expected-marker 5s \
    "${PROVE_GATES_BASH_PATH}" -p -c \
    'printf "expected-marker\n"; exit 8'
  run_host_command grep -Fqx 'actual_status=7' \
    "${evidence_dir}/marker-guard.txt"
  run_host_command grep -Fqx 'marker_observed=false' \
    "${evidence_dir}/marker-guard.txt"
  run_host_command grep -Fqx 'actual_status=8' \
    "${evidence_dir}/status-guard.txt"
  run_host_command grep -Fqx 'marker_observed=true' \
    "${evidence_dir}/status-guard.txt"
}

prove_literal_redaction() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local special_root='/tmp/flare #review[1]&repo'
  local supported_home='/ho''me/review-user'
  # The positional argument expands in the fixture shell.
  # shellcheck disable=SC2016
  PLATFORM_ROOT="${special_root}" expect_failure_with_marker special-path 7 marker 5s \
    "${PROVE_GATES_BASH_PATH}" -p -c \
    'printf "%s marker\n" "$1"; exit 7' _ "${special_root}"
  run_host_command grep -Fq '<REPO> marker' \
    "${evidence_dir}/special-path.txt"
  if run_host_command grep -Fq \
    "${special_root}" "${evidence_dir}/special-path.txt"; then
    printf 'FAIL  red-marker    special repository path was retained\n' >&2
    return 1
  fi
  (
    export HOME="${supported_home}"
    # The positional argument expands in the fixture shell.
    # shellcheck disable=SC2016
    expect_failure_with_marker home-redaction 7 marker 5s \
      "${PROVE_GATES_BASH_PATH}" -p -c \
      'printf "%s/.cache/tool marker\n" "$1"; exit 7' _ "${supported_home}"
  )
  run_host_command grep -Fq '<HOME>/.cache/tool marker' \
    "${evidence_dir}/home-redaction.txt"
  if run_host_command grep -Fq \
    "${supported_home}" "${evidence_dir}/home-redaction.txt"; then
    printf 'FAIL  red-marker    supported home path was retained\n' >&2
    return 1
  fi
}

run_forced_renderer_failure() {
  PLATFORM_TEST_FORCE_EVIDENCE_RENDER_FAILURE=true \
    expect_failure_with_marker renderer-failure 7 marker 5s \
    "${PROVE_GATES_BASH_PATH}" -p -c 'printf "marker\n"; exit 7'
}

prove_renderer_and_size_bounds() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local saved_output="${evidence_dir}/renderer-failure.txt"
  printf 'retained-final\n' >"${saved_output}"
  expect_helper_status renderer-failure "${EVIDENCE_BOUNDARY_STATUS}" \
    run_forced_renderer_failure
  run_host_command grep -Fqx retained-final "${saved_output}"
  expect_failure_with_marker oversized-output 124 oversize-marker 1s \
    "${PROVE_GATES_BASH_PATH}" -p -c \
    'while :; do printf "oversize-marker\n"; done'
  run_host_command grep -Fqx 'raw_truncated=true' \
    "${evidence_dir}/oversized-output.txt"
  [[ "$(run_host_command wc -c \
    <"${evidence_dir}/oversized-output.txt")" -le "${EVIDENCE_MAX_FILE_BYTES}" ]]
}

prove_inherited_stdout_cleanup() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local pid_file child_pid="" child_starttime="" child_state=""
  local start elapsed proof_status=0
  pid_file="$(run_host_command mktemp \
    "${evidence_dir}/.inherited-child.XXXXXXXX")" || return
  start="${SECONDS}"
  # The child PID expands in the fixture shell.
  # shellcheck disable=SC2016
  expect_failure_with_marker inherited-stdout 7 inherited-marker 2s \
    "${PROVE_GATES_BASH_PATH}" -p -c 'set -euo pipefail
      "$2" 6 &
      child=$!
      builtin source "$3"
      snapshot="$(linux_process_snapshot "${child}")" || builtin exit "$4"
      IFS=$'"'"'\t'"'"' builtin read -r \
        observed_pid pgrp starttime kernel_state <<<"${snapshot}"
      [[ "${observed_pid}" == "${child}" ]] || builtin exit "$4"
      printf "%s\t%s\n" "${child}" "${starttime}" >"$1"
      printf "inherited-marker\n"
      exit 7' _ "${pid_file}" "${PROVE_GATES_SLEEP_PATH}" \
    "${PLATFORM_ROOT}/tools/common/process-state.sh" \
    "${EVIDENCE_BOUNDARY_STATUS}" || proof_status=$?
  elapsed=$((SECONDS - start))
  if ! IFS=$'\t' builtin read -r \
    child_pid child_starttime <"${pid_file}" ||
    ! linux_process_valid_id "${child_pid}" ||
    [[ ! "${child_starttime}" =~ ^[0-9]+$ ]]; then
    printf 'FAIL  red-marker    inherited-output child PID was not captured\n' >&2
    proof_status=1
  elif ! child_state="$(linux_process_state \
    "${child_pid}" "${child_starttime}")"; then
    printf 'FAIL  red-marker    inherited-output child state was not inspectable\n' >&2
    proof_status=1
  elif [[ "${child_state}" == live ]]; then
    builtin kill -KILL "${child_pid}" 2>/dev/null || true
    printf 'FAIL  red-marker    inherited-output child survived capture\n' >&2
    proof_status=1
  fi
  run_host_command rm -f -- "${pid_file}" || proof_status=1
  if ((elapsed > 3)); then
    printf 'FAIL  red-marker    inherited-output capture exceeded overall bound\n' >&2
    proof_status=1
  fi
  run_host_command grep -Fqx 'actual_status=7' \
    "${evidence_dir}/inherited-stdout.txt" || proof_status=1
  run_host_command grep -Fqx 'marker_observed=true' \
    "${evidence_dir}/inherited-stdout.txt" || proof_status=1
  [[ "${proof_status}" -eq 0 ]] || return 1
  printf 'PASS  red-marker    inherited-output child stopped without status drift\n'
}

prove_evidence_symlink_guards() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local raw_sentinel="${evidence_dir}/raw-sentinel"
  local final_sentinel="${evidence_dir}/final-sentinel"
  printf 'raw-safe\n' >"${raw_sentinel}"
  run_host_command ln -s raw-sentinel "${evidence_dir}/.raw-symlink.raw"
  expect_helper_status raw-symlink "${EVIDENCE_BOUNDARY_STATUS}" \
    expect_failure_with_marker raw-symlink 7 marker 5s \
    "${PROVE_GATES_BASH_PATH}" -p -c 'printf "marker\n"; exit 7'
  run_host_command grep -Fqx raw-safe "${raw_sentinel}"
  run_host_command rm -f "${evidence_dir}/.raw-symlink.raw"
  printf 'final-safe\n' >"${final_sentinel}"
  run_host_command ln -s final-sentinel "${evidence_dir}/final-symlink.txt"
  expect_helper_status final-symlink "${EVIDENCE_BOUNDARY_STATUS}" \
    expect_failure_with_marker final-symlink 7 marker 5s \
    "${PROVE_GATES_BASH_PATH}" -p -c 'printf "marker\n"; exit 7'
  run_host_command grep -Fqx final-safe "${final_sentinel}"
  run_host_command rm -f "${evidence_dir}/final-symlink.txt"
}

prove_red_marker_guard() {
  reset_state_directory "gate-evidence" || return
  prove_marker_semantics
  prove_literal_redaction
  prove_renderer_and_size_bounds
  prove_inherited_stdout_cleanup
  prove_evidence_symlink_guards
  assert_evidence_hygiene
  printf 'PASS  red-marker    rendering, reason, status, and bounds fail closed\n'
}

prove_local_gates() {
  "${PLATFORM_ROOT}/tools/bootstrap/prove-environment.sh"
  "${PLATFORM_ROOT}/tools/artifacts/prove-integrity.sh"
  "${PLATFORM_ROOT}/tools/diagnostics/prove-delivery-contract.sh"
  "${PLATFORM_ROOT}/tools/common/prove-state-safety.sh"
  "${PLATFORM_ROOT}/tools/common/prove-process-state.sh"
  "${PLATFORM_ROOT}/tools/kubernetes/prove-identity.sh"
  "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh" --self-check
  "${PLATFORM_ROOT}/tools/kubernetes/identity-negative-smoke.sh" --self-check
  "${PLATFORM_ROOT}/tools/kubernetes/publish-runtime-evidence.sh" --self-check
  "${PLATFORM_ROOT}/tools/kubernetes/negative-smoke.sh" --self-check
  prove_red_marker_guard
  expect_failure source-line-policy run_managed_tool go run \
    ./tools/quality/policycheck -path tests/fixtures/policy/long-line.sh
  expect_failure source-function-policy run_managed_tool go run \
    ./tools/quality/policycheck -path tests/fixtures/policy/long-function.sh
  expect_failure go-format run_managed_tool gofmt -d \
    tests/fixtures/go/unformatted.go
  expect_failure doctor-boundary "${PROVE_GATES_ENV_PATH}" \
    PLATFORM_TEST_FORCE_MISSING=curl \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only
  prove_unlocked_ci
  "${PLATFORM_ROOT}/tools/bootstrap/prove-tool-lock.sh"
  "${PLATFORM_ROOT}/tools/common/prove-managed-tools.sh"
  prove_kube_context_guard
  "${PLATFORM_ROOT}/tools/kubernetes/prove-safety.sh"
  prove_commit_policy
}

require_external_tools() {
  local tool
  for tool in shellcheck shfmt actionlint zizmor hadolint trivy kubeconform kube-linter; do
    require_tool "${tool}"
  done
}

prove_external_gates() {
  expect_failure_with_marker shellcheck 1 SC1046 30s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" shellcheck \
    tests/fixtures/shell/invalid.sh
  expect_failure_with_marker shell-format 1 \
    '+if true; then echo unformatted; fi' 30s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" shfmt -d -i 2 -ci \
    tests/fixtures/shell/unformatted.sh
  expect_failure_with_marker actionlint 1 '[syntax-check]' 30s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" actionlint \
    tests/fixtures/github/invalid.yml
  expect_failure_with_marker workflow-security 14 \
    'error[dangerous-triggers]' 30s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" zizmor --offline \
    tests/fixtures/github/unsafe.yml
  expect_failure_with_marker dockerfile 1 DL3007 30s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" hadolint \
    tests/fixtures/docker/Dockerfile
  expect_failure_with_marker secret-scan 1 \
    'CRITICAL: AWS (aws-access-key-id)' 60s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" trivy fs \
    --scanners secret --exit-code 1 tests/fixtures/secrets
  reset_state_directory "kubeconform" || return
  expect_failure_with_marker kube-schema 1 \
    'got string, want null or integer' 30s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" kubeconform \
    -cache "${PLATFORM_STATE_DIR}/kubeconform" \
    -kubernetes-version "${PLATFORM_KUBERNETES_SCHEMA_VERSION}" \
    -strict tests/fixtures/kubernetes/invalid-schema.yaml
  run_host_command grep -Fq \
    "/v${PLATFORM_KUBERNETES_SCHEMA_VERSION}-standalone-strict/" \
    "${PLATFORM_STATE_DIR}/gate-evidence/kube-schema.txt"
  if run_host_command grep -Fq '/master-standalone-strict/' \
    "${PLATFORM_STATE_DIR}/gate-evidence/kube-schema.txt"; then
    printf 'FAIL  kube-schema   floating master schema identity retained\n' >&2
    return 1
  fi
  expect_failure_with_marker kube-security 1 \
    '(check: privileged-container' 30s \
    "${PLATFORM_ROOT}/tools/common/run-managed-tool.sh" kube-linter lint \
    tests/fixtures/kubernetes/security-defect.yaml
}

main() {
  local local_only=false
  [[ "${1:-}" == "--local-only" ]] && local_only=true
  builtin cd -P -- "${PLATFORM_ROOT}"
  require_tool go
  require_tool gofmt
  prove_local_gates
  if [[ "${local_only}" == true ]]; then
    printf 'PASS  prove-gates    local configured gates demonstrated RED\n'
    return 0
  fi
  require_external_tools
  prove_external_gates
  printf 'PASS  prove-gates    all configured gates demonstrated RED\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
