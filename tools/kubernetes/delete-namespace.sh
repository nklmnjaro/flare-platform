#!/bin/bash -p
set -euo pipefail

DELETE_NAMESPACE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DELETE_NAMESPACE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  DELETE_NAMESPACE_SOURCE_DIR=.
builtin source "${DELETE_NAMESPACE_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
builtin unset DELETE_NAMESPACE_SOURCE_DIR

namespace_presence() {
  local output
  output="$(kubectl_command 5s get namespace "${PLATFORM_NAMESPACE}" \
    --ignore-not-found -o name)" || {
    printf 'FAIL  namespace     unable to inspect namespace\n' >&2
    return 1
  }
  if [[ -n "${output}" ]]; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

main() {
  local deadline
  local presence
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null
  kubectl_command 20s delete namespace "${PLATFORM_NAMESPACE}" \
    --ignore-not-found=true --wait=false >/dev/null

  deadline=$((SECONDS + 45))
  while ((SECONDS < deadline)); do
    presence="$(namespace_presence)"
    if [[ "${presence}" == absent ]]; then
      printf 'PASS  namespace     %s removed\n' "${PLATFORM_NAMESPACE}"
      return 0
    fi
    run_host_command sleep 1
  done
  printf 'FAIL  namespace     cleanup exceeded bounded poll window\n' >&2
  return 1
}

main "$@"
