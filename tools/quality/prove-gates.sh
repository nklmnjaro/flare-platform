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

prove_local_gates() {
  "${PLATFORM_ROOT}/tools/artifacts/prove-integrity.sh"
  "${PLATFORM_ROOT}/tools/common/prove-state-safety.sh"
  expect_failure source-line-policy bash -c \
    'cd tools/quality/policycheck && go run . -path ../../../tests/fixtures/policy/long-line.sh'
  expect_failure source-function-policy bash -c \
    'cd tools/quality/policycheck && go run . -path ../../../tests/fixtures/policy/long-function.sh'
  expect_failure go-format bash -c \
    '[[ -z "$(gofmt -d tests/fixtures/go/unformatted.go)" ]]'
  expect_failure doctor-boundary env PLATFORM_TEST_FORCE_MISSING=curl \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only
  expect_failure aqua-ci-unlocked env CI=true \
    "${PLATFORM_ROOT}/tools/bootstrap/bootstrap.sh"
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
  expect_failure shellcheck shellcheck tests/fixtures/shell/invalid.sh
  expect_failure shell-format shfmt -d -i 2 -ci tests/fixtures/shell/unformatted.sh
  expect_failure actionlint actionlint tests/fixtures/github/invalid.yml
  expect_failure workflow-security zizmor tests/fixtures/github/unsafe.yml
  expect_failure dockerfile hadolint tests/fixtures/docker/Dockerfile
  expect_failure secret-scan trivy fs --scanners secret --exit-code 1 tests/fixtures/secrets
  expect_failure kube-schema kubeconform -strict tests/fixtures/kubernetes/invalid-schema.yaml
  expect_failure kube-security kube-linter lint tests/fixtures/kubernetes/security-defect.yaml
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
