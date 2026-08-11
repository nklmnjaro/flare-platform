#!/bin/bash -p
set -euo pipefail

DIAGNOSTICS_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DIAGNOSTICS_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  DIAGNOSTICS_SOURCE_DIR=.
builtin source "${DIAGNOSTICS_SOURCE_DIR}/ownership.sh"
builtin unset DIAGNOSTICS_SOURCE_DIR

MAX_CAPTURE_BYTES=131072
DIAGNOSTICS_TARGET="${PLATFORM_DIAGNOSTICS_DIR}/kubernetes"

capture() {
  local name="$1"
  shift
  local -a pipeline_status=()
  local payload size status truncated=false
  payload="$(run_host_command mktemp "${DIAGNOSTICS_TARGET}/.capture.XXXXXX")"

  set +e
  "$@" 2>&1 | run_host_command head -c "$((MAX_CAPTURE_BYTES + 1))" \
    >"${payload}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  status="${pipeline_status[0]}"
  if ((pipeline_status[1] != 0)); then
    run_host_command rm -f -- "${payload}"
    printf 'FAIL  diagnostics   unable to bound %s capture\n' "${name}" >&2
    return 1
  fi

  size="$(run_host_command wc -c <"${payload}")"
  ((size > MAX_CAPTURE_BYTES)) && truncated=true
  {
    printf 'exit_code=%s\n' "${status}"
    printf 'truncated=%s\n' "${truncated}"
    run_host_command head -c "${MAX_CAPTURE_BYTES}" "${payload}"
  } >"${DIAGNOSTICS_TARGET}/${name}.txt"
  run_host_command rm -f -- "${payload}"
}

main() {
  reset_state_directory "diagnostics/raw/kubernetes" || return
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null

  capture checkout-identity platform_checkout_identity
  capture ownership ownership_read_snapshot
  capture nodes kubectl_command 20s get nodes -o wide
  capture resources kubectl_command 20s -n "${PLATFORM_NAMESPACE}" get all -o wide
  capture events kubectl_command 20s -n "${PLATFORM_NAMESPACE}" \
    get events --sort-by=.lastTimestamp
  capture describe-pods kubectl_command 25s -n "${PLATFORM_NAMESPACE}" describe pods
  capture logs kubectl_command 20s -n "${PLATFORM_NAMESPACE}" \
    logs deployment/platform-reference --all-pods=true --tail=200 --timestamps=true
  printf 'INFO  diagnostics   bounded Kubernetes captures recorded\n'
}

main "$@"
