#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

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
    sleep 1
  done
  printf 'FAIL  namespace     cleanup exceeded bounded poll window\n' >&2
  return 1
}

main "$@"
