#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

prove_commit_policy() {
  local message_file="${PLATFORM_STATE_DIR}/bad-commit-message.txt"
  mkdir -p "${PLATFORM_STATE_DIR}"
  printf 'bad commit title\n' >"${message_file}"
  expect_failure commit-policy "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" "${message_file}"
}

main() {
  local tool
  for tool in shellcheck actionlint zizmor hadolint trivy kubeconform kube-linter go; do
    require_tool "${tool}"
  done

  expect_failure source-line-policy bash -c \
    'cd tools/quality/policycheck && go run . -path ../../../tests/fixtures/policy/long-line.sh'
  expect_failure source-function-policy bash -c \
    'cd tools/quality/policycheck && go run . -path ../../../tests/fixtures/policy/long-function.sh'
  expect_failure shellcheck shellcheck tests/fixtures/shell/invalid.sh
  expect_failure actionlint actionlint tests/fixtures/github/invalid.yml
  expect_failure workflow-security zizmor tests/fixtures/github/unsafe.yml
  expect_failure dockerfile hadolint tests/fixtures/docker/Dockerfile
  expect_failure secret-scan trivy fs --scanners secret --exit-code 1 tests/fixtures/secrets
  expect_failure kube-schema kubeconform -strict tests/fixtures/kubernetes/invalid-schema.yaml
  expect_failure kube-security kube-linter lint tests/fixtures/kubernetes/security-defect.yaml
  expect_failure doctor-boundary env PLATFORM_TEST_FORCE_MISSING=curl \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only
  expect_failure kube-context env PLATFORM_TEST_CURRENT_CONTEXT=kind-unrelated \
    "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
  prove_commit_policy
  printf 'PASS  prove-gates    all static candidate gates demonstrated RED\n'
}

main "$@"
