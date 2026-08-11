#!/usr/bin/env bash

# Print the config identity from exactly one canonical BuildKit result line.
buildkit_result_config_id() {
  local log="$1"
  local line result="" count=0 _
  local pattern='^#[0-9]+ writing image (sha256:[0-9a-f]{64}) done$'
  if [[ -L "${log}" || ! -f "${log}" ]]; then
    return 1
  fi
  if IFS= read -r -d '' _ <"${log}"; then
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ${pattern} ]]; then
      result="${BASH_REMATCH[1]}"
      ((count += 1))
    fi
  done <"${log}"
  [[ "${count}" -eq 1 ]] || return 1
  printf '%s\n' "${result}"
}
