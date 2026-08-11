#!/bin/bash -p
set -euo pipefail

PROVE_INTEGRITY_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_INTEGRITY_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_INTEGRITY_SOURCE_DIR=.
builtin source "${PROVE_INTEGRITY_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
unset PROVE_INTEGRITY_SOURCE_DIR

prove_home_path_rejection() {
  local fixture log output status
  ensure_state_directory "" || return
  fixture="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/artifact-home-path.XXXXXX")"
  log="$(run_host_command mktemp \
    "${PLATFORM_STATE_DIR}/artifact-home-path.XXXXXX.log")"
  output="${PLATFORM_STATE_DIR}/artifact-home-path-red.zip"
  printf 'synthetic workstation path: /%s\n' \
    'home/alice/project/worktree' >"${fixture}/leak.txt"
  run_host_command rm -f -- "${output}" "${output}.sha256"

  set +e
  (
    cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    run_managed_tool go run . pack --source "${fixture}" --output "${output}"
  ) >"${log}" 2>&1
  status=$?
  set -e

  run_host_command rm -rf -- "${fixture}"
  run_host_command rm -f -- "${output}" "${output}.sha256"
  if ((status == 0)); then
    run_host_command rm -f -- "${log}"
    printf 'FAIL  artifact-red  workstation home path unexpectedly passed\n' >&2
    return 1
  fi
  if ! run_host_command grep -Fq 'home path' "${log}"; then
    run_host_command cat -- "${log}" >&2
    run_host_command rm -f -- "${log}"
    printf 'FAIL  artifact-red  rejection reason was not home-path policy\n' >&2
    return 1
  fi
  run_host_command rm -f -- "${log}"
  printf 'PASS  artifact-red  workstation home path rejected at CLI boundary\n'
}

prove_empty_source_rejection() {
  local fixture log output status=0 reason_count
  ensure_state_directory "" || return
  fixture="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/artifact-empty-source.XXXXXX")" || return
  log="$(run_host_command mktemp \
    "${PLATFORM_STATE_DIR}/artifact-empty-source.XXXXXX.log")" || {
    run_host_command rm -rf -- "${fixture}"
    return 1
  }
  output="${PLATFORM_STATE_DIR}/artifact-empty-source-red.zip"
  run_host_command rm -f -- "${output}" "${output}.sha256"

  (
    builtin cd -P -- "${PLATFORM_ROOT}/tools/artifacts/archive"
    run_managed_tool go run . pack --source "${fixture}" --output "${output}"
  ) >"${log}" 2>&1 || status=$?
  reason_count="$(run_host_command grep -Fxc \
    'FAIL  artifact      source directory contains no regular files' \
    "${log}" || true)"
  if ((status == 0)) || [[ "${reason_count}" != 1 ]] ||
    [[ -e "${output}" || -L "${output}" ||
      -e "${output}.sha256" || -L "${output}.sha256" ]]; then
    run_host_command cat -- "${log}" >&2
    run_host_command rm -rf -- "${fixture}"
    run_host_command rm -f -- "${log}" "${output}" "${output}.sha256"
    printf 'FAIL  artifact-red  empty source rejection published output\n' >&2
    return 1
  fi
  run_host_command rm -rf -- "${fixture}"
  run_host_command rm -f -- "${log}"
  printf 'PASS  artifact-red  empty source rejected without ZIP or checksum\n'
}

stage_repository_source() {
  local destination="$1"
  local raw_list selected_list path status=0
  raw_list="$(run_host_command mktemp \
    "${PLATFORM_STATE_DIR}/artifact-source-raw.XXXXXX")" || return
  selected_list="$(run_host_command mktemp \
    "${PLATFORM_STATE_DIR}/artifact-source-selected.XXXXXX")" || {
    run_host_command rm -f -- "${raw_list}"
    return 1
  }

  run_host_command git -C "${PLATFORM_ROOT}" ls-files -z --cached --others \
    --exclude-standard >"${raw_list}" || status=$?
  if ((status == 0)); then
    : >"${selected_list}" || status=$?
  fi
  if ((status == 0)); then
    while IFS= read -r -d '' path; do
      if [[ -e "${PLATFORM_ROOT}/${path}" || -L "${PLATFORM_ROOT}/${path}" ]]; then
        printf '%s\0' "${path}" >>"${selected_list}" || {
          status=$?
          break
        }
      fi
    done <"${raw_list}"
  fi
  if ((status == 0)); then
    (
      builtin cd -P -- "${PLATFORM_ROOT}"
      run_host_command tar --null --verbatim-files-from \
        --files-from="${selected_list}" --create --file=-
    ) | run_host_command tar --extract --file=- \
      --directory="${destination}" || status=$?
  fi
  run_host_command rm -f -- "${raw_list}" "${selected_list}" || status=$?
  return "${status}"
}

prove_repository_packability() {
  local stage output status=0
  ensure_state_directory "" || return
  stage="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/artifact-source.XXXXXX")" || return
  output="$(prepare_state_file "artifact-source-selftest.zip")" || {
    run_host_command rm -rf -- "${stage}"
    return 1
  }
  run_host_command rm -f -- "${output}" "${output}.sha256"

  stage_repository_source "${stage}" || status=$?
  if ((status == 0)); then
    (
      cd "${PLATFORM_ROOT}/tools/artifacts/archive"
      run_managed_tool go run . pack --source "${stage}" --output "${output}" &&
        run_managed_tool go run . verify --archive "${output}"
    ) >/dev/null || status=$?
  fi
  run_host_command rm -rf -- "${stage}"
  run_host_command rm -f -- "${output}" "${output}.sha256"
  if ((status != 0)); then
    printf 'FAIL  artifact-self tracked source is not artifact-safe\n' >&2
    return 1
  fi
  printf 'PASS  artifact-self tracked source packages through canonical boundary\n'
}
main() {
  require_tool go
  (
    cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    run_managed_tool go test -count=1 -v ./...
  )
  prove_home_path_rejection
  prove_empty_source_rejection
  prove_repository_packability
  printf 'PASS  artifact-red  integrity, path, metadata, and resource bounds proved\n'
}

main "$@"
