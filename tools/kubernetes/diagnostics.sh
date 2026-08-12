#!/bin/bash -p
set -euo pipefail

KUBERNETES_DIAGNOSTICS_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${KUBERNETES_DIAGNOSTICS_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  KUBERNETES_DIAGNOSTICS_SOURCE_DIR=.
builtin source \
  "${KUBERNETES_DIAGNOSTICS_SOURCE_DIR}/../diagnostics/evidence.sh"
builtin source \
  "${KUBERNETES_DIAGNOSTICS_SOURCE_DIR}/diagnostic-authorization.sh"
builtin source "${KUBERNETES_DIAGNOSTICS_SOURCE_DIR}/runtime.sh"
builtin unset KUBERNETES_DIAGNOSTICS_SOURCE_DIR

MAX_CAPTURE_BYTES=131072

capture() {
  local name="$1"
  shift
  capture_diagnostic_command "kubernetes/${name}.txt" \
    "${MAX_CAPTURE_BYTES}" "$@" || return
}

collect_kubernetes_payloads() {
  capture nodes kubectl_command 20s get nodes -o wide || return
  capture resources kubectl_command 20s -n "${PLATFORM_NAMESPACE}" \
    get all -o wide || return
  capture events kubectl_command 20s -n "${PLATFORM_NAMESPACE}" \
    get events --sort-by=.lastTimestamp || return
  capture logs kubectl_command 20s -n "${PLATFORM_NAMESPACE}" \
    logs deployment/platform-reference --all-pods=true --tail=200 \
    --timestamps=true || return
}

main() {
  local context_guard="${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"
  local ownership_guard="${PLATFORM_ROOT}/tools/kubernetes/guard-ownership.sh"
  require_diagnostics_sanitizer || return
  run_fresh_diagnostic_collection \
    "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes" \
    run_authorized_diagnostic_collection \
    "${context_guard}" "${ownership_guard}" collect_kubernetes_payloads
  builtin printf \
    'INFO  diagnostics   owned bounded Kubernetes evidence collected\n'
}

main "$@"
