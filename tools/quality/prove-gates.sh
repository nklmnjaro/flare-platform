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
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${directory}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${directory}/tools/common/state.sh"
  sed 's/^  require_checksum: true$/  require_checksum: false/' \
    "${PLATFORM_ROOT}/aqua.yaml" >"${directory}/aqua.yaml"
  grep -Fqx '  require_checksum: false' "${directory}/aqua.yaml"
  expect_failure_with_marker aqua-ci-unlocked 1 \
    'CI requires committed Aqua checksums.' 30s env CI=true \
    "${directory}/tools/bootstrap/bootstrap.sh"
}

prove_red_marker_guard() {
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  if expect_failure_with_marker marker-guard 7 expected-marker 5s \
    bash -c 'printf "unrelated-output\n"; exit 7' >/dev/null 2>&1; then
    printf 'FAIL  red-marker    missing marker was accepted\n' >&2
    return 1
  fi
  if expect_failure_with_marker status-guard 7 expected-marker 5s \
    bash -c 'printf "expected-marker\n"; exit 8' >/dev/null 2>&1; then
    printf 'FAIL  red-marker    wrong exit status was accepted\n' >&2
    return 1
  fi
  grep -Fqx 'actual_status=7' "${evidence_dir}/marker-guard.txt"
  grep -Fqx 'actual_status=8' "${evidence_dir}/status-guard.txt"
  printf 'PASS  red-marker    wrong reason and status fail closed\n'
}

prove_local_gates() {
  "${PLATFORM_ROOT}/tools/artifacts/prove-integrity.sh"
  "${PLATFORM_ROOT}/tools/common/prove-state-safety.sh"
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
    'error[dangerous-triggers]' 30s zizmor tests/fixtures/github/unsafe.yml
  expect_failure_with_marker dockerfile 1 DL3007 30s \
    hadolint tests/fixtures/docker/Dockerfile
  expect_failure_with_marker secret-scan 1 \
    'CRITICAL: AWS (aws-access-key-id)' 60s \
    trivy fs --scanners secret --exit-code 1 tests/fixtures/secrets
  expect_failure_with_marker kube-schema 1 \
    'got string, want null or integer' 30s \
    kubeconform -strict tests/fixtures/kubernetes/invalid-schema.yaml
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
