#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

AQUA_BIN="${PLATFORM_STATE_DIR}/bootstrap/aqua"
CHECKSUM_FILE="${PLATFORM_ROOT}/aqua-checksums.json"

if [[ ! -x "${AQUA_BIN}" ]]; then
  printf 'FAIL  tool-lock     Aqua is not bootstrapped; run make bootstrap first.\n' >&2
  exit 2
fi

(
  cd "${PLATFORM_ROOT}"
  "${AQUA_BIN}" update-checksum -prune
)

if [[ ! -s "${CHECKSUM_FILE}" ]]; then
  printf 'FAIL  tool-lock     %s was not created.\n' "${CHECKSUM_FILE}" >&2
  exit 2
fi

AQUA_ENFORCE_REQUIRE_CHECKSUM=true "${AQUA_BIN}" install

if grep -Fqx '  require_checksum: false' "${AQUA_CONFIG}"; then
  sed -i 's/^  require_checksum: false$/  require_checksum: true/' "${AQUA_CONFIG}"
elif ! grep -Fqx '  require_checksum: true' "${AQUA_CONFIG}"; then
  printf 'FAIL  tool-lock     Unsupported require_checksum setting in aqua.yaml.\n' >&2
  exit 2
fi

printf 'PASS  tool-lock     checksums locked and require_checksum enabled.\n'
