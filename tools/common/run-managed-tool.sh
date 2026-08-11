#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/tooling.sh"

if (($# == 0)); then
  printf 'FAIL  tooling       managed command name is required\n' >&2
  exit 2
fi

run_managed_tool "$@"
