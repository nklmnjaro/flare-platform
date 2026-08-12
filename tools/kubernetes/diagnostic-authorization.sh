#!/bin/bash -p
set -euo pipefail

run_authorized_diagnostic_collection() {
  local context_guard="${1:?context guard is required}"
  local ownership_guard="${2:?ownership guard is required}"
  local collector="${3:?collector is required}"
  if [[ ! -f "${context_guard}" || -L "${context_guard}" ||
    ! -x "${context_guard}" ]]; then
    builtin printf \
      'FAIL  diagnostics   context guard is unavailable or unsafe\n' >&2
    return 1
  fi
  if [[ ! -f "${ownership_guard}" || -L "${ownership_guard}" ||
    ! -x "${ownership_guard}" ]]; then
    builtin printf \
      'FAIL  diagnostics   ownership guard is unavailable or unsafe\n' >&2
    return 1
  fi
  "${context_guard}" >/dev/null || return
  "${ownership_guard}" >/dev/null || return
  "${collector}"
}
