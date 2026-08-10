#!/usr/bin/env bash
set -euo pipefail

require_tool() {
  local command_name="$1"
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

expect_failure_with_marker() {
  local label="$1"
  local expected_status="$2"
  local marker="$3"
  local max_time="$4"
  local evidence_dir="${PLATFORM_STATE_DIR}/gate-evidence"
  local raw_output="${evidence_dir}/.${label}.raw"
  local saved_output="${evidence_dir}/${label}.txt"
  local marker_found=false
  local status
  shift 4
  mkdir -p "${evidence_dir}"
  rm -f "${raw_output}" "${saved_output}"
  set +e
  (
    ulimit -f 128
    timeout "${max_time}" "$@"
  ) >"${raw_output}" 2>&1
  status=$?
  set -e
  if grep -Fq -- "${marker}" "${raw_output}"; then
    marker_found=true
  fi
  {
    printf 'label=%s\nexpected_status=%s\nactual_status=%s\nmarker=%s\n' \
      "${label}" "${expected_status}" "${status}" "${marker}"
    head -c 32768 "${raw_output}" | sed "s#${PLATFORM_ROOT}#<REPO>#g"
  } >"${saved_output}"
  rm -f "${raw_output}"
  if [[ "${status}" -ne "${expected_status}" ]]; then
    printf 'FAIL  red-marker    %s exited %s, expected %s\n' \
      "${label}" "${status}" "${expected_status}" >&2
    sed -n '1,40p' "${saved_output}" >&2
    return 1
  fi
  if [[ "${marker_found}" != true ]]; then
    printf 'FAIL  red-marker    %s missed expected marker: %s\n' \
      "${label}" "${marker}" >&2
    sed -n '1,40p' "${saved_output}" >&2
    return 1
  fi
  printf 'PASS  red-marker    %s rejected with %s\n' "${label}" "${marker}"
}

expect_success() {
  local label="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'FAIL  green-fixture %s unexpectedly failed\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  green-fixture %s accepted\n' "${label}"
}
