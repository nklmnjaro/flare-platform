#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

main() {
  local owner
  local cluster_name
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null

  owner="$(kubectl -n kube-system get configmap flare-platform-ownership \
    -o jsonpath='{.data.owner}' 2>/dev/null || true)"
  cluster_name="$(kubectl -n kube-system get configmap flare-platform-ownership \
    -o jsonpath='{.data.cluster-name}' 2>/dev/null || true)"

  if [[ "${owner}" != "flare-platform-infra" || "${cluster_name}" != "${PLATFORM_CLUSTER_NAME}" ]]; then
    printf 'FAIL  ownership     refusing unowned same-name cluster\n' >&2
    return 1
  fi
  printf 'PASS  ownership     %s\n' "${PLATFORM_CLUSTER_NAME}"
}

main "$@"
