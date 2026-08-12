#!/bin/bash -p
set -euo pipefail

DIAGNOSTICS_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DIAGNOSTICS_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  DIAGNOSTICS_SOURCE_DIR=.
builtin source "${DIAGNOSTICS_SOURCE_DIR}/evidence.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
builtin unset DIAGNOSTICS_SOURCE_DIR

diagnostics_tool_identity_command() {
  local tool="$1"
  case "${tool}" in
    go)
      run_managed_tool_bounded 5s go version
      ;;
    docker)
      docker_target_ensure && docker_command 5s --version
      ;;
    kind)
      kind_command 5s version
      ;;
    kubectl)
      kubectl_command 5s version --client=true
      ;;
    *)
      run_managed_tool_bounded 5s "${tool}" --version
      ;;
  esac
}

first_line() {
  local tool="$1" framed report payload
  framed="$({
    set +e
    diagnostics_tool_identity_command "${tool}" 2>&1 |
      sanitize_diagnostics_stream 300 --single-line 2>/dev/null
    local -a statuses=("${PIPESTATUS[@]}")
    ((statuses[1] == 0))
  })" || {
    builtin printf 'version-unavailable\n'
    return 0
  }
  [[ "${framed}" == *$'\n'* ]] || {
    builtin printf 'version-unavailable\n'
    return 0
  }
  report="${framed%%$'\n'*}"
  payload="${framed#*$'\n'}"
  case "${report}" in
    sanitizer_truncated=true | sanitizer_truncated=false) ;;
    *)
      builtin printf 'version-unavailable\n'
      return 0
      ;;
  esac
  [[ -n "${payload}" ]] || payload=version-unavailable
  builtin printf '%s\n' "${payload}"
}

write_tool_inventory() {
  local tool
  for tool in go docker kind kubectl shellcheck shfmt actionlint zizmor \
    hadolint trivy kubeconform kube-linter; do
    if require_tool "${tool}" >/dev/null 2>&1; then
      builtin printf 'tool.%s=present | %s\n' \
        "${tool}" "$(first_line "${tool}")"
    else
      builtin printf 'tool.%s=missing\n' "${tool}"
    fi
  done
}

render_capture_state() {
  local state="$1"
  builtin printf 'schema=flare-platform-diagnostics-capture-v2\n'
  builtin printf 'state=%s\n' "${state}"
  builtin printf 'run_id=%s\n' "${DIAGNOSTICS_RUN_ID}"
  builtin printf 'head=%s\n' "${DIAGNOSTICS_SOURCE_HEAD}"
  builtin printf 'tree=%s\n' "${DIAGNOSTICS_SOURCE_TREE}"
}

write_capture_state() {
  write_sanitized_diagnostic capture-status.txt 4096 \
    render_capture_state "$1"
}

render_summary() {
  builtin printf 'schema=flare-platform-diagnostics-v3\n'
  builtin printf 'run_id=%s\n' "${DIAGNOSTICS_RUN_ID}"
  builtin printf 'head=%s\n' "${DIAGNOSTICS_SOURCE_HEAD}"
  builtin printf 'tree=%s\n' "${DIAGNOSTICS_SOURCE_TREE}"
  builtin printf 'branch=%s\n' "${DIAGNOSTICS_SOURCE_BRANCH}"
  builtin printf 'dirty_entries=%s\n' "${DIAGNOSTICS_SOURCE_DIRTY_ENTRIES}"
  builtin printf 'os=%s\n' "$(run_host_command uname -s)"
  builtin printf 'arch=%s\n' "$(run_host_command uname -m)"
  builtin printf 'privacy=supported-secrets-controls-paths-redacted\n'
  write_tool_inventory
}

write_summary() {
  write_sanitized_diagnostic platform.txt \
    "${DIAGNOSTICS_MAX_SUMMARY_BYTES}" render_summary
}

write_cluster_status() {
  local message="$1"
  write_sanitized_diagnostic kubernetes-status.txt 4096 \
    builtin printf '%s\n' "${message}"
}

collect_cluster_diagnostics() {
  local presence
  if ! require_tool kind >/dev/null 2>&1 ||
    ! require_tool kubectl >/dev/null 2>&1; then
    write_cluster_status 'cluster=not-inspected; kind or kubectl missing'
    return 0
  fi
  presence="$(cluster_presence)" || {
    write_cluster_status 'cluster=not-inspected; kind query failed'
    return 0
  }
  if [[ "${presence}" == absent ]]; then
    write_cluster_status 'cluster=absent; no Kubernetes payload collected'
    return 0
  fi
  if [[ ! -f "${KUBECONFIG}" || -L "${KUBECONFIG}" ]]; then
    write_cluster_status 'cluster=present; kubeconfig=absent-or-unsafe'
    return 0
  fi
  if "${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh"; then
    write_cluster_status \
      'cluster=present; owned bounded inspection collected'
  else
    reset_state_directory "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes" || return
    write_cluster_status \
      'cluster=present; inspection refused or failed; no raw command output retained'
  fi
}

package_diagnostics() {
  publish_diagnostics_archive "$(diagnostics_raw_directory)"
  builtin printf \
    'PASS  diagnose      fresh bounded verified diagnostics published\n'
}

finalize_failed_capture() {
  local status=$? cleanup_status=0
  trap - EXIT
  invalidate_published_diagnostics >/dev/null 2>&1 || cleanup_status=1
  if [[ -n "${DIAGNOSTICS_RUN_ID}" ]] &&
    require_diagnostics_sanitizer >/dev/null 2>&1; then
    write_capture_state failed >/dev/null 2>&1 || cleanup_status=1
  fi
  if ((status == 0 && cleanup_status != 0)); then
    status=1
  fi
  builtin exit "${status}"
}

main() {
  umask 077
  trap finalize_failed_capture EXIT
  prepare_diagnostics_run
  write_capture_state collecting
  write_summary
  collect_cluster_diagnostics
  write_capture_state complete
  package_diagnostics
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
