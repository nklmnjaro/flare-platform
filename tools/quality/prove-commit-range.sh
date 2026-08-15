#!/bin/bash -p
set -euo pipefail

COMMIT_RANGE_PROOF_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${COMMIT_RANGE_PROOF_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  COMMIT_RANGE_PROOF_SOURCE_DIR=.
builtin source "${COMMIT_RANGE_PROOF_SOURCE_DIR}/../common/env.sh"
unset COMMIT_RANGE_PROOF_SOURCE_DIR

readonly COMMIT_RANGE_PROOF_ZERO_SHA=0000000000000000000000000000000000000000
COMMIT_RANGE_PROOF_REPO=""
COMMIT_RANGE_PROOF_TREE=""

fixture_commit() {
  local message_file="$1"
  shift
  local parent
  local -a arguments=(commit-tree "${COMMIT_RANGE_PROOF_TREE}" -F "${message_file}")
  for parent in "$@"; do
    arguments+=(-p "${parent}")
  done
  (
    builtin export GIT_AUTHOR_NAME='Flare Fixture'
    builtin export GIT_AUTHOR_EMAIL='fixture@flare.invalid'
    # The exported fixture identity is consumed by the Git child process.
    # shellcheck disable=SC2034
    builtin export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
    # shellcheck disable=SC2034
    builtin export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
    run_host_command git -C "${COMMIT_RANGE_PROOF_REPO}" "${arguments[@]}"
  )
}

run_validator() {
  local event_name="$1" base_sha="$2" head_sha="$3"
  (
    builtin cd -- "${COMMIT_RANGE_PROOF_REPO}"
    "${PLATFORM_ROOT}/tools/quality/check-commit-range.sh" \
      "${event_name}" "${base_sha}" "${head_sha}"
  )
}

expect_validator_pass() {
  local label="$1" marker="$2" output="$3"
  shift 3
  if ! "$@" >"${output}" 2>&1; then
    run_host_command sed -n '1,20p' "${output}" >&2 || true
    printf 'FAIL  commit-range  %s fixture was rejected\n' "${label}" >&2
    return 1
  fi
  run_host_command grep -Fq "${marker}" "${output}" || {
    run_host_command sed -n '1,20p' "${output}" >&2 || true
    printf 'FAIL  commit-range  %s PASS marker missing\n' "${label}" >&2
    return 1
  }
}

expect_validator_fail() {
  local label="$1" marker="$2" output="$3" status
  shift 3
  if "$@" >"${output}" 2>&1; then
    printf 'FAIL  commit-range  %s fixture unexpectedly passed\n' \
      "${label}" >&2
    return 1
  else
    status=$?
  fi
  if [[ "${status}" -ne 1 ]]; then
    printf 'FAIL  commit-range  %s returned status %s, expected 1\n' \
      "${label}" "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq "${marker}" "${output}" || {
    run_host_command sed -n '1,20p' "${output}" >&2 || true
    printf 'FAIL  commit-range  %s failure reason drifted\n' "${label}" >&2
    return 1
  }
}

build_fixture_graph() {
  local fixture_dir="$1"
  local root base head bad left right merge
  root="$(fixture_commit "${fixture_dir}/good-root.txt")"
  base="$(fixture_commit "${fixture_dir}/good-base.txt" "${root}")"
  head="$(fixture_commit "${fixture_dir}/good-head.txt" "${base}")"
  bad="$(fixture_commit "${fixture_dir}/bad.txt" "${base}")"
  left="$(fixture_commit "${fixture_dir}/good-left.txt" "${base}")"
  right="$(fixture_commit "${fixture_dir}/good-right.txt" "${base}")"
  merge="$(fixture_commit "${fixture_dir}/good-merge.txt" "${left}" "${right}")"
  printf '%s\n' "${root}" "${base}" "${head}" "${bad}" \
    "${left}" "${right}" "${merge}"
}

prove_fixture_graph() {
  local output_dir="$1" missing_sha=1111111111111111111111111111111111111111
  local root base head bad left right merge
  mapfile -t graph < <(build_fixture_graph \
    "${PLATFORM_ROOT}/tests/fixtures/git/commit-range")
  root="${graph[0]}" base="${graph[1]}" head="${graph[2]}"
  bad="${graph[3]}" left="${graph[4]}" right="${graph[5]}"
  merge="${graph[6]}"
  expect_validator_pass pull-request 'pull_request validated 1 commit(s)' \
    "${output_dir}/pull-request.txt" run_validator pull_request "${base}" "${head}"
  expect_validator_pass push 'push validated 1 commit(s)' \
    "${output_dir}/push.txt" run_validator push "${base}" "${head}"
  expect_validator_pass initial-push 'push validated 3 commit(s)' \
    "${output_dir}/initial-push.txt" run_validator push \
    "${COMMIT_RANGE_PROOF_ZERO_SHA}" "${head}"
  expect_validator_pass merge 'push validated 2 commit(s)' \
    "${output_dir}/merge.txt" run_validator push "${base}" "${merge}"
  expect_validator_fail bad-message 'commit title must follow Conventional Commits' \
    "${output_dir}/bad.txt" run_validator push "${base}" "${bad}"
  expect_validator_fail missing-base "base commit unavailable: ${missing_sha}" \
    "${output_dir}/missing-base.txt" run_validator pull_request \
    "${missing_sha}" "${head}"
  expect_validator_fail zero-pr-base 'pull_request base commit cannot be the zero SHA' \
    "${output_dir}/zero-pr-base.txt" run_validator pull_request \
    "${COMMIT_RANGE_PROOF_ZERO_SHA}" "${head}"
  [[ -n "${root}${left}${right}" ]]
}

main() {
  local output_dir="${PLATFORM_STATE_DIR}/commit-range-proof"
  reset_state_directory commit-range-proof || return
  COMMIT_RANGE_PROOF_REPO="${output_dir}/fixture.git"
  run_host_command git init --bare --quiet "${COMMIT_RANGE_PROOF_REPO}"
  COMMIT_RANGE_PROOF_TREE="$(
    run_host_command git -C "${COMMIT_RANGE_PROOF_REPO}" mktree </dev/null
  )"
  prove_fixture_graph "${output_dir}"
  printf 'PASS  commit-range  PR, push, initial, merge, bad, and missing-base fixtures\n'
}

main "$@"
