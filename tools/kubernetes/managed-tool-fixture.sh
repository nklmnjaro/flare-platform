#!/usr/bin/env bash

# Explicit dependency adapter for isolated Kubernetes shell fixtures only.
# Production scripts never source this file.

# shellcheck source=../common/tooling.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/tooling-production.sh"

resolve_managed_tool() {
  local command_name="$1"
  local fixture_root candidate resolved
  is_managed_tool "${command_name}" || return 2
  verify_existing_aqua tooling-fixture >/dev/null 2>&1 || return 1
  fixture_root="${AQUA_ROOT_DIR}/test-fixtures"
  candidate="${fixture_root}/${command_name}"
  if [[ -L "${candidate}" || ! -f "${candidate}" || ! -x "${candidate}" ]]; then
    return 1
  fi
  resolved="$(readlink -f -- "${candidate}")" || return
  case "${resolved}" in
    "${fixture_root}"/*) ;;
    *) return 1 ;;
  esac
  MANAGED_TOOL_PATH="${candidate}"
}
