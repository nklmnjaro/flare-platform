#!/usr/bin/env bash

# Print the config identity from exactly one canonical completed BuildKit result line.
buildkit_result_config_id() {
  local log="$1"
  local line result="" step="" count=0 _ observed_result observed_step
  local prefix_pattern='^#[0-9]+ writing image '
  local transient_pattern='^#([0-9]+) writing image (sha256:[0-9a-f]{64})$'
  local terminal_pattern='^#([0-9]+) writing image (sha256:[0-9a-f]{64})( [0-9]+[.][0-9]+s)? done$'
  if [[ -L "${log}" || ! -f "${log}" ]]; then
    return 1
  fi
  if IFS= read -r -d '' _ <"${log}"; then
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ${transient_pattern} ]]; then
      observed_step="${BASH_REMATCH[1]}"
      observed_result="${BASH_REMATCH[2]}"
    elif [[ "${line}" =~ ${terminal_pattern} ]]; then
      observed_step="${BASH_REMATCH[1]}"
      observed_result="${BASH_REMATCH[2]}"
      ((count += 1))
    elif [[ "${line}" =~ ${prefix_pattern} ]]; then
      return 1
    else
      continue
    fi
    if [[ -z "${step}" ]]; then
      step="${observed_step}"
      result="${observed_result}"
    elif [[ "${observed_step}" != "${step}" ||
      "${observed_result}" != "${result}" ]]; then
      return 1
    fi
  done <"${log}"
  [[ "${count}" -eq 1 ]] || return 1
  printf '%s\n' "${result}"
}
