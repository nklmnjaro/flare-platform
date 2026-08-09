#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

ownership_value() {
  local key="$1"
  kubectl_command 15s -n kube-system get configmap flare-platform-ownership \
    -o "jsonpath={.data.${key}}"
}

main() {
  local owner
  local cluster_name
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null

  owner="$(ownership_value owner)" || {
    printf 'FAIL  ownership     ownership marker is unreadable\n' >&2
    return 1
  }
  cluster_name="$(ownership_value cluster-name)" || {
    printf 'FAIL  ownership     cluster-name marker is unreadable\n' >&2
    return 1
  }

  if [[ "${owner}" != "flare-platform-infra" || "${cluster_name}" != "${PLATFORM_CLUSTER_NAME}" ]]; then
    printf 'FAIL  ownership     refusing unowned same-name cluster\n' >&2
    return 1
  fi
  printf 'PASS  ownership     %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
