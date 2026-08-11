#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

main() {
  local tool
  for tool in hadolint trivy kubeconform kube-linter; do
    require_tool "${tool}"
  done

  "${PLATFORM_ROOT}/tools/quality/check-fast.sh"
  run_managed_tool hadolint kubernetes/reference/Dockerfile
  printf 'PASS  hadolint      reference Dockerfile accepted\n'
  run_managed_tool trivy fs --scanners secret --exit-code 1 \
    --skip-dirs .git --skip-dirs .platform --skip-dirs tests/fixtures .
  printf 'PASS  trivy         real repository secret target accepted\n'
  ensure_state_directory "kubeconform" || return
  run_managed_tool kubeconform -cache "${PLATFORM_STATE_DIR}/kubeconform" \
    -kubernetes-version "${PLATFORM_KUBERNETES_SCHEMA_VERSION}" \
    -strict -summary kubernetes/reference/*.yaml
  printf 'PASS  kube-schema   pinned real manifests accepted\n'
  run_managed_tool kube-linter lint kubernetes/reference
  printf 'PASS  kube-security real manifests accepted\n'
  printf 'PASS  check         full static and security checks\n'
}

main "$@"
