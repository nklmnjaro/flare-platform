#!/usr/bin/env bash
builtin set -euo pipefail

builtin source "${PLATFORM_ROOT}/tools/common/state.sh"
builtin source "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh"
PROCESS_STATE_MODULE_PATH="${PLATFORM_ROOT}/tools/common/process-state.sh"
EVIDENCE_CAPTURE_SCRIPT="${PLATFORM_ROOT}/tools/common/evidence-capture.sh"
# shellcheck source=process-state.sh
builtin source "${PROCESS_STATE_MODULE_PATH}"

EVIDENCE_BOUNDARY_STATUS=70
EVIDENCE_WRONG_STATUS=71
EVIDENCE_MISSING_MARKER=72
EVIDENCE_MAX_FILE_BYTES=32768
EVIDENCE_MAX_RAW_BYTES=65536
MANAGED_TOOL_PATH=""

is_managed_tool() {
  case "$1" in
    go | gofmt | kind | kubectl | shellcheck | shfmt | actionlint | zizmor | \
      hadolint | trivy | kubeconform | kube-linter | prek)
      return 0
      ;;
    *) return 1 ;;
  esac
}

managed_tool_failure() {
  local command_name="$1"
  builtin printf \
    'FAIL  tooling       project-managed toolchain unavailable or untrusted: %s; run make bootstrap\n' \
    "${command_name}" >&2
  return 1
}

resolve_managed_tool() {
  local command_name="$1"
  local candidate proxy resolved root symlink_target
  is_managed_tool "${command_name}" || {
    builtin printf 'FAIL  tooling       %s is not an Aqua-managed command\n' \
      "${command_name}" >&2
    return 2
  }
  if ! verify_existing_aqua tooling >/dev/null 2>&1; then
    managed_tool_failure "${command_name}"
    return
  fi
  if ! verify_existing_aqua_proxy tooling >/dev/null 2>&1; then
    managed_tool_failure "${command_name}"
    return
  fi
  if ! assert_existing_state_directory "aqua/bin"; then
    managed_tool_failure "${command_name}"
    return
  fi
  candidate="${AQUA_ROOT_DIR}/bin/${command_name}"
  proxy="${AQUA_ROOT_DIR}/aqua-proxy"
  if [[ ! -L "${candidate}" || ! -L "${proxy}" ||
    ! -f "${candidate}" || ! -x "${candidate}" ]]; then
    managed_tool_failure "${command_name}"
    return
  fi
  symlink_target="$({
    "${AQUA_TRUST_READLINK}" -n -- "${candidate}" && builtin printf '\036'
  })" || {
    managed_tool_failure "${command_name}"
    return
  }
  if [[ "${symlink_target}" != "../aqua-proxy"$'\036' ]]; then
    managed_tool_failure "${command_name}"
    return
  fi
  root="$("${AQUA_TRUST_READLINK}" -f -- "${AQUA_ROOT_DIR}")" || {
    managed_tool_failure "${command_name}"
    return
  }
  resolved="$("${AQUA_TRUST_READLINK}" -f -- "${candidate}")" || {
    managed_tool_failure "${command_name}"
    return
  }
  case "${resolved}" in
    "${root}"/*) ;;
    *)
      managed_tool_failure "${command_name}"
      return
      ;;
  esac
  if [[ ! "${candidate}" -ef "${proxy}" ]]; then
    managed_tool_failure "${command_name}"
    return
  fi
  MANAGED_TOOL_PATH="${candidate}"
}

managed_tool_path() {
  resolve_managed_tool "$1" || return
  builtin printf '%s\n' "${MANAGED_TOOL_PATH}"
}

run_managed_tool() {
  local command_name="$1"
  shift
  resolve_managed_tool "${command_name}" || return
  run_project_aqua_command "${command_name}" "$@"
}

run_managed_tool_bounded() {
  local max_time="${1:-}" command_name="${2:-}"
  (($# >= 2)) || {
    builtin printf \
      'FAIL  tooling       timeout and managed command are required\n' >&2
    return "${HOST_COMMAND_USAGE_STATUS}"
  }
  shift 2
  aqua_validate_bounded_duration "${max_time}" || return
  resolve_managed_tool "${command_name}" || return
  run_project_aqua_command_bounded "${max_time}" "${command_name}" "$@"
}

# Replace the current isolated process-group leader with the bounded command.
exec_managed_tool_bounded() {
  local max_time="${1:-}" command_name="${2:-}"
  (($# >= 2)) || {
    builtin printf \
      'FAIL  tooling       timeout and managed command are required\n' >&2
    return "${HOST_COMMAND_USAGE_STATUS}"
  }
  shift 2
  aqua_validate_bounded_duration "${max_time}" || return
  resolve_managed_tool "${command_name}" || return
  exec_project_aqua_command_bounded "${max_time}" "${command_name}" "$@"
}

require_tool() {
  local command_name="$1"
  if is_managed_tool "${command_name}"; then
    resolve_managed_tool "${command_name}" >/dev/null
    return
  fi
  host_command_admit "${command_name}" >/dev/null
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    builtin printf 'FAIL  red-fixture   %s unexpectedly passed\n' \
      "${label}" >&2
    return 1
  fi
  builtin printf 'PASS  red-fixture   %s rejected\n' "${label}"
}

validate_evidence_arguments() {
  local label="$1"
  local expected_status="$2"
  if [[ ! "${label}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    builtin printf 'FAIL  red-marker    unsafe evidence label: %q\n' \
      "${label}" >&2
    return "${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ ! "${expected_status}" =~ ^[0-9]+$ ]] || ((expected_status > 255)); then
    builtin printf 'FAIL  red-marker    invalid expected status: %q\n' \
      "${expected_status}" >&2
    return "${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ -z "${PLATFORM_ROOT:-}" || -z "${PLATFORM_STATE_DIR:-}" ]]; then
    builtin printf 'FAIL  red-marker    repository or state root is empty\n' >&2
    return "${EVIDENCE_BOUNDARY_STATUS}"
  fi
}

cleanup_evidence_capture() {
  local status=$?
  trap - EXIT
  if [[ "${raw_owned}" == true ]] &&
    ! run_host_command rm -f -- "${raw_output}"; then
    status="${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ "${render_owned}" == true ]] &&
    ! run_host_command rm -f -- "${render_output}"; then
    status="${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ "${bound_owned}" == true ]] &&
    ! run_host_command rm -f -- "${bound_output}"; then
    status="${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ "${status_owned}" == true ]] &&
    ! run_host_command rm -f -- "${status_output}"; then
    status="${EVIDENCE_BOUNDARY_STATUS}"
  fi
  exit "${status}"
}

render_evidence_file() {
  local raw_output="$1"
  local render_output="$2"
  local label="$3"
  local expected_status="$4"
  local actual_status="$5"
  local marker="$6"
  local marker_found="$7"
  local raw_truncated="$8"
  local payload read_status raw_size header_size remaining marker_evidence
  local sentinel=$'\036'
  local LC_ALL=C
  [[ "${PLATFORM_TEST_FORCE_EVIDENCE_RENDER_FAILURE:-}" != true ]] || return 1
  raw_size="$(run_host_command wc -c <"${raw_output}")" || return
  ((raw_size <= EVIDENCE_MAX_RAW_BYTES)) || return 1
  payload="$({
    run_host_command cat -- "${raw_output}" || exit 1
    builtin printf '%s' "${sentinel}"
  })"
  read_status=$?
  [[ "${read_status}" -eq 0 && "${payload: -1}" == "${sentinel}" ]] || return 1
  payload="${payload::-1}"
  ((${#payload} == raw_size)) || return 1
  payload="${payload//"${PLATFORM_ROOT}"/<REPO>}"
  marker_evidence="${marker//"${PLATFORM_ROOT}"/<REPO>}"
  if [[ -n "${HOME:-}" ]]; then
    payload="${payload//"${HOME}"/<HOME>}"
    marker_evidence="${marker_evidence//"${HOME}"/<HOME>}"
  fi
  {
    builtin printf 'schema=flare-platform-red-evidence-v1\n'
    builtin printf 'label=%s\nexpected_status=%s\nactual_status=%s\n' \
      "${label}" "${expected_status}" "${actual_status}"
    builtin printf \
      'expected_marker=%q\nmarker_observed=%s\nraw_truncated=%s\n' \
      "${marker_evidence}" "${marker_found}" "${raw_truncated}"
    builtin printf 'total_file_bound_bytes=%s\npayload_begin\n' \
      "${EVIDENCE_MAX_FILE_BYTES}"
  } >"${render_output}" || return
  header_size="$(run_host_command wc -c <"${render_output}")" || return
  ((header_size <= EVIDENCE_MAX_FILE_BYTES)) || return 1
  remaining=$((EVIDENCE_MAX_FILE_BYTES - header_size))
  builtin printf '%s' "${payload:0:remaining}" >>"${render_output}" || return
  [[ "$(run_host_command wc -c <"${render_output}")" -le "${EVIDENCE_MAX_FILE_BYTES}" ]]
}

capture_bounded_evidence() {
  local raw_output="$1" status_output="$2" max_time="$3"
  local timeout_path bash_path head_path cat_path mktemp_path rm_path sleep_path
  shift 3
  timeout_path="$(host_command_path timeout)" || return
  bash_path="$(host_command_path bash)" || return
  head_path="$(host_command_path head)" || return
  cat_path="$(host_command_path cat)" || return
  mktemp_path="$(host_command_path mktemp)" || return
  rm_path="$(host_command_path rm)" || return
  sleep_path="$(host_command_path sleep)" || return
  [[ -f "${EVIDENCE_CAPTURE_SCRIPT}" && ! -L "${EVIDENCE_CAPTURE_SCRIPT}" ]] ||
    return "${EVIDENCE_BOUNDARY_STATUS}"
  "${timeout_path}" --foreground --signal=TERM --kill-after=2s \
    "${max_time}" "${bash_path}" -p "${EVIDENCE_CAPTURE_SCRIPT}" \
    "${raw_output}" "${status_output}" \
    "${EVIDENCE_MAX_RAW_BYTES}" "${EVIDENCE_BOUNDARY_STATUS}" \
    "${PROCESS_STATE_MODULE_PATH}" "${head_path}" "${cat_path}" \
    "${mktemp_path}" "${rm_path}" "${sleep_path}" "$@"
}

read_captured_status() {
  local status_output="$1"
  local -a lines=()
  mapfile -t lines <"${status_output}" || return
  [[ "${#lines[@]}" -eq 1 && "${lines[0]}" =~ ^[0-9]+$ ]] || return 1
  ((10#${lines[0]} <= 255)) || return 1
  builtin printf '%s\n' "$((10#${lines[0]}))"
}

expect_failure_with_marker() (
  set +e
  local label="$1" expected_status="$2" marker="$3" max_time="$4"
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local raw_output="${evidence_dir}/.${label}.raw"
  local saved_output="${evidence_dir}/${label}.txt"
  local render_output="" bound_output="" status_output=""
  local raw_owned=false render_owned=false bound_owned=false status_owned=false
  local capture_status=0 marker_found=false raw_truncated=false raw_size status
  shift 4
  trap cleanup_evidence_capture EXIT
  validate_evidence_arguments "${label}" "${expected_status}" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  ensure_state_directory "gate-evidence" || return "${EVIDENCE_BOUNDARY_STATUS}"
  raw_output="$(prepare_state_file "gate-evidence/.${label}.raw")" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  saved_output="$(prepare_state_file "gate-evidence/${label}.txt")" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  run_host_command rm -f -- "${raw_output}" ||
    return "${EVIDENCE_BOUNDARY_STATUS}"
  raw_owned=true
  status_output="$(run_host_command mktemp \
    "${evidence_dir}/.${label}.status.XXXXXXXX")" ||
    return "${EVIDENCE_BOUNDARY_STATUS}"
  status_owned=true
  [[ -f "${status_output}" && ! -L "${status_output}" ]] || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  capture_bounded_evidence "${raw_output}" "${status_output}" "${max_time}" "$@" ||
    capture_status=$?
  if [[ "${capture_status}" -eq 124 && ! -s "${status_output}" ]]; then
    status=124
  elif [[ "${capture_status}" -ne 0 ]]; then
    return "${EVIDENCE_BOUNDARY_STATUS}"
  else
    status="$(read_captured_status "${status_output}")" || return \
      "${EVIDENCE_BOUNDARY_STATUS}"
  fi
  raw_size="$(run_host_command wc -c <"${raw_output}")" ||
    return "${EVIDENCE_BOUNDARY_STATUS}"
  if ((raw_size > EVIDENCE_MAX_RAW_BYTES)); then
    raw_truncated=true
    bound_output="$(run_host_command mktemp \
      "${evidence_dir}/.${label}.bound.XXXXXXXX")" ||
      return "${EVIDENCE_BOUNDARY_STATUS}"
    bound_owned=true
    run_host_command head -c "${EVIDENCE_MAX_RAW_BYTES}" "${raw_output}" \
      >"${bound_output}" || return "${EVIDENCE_BOUNDARY_STATUS}"
    run_host_command mv -f -- "${bound_output}" "${raw_output}" ||
      return "${EVIDENCE_BOUNDARY_STATUS}"
    bound_owned=false
  fi
  run_host_command grep -Fq -- "${marker}" "${raw_output}" && marker_found=true
  render_output="$(run_host_command mktemp \
    "${evidence_dir}/.${label}.render.XXXXXXXX")" ||
    return "${EVIDENCE_BOUNDARY_STATUS}"
  render_owned=true
  [[ -f "${render_output}" && ! -L "${render_output}" ]] || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  render_evidence_file "${raw_output}" "${render_output}" "${label}" \
    "${expected_status}" "${status}" "${marker}" "${marker_found}" \
    "${raw_truncated}" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  prepare_state_file "gate-evidence/${label}.txt" >/dev/null || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  run_host_command mv -f -- "${render_output}" "${saved_output}" ||
    return "${EVIDENCE_BOUNDARY_STATUS}"
  render_owned=false
  if [[ "${status}" -ne "${expected_status}" ]]; then
    builtin printf 'FAIL  red-marker    %s exited %s, expected %s\n' \
      "${label}" "${status}" "${expected_status}" >&2
    return "${EVIDENCE_WRONG_STATUS}"
  fi
  if [[ "${marker_found}" != true ]]; then
    builtin printf 'FAIL  red-marker    %s missed expected marker: %s\n' \
      "${label}" "${marker}" >&2
    return "${EVIDENCE_MISSING_MARKER}"
  fi
  builtin printf 'PASS  red-marker    %s rejected with %s\n' \
    "${label}" "${marker}"
)

expect_success() {
  local label="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    builtin printf 'FAIL  green-fixture %s unexpectedly failed\n' \
      "${label}" >&2
    return 1
  fi
  builtin printf 'PASS  green-fixture %s accepted\n' "${label}"
}
