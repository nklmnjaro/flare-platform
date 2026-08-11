#!/bin/bash -p
set -euo pipefail

DIAGNOSTICS_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DIAGNOSTICS_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  DIAGNOSTICS_SOURCE_DIR=.
builtin source "${DIAGNOSTICS_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
unset DIAGNOSTICS_SOURCE_DIR

first_line() {
  local tool="$1"
  local output
  case "${tool}" in
    go)
      output="$(run_managed_tool_bounded 5s go version 2>&1)" || return
      ;;
    docker)
      docker_target_ensure || return
      output="$(docker_command 5s --version 2>&1)" || return
      ;;
    kind)
      output="$(kind_command 5s version 2>&1)" || return
      ;;
    kubectl)
      output="$(kubectl_command 5s version --client=true 2>&1)" || return
      ;;
    *)
      output="$(run_managed_tool_bounded 5s "${tool}" --version 2>&1)" || return
      ;;
  esac
  output="${output%%$'\n'*}"
  printf '%.300s\n' "${output}"
}

write_tool_inventory() {
  local tool
  for tool in go docker kind kubectl shellcheck shfmt actionlint zizmor hadolint trivy kubeconform kube-linter; do
    if require_tool "${tool}" >/dev/null 2>&1; then
      printf 'tool.%s=present | %s\n' "${tool}" "$(first_line "${tool}")"
    else
      printf 'tool.%s=missing\n' "${tool}"
    fi
  done
}

write_summary() {
  local dirty_count
  local target
  target="$(prepare_state_file "diagnostics/raw/platform.txt")" || return
  dirty_count="$(run_host_command git -C "${PLATFORM_ROOT}" \
    status --porcelain=v1 | run_host_command wc -l)"
  dirty_count="${dirty_count//[[:space:]]/}"
  {
    printf 'schema=flare-platform-diagnostics-v1\n'
    printf 'head=%s\n' "$(run_host_command git -C "${PLATFORM_ROOT}" rev-parse HEAD)"
    printf 'branch=%s\n' "$(run_host_command git -C "${PLATFORM_ROOT}" branch --show-current)"
    printf 'dirty_entries=%s\n' "${dirty_count}"
    printf 'os=%s\n' "$(run_host_command uname -s)"
    printf 'arch=%s\n' "$(run_host_command uname -m)"
    write_tool_inventory
  } >"${target}"
}

write_cluster_status() {
  local message="$1"
  local target
  target="$(prepare_state_file "diagnostics/raw/kubernetes-status.txt")" || return
  printf '%s\n' "${message}" >"${target}"
}

collect_cluster_diagnostics() {
  local presence
  if ! require_tool kind >/dev/null 2>&1 || ! require_tool kubectl >/dev/null 2>&1; then
    write_cluster_status 'cluster=not-inspected; kind or kubectl missing'
    return 0
  fi
  presence="$(cluster_presence)" || {
    write_cluster_status 'cluster=not-inspected; kind query failed'
    return 0
  }
  if [[ "${presence}" == absent ]]; then
    write_cluster_status 'cluster=absent; retained current runtime capture when present'
    return 0
  fi
  if [[ ! -f "${KUBECONFIG}" ]]; then
    write_cluster_status 'cluster=present; kubeconfig=absent'
    return 0
  fi
  if "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh"; then
    write_cluster_status 'cluster=present; bounded inspection collected'
  else
    write_cluster_status 'cluster=present; bounded inspection failed; partial evidence retained'
  fi
}

package_diagnostics() {
  local archive
  if ! require_tool go >/dev/null 2>&1; then
    printf 'WARN  diagnose      Go missing; raw diagnostics kept below .platform/diagnostics\n' >&2
    return 0
  fi
  archive="$(prepare_state_file "platform-diagnostics.zip")" || return
  prepare_state_file "platform-diagnostics.zip.sha256" >/dev/null || return
  run_host_command rm -f -- "${archive}" "${archive}.sha256"
  (
    builtin cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    run_managed_tool go run . pack \
      --source "${PLATFORM_DIAGNOSTICS_DIR}" --output "${archive}"
  )
  printf 'PASS  diagnose      .platform/platform-diagnostics.zip\n'
}

main() {
  docker_target_ensure || return
  ensure_state_directory "diagnostics/raw" || return
  write_summary
  collect_cluster_diagnostics
  package_diagnostics
}

main "$@"
