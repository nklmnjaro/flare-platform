#!/bin/bash -p
set -euo pipefail

NEGATIVE_SMOKE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${NEGATIVE_SMOKE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  NEGATIVE_SMOKE_SOURCE_DIR=.
builtin source "${NEGATIVE_SMOKE_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
unset NEGATIVE_SMOKE_SOURCE_DIR

STARTUP_MARKER="intentional startup failure requested"
NEGATIVE_EVIDENCE_SCHEMA="flare-platform-runtime-identity-negative-v1"
NEGATIVE_EVIDENCE_RELATIVE="runtime-identity/negative.env"

emergency_cleanup() {
  local status=$?
  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" >/dev/null 2>&1 || true
  fi
  return "${status}"
}

load_reference_image() {
  "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  kind_command 120s load docker-image "${PLATFORM_IMAGE}" \
    --name "${PLATFORM_CLUSTER_NAME}"
}

observe_expected_failure() {
  local attempt
  local line
  local output
  for ((attempt = 1; attempt <= 20; attempt++)); do
    output="$(kubectl_command 10s -n "${PLATFORM_NAMESPACE}" \
      logs deployment/platform-reference --all-pods=true --tail=40 2>/dev/null || true)"
    while IFS= read -r line; do
      if [[ "${line}" == "${STARTUP_MARKER}" ||
        "${line}" == *" ${STARTUP_MARKER}" ]]; then
        printf 'INFO  kind-negative startup_marker="%s"\n' "${STARTUP_MARKER}"
        return 0
      fi
    done <<<"${output}"
    run_host_command sleep 1
  done
  return 1
}

diagnostics_are_bounded() {
  local capture file size
  local target="${PLATFORM_DIAGNOSTICS_DIR}/kubernetes"
  local -a captures=(nodes resources events describe-pods logs)
  if [[ ! -d "${target}" ]]; then
    printf 'FAIL  diagnostics   expected capture directory is missing\n' >&2
    return 1
  fi
  for capture in "${captures[@]}"; do
    file="${target}/${capture}.txt"
    if [[ ! -s "${file}" ]]; then
      printf 'FAIL  diagnostics   expected capture is missing: %s\n' "${capture}" >&2
      return 1
    fi
    if ! size="$(run_host_command wc -c <"${file}")" ||
      [[ ! "${size}" =~ ^[0-9]+$ ]]; then
      printf 'FAIL  diagnostics   unable to measure capture: %s\n' "${file}" >&2
      return 1
    fi
    if ((size > 132000)); then
      printf 'FAIL  diagnostics   oversized file: %s\n' "${file}" >&2
      return 1
    fi
  done
  if ! run_host_command grep -Fq "${STARTUP_MARKER}" "${target}/logs.txt"; then
    printf 'FAIL  diagnostics   expected startup marker is absent from evidence\n' >&2
    return 1
  fi
}

render_negative_evidence() {
  printf 'SCHEMA=%s\n' "${NEGATIVE_EVIDENCE_SCHEMA}"
  printf 'STARTUP_MARKER=%q\n' "${STARTUP_MARKER}"
  printf 'NAMESPACE_ABSENT=true\n'
}

negative_evidence_is_exact() {
  local file="$1"
  local actual=""
  local expected
  if [[ -L "${file}" || ! -f "${file}" ]]; then
    printf 'FAIL  kind-negative evidence staging file is not regular\n' >&2
    return 1
  fi
  printf -v expected 'SCHEMA=%s\nSTARTUP_MARKER=%q\nNAMESPACE_ABSENT=true\n' \
    "${NEGATIVE_EVIDENCE_SCHEMA}" "${STARTUP_MARKER}"
  IFS= read -r -d '' actual <"${file}" || true
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL  kind-negative evidence staging content is not exact\n' >&2
    return 1
  fi
}

publish_negative_evidence() {
  local prepared
  local target
  local temporary
  target="$(prepare_state_file "${NEGATIVE_EVIDENCE_RELATIVE}")" || return
  temporary="$(run_host_command mktemp -- "${target}.tmp.XXXXXX")" || {
    printf 'FAIL  kind-negative unable to create evidence staging file\n' >&2
    return 1
  }
  if ! render_negative_evidence >"${temporary}"; then
    run_host_command rm -f -- "${temporary}"
    printf 'FAIL  kind-negative unable to render evidence\n' >&2
    return 1
  fi
  if ! negative_evidence_is_exact "${temporary}"; then
    run_host_command rm -f -- "${temporary}"
    return 1
  fi
  prepared="$(prepare_state_file "${NEGATIVE_EVIDENCE_RELATIVE}")" || {
    run_host_command rm -f -- "${temporary}"
    return 1
  }
  if [[ "${prepared}" != "${target}" ]]; then
    run_host_command rm -f -- "${temporary}"
    printf 'FAIL  kind-negative state helper returned unexpected evidence path\n' >&2
    return 1
  fi
  if ! run_host_command mv -fT -- "${temporary}" "${target}"; then
    run_host_command rm -f -- "${temporary}"
    printf 'FAIL  kind-negative unable to publish evidence atomically\n' >&2
    return 1
  fi
}

prove_negative_evidence_format() (
  local expected_marker="${STARTUP_MARKER}"
  local temporary
  temporary="$(run_host_command mktemp)"
  trap 'run_host_command rm -f -- "${temporary}"' EXIT
  render_negative_evidence >"${temporary}"
  negative_evidence_is_exact "${temporary}"
  if ! (
    unset SCHEMA STARTUP_MARKER NAMESPACE_ABSENT
    # The generated file is trusted test output and must remain sourceable.
    # shellcheck disable=SC1090
    builtin source "${temporary}"
    # These variables are assigned by the sourced evidence above.
    # shellcheck disable=SC2153
    [[ "${SCHEMA}" == "${NEGATIVE_EVIDENCE_SCHEMA}" &&
      "${STARTUP_MARKER}" == "${expected_marker}" &&
      "${NAMESPACE_ABSENT}" == true ]]
  ); then
    printf 'FAIL  kind-negative evidence is not exactly sourceable\n' >&2
    return 1
  fi
  printf 'UNEXPECTED=true\n' >>"${temporary}"
  if negative_evidence_is_exact "${temporary}" >/dev/null 2>&1; then
    printf 'FAIL  kind-negative altered evidence was accepted\n' >&2
    return 1
  fi
  printf 'PASS  kind-negative evidence format and rejection self-check\n'
)

prove_diagnostics_measurement_failure() (
  local capture status
  local -a captures=(nodes resources events describe-pods logs)
  PLATFORM_DIAGNOSTICS_DIR="$(run_host_command mktemp -d)"
  trap 'run_host_command rm -rf -- "${PLATFORM_DIAGNOSTICS_DIR}"' EXIT
  run_host_command mkdir -p -- "${PLATFORM_DIAGNOSTICS_DIR}/kubernetes"
  for capture in "${captures[@]}"; do
    printf '%s\n' "${STARTUP_MARKER}" >"${PLATFORM_DIAGNOSTICS_DIR}/kubernetes/${capture}.txt"
  done
  # Proves that the host-command boundary rejects an inherited function.
  # shellcheck disable=SC2317,SC2329
  wc() { return 1; }
  if diagnostics_are_bounded >/dev/null 2>&1; then
    printf 'FAIL  kind-negative diagnostics measurement failure was accepted\n' >&2
    return 1
  else
    status=$?
  fi
  [[ "${status}" -eq 1 ]] || return 1
  printf 'PASS  kind-negative diagnostics measurement failure rejected\n'
)

main() {
  local diagnostics_bounded=false
  local evidence
  local fixture="${PLATFORM_ROOT}/tests/fixtures/kubernetes/failing-workload.yaml"
  local marker_observed=false
  local namespace_absent=false
  local status=0

  if [[ "${1:-}" == --self-check ]]; then
    prove_negative_evidence_format
    prove_diagnostics_measurement_failure
    return
  fi
  docker_target_ensure || return
  trap emergency_cleanup EXIT

  evidence="$(prepare_state_file "${NEGATIVE_EVIDENCE_RELATIVE}")" || return
  run_host_command rm -f -- "${evidence}"

  "${PLATFORM_ROOT}/tools/kubernetes/kind-up.sh" || status=1
  if [[ "${status}" == 0 ]] && ! load_reference_image; then
    status=1
  fi
  if [[ "${status}" == 0 ]]; then
    if ! kubectl_command 30s apply \
      -f "${PLATFORM_ROOT}/kubernetes/reference/namespace.yaml"; then
      status=1
    elif ! kubectl_command 30s apply -f "${fixture}"; then
      status=1
    fi
  fi
  if [[ "${status}" == 0 ]]; then
    if kubectl_command 25s -n "${PLATFORM_NAMESPACE}" rollout status \
      deployment/platform-reference --timeout=15s; then
      printf 'FAIL  kind-negative failing workload unexpectedly became ready\n' >&2
      status=1
    elif observe_expected_failure; then
      marker_observed=true
    else
      printf 'FAIL  kind-negative expected startup marker was not observed\n' >&2
      status=1
    fi
  fi

  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh" || status=1
    if diagnostics_are_bounded; then
      diagnostics_bounded=true
    else
      status=1
    fi
  else
    status=1
  fi
  if [[ -f "${KUBECONFIG}" ]]; then
    if "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh"; then
      namespace_absent=true
    else
      status=1
    fi
  else
    status=1
  fi
  if [[ "${status}" == 0 ]]; then
    if [[ "${marker_observed}" != true || "${diagnostics_bounded}" != true ||
      "${namespace_absent}" != true ]]; then
      printf 'FAIL  kind-negative evidence prerequisites are incomplete\n' >&2
      status=1
    elif ! publish_negative_evidence; then
      status=1
    fi
  fi
  [[ "${status}" == 0 ]] || return 1
  printf 'PASS  kind-negative expected failure, diagnostics, and cleanup proved\n'
  trap - EXIT
}

main "$@"
