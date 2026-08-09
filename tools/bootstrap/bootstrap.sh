#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

AQUA_VERSION="2.62.3"
AQUA_SHA256="89cb081adb19e425b1dca6b16d912c349a43535ce88d8713050738c9263618d0"
AQUA_ARCHIVE="aqua_linux_amd64.tar.gz"
AQUA_URL="https://github.com/aquaproj/aqua/releases/download/v${AQUA_VERSION}/${AQUA_ARCHIVE}"
AQUA_BOOTSTRAP_DIR="${PLATFORM_STATE_DIR}/bootstrap"
AQUA_BIN="${AQUA_BOOTSTRAP_DIR}/aqua"

require_checksum_enabled() {
  grep -Fqx '  require_checksum: true' "${AQUA_CONFIG}"
}

enforce_ci_checksum_policy() {
  if [[ "${CI:-}" != "true" ]] || require_checksum_enabled; then
    return 0
  fi
  printf 'FAIL  bootstrap     CI requires committed Aqua checksums.\n' >&2
  printf '      Run make tool-lock on a trusted online host and commit both lock files.\n' >&2
  return 1
}

install_aqua() {
  local archive="${AQUA_BOOTSTRAP_DIR}/${AQUA_ARCHIVE}"
  mkdir -p "${AQUA_BOOTSTRAP_DIR}" "${AQUA_ROOT_DIR}"

  if [[ -x "${AQUA_BIN}" ]] && [[ "$("${AQUA_BIN}" version)" == *"${AQUA_VERSION}"* ]]; then
    return 0
  fi

  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 120 --retry 3 --retry-connrefused \
    --output "${archive}" "${AQUA_URL}"
  printf '%s  %s\n' "${AQUA_SHA256}" "${archive}" | sha256sum --check --status
  tar -xzf "${archive}" -C "${AQUA_BOOTSTRAP_DIR}" aqua
  rm -f "${archive}"
}

main() {
  "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only
  enforce_ci_checksum_policy
  install_aqua
  (cd "${PLATFORM_ROOT}" && "${AQUA_BIN}" install)
  printf 'PASS  bootstrap     pinned tools installed under %s\n' "${AQUA_ROOT_DIR}"
}

main "$@"
