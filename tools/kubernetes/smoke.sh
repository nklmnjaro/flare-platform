#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"

PORT_FORWARD_PID=""
PROBE_RESPONSE_FILE=""

stop_probe() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    PORT_FORWARD_PID=""
  fi
  if [[ -n "${PROBE_RESPONSE_FILE}" ]]; then
    rm -f -- "${PROBE_RESPONSE_FILE}"
    PROBE_RESPONSE_FILE=""
  fi
}

emergency_cleanup() {
  local status=$?
  stop_probe
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

apply_reference() {
  local manifest
  for manifest in namespace deployment service; do
    kubectl_command 30s apply -f \
      "${PLATFORM_ROOT}/kubernetes/reference/${manifest}.yaml" || return 1
  done
}

probe() {
  local attempt
  local port_forward_log
  local response
  port_forward_log="$(prepare_state_file "port-forward.log")" || return
  PROBE_RESPONSE_FILE="$(mktemp "${PLATFORM_STATE_DIR}/.health-response.XXXXXXXX")" || return
  timeout --signal=TERM --kill-after=5s 35s kubectl \
    --request-timeout=0 port-forward \
    -n "${PLATFORM_NAMESPACE}" service/platform-reference 18080:8080 \
    >"${port_forward_log}" 2>&1 &
  PORT_FORWARD_PID=$!

  for ((attempt = 1; attempt <= 20; attempt++)); do
    kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1 || break
    if curl --fail --silent --show-error --max-time 2 --max-filesize 16 \
      --output "${PROBE_RESPONSE_FILE}" http://127.0.0.1:18080/healthz &&
      [[ "$(wc -c <"${PROBE_RESPONSE_FILE}")" -eq 3 ]] &&
      [[ "$(wc -l <"${PROBE_RESPONSE_FILE}")" -eq 1 ]] &&
      IFS= read -r response <"${PROBE_RESPONSE_FILE}" && [[ "${response}" == ok ]]; then
      printf 'INFO  kind-smoke    health_response="%s" terminator=LF\n' "${response}"
      stop_probe
      return 0
    fi
    sleep 1
  done
  stop_probe
  return 1
}

capture_failure() {
  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh" || true
  fi
}

main() {
  local status=0
  trap emergency_cleanup EXIT

  "${PLATFORM_ROOT}/tools/kubernetes/kind-up.sh" || status=1
  if [[ "${status}" == 0 ]] && ! load_reference_image; then
    status=1
  fi
  if [[ "${status}" == 0 ]] && ! apply_reference; then
    status=1
  fi
  if [[ "${status}" == 0 ]] && ! kubectl_command 75s -n "${PLATFORM_NAMESPACE}" \
    rollout status deployment/platform-reference --timeout=60s; then
    status=1
  fi
  if [[ "${status}" == 0 ]] && ! probe; then
    status=1
  fi
  if [[ "${status}" != 0 ]]; then
    capture_failure
  fi

  if [[ -f "${KUBECONFIG}" ]]; then
    "${PLATFORM_ROOT}/tools/kubernetes/delete-namespace.sh" || status=1
  fi
  trap - EXIT
  if [[ "${status}" != 0 ]]; then
    printf 'FAIL  kind-smoke    reference workload verification failed\n' >&2
    return 1
  fi
  printf 'PASS  kind-smoke    build -> load -> rollout -> HTTP probe -> cleanup\n'
}

main "$@"
