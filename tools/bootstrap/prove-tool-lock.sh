#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh" || exit 1
source "$(dirname -- "${BASH_SOURCE[0]}")/aqua-trust.sh" || exit 1

WORK_DIR=""

write_fake_aqua() {
  local target="$1"
  local install_status="$2"
  cat >"${target}" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
  version) printf '${AQUA_VERSION}\\n' ;;
  update-checksum) printf '{"fixture":true}\\n' >aqua-checksums.json ;;
  install) exit ${install_status} ;;
  *) exit 2 ;;
esac
FAKE
  chmod +x "${target}"
}

write_marker_aqua() {
  local target="$1"
  cat >"${target}" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
printf 'executed:%s\n' "\${1:-}" >>"\${AQUA_RED_MARKER:?}"
case "\${1:-}" in
  version) printf '${AQUA_VERSION}\n' ;;
  update-checksum)
    printf '{"checksums":[{"id":"hostile","checksum":"00","algorithm":"sha256"}]}\n' \
      >aqua-checksums.json
    ;;
  install) ;;
  *) exit 2 ;;
esac
FAKE
  chmod +x "${target}"
}

prepare_bootstrap_fixture() {
  local target="$1"
  mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/.platform/bootstrap" "${target}/fake-bin"
  cp "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  cp "${PLATFORM_ROOT}/tools/bootstrap/bootstrap.sh" \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" "${target}/tools/bootstrap/"
  cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  cat >"${target}/fake-bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${AQUA_CURL_MARKER:-}" ]]; then
  printf 'invoked\n' >"${AQUA_CURL_MARKER}"
fi
printf 'fixture curl denied\n' >&2
exit 70
FAKE
  chmod +x "${target}/fake-bin/curl"
}

prove_unique_checksum_policy() {
  local target="$1"
  local marker="${target}/.platform/CURL_INVOKED"
  local output="${target}/bootstrap.out"
  prepare_bootstrap_fixture "${target}"
  if (
    cd "${target}"
    env CI=true AQUA_CURL_MARKER="${marker}" \
      PATH="${target}/fake-bin:${PATH}" tools/bootstrap/bootstrap.sh
  ) >"${output}" 2>&1; then
    printf 'FAIL  aqua-ci-lock  fixture download unexpectedly passed\n' >&2
    return 1
  fi
  grep -Fq 'verified Aqua download failed' "${output}"
  grep -Fqx invoked "${marker}"
  printf 'PASS  aqua-ci-lock  unique require_checksum true reached install\n'
}

prove_duplicate_checksum_policy() {
  local target="$1"
  local marker="${target}/.platform/CURL_INVOKED"
  local output="${target}/bootstrap.out"
  local duplicate="${target}/aqua.duplicate.yaml"
  prepare_bootstrap_fixture "${target}"
  sed '/^  require_checksum: true$/a\  require_checksum: false' \
    "${target}/aqua.yaml" >"${duplicate}"
  mv "${duplicate}" "${target}/aqua.yaml"
  [[ "$(grep -Ec '^[[:space:]]*require_checksum[[:space:]]*:' \
    "${target}/aqua.yaml")" == "2" ]]
  if (
    cd "${target}"
    env CI=true AQUA_CURL_MARKER="${marker}" \
      PATH="${target}/fake-bin:${PATH}" tools/bootstrap/bootstrap.sh
  ) >"${output}" 2>&1; then
    printf 'FAIL  aqua-ci-red   duplicate checksum policy unexpectedly passed\n' >&2
    return 1
  fi
  grep -Fq 'CI requires committed Aqua checksums.' "${output}"
  grep -Fq 'Expected exactly one require_checksum: true setting.' "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  aqua-ci-red   duplicate policy reached the network\n' >&2
    return 1
  fi
  printf 'PASS  aqua-ci-red   mixed duplicate rejected before network\n'
}

expect_cached_aqua_rejection() {
  local target="$1"
  local expected="$2"
  local marker="${target}/.platform/FAKE_AQUA_EXECUTED"
  local output="${target}/bootstrap.out"
  if (
    cd "${target}"
    env AQUA_RED_MARKER="${marker}" PATH="${target}/fake-bin:${PATH}" \
      tools/bootstrap/bootstrap.sh
  ) >"${output}" 2>&1; then
    printf 'FAIL  aqua-cache-red unsafe cached candidate unexpectedly passed\n' >&2
    return 1
  fi
  grep -Fq "${expected}" "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  aqua-cache-red unsafe cached candidate was executed\n' >&2
    return 1
  fi
}

prove_fake_cached_aqua() {
  local target="$1"
  prepare_bootstrap_fixture "${target}"
  write_marker_aqua "${target}/.platform/bootstrap/aqua"
  cp "${target}/.platform/bootstrap/aqua" "${target}/aqua.before"
  expect_cached_aqua_rejection "${target}" 'cached Aqua integrity rejected'
  cmp "${target}/aqua.before" "${target}/.platform/bootstrap/aqua"
  [[ -z "$(find "${target}/.platform/bootstrap" -maxdepth 1 \
    -name '.aqua-install.*' -print -quit)" ]]
  printf 'PASS  aqua-cache-red fake version-compatible binary was never executed\n'
}

prove_symlink_cached_aqua() {
  local target="$1"
  prepare_bootstrap_fixture "${target}"
  write_marker_aqua "${target}/.platform/hostile-aqua"
  ln -s ../hostile-aqua "${target}/.platform/bootstrap/aqua"
  expect_cached_aqua_rejection "${target}" 'cached Aqua candidate is a symlink'
  printf 'PASS  aqua-cache-red symlink candidate was never executed\n'
}

prove_nonregular_cached_aqua() {
  local target="$1"
  prepare_bootstrap_fixture "${target}"
  mkdir "${target}/.platform/bootstrap/aqua"
  write_marker_aqua "${target}/.platform/bootstrap/aqua/version"
  expect_cached_aqua_rejection "${target}" \
    'cached Aqua candidate is not a regular file'
  printf 'PASS  aqua-cache-red non-regular candidate was never executed\n'
}

prepare_fixture() {
  local target="$1"
  mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/.platform/bootstrap"
  cp "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  cp "${PLATFORM_ROOT}/aqua-checksums.json" \
    "${target}/aqua-checksums.json"
  cp "${PLATFORM_ROOT}/Makefile" "${target}/Makefile"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  cp "${PLATFORM_ROOT}/tools/bootstrap/lock-tools.sh" \
    "${target}/tools/bootstrap/lock-tools.sh"
  cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
}

pin_fixture_aqua() {
  local target="$1"
  local module="${target}/tools/bootstrap/aqua-trust.sh"
  local temporary="${module}.new"
  local digest
  digest="$(sha256sum -- "${target}/.platform/bootstrap/aqua")"
  digest="${digest%% *}"
  sed -E \
    "s/^(readonly AQUA_BIN_SHA256=\")[0-9a-f]{64}(\")$/\\1${digest}\\2/" \
    "${module}" >"${temporary}"
  grep -Fqx "readonly AQUA_BIN_SHA256=\"${digest}\"" "${temporary}"
  mv "${temporary}" "${module}"
}

prove_untrusted_tool_lock_rejection() {
  local target="$1"
  local marker="${target}/.platform/FAKE_AQUA_EXECUTED"
  local output="${target}/tool-lock.out"
  local status=0
  prepare_fixture "${target}"
  write_marker_aqua "${target}/.platform/bootstrap/aqua"
  cp "${target}/aqua.yaml" "${target}/aqua.before"
  cp "${target}/aqua-checksums.json" "${target}/checksums.before"
  cp "${target}/.platform/bootstrap/aqua" "${target}/aqua-bin.before"
  (
    cd "${target}"
    AQUA_RED_MARKER="${marker}" make --no-print-directory tool-lock
  ) >"${output}" 2>&1 || status=$?
  if [[ "${status}" == "0" ]]; then
    printf 'FAIL  tool-lock-red forged Aqua unexpectedly passed\n' >&2
    return 1
  fi
  grep -Fq 'cached Aqua integrity mismatch' "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  tool-lock-red forged Aqua was executed\n' >&2
    return 1
  fi
  cmp "${target}/aqua.before" "${target}/aqua.yaml"
  cmp "${target}/checksums.before" "${target}/aqua-checksums.json"
  cmp "${target}/aqua-bin.before" "${target}/.platform/bootstrap/aqua"
  [[ -z "$(find "${target}/.platform" -maxdepth 1 \
    -name 'tool-lock.*' -print -quit)" ]]
  printf 'PASS  tool-lock-red forged Aqua rejected before execution or mutation\n'
}

prove_inherited_verifier_cannot_bypass() {
  local target="$1"
  local marker="${target}/.platform/INHERITED_FUNCTION_EXECUTED"
  local output="${target}/tool-lock.out"
  local status=0
  prepare_fixture "${target}"
  write_marker_aqua "${target}/.platform/bootstrap/aqua"
  cp "${target}/aqua.yaml" "${target}/aqua.before"
  cp "${target}/aqua-checksums.json" "${target}/checksums.before"
  (
    cd "${target}"
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2329
    verify_existing_aqua() {
      printf 'verify_existing_aqua\n' >>"${AQUA_RED_MARKER:?}"
      return 0
    }
    export -f verify_existing_aqua
    AQUA_RED_MARKER="${marker}" make --no-print-directory tool-lock
  ) >"${output}" 2>&1 || status=$?
  if ((status == 0)); then
    printf 'FAIL  tool-lock-red inherited verifier bypassed canonical trust\n' >&2
    return 1
  fi
  grep -Fq 'cached Aqua integrity mismatch' "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  tool-lock-red inherited verifier or forged Aqua executed\n' >&2
    return 1
  fi
  cmp "${target}/aqua.before" "${target}/aqua.yaml"
  cmp "${target}/checksums.before" "${target}/aqua-checksums.json"
  printf 'PASS  tool-lock-red inherited verifier cannot bypass canonical trust\n'
}

prove_nonexecutable_tool_lock_rejection() {
  local target="$1"
  local marker="${target}/.platform/FAKE_AQUA_EXECUTED"
  local output="${target}/tool-lock.out"
  local mode_before
  local status=0
  prepare_fixture "${target}"
  write_marker_aqua "${target}/.platform/bootstrap/aqua"
  pin_fixture_aqua "${target}"
  chmod -x "${target}/.platform/bootstrap/aqua"
  mode_before="$(stat -c '%a' "${target}/.platform/bootstrap/aqua")"
  cp "${target}/aqua.yaml" "${target}/aqua.before"
  cp "${target}/aqua-checksums.json" "${target}/checksums.before"
  (
    cd "${target}"
    AQUA_RED_MARKER="${marker}" make --no-print-directory tool-lock
  ) >"${output}" 2>&1 || status=$?
  if [[ "${status}" == "0" ]]; then
    printf 'FAIL  tool-lock-red non-executable Aqua unexpectedly passed\n' >&2
    return 1
  fi
  grep -Fq 'cached Aqua is not executable' "${output}"
  [[ ! -e "${marker}" ]]
  cmp "${target}/aqua.before" "${target}/aqua.yaml"
  cmp "${target}/checksums.before" "${target}/aqua-checksums.json"
  [[ "$(stat -c '%a' "${target}/.platform/bootstrap/aqua")" == "${mode_before}" ]]
  [[ -z "$(find "${target}/.platform" -maxdepth 1 \
    -name 'tool-lock.*' -print -quit)" ]]
  printf 'PASS  tool-lock-red non-executable Aqua rejected before mutation\n'
}

prove_rollback() {
  local target="$1"
  prepare_fixture "${target}"
  cp "${target}/aqua.yaml" "${target}/aqua.before"
  cp "${target}/aqua-checksums.json" "${target}/checksums.before"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 9
  pin_fixture_aqua "${target}"
  if (cd "${target}" && tools/bootstrap/lock-tools.sh >/dev/null 2>&1); then
    printf 'FAIL  tool-lock-red failure fixture unexpectedly passed\n' >&2
    return 1
  fi
  cmp "${target}/aqua.before" "${target}/aqua.yaml"
  cmp "${target}/checksums.before" "${target}/aqua-checksums.json"
  printf 'PASS  tool-lock-red failed update restored prior state\n'
}

prove_success() {
  local target="$1"
  prepare_fixture "${target}"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 0
  pin_fixture_aqua "${target}"
  (cd "${target}" && tools/bootstrap/lock-tools.sh >/dev/null)
  grep -Fqx '  require_checksum: true' "${target}/aqua.yaml"
  [[ -s "${target}/aqua-checksums.json" ]]
  printf 'PASS  tool-lock-green checksum lock committed atomically\n'
}

prove_proxy_resolution() {
  local target="$1"
  mkdir -p "${target}/tools/common" "${target}/.platform/bootstrap" \
    "${target}/.platform/aqua/bin"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  printf '#!/usr/bin/env bash\nprintf "proxy-ok\\n"\n' \
    >"${target}/.platform/bootstrap/aqua"
  printf '#!/usr/bin/env bash\naqua fixture\n' \
    >"${target}/.platform/aqua/bin/kind"
  chmod +x "${target}/.platform/bootstrap/aqua" \
    "${target}/.platform/aqua/bin/kind"
  (
    cd "${target}"
    source tools/common/env.sh
    [[ "$(kind)" == proxy-ok ]]
  )
  printf 'PASS  aqua-proxy    bootstrap Aqua resolves project tool proxies\n'
}

main() {
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${WORK_DIR}"' EXIT
  prove_unique_checksum_policy "${WORK_DIR}/unique-checksum"
  prove_duplicate_checksum_policy "${WORK_DIR}/duplicate-checksum"
  prove_fake_cached_aqua "${WORK_DIR}/fake-cache"
  prove_symlink_cached_aqua "${WORK_DIR}/symlink-cache"
  prove_nonregular_cached_aqua "${WORK_DIR}/nonregular-cache"
  prove_untrusted_tool_lock_rejection "${WORK_DIR}/untrusted-tool-lock"
  prove_inherited_verifier_cannot_bypass "${WORK_DIR}/inherited-tool-lock"
  prove_nonexecutable_tool_lock_rejection "${WORK_DIR}/nonexec-tool-lock"
  prove_rollback "${WORK_DIR}/rollback"
  prove_success "${WORK_DIR}/success"
  prove_proxy_resolution "${WORK_DIR}/proxy"
}

main "$@"
