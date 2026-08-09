#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

if ! command -v prek >/dev/null 2>&1; then
  printf 'FAIL  hooks         run make bootstrap first\n' >&2
  exit 1
fi

prek install --hook-type pre-commit --hook-type commit-msg
printf 'PASS  hooks         pre-commit and commit-msg hooks installed\n'
