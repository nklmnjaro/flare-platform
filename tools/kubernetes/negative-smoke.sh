#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

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
  local output
  for ((attempt = 1; attempt <= 20; attempt++)); do
    output="$(kubectl_command 10s -n "${PLATFORM_NAMESPACE}" \
      logs deployment/platform-reference --all-pods=true --tail=40 2>/dev/null || true)"
    if grep -Fq 'intentional startup failure requested' <<<"${output}"; then
      return 0
    fi
    sleep 1
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
    size="$(wc -c <"${file}" | tr -d ' ')"
    if ((size > 132000)); then
      printf 'FAIL  diagnostics   oversized file: %s\n' "${file}" >&2
      return 1
    fi
  done
  if ! grep -Fq 'intentional startup failure requested' "${target}/logs.txt"; then
    printf 'FAIL  diagnostics   expected startup marker is absent from evidence\n' >&2
    return 1
  fi
}

main() {
  local fixture="${PLATFORM_ROOT}/tests/fixtures/kubernetes/failing-workload.yaml"
  local status=0
  trap emergency_cleanup EXIT

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
    elif ! observe_expected_failure; then
      printf 'FAIL  kind-negative expected startup marker was not observed\n' >&2
      status=1
    fi
  fi

  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh" || status=1
  fi
  diagnostics_are_bounded || status=1
  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" || status=1
  fi
  trap - EXIT
  [[ "${status}" == 0 ]] || return 1
  printf 'PASS  kind-negative expected failure, diagnostics, and cleanup proved\n'
}

main "$@"
