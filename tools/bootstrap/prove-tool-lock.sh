#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

WORK_DIR=""

write_fake_aqua() {
  local target="$1"
  local install_status="$2"
  cat >"${target}" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
  update-checksum) printf '{"fixture":true}\\n' >aqua-checksums.json ;;
  install) exit ${install_status} ;;
  *) exit 2 ;;
esac
FAKE
  chmod +x "${target}"
}

prepare_fixture() {
  local target="$1"
  mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/.platform/bootstrap"
  cp "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  cp "${PLATFORM_ROOT}/tools/bootstrap/lock-tools.sh" \
    "${target}/tools/bootstrap/lock-tools.sh"
}

prove_rollback() {
  local target="$1"
  prepare_fixture "${target}"
  cp "${target}/aqua.yaml" "${target}/aqua.before"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 9
  if (cd "${target}" && tools/bootstrap/lock-tools.sh >/dev/null 2>&1); then
    printf 'FAIL  tool-lock-red failure fixture unexpectedly passed\n' >&2
    return 1
  fi
  cmp "${target}/aqua.before" "${target}/aqua.yaml"
  [[ ! -e "${target}/aqua-checksums.json" ]]
  printf 'PASS  tool-lock-red failed update restored prior state\n'
}

prove_success() {
  local target="$1"
  prepare_fixture "${target}"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 0
  (cd "${target}" && tools/bootstrap/lock-tools.sh >/dev/null)
  grep -Fqx '  require_checksum: true' "${target}/aqua.yaml"
  [[ -s "${target}/aqua-checksums.json" ]]
  printf 'PASS  tool-lock-green checksum lock committed atomically\n'
}

main() {
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${WORK_DIR}"' EXIT
  prove_rollback "${WORK_DIR}/rollback"
  prove_success "${WORK_DIR}/success"
}

main "$@"
