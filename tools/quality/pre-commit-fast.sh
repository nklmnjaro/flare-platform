#!/bin/bash -p
set -euo pipefail

PRE_COMMIT_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PRE_COMMIT_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PRE_COMMIT_SOURCE_DIR=.
builtin exec "${PRE_COMMIT_SOURCE_DIR}/check-fast.sh"
