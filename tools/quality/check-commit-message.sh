#!/usr/bin/env bash
set -euo pipefail

MESSAGE_FILE="${1:?commit message file is required}"
TITLE="$(head -n 1 "${MESSAGE_FILE}")"
PATTERN='^(feat|fix|docs|style|refactor|test|chore|ci|build|perf|revert)(\([a-z0-9][a-z0-9._/-]*\))?: [^[:space:]].*$'

if grep -n $'\t' "${MESSAGE_FILE}" >/dev/null; then
  printf 'commit message must not contain hard tabs\n' >&2
  exit 1
fi

if grep -nE '[[:blank:]]+$' "${MESSAGE_FILE}" >/dev/null; then
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

if [[ -n "$(sed -n '2p' "${MESSAGE_FILE}")" ]]; then
  printf 'commit body must start after a blank line\n' >&2
  exit 1
fi

if ! awk 'NR > 1 && length($0) > 72 {exit 1}' "${MESSAGE_FILE}"; then
  printf 'commit body contains a line longer than 72 characters\n' >&2
  exit 1
fi
