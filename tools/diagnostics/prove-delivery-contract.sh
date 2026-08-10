#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

WORKFLOW="${PLATFORM_ROOT}/.github/workflows/ci.yml"
PROOF_DIR=""

cleanup() {
  [[ -n "${PROOF_DIR}" ]] || return
  case "${PROOF_DIR}" in
    "${PLATFORM_STATE_DIR}"/diagnostics-delivery.*)
      rm -rf -- "${PROOF_DIR}"
      ;;
    *)
      printf 'FAIL  delivery      refusing unsafe proof cleanup: %s\n' \
        "${PROOF_DIR}" >&2
      return 1
      ;;
  esac
}

extract_workflow_step() {
  local name="$1"
  awk -v header="      - name: ${name}" '
    $0 == header { found = 1 }
    found && emitted && /^      - name: / { exit }
    found { print; emitted = 1 }
    END { if (!found) exit 1 }
  ' "${WORKFLOW}"
}

assert_exact_block() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    return 0
  fi
  printf 'FAIL  delivery      workflow %s contract drifted\n' "${label}" >&2
  return 1
}

prove_workflow_contract() {
  local actual collect_expected permissions_count permissions_expected upload_expected
  collect_expected="$(
    cat <<'EOF'
      - name: Collect bounded diagnostics
        id: diagnostics
        if: failure()
        run: |
          make diagnose
          make artifact-verify ARCHIVE=.platform/platform-diagnostics.zip
EOF
  )"
  upload_expected="$(
    cat <<'EOF'
      - name: Upload bounded diagnostics
        if: failure() && steps.diagnostics.outcome == 'success'
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: platform-kind-diagnostics
          path: |
            .platform/platform-diagnostics.zip
            .platform/platform-diagnostics.zip.sha256
          include-hidden-files: true
          if-no-files-found: error
          retention-days: 7
EOF
  )"
  permissions_expected=$'permissions:\n  contents: read'

  actual="$(extract_workflow_step 'Collect bounded diagnostics')"
  assert_exact_block collect "${actual}" "${collect_expected}"
  actual="$(extract_workflow_step 'Upload bounded diagnostics')"
  assert_exact_block upload "${actual}" "${upload_expected}"
  actual="$(awk '
    $0 == "permissions:" { found = 1 }
    found && emitted && /^[^[:space:]]/ { exit }
    found && NF { print; emitted = 1 }
    END { if (!found) exit 1 }
  ' "${WORKFLOW}")"
  assert_exact_block permissions "${actual}" "${permissions_expected}"
  permissions_count="$(grep -Ec '^[[:space:]]*permissions:' "${WORKFLOW}")"
  if [[ "${permissions_count}" -ne 1 ]]; then
    printf 'FAIL  delivery      workflow permissions must have one least-privilege block\n' >&2
    return 1
  fi
  if grep -Eq '^[[:space:]]*archive:[[:space:]]*false' "${WORKFLOW}"; then
    printf 'FAIL  delivery      diagnostics must use normal artifact mode\n' >&2
    return 1
  fi
  printf 'PASS  delivery      workflow uploads only the verified diagnostics pair\n'
}

prove_artifact_pair() {
  local archive="${PROOF_DIR}/platform-diagnostics.zip"
  local source="${PROOF_DIR}/source"
  mkdir -- "${source}"
  printf 'schema=flare-platform-diagnostics-proof-v1\n' >"${source}/platform.txt"
  make --no-print-directory -C "${PLATFORM_ROOT}" artifact-pack \
    SOURCE="${source}" OUTPUT="${archive}" >/dev/null
  [[ -f "${archive}" && ! -L "${archive}" ]]
  [[ -f "${archive}.sha256" && ! -L "${archive}.sha256" ]]
  make --no-print-directory -C "${PLATFORM_ROOT}" artifact-verify \
    ARCHIVE="${archive}" >/dev/null
  printf 'PASS  delivery      diagnostics ZIP and detached checksum verify\n'
}

prove_special_path_pair() {
  local relative_root=".platform/${PROOF_DIR##*/}/special path #[]&"
  local relative_source="${relative_root}/source path #[]&"
  local relative_archive="${relative_root}/platform diagnostics #[]&.zip"
  local archive="${PLATFORM_ROOT}/${relative_archive}"
  local source="${PLATFORM_ROOT}/${relative_source}"
  mkdir -p -- "${source}"
  printf 'schema=flare-platform-special-path-proof-v1\n' >"${source}/platform data.txt"
  make --no-print-directory -C "${PLATFORM_ROOT}" artifact-pack \
    SOURCE="${relative_source}" OUTPUT="${relative_archive}" >/dev/null
  [[ -f "${archive}" && -f "${archive}.sha256" ]]
  make --no-print-directory -C "${PLATFORM_ROOT}" artifact-verify \
    ARCHIVE="${relative_archive}" >/dev/null
  printf 'PASS  delivery      special-character Make paths pack and verify\n'
}

prove_missing_checksum_rejected() {
  local archive="${PROOF_DIR}/platform-diagnostics.zip"
  local log="${PROOF_DIR}/missing-checksum.log"
  local reason status
  rm -f -- "${archive}.sha256"
  set +e
  make --no-print-directory -C "${PLATFORM_ROOT}" artifact-verify \
    ARCHIVE="${archive}" >"${log}" 2>&1
  status=$?
  set -e
  reason="$(grep -m 1 '^FAIL  artifact      ' "${log}" || true)"
  if ((status != 2)) || [[ "${reason}" != 'FAIL  artifact      detached checksum:'* ]]; then
    sed -n '1,20p' "${log}" >&2
    printf 'FAIL  delivery      missing checksum failed for the wrong reason\n' >&2
    return 1
  fi
  printf 'PASS  delivery      missing checksum rejected at detached-checksum boundary\n'
}

main() {
  require_tool go
  ensure_state_directory "" || return
  PROOF_DIR="$(mktemp -d "${PLATFORM_STATE_DIR}/diagnostics-delivery.XXXXXX")"
  trap cleanup EXIT
  prove_workflow_contract
  prove_artifact_pair
  prove_special_path_pair
  prove_missing_checksum_rejected
}

main "$@"
