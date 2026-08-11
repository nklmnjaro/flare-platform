#!/bin/bash -p
set -euo pipefail

DELETE_NAMESPACE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DELETE_NAMESPACE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  DELETE_NAMESPACE_SOURCE_DIR=.
builtin source "${DELETE_NAMESPACE_SOURCE_DIR}/ownership.sh"
builtin unset DELETE_NAMESPACE_SOURCE_DIR

namespace_presence() {
  local output
  output="$(kubectl_command 5s get namespace "${PLATFORM_NAMESPACE}" \
    --ignore-not-found -o name)" || {
    printf 'FAIL  namespace     unable to inspect namespace\n' >&2
    return 1
  }
  if [[ "${output}" == "namespace/${PLATFORM_NAMESPACE}" ]]; then
    printf 'present\n'
  elif [[ -z "${output}" ]]; then
    printf 'absent\n'
  else
    printf 'FAIL  namespace     namespace state is malformed\n' >&2
    return 1
  fi
}

main() {
  local deadline
  local presence
  local ownership_snapshot
  ownership_snapshot="$(ownership_current_checkout_snapshot)" || return
  presence="$(namespace_presence)" || return
  if [[ "${presence}" == absent ]]; then
    printf 'PASS  namespace     %s already absent\n' "${PLATFORM_NAMESPACE}"
    return 0
  fi
  ownership_recheck_snapshot "${ownership_snapshot}" >/dev/null
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
