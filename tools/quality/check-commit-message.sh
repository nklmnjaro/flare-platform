#!/bin/bash -p
# The embedded awk program intentionally uses awk fields.
# shellcheck disable=SC2016
set -euo pipefail

COMMIT_CHECK_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${COMMIT_CHECK_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  COMMIT_CHECK_SOURCE_DIR=.
builtin source "${COMMIT_CHECK_SOURCE_DIR}/../common/env.sh"
unset COMMIT_CHECK_SOURCE_DIR

MESSAGE_FILE="${1:?commit message file is required}"
TITLE="$(run_host_command head -n 1 "${MESSAGE_FILE}")"
PATTERN='^(feat|fix|docs|style|refactor|test|chore|ci|build|perf|revert)(\([a-z0-9][a-z0-9._/-]*\))?: [^[:space:]].*$'

if run_host_command grep -n $'\t' "${MESSAGE_FILE}" >/dev/null; then
  printf 'commit message must not contain hard tabs\n' >&2
  exit 1
fi

if run_host_command grep -nE '[[:blank:]]+$' "${MESSAGE_FILE}" >/dev/null; then
  printf 'commit message must not contain trailing whitespace\n' >&2
  exit 1
fi

if ((${#TITLE} > 72)); then
  printf 'commit title exceeds 72 characters: %d\n' "${#TITLE}" >&2
  exit 1
fi

if [[ ! "${TITLE}" =~ ${PATTERN} ]]; then
  printf 'commit title must follow Conventional Commits\n' >&2
  exit 1
fi

if [[ -n "$(run_host_command sed -n '2p' "${MESSAGE_FILE}")" ]]; then
  printf 'commit body must start after a blank line\n' >&2
  exit 1
fi

if ! run_host_command awk 'NR > 1 && length($0) > 72 {exit 1}' \
  "${MESSAGE_FILE}"; then
  printf 'commit body contains a line longer than 72 characters\n' >&2
  exit 1
fi
