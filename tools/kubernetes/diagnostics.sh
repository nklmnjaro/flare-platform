#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

MAX_CAPTURE_BYTES=131072
DIAGNOSTICS_TARGET="${PLATFORM_DIAGNOSTICS_DIR}/kubernetes"

capture() {
  local name="$1"
  shift
  local -a pipeline_status=()
  local payload size status truncated=false
  payload="$(mktemp "${DIAGNOSTICS_TARGET}/.capture.XXXXXX")"

  set +e
  "$@" 2>&1 | head -c "$((MAX_CAPTURE_BYTES + 1))" >"${payload}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  status="${pipeline_status[0]}"
  if ((pipeline_status[1] != 0)); then
    rm -f "${payload}"
    printf 'FAIL  diagnostics   unable to bound %s capture\n' "${name}" >&2
    return 1
  fi

  size="$(wc -c <"${payload}" | tr -d ' ')"
  ((size > MAX_CAPTURE_BYTES)) && truncated=true
  {
    printf 'exit_code=%s\n' "${status}"
    printf 'truncated=%s\n' "${truncated}"
    head -c "${MAX_CAPTURE_BYTES}" "${payload}"
  } >"${DIAGNOSTICS_TARGET}/${name}.txt"
  rm -f "${payload}"
}

main() {
  rm -rf "${DIAGNOSTICS_TARGET}"
  mkdir -p "${DIAGNOSTICS_TARGET}"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null

  capture nodes kubectl_command 20s get nodes -o wide
  capture resources kubectl_command 20s -n "${PLATFORM_NAMESPACE}" get all -o wide
  capture events kubectl_command 20s -n "${PLATFORM_NAMESPACE}" \
    get events --sort-by=.lastTimestamp
  capture describe-pods kubectl_command 25s -n "${PLATFORM_NAMESPACE}" describe pods
  capture logs kubectl_command 20s -n "${PLATFORM_NAMESPACE}" \
    logs deployment/platform-reference --all-pods=true --tail=200 --timestamps=true
  printf 'INFO  diagnostics   %s\n' "${DIAGNOSTICS_TARGET}"
}

main "$@"
