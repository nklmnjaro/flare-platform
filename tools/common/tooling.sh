#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/state.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../bootstrap/aqua-trust.sh"

EVIDENCE_BOUNDARY_STATUS=70
EVIDENCE_WRONG_STATUS=71
EVIDENCE_MISSING_MARKER=72
EVIDENCE_MAX_FILE_BYTES=32768
EVIDENCE_MAX_RAW_BYTES=65536
MANAGED_TOOL_PATH=""
PROJECT_AQUA_VERIFIED=false

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
  printf 'FAIL  tooling       project-managed toolchain unavailable or untrusted: %s; run make bootstrap\n' \
    "${command_name}" >&2
  return 1
}

resolve_managed_tool() {
  local command_name="$1"
  local candidate proxy resolved root symlink_target
  is_managed_tool "${command_name}" || {
    printf 'FAIL  tooling       %s is not an Aqua-managed command\n' \
      "${command_name}" >&2
    return 2
  }
  if [[ "${PROJECT_AQUA_VERIFIED}" != true ]]; then
    if ! verify_existing_aqua tooling >/dev/null 2>&1; then
      managed_tool_failure "${command_name}"
      return
    fi
    PROJECT_AQUA_VERIFIED=true
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
    readlink -n -- "${candidate}" && printf '\036'
  })" || {
    managed_tool_failure "${command_name}"
    return
  }
  if [[ "${symlink_target}" != "../aqua-proxy"$'\036' ]]; then
    managed_tool_failure "${command_name}"
    return
  fi
  root="$(readlink -f -- "${AQUA_ROOT_DIR}")" || {
    managed_tool_failure "${command_name}"
    return
  }
  resolved="$(readlink -f -- "${candidate}")" || {
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
  printf '%s\n' "${MANAGED_TOOL_PATH}"
}

run_managed_tool() {
  local command_name="$1"
  shift
  resolve_managed_tool "${command_name}" || return
  "${MANAGED_TOOL_PATH}" "$@"
}

require_tool() {
  local command_name="$1"
  if is_managed_tool "${command_name}"; then
    resolve_managed_tool "${command_name}" >/dev/null
    return
  fi
  if command -v "${command_name}" >/dev/null 2>&1; then
    return 0
  fi
  printf 'FAIL  tooling       %s missing; run make bootstrap\n' "${command_name}" >&2
  return 1
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL  red-fixture   %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  red-fixture   %s rejected\n' "${label}"
}

validate_evidence_arguments() {
  local label="$1"
  local expected_status="$2"
  if [[ ! "${label}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'FAIL  red-marker    unsafe evidence label: %q\n' "${label}" >&2
    return "${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ ! "${expected_status}" =~ ^[0-9]+$ ]] || ((expected_status > 255)); then
    printf 'FAIL  red-marker    invalid expected status: %q\n' \
      "${expected_status}" >&2
    return "${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ -z "${PLATFORM_ROOT:-}" || -z "${PLATFORM_STATE_DIR:-}" ]]; then
    printf 'FAIL  red-marker    repository or state root is empty\n' >&2
    return "${EVIDENCE_BOUNDARY_STATUS}"
  fi
}

cleanup_evidence_capture() {
  local status=$?
  trap - EXIT
  if [[ "${raw_owned}" == true ]] && ! rm -f -- "${raw_output}"; then
    status="${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ "${render_owned}" == true ]] && ! rm -f -- "${render_output}"; then
    status="${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ "${bound_owned}" == true ]] && ! rm -f -- "${bound_output}"; then
    status="${EVIDENCE_BOUNDARY_STATUS}"
  fi
  if [[ "${status_owned}" == true ]] && ! rm -f -- "${status_output}"; then
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
  raw_size="$(wc -c <"${raw_output}")" || return
  ((raw_size <= EVIDENCE_MAX_RAW_BYTES)) || return 1
  payload="$({
    cat -- "${raw_output}" || exit 1
    printf '%s' "${sentinel}"
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
    printf 'schema=flare-platform-red-evidence-v1\n'
    printf 'label=%s\nexpected_status=%s\nactual_status=%s\n' \
      "${label}" "${expected_status}" "${actual_status}"
    printf 'expected_marker=%q\nmarker_observed=%s\nraw_truncated=%s\n' \
      "${marker_evidence}" "${marker_found}" "${raw_truncated}"
    printf 'total_file_bound_bytes=%s\npayload_begin\n' "${EVIDENCE_MAX_FILE_BYTES}"
  } >"${render_output}" || return
  header_size="$(wc -c <"${render_output}")" || return
  ((header_size <= EVIDENCE_MAX_FILE_BYTES)) || return 1
  remaining=$((EVIDENCE_MAX_FILE_BYTES - header_size))
  printf '%s' "${payload:0:remaining}" >>"${render_output}" || return
  [[ "$(wc -c <"${render_output}")" -le "${EVIDENCE_MAX_FILE_BYTES}" ]]
}

capture_bounded_evidence() {
  local raw_output="$1" status_output="$2" max_time="$3"
  shift 3
  # The capture program expands in the bounded child shell.
  # shellcheck disable=SC2016
  timeout --signal=TERM --kill-after=2s "${max_time}" bash -c '
set +e
raw_output=$1
status_output=$2
raw_max=$3
boundary_status=$4
shift 4
command_pid=""
collector_pid=""
writer_fd=""
set -m || exit "${boundary_status}"

cleanup_capture() {
  local saved_status=$?
  trap - EXIT TERM INT HUP
  [[ -z "${command_pid}" ]] || kill -KILL -- "-${command_pid}" 2>/dev/null || true
  [[ -z "${collector_pid}" ]] || kill -KILL -- "-${collector_pid}" 2>/dev/null || true
  [[ -z "${writer_fd}" ]] || exec {writer_fd}>&-
  [[ -z "${command_pid}" ]] || wait "${command_pid}" 2>/dev/null || true
  [[ -z "${collector_pid}" ]] || wait "${collector_pid}" 2>/dev/null || true
  exit "${saved_status}"
}

trap cleanup_capture EXIT
trap "exit 124" TERM INT HUP
coproc EVIDENCE_COLLECTOR {
  collector_status=0
  head -c "$((raw_max + 1))" >"${raw_output}" || collector_status=$?
  cat >/dev/null || collector_status=$?
  exit "${collector_status}"
}
collector_pid=${EVIDENCE_COLLECTOR_PID:-}
[[ -n "${collector_pid}" && ${#EVIDENCE_COLLECTOR[@]} -eq 2 ]] || exit "${boundary_status}"
collector_output_fd=${EVIDENCE_COLLECTOR[0]}
exec {writer_fd}>&"${EVIDENCE_COLLECTOR[1]}" || exit "${boundary_status}"
collector_input_fd=${EVIDENCE_COLLECTOR[1]}
exec {collector_input_fd}>&- || exit "${boundary_status}"
exec {collector_output_fd}<&- || exit "${boundary_status}"
(
  set +m || exit "${boundary_status}"
  ulimit -c 0 || exit "${boundary_status}"
  "$@"
  command_status=$?
  printf "%s\n" "${command_status}" >"${status_output}" || exit "${boundary_status}"
  exit 0
) >&"${writer_fd}" 2>&1 &
command_pid=$!
exec {writer_fd}>&- || exit "${boundary_status}"
writer_fd=""
set +m || exit "${boundary_status}"
wait "${command_pid}"
producer_status=$?
kill -KILL -- "-${command_pid}" 2>/dev/null || true
wait "${collector_pid}"
collector_status=$?
command_pid=""
collector_pid=""
trap - EXIT TERM INT HUP
[[ "${producer_status}" -eq 0 && "${collector_status}" -eq 0 ]]
' evidence-capture "${raw_output}" "${status_output}" \
    "${EVIDENCE_MAX_RAW_BYTES}" "${EVIDENCE_BOUNDARY_STATUS}" "$@"
}

read_captured_status() {
  local status_output="$1"
  local -a lines=()
  mapfile -t lines <"${status_output}" || return
  [[ "${#lines[@]}" -eq 1 && "${lines[0]}" =~ ^[0-9]+$ ]] || return 1
  ((10#${lines[0]} <= 255)) || return 1
  printf '%s\n' "$((10#${lines[0]}))"
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
  rm -f -- "${raw_output}" || return "${EVIDENCE_BOUNDARY_STATUS}"
  raw_owned=true
  status_output="$(mktemp "${evidence_dir}/.${label}.status.XXXXXXXX")" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
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
  raw_size="$(wc -c <"${raw_output}")" || return "${EVIDENCE_BOUNDARY_STATUS}"
  if ((raw_size > EVIDENCE_MAX_RAW_BYTES)); then
    raw_truncated=true
    bound_output="$(mktemp "${evidence_dir}/.${label}.bound.XXXXXXXX")" || return \
      "${EVIDENCE_BOUNDARY_STATUS}"
    bound_owned=true
    head -c "${EVIDENCE_MAX_RAW_BYTES}" "${raw_output}" >"${bound_output}" || return \
      "${EVIDENCE_BOUNDARY_STATUS}"
    mv -f -- "${bound_output}" "${raw_output}" || return \
      "${EVIDENCE_BOUNDARY_STATUS}"
    bound_owned=false
  fi
  grep -Fq -- "${marker}" "${raw_output}" && marker_found=true
  render_output="$(mktemp "${evidence_dir}/.${label}.render.XXXXXXXX")" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  render_owned=true
  [[ -f "${render_output}" && ! -L "${render_output}" ]] || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  render_evidence_file "${raw_output}" "${render_output}" "${label}" \
    "${expected_status}" "${status}" "${marker}" "${marker_found}" \
    "${raw_truncated}" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  prepare_state_file "gate-evidence/${label}.txt" >/dev/null || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  mv -f -- "${render_output}" "${saved_output}" || return \
    "${EVIDENCE_BOUNDARY_STATUS}"
  render_owned=false
  if [[ "${status}" -ne "${expected_status}" ]]; then
    printf 'FAIL  red-marker    %s exited %s, expected %s\n' \
      "${label}" "${status}" "${expected_status}" >&2
    return "${EVIDENCE_WRONG_STATUS}"
  fi
  if [[ "${marker_found}" != true ]]; then
    printf 'FAIL  red-marker    %s missed expected marker: %s\n' \
      "${label}" "${marker}" >&2
    return "${EVIDENCE_MISSING_MARKER}"
  fi
  printf 'PASS  red-marker    %s rejected with %s\n' "${label}" "${marker}"
)

expect_success() {
  local label="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL  green-fixture %s unexpectedly failed\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  green-fixture %s accepted\n' "${label}"
}
