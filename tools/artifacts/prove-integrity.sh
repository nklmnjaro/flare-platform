#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

prove_home_path_rejection() {
  local fixture log output status
  ensure_state_directory "" || return
  fixture="$(mktemp -d "${PLATFORM_STATE_DIR}/artifact-home-path.XXXXXX")"
  log="$(mktemp "${PLATFORM_STATE_DIR}/artifact-home-path.XXXXXX.log")"
  output="${PLATFORM_STATE_DIR}/artifact-home-path-red.zip"
  printf 'synthetic workstation path: /%s\n' \
    'home/alice/project/worktree' >"${fixture}/leak.txt"
  rm -f "${output}" "${output}.sha256"

  set +e
  (
    cd "${PLATFORM_ROOT}/tools/artifacts/archive"
    run_managed_tool go run . pack --source "${fixture}" --output "${output}"
  ) >"${log}" 2>&1
  status=$?
  set -e

  rm -rf "${fixture}"
  rm -f "${output}" "${output}.sha256"
  if ((status == 0)); then
    rm -f "${log}"
    printf 'FAIL  artifact-red  workstation home path unexpectedly passed\n' >&2
    return 1
  fi
  if ! grep -Fq 'home path' "${log}"; then
    cat "${log}" >&2
    rm -f "${log}"
    printf 'FAIL  artifact-red  rejection reason was not home-path policy\n' >&2
    return 1
  fi
  rm -f "${log}"
  printf 'PASS  artifact-red  workstation home path rejected at CLI boundary\n'
}

stage_repository_source() {
  local destination="$1"
  local raw_list selected_list path status=0
  raw_list="$(mktemp "${PLATFORM_STATE_DIR}/artifact-source-raw.XXXXXX")" || return
  selected_list="$(mktemp "${PLATFORM_STATE_DIR}/artifact-source-selected.XXXXXX")" || {
    rm -f -- "${raw_list}"
    return 1
  }

  git -C "${PLATFORM_ROOT}" ls-files -z --cached --others --exclude-standard >"${raw_list}" || status=$?
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
      cd "${PLATFORM_ROOT}"
      tar --null --verbatim-files-from --files-from="${selected_list}" --create --file=-
    ) | tar --extract --file=- --directory="${destination}" || status=$?
  fi
  rm -f -- "${raw_list}" "${selected_list}" || status=$?
  return "${status}"
}

prove_repository_packability() {
  local stage output status=0
  ensure_state_directory "" || return
  stage="$(mktemp -d "${PLATFORM_STATE_DIR}/artifact-source.XXXXXX")" || return
  output="$(prepare_state_file "artifact-source-selftest.zip")" || {
    rm -rf -- "${stage}"
    return 1
  }
  rm -f -- "${output}" "${output}.sha256"

  stage_repository_source "${stage}" || status=$?
  if ((status == 0)); then
    (
      cd "${PLATFORM_ROOT}/tools/artifacts/archive"
      run_managed_tool go run . pack --source "${stage}" --output "${output}" &&
        run_managed_tool go run . verify --archive "${output}"
    ) >/dev/null || status=$?
  fi
  rm -rf -- "${stage}"
  rm -f -- "${output}" "${output}.sha256"
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
  prove_repository_packability
  printf 'PASS  artifact-red  integrity, path, metadata, and resource bounds proved\n'
}

main "$@"
