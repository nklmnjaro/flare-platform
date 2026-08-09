#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

first_line() {
  local tool="$1"
  "${tool}" --version 2>&1 | head -n 1 | cut -c 1-300 || true
}

write_tool_inventory() {
  local tool
  for tool in go docker kind kubectl shellcheck shfmt actionlint zizmor hadolint trivy kubeconform kube-linter; do
    if command -v "${tool}" >/dev/null 2>&1; then
      printf 'tool.%s=present | %s\n' "${tool}" "$(first_line "${tool}")"
    else
      printf 'tool.%s=missing\n' "${tool}"
    fi
  done
}

write_summary() {
  local dirty_count
  dirty_count="$(git -C "${PLATFORM_ROOT}" status --porcelain=v1 | wc -l | tr -d ' ')"
  {
    printf 'schema=flare-platform-diagnostics-v1\n'
    printf 'head=%s\n' "$(git -C "${PLATFORM_ROOT}" rev-parse HEAD)"
    printf 'branch=%s\n' "$(git -C "${PLATFORM_ROOT}" branch --show-current)"
    printf 'dirty_entries=%s\n' "${dirty_count}"
    printf 'os=%s\n' "$(uname -s)"
    printf 'arch=%s\n' "$(uname -m)"
    write_tool_inventory
  } >"${PLATFORM_DIAGNOSTICS_DIR}/platform.txt"
}

collect_cluster_diagnostics() {
  if ! command -v kind >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
    printf 'cluster=not-inspected; kind or kubectl missing\n' \
      >"${PLATFORM_DIAGNOSTICS_DIR}/kubernetes-status.txt"
    return 0
  fi
  if ! kind get clusters 2>/dev/null | grep -Fxq "${PLATFORM_CLUSTER_NAME}"; then
    printf 'cluster=absent\n' >"${PLATFORM_DIAGNOSTICS_DIR}/kubernetes-status.txt"
    return 0
  fi
  if [[ ! -f "${KUBECONFIG}" ]]; then
    printf 'cluster=present; kubeconfig=absent\n' \
      >"${PLATFORM_DIAGNOSTICS_DIR}/kubernetes-status.txt"
    return 0
  fi
  "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh" || true
}

package_diagnostics() {
  local archive="${PLATFORM_STATE_DIR}/platform-diagnostics.zip"
  if ! command -v go >/dev/null 2>&1; then
    printf 'WARN  diagnose      Go missing; raw diagnostics kept at .platform/diagnostics/raw\n' >&2
    return 0
  fi
  rm -f "${archive}" "${archive}.sha256"
  (
    cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    go run . pack --source "${PLATFORM_DIAGNOSTICS_DIR}" --output "${archive}"
  )
  printf 'PASS  diagnose      .platform/platform-diagnostics.zip\n'
}

main() {
  rm -rf "${PLATFORM_DIAGNOSTICS_DIR}"
  mkdir -p "${PLATFORM_DIAGNOSTICS_DIR}"
  write_summary
  collect_cluster_diagnostics
  package_diagnostics
}

main "$@"
