#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

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
  mkdir -p "${directory}/tools/bootstrap" "${directory}/tools/common"
  cp "${PLATFORM_ROOT}/tools/bootstrap/bootstrap.sh" \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" "${directory}/tools/bootstrap/"
  cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${directory}/tools/bootstrap/aqua-trust.sh"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${directory}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${directory}/tools/common/state.sh"
  sed 's/^  require_checksum: true$/  require_checksum: false/' \
    "${PLATFORM_ROOT}/aqua.yaml" >"${directory}/aqua.yaml"
  grep -Fqx '  require_checksum: false' "${directory}/aqua.yaml"
  expect_failure_with_marker aqua-ci-unlocked 1 \
    'CI requires committed Aqua checksums.' 30s env CI=true \
    "${directory}/tools/bootstrap/bootstrap.sh"
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
  if find "${evidence_dir}" -maxdepth 1 \
    \( -name '.*.raw' -o -name '.*.render.*' -o -name '.*.bound.*' -o \
    -name '.*.status.*' \) \
    -print -quit | grep -q .; then
    printf 'FAIL  red-marker    transient evidence file survived\n' >&2
    return 1
  fi
  while IFS= read -r file; do
    size="$(wc -c <"${file}")"
    if ((size > EVIDENCE_MAX_FILE_BYTES)); then
      printf 'FAIL  red-marker    oversized durable evidence: %s\n' "${file}" >&2
      return 1
    fi
  done < <(find "${evidence_dir}" -maxdepth 1 -type f -name '*.txt' -print)
}

prove_marker_semantics() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  expect_helper_status missing-marker "${EVIDENCE_MISSING_MARKER}" \
    expect_failure_with_marker marker-guard 7 expected-marker 5s \
    bash -c 'printf "unrelated-output\n"; exit 7'
  expect_helper_status wrong-status "${EVIDENCE_WRONG_STATUS}" \
    expect_failure_with_marker status-guard 7 expected-marker 5s \
    bash -c 'printf "expected-marker\n"; exit 8'
  grep -Fqx 'actual_status=7' "${evidence_dir}/marker-guard.txt"
  grep -Fqx 'marker_observed=false' "${evidence_dir}/marker-guard.txt"
  grep -Fqx 'actual_status=8' "${evidence_dir}/status-guard.txt"
  grep -Fqx 'marker_observed=true' "${evidence_dir}/status-guard.txt"
}

prove_literal_redaction() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local special_root='/tmp/flare #review[1]&repo'
  local supported_home='/ho''me/review-user'
  # The positional argument expands in the fixture shell.
  # shellcheck disable=SC2016
  PLATFORM_ROOT="${special_root}" expect_failure_with_marker special-path 7 marker 5s \
    bash -c 'printf "%s marker\n" "$1"; exit 7' _ "${special_root}"
  grep -Fq '<REPO> marker' "${evidence_dir}/special-path.txt"
  if grep -Fq "${special_root}" "${evidence_dir}/special-path.txt"; then
    printf 'FAIL  red-marker    special repository path was retained\n' >&2
    return 1
  fi
  (
    export HOME="${supported_home}"
    # The positional argument expands in the fixture shell.
    # shellcheck disable=SC2016
    expect_failure_with_marker home-redaction 7 marker 5s \
      bash -c 'printf "%s/.cache/tool marker\n" "$1"; exit 7' _ "${supported_home}"
  )
  grep -Fq '<HOME>/.cache/tool marker' "${evidence_dir}/home-redaction.txt"
  if grep -Fq "${supported_home}" "${evidence_dir}/home-redaction.txt"; then
    printf 'FAIL  red-marker    supported home path was retained\n' >&2
    return 1
  fi
}

run_forced_renderer_failure() {
  PLATFORM_TEST_FORCE_EVIDENCE_RENDER_FAILURE=true \
    expect_failure_with_marker renderer-failure 7 marker 5s \
    bash -c 'printf "marker\n"; exit 7'
}

prove_renderer_and_size_bounds() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local saved_output="${evidence_dir}/renderer-failure.txt"
  printf 'retained-final\n' >"${saved_output}"
  expect_helper_status renderer-failure "${EVIDENCE_BOUNDARY_STATUS}" \
    run_forced_renderer_failure
  grep -Fqx retained-final "${saved_output}"
  expect_failure_with_marker oversized-output 124 oversize-marker 1s \
    bash -c 'while :; do printf "oversize-marker\n"; done'
  grep -Fqx 'raw_truncated=true' "${evidence_dir}/oversized-output.txt"
  [[ "$(wc -c <"${evidence_dir}/oversized-output.txt")" -le "${EVIDENCE_MAX_FILE_BYTES}" ]]
}

prove_inherited_stdout_cleanup() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local pid_file child_pid="" start elapsed proof_status=0
  pid_file="$(mktemp "${evidence_dir}/.inherited-child.XXXXXXXX")" || return
  start="${SECONDS}"
  # The child PID expands in the fixture shell.
  # shellcheck disable=SC2016
  expect_failure_with_marker inherited-stdout 7 inherited-marker 2s \
    bash -c 'set -euo pipefail
      sleep 6 &
      printf "%s\n" "$!" >"$1"
      printf "inherited-marker\n"
      exit 7' _ "${pid_file}" || proof_status=$?
  elapsed=$((SECONDS - start))
  if ! IFS= read -r child_pid <"${pid_file}" || [[ ! "${child_pid}" =~ ^[0-9]+$ ]]; then
    printf 'FAIL  red-marker    inherited-output child PID was not captured\n' >&2
    proof_status=1
  elif kill -0 "${child_pid}" 2>/dev/null; then
    kill -KILL "${child_pid}" 2>/dev/null || true
    printf 'FAIL  red-marker    inherited-output child survived capture\n' >&2
    proof_status=1
  fi
  rm -f -- "${pid_file}" || proof_status=1
  if ((elapsed > 3)); then
    printf 'FAIL  red-marker    inherited-output capture exceeded overall bound\n' >&2
    proof_status=1
  fi
  grep -Fqx 'actual_status=7' "${evidence_dir}/inherited-stdout.txt" || proof_status=1
  grep -Fqx 'marker_observed=true' "${evidence_dir}/inherited-stdout.txt" || proof_status=1
  [[ "${proof_status}" -eq 0 ]] || return 1
  printf 'PASS  red-marker    inherited-output child killed without status drift\n'
}

prove_evidence_symlink_guards() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local raw_sentinel="${evidence_dir}/raw-sentinel"
  local final_sentinel="${evidence_dir}/final-sentinel"
  printf 'raw-safe\n' >"${raw_sentinel}"
  ln -s raw-sentinel "${evidence_dir}/.raw-symlink.raw"
  expect_helper_status raw-symlink "${EVIDENCE_BOUNDARY_STATUS}" \
    expect_failure_with_marker raw-symlink 7 marker 5s \
    bash -c 'printf "marker\n"; exit 7'
  grep -Fqx raw-safe "${raw_sentinel}"
  rm -f "${evidence_dir}/.raw-symlink.raw"
  printf 'final-safe\n' >"${final_sentinel}"
  ln -s final-sentinel "${evidence_dir}/final-symlink.txt"
  expect_helper_status final-symlink "${EVIDENCE_BOUNDARY_STATUS}" \
    expect_failure_with_marker final-symlink 7 marker 5s \
    bash -c 'printf "marker\n"; exit 7'
  grep -Fqx final-safe "${final_sentinel}"
  rm -f "${evidence_dir}/final-symlink.txt"
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
  "${PLATFORM_ROOT}/tools/artifacts/prove-integrity.sh"
  "${PLATFORM_ROOT}/tools/diagnostics/prove-delivery-contract.sh"
  "${PLATFORM_ROOT}/tools/common/prove-state-safety.sh"
  "${PLATFORM_ROOT}/tools/kubernetes/prove-identity.sh"
  "${PLATFORM_ROOT}/tools/kubernetes/smoke.sh" --self-check
  "${PLATFORM_ROOT}/tools/kubernetes/identity-negative-smoke.sh" --self-check
  "${PLATFORM_ROOT}/tools/kubernetes/negative-smoke.sh" --self-check
  prove_red_marker_guard
  expect_failure source-line-policy bash -c \
    'cd tools/quality/policycheck && go run . -path ../../../tests/fixtures/policy/long-line.sh'
  expect_failure source-function-policy bash -c \
    'cd tools/quality/policycheck && go run . -path ../../../tests/fixtures/policy/long-function.sh'
  # The command must expand inside the fixture shell.
  # shellcheck disable=SC2016
  expect_failure go-format bash -c \
    '[[ -z "$(gofmt -d tests/fixtures/go/unformatted.go)" ]]'
  expect_failure doctor-boundary env PLATFORM_TEST_FORCE_MISSING=curl \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only
  prove_unlocked_ci
  "${PLATFORM_ROOT}/tools/bootstrap/prove-tool-lock.sh"
  expect_failure kube-context env PLATFORM_TEST_CURRENT_CONTEXT=kind-unrelated \
    "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
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
    shellcheck tests/fixtures/shell/invalid.sh
  expect_failure_with_marker shell-format 1 \
    '+if true; then echo unformatted; fi' 30s \
    shfmt -d -i 2 -ci tests/fixtures/shell/unformatted.sh
  expect_failure_with_marker actionlint 1 '[syntax-check]' 30s \
    actionlint tests/fixtures/github/invalid.yml
  expect_failure_with_marker workflow-security 14 \
    'error[dangerous-triggers]' 30s zizmor --offline \
    tests/fixtures/github/unsafe.yml
  expect_failure_with_marker dockerfile 1 DL3007 30s \
    hadolint tests/fixtures/docker/Dockerfile
  expect_failure_with_marker secret-scan 1 \
    'CRITICAL: AWS (aws-access-key-id)' 60s \
    trivy fs --scanners secret --exit-code 1 tests/fixtures/secrets
  reset_state_directory "kubeconform" || return
  expect_failure_with_marker kube-schema 1 \
    'got string, want null or integer' 30s \
    kubeconform -cache "${PLATFORM_STATE_DIR}/kubeconform" \
    -kubernetes-version "${PLATFORM_KUBERNETES_SCHEMA_VERSION}" \
    -strict tests/fixtures/kubernetes/invalid-schema.yaml
  grep -Fq "/v${PLATFORM_KUBERNETES_SCHEMA_VERSION}-standalone-strict/" \
    "${PLATFORM_STATE_DIR}/gate-evidence/kube-schema.txt"
  if grep -Fq '/master-standalone-strict/' \
    "${PLATFORM_STATE_DIR}/gate-evidence/kube-schema.txt"; then
    printf 'FAIL  kube-schema   floating master schema identity retained\n' >&2
    return 1
  fi
  expect_failure_with_marker kube-security 1 \
    '(check: privileged-container' 30s \
    kube-linter lint tests/fixtures/kubernetes/security-defect.yaml
}

main() {
  local local_only=false
  [[ "${1:-}" == "--local-only" ]] && local_only=true
  cd "${PLATFORM_ROOT}"
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

main "$@"
