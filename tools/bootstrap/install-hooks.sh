#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

require_tool prek

run_managed_tool prek install --hook-type pre-commit --hook-type commit-msg
printf 'PASS  hooks         pre-commit and commit-msg hooks installed\n'
