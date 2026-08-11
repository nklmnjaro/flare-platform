#!/bin/bash -p
builtin set -euo pipefail

RUN_MANAGED_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${RUN_MANAGED_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  RUN_MANAGED_SOURCE_DIR=.
builtin source "${RUN_MANAGED_SOURCE_DIR}/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin unset RUN_MANAGED_SOURCE_DIR

if (($# == 0)); then
  builtin printf 'FAIL  tooling       managed command name is required\n' >&2
  exit 2
fi

run_managed_tool "$@"
