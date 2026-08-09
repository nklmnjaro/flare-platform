#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

cleanup_namespace() {
  kubectl delete namespace "${PLATFORM_NAMESPACE}" --wait=true --timeout=30s >/dev/null 2>&1 || true
}

probe() {
  local pid
  local result=1
  kubectl -n "${PLATFORM_NAMESPACE}" port-forward service/platform-reference 18080:8080 \
    >"${PLATFORM_STATE_DIR}/port-forward.log" 2>&1 &
  pid=$!

  for _ in $(seq 1 20); do
    if curl --fail --silent --show-error http://127.0.0.1:18080/healthz | grep -Fxq ok; then
      result=0
      break
    fi
    sleep 1
  done

  kill "${pid}" >/dev/null 2>&1 || true
  wait "${pid}" >/dev/null 2>&1 || true
  return "${result}"
}

main() {
  local failed=0
  trap cleanup_namespace EXIT

  "${PLATFORM_ROOT}/tools/kubernetes/kind-up.sh"
  "${PLATFORM_ROOT}/tools/kubernetes/build-reference.sh"
  kind load docker-image "${PLATFORM_IMAGE}" --name "${PLATFORM_CLUSTER_NAME}"
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh"

  kubectl apply -f "${PLATFORM_ROOT}/kubernetes/reference/namespace.yaml"
  kubectl apply -f "${PLATFORM_ROOT}/kubernetes/reference/deployment.yaml"
  kubectl apply -f "${PLATFORM_ROOT}/kubernetes/reference/service.yaml"
  kubectl -n "${PLATFORM_NAMESPACE}" rollout status deployment/platform-reference --timeout=60s || failed=1
  probe || failed=1

  if ((failed)); then
    "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh"
    return 1
  fi
  printf 'PASS  kind-smoke    build -> load -> rollout -> HTTP probe -> cleanup\n'
}

main "$@"
