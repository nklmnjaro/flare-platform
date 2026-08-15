#!/bin/bash -p
set -euo pipefail

COMMIT_RANGE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${COMMIT_RANGE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  COMMIT_RANGE_SOURCE_DIR=.
builtin source "${COMMIT_RANGE_SOURCE_DIR}/../common/env.sh"
unset COMMIT_RANGE_SOURCE_DIR

readonly COMMIT_RANGE_ZERO_SHA=0000000000000000000000000000000000000000
readonly COMMIT_RANGE_MAX_COMMITS=4096
COMMIT_RANGE_WORK_DIR=""

commit_range_cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${COMMIT_RANGE_WORK_DIR}" ]] &&
    ! run_host_command rm -rf -- "${COMMIT_RANGE_WORK_DIR}"; then
    status=1
  fi
  exit "${status}"
}

commit_range_fail() {
  printf 'FAIL  commit-range  %s\n' "$*" >&2
  return 1
}

validate_commit_sha() {
  local label="$1" value="$2"
  if [[ ! "${value}" =~ ^[0-9a-f]{40}$ ]]; then
    commit_range_fail "${label} must be a lowercase 40-character Git SHA"
  fi
}

require_commit_object() {
  local label="$1" sha="$2"
  if ! run_host_command git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    commit_range_fail "${label} commit unavailable: ${sha}"
  fi
}

collect_commit_range() {
  local event_name="$1" base_sha="$2" head_sha="$3" list_file="$4"
  local revision
  case "${event_name}" in
    pull_request)
      [[ "${base_sha}" != "${COMMIT_RANGE_ZERO_SHA}" ]] ||
        commit_range_fail 'pull_request base commit cannot be the zero SHA'
      require_commit_object base "${base_sha}"
      revision="${base_sha}..${head_sha}"
      ;;
    push)
      if [[ "${base_sha}" == "${COMMIT_RANGE_ZERO_SHA}" ]]; then
        revision="${head_sha}"
      else
        require_commit_object before "${base_sha}"
        revision="${base_sha}..${head_sha}"
      fi
      ;;
    *) commit_range_fail "unsupported GitHub event: ${event_name}" ;;
  esac
  run_host_command git rev-list --reverse --topo-order --no-merges \
    --max-count="$((COMMIT_RANGE_MAX_COMMITS + 1))" "${revision}" -- >"${list_file}" ||
    commit_range_fail 'unable to enumerate the event commit range'
}

validate_range_messages() {
  local event_name="$1" list_file="$2" message_file="$3"
  local commit_sha
  local -a commits=()
  mapfile -t commits <"${list_file}"
  ((${#commits[@]} > 0)) || commit_range_fail 'event commit range is empty'
  if ((${#commits[@]} > COMMIT_RANGE_MAX_COMMITS)); then
    commit_range_fail "event range exceeds ${COMMIT_RANGE_MAX_COMMITS} commits"
  fi
  for commit_sha in "${commits[@]}"; do
    run_host_command git show -s --format=%B "${commit_sha}" >"${message_file}" ||
      commit_range_fail "unable to read commit message: ${commit_sha}"
    if ! "${PLATFORM_ROOT}/tools/quality/check-commit-message.sh" \
      "${message_file}"; then
      commit_range_fail "commit rejected: ${commit_sha}"
    fi
  done
  printf 'PASS  commit-range  %s validated %d commit(s)\n' \
    "${event_name}" "${#commits[@]}"
}

main() {
  local event_name="${1:-}" base_sha="${2:-}" head_sha="${3:-}"
  local list_file message_file
  if (($# != 3)); then
    printf 'usage: %s <pull_request|push> <base-or-before-sha> <head-sha>\n' \
      "${0##*/}" >&2
    return 64
  fi
  validate_commit_sha base-or-before "${base_sha}"
  validate_commit_sha head "${head_sha}"
  [[ "${head_sha}" != "${COMMIT_RANGE_ZERO_SHA}" ]] ||
    commit_range_fail 'head commit cannot be the zero SHA'
  require_commit_object head "${head_sha}"
  ensure_state_directory commit-range || return
  COMMIT_RANGE_WORK_DIR="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/commit-range/check.XXXXXXXX")" || return
  trap commit_range_cleanup EXIT
  list_file="${COMMIT_RANGE_WORK_DIR}/commits.txt"
  message_file="${COMMIT_RANGE_WORK_DIR}/message.txt"
  collect_commit_range "${event_name}" "${base_sha}" "${head_sha}" \
    "${list_file}"
  validate_range_messages "${event_name}" "${list_file}" "${message_file}"
}

main "$@"
