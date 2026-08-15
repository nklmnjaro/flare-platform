#!/bin/bash -p
set -euo pipefail

PROVE_TOOL_LOCK_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_TOOL_LOCK_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_TOOL_LOCK_SOURCE_DIR=.
builtin source "${PROVE_TOOL_LOCK_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh"
unset PROVE_TOOL_LOCK_SOURCE_DIR

WORK_DIR=""

write_fake_aqua() {
  local target="$1"
  local install_status="$2"
  run_host_command cat >"${target}" <<FAKE
#!/bin/bash -p
set -euo pipefail
case "\$1" in
  version) printf '${AQUA_VERSION}\\n' ;;
  update-checksum) printf '{"fixture":true}\\n' >aqua-checksums.json ;;
  install) exit ${install_status} ;;
  *) exit 2 ;;
esac
FAKE
  run_host_command chmod +x -- "${target}"
}

write_exec_marker_aqua() {
  local target="$1"
  run_host_command cat >"${target}" <<FAKE
#!/bin/bash -p
set -euo pipefail
case "\${1:-}" in
  version) builtin printf '${AQUA_VERSION}\n' ;;
  exec)
    builtin printf 'executed\n' >"\${PLATFORM_AQUA_PROXY_RED_MARKER:?}"
    ;;
  *) builtin exit 2 ;;
esac
FAKE
  run_host_command chmod 0755 -- "${target}"
}

write_second_install_failure_aqua() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
case "${1:-}" in
  version) printf '2.62.3\n' ;;
  update-checksum) printf '{"fixture":"mutated"}\n' >aqua-checksums.json ;;
  install)
    count=0
    [[ ! -f "${PLATFORM_AQUA_INSTALL_COUNT:?}" ]] || \
      count="$(<"${PLATFORM_AQUA_INSTALL_COUNT}")"
    ((count += 1))
    printf '%s\n' "${count}" >"${PLATFORM_AQUA_INSTALL_COUNT}"
    ((count == 1)) || exit 9
    ;;
  *) exit 2 ;;
esac
FAKE
  run_host_command chmod +x -- "${target}"
}

write_selective_cp_failure() {
  local target="$1" real_cp
  real_cp="$(host_command_path cp)" || return
  run_host_command cat >"${target}" <<FAKE
#!/bin/bash -p
set -euo pipefail
destination="\${!#}"
case "\${PLATFORM_FAKE_CP_MODE:?}:\${destination}" in
  backup:*/tool-lock.*/aqua.yaml | restore:*.restore.*) exit 99 ;;
esac
exec ${real_cp@Q} "\$@"
FAKE
  run_host_command chmod +x -- "${target}"
}

write_marker_aqua() {
  local target="$1"
  run_host_command cat >"${target}" <<FAKE
#!/bin/bash -p
set -euo pipefail
printf 'executed:%s\n' "\${1:-}" >>"\${PLATFORM_AQUA_RED_MARKER:?}"
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
  run_host_command chmod +x -- "${target}"
}

write_identity_marker_aqua() {
  local target="$1" identity="$2"
  run_host_command cat >"${target}" <<FAKE
#!/bin/bash -p
set -euo pipefail
case "\${1:-}" in
  version) builtin printf '${AQUA_VERSION}\n' ;;
  probe) builtin printf '%s\n' ${identity@Q} >"\${PLATFORM_AQUA_IDENTITY_MARKER:?}" ;;
  *) builtin exit 2 ;;
esac
FAKE
  run_host_command chmod 0755 -- "${target}"
}

prepare_bootstrap_fixture() {
  local target="$1"
  run_host_command mkdir -p -- \
    "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/.platform/bootstrap" "${target}.host-bin"
  run_host_command cp -- "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/bootstrap/bootstrap.sh" \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" "${target}/tools/bootstrap/"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${PLATFORM_ROOT}/tools/bootstrap/environment-profile.sh" \
    "${target}/tools/bootstrap/"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/common/env.sh" \
    "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${PLATFORM_ROOT}/tools/common/docker-target.sh" \
    "${PLATFORM_ROOT}/tools/common/process-state.sh" \
    "${PLATFORM_ROOT}/tools/common/state.sh" \
    "${PLATFORM_ROOT}/tools/common/tooling.sh" "${target}/tools/common/"
  run_host_command cat >"${target}.host-bin/curl" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
[[ "${1:-}" == --disable ]] || exit 64
shift
case "${1:-}:${2:-}" in
  --version:)
    printf 'curl 9.0.0 fixture\nProtocols: http https\n'
    exit 0
    ;;
  --help:all)
    printf '%s\n' --fail --location --proto --proto-redir --tlsv1.2 \
      --connect-timeout --max-time --max-filesize --retry \
      --retry-connrefused --output --silent --show-error
    exit 0
    ;;
esac
[[ -z "${PLATFORM_AQUA_CURL_MARKER:-}" ]] || \
  printf 'invoked\n' >"${PLATFORM_AQUA_CURL_MARKER}"
printf 'fixture curl denied\n' >&2
exit 70
FAKE
  run_host_command chmod +x -- "${target}.host-bin/curl"
}

prove_unique_checksum_policy() {
  local target="$1"
  local marker="${target}/.platform/CURL_INVOKED"
  local output="${target}/bootstrap.out"
  prepare_bootstrap_fixture "${target}"
  if (
    builtin cd -- "${target}"
    run_host_command env CI=true PLATFORM_AQUA_CURL_MARKER="${marker}" \
      PATH="${target}.host-bin:${PATH}" tools/bootstrap/bootstrap.sh
  ) >"${output}" 2>&1; then
    printf 'FAIL  aqua-ci-lock  fixture download unexpectedly passed\n' >&2
    return 1
  fi
  run_host_command grep -Fq 'verified Aqua download failed' "${output}" || {
    run_host_command cat -- "${output}" >&2
    return 1
  }
  run_host_command grep -Fqx invoked "${marker}"
  printf 'PASS  aqua-ci-lock  unique require_checksum true reached install\n'
}

prove_duplicate_checksum_policy() {
  local target="$1"
  local marker="${target}/.platform/CURL_INVOKED"
  local output="${target}/bootstrap.out"
  local duplicate="${target}/aqua.duplicate.yaml"
  prepare_bootstrap_fixture "${target}"
  run_host_command sed '/^  require_checksum: true$/a\  require_checksum: false' \
    "${target}/aqua.yaml" >"${duplicate}"
  run_host_command mv -fT -- "${duplicate}" "${target}/aqua.yaml"
  [[ "$(run_host_command grep -Ec \
    '^[[:space:]]*require_checksum[[:space:]]*:' \
    "${target}/aqua.yaml")" == "2" ]]
  if (
    builtin cd -- "${target}"
    run_host_command env CI=true PLATFORM_AQUA_CURL_MARKER="${marker}" \
      PATH="${target}.host-bin:${PATH}" tools/bootstrap/bootstrap.sh
  ) >"${output}" 2>&1; then
    printf 'FAIL  aqua-ci-red   duplicate checksum policy unexpectedly passed\n' >&2
    return 1
  fi
  run_host_command grep -Fq 'CI requires committed Aqua checksums.' "${output}"
  run_host_command grep -Fq \
    'Expected exactly one require_checksum: true setting.' "${output}"
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
    builtin cd -- "${target}"
    run_host_command env PLATFORM_AQUA_RED_MARKER="${marker}" \
      PATH="${target}.host-bin:${PATH}" \
      tools/bootstrap/bootstrap.sh
  ) >"${output}" 2>&1; then
    printf 'FAIL  aqua-cache-red unsafe cached candidate unexpectedly passed\n' >&2
    return 1
  fi
  run_host_command grep -Fq "${expected}" "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  aqua-cache-red unsafe cached candidate was executed\n' >&2
    return 1
  fi
}

prove_fake_cached_aqua() {
  local target="$1"
  prepare_bootstrap_fixture "${target}"
  write_marker_aqua "${target}/.platform/bootstrap/aqua"
  run_host_command cp -- \
    "${target}/.platform/bootstrap/aqua" "${target}/aqua.before"
  expect_cached_aqua_rejection "${target}" 'cached Aqua integrity rejected'
  run_host_command cmp -- \
    "${target}/aqua.before" "${target}/.platform/bootstrap/aqua"
  [[ -z "$(run_host_command find "${target}/.platform/bootstrap" -maxdepth 1 \
    -name '.aqua-install.*' -print -quit)" ]]
  printf 'PASS  aqua-cache-red fake version-compatible binary was never executed\n'
}

prove_symlink_cached_aqua() {
  local target="$1"
  prepare_bootstrap_fixture "${target}"
  write_marker_aqua "${target}/.platform/hostile-aqua"
  run_host_command ln -s -- \
    ../hostile-aqua "${target}/.platform/bootstrap/aqua"
  expect_cached_aqua_rejection "${target}" 'cached Aqua candidate is a symlink'
  printf 'PASS  aqua-cache-red symlink candidate was never executed\n'
}

prove_nonregular_cached_aqua() {
  local target="$1"
  prepare_bootstrap_fixture "${target}"
  run_host_command mkdir -- "${target}/.platform/bootstrap/aqua"
  write_marker_aqua "${target}/.platform/bootstrap/aqua/version"
  expect_cached_aqua_rejection "${target}" \
    'cached Aqua candidate is not a regular file'
  printf 'PASS  aqua-cache-red non-regular candidate was never executed\n'
}

prepare_fixture() {
  local target="$1"
  run_host_command mkdir -p -- \
    "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/.platform/bootstrap" "${target}/.platform/aqua"
  run_host_command cp -- "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  run_host_command cp -- "${PLATFORM_ROOT}/aqua-checksums.json" \
    "${target}/aqua-checksums.json"
  run_host_command cp -- "${PLATFORM_ROOT}/Makefile" "${target}/Makefile"
  run_host_command cp -- \
    "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${target}/tools/common/host-commands.sh"
  run_host_command cp -- \
    "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/bootstrap/lock-tools.sh" \
    "${target}/tools/bootstrap/lock-tools.sh"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
}

pin_fixture_digest() {
  local target="$1"
  local digest_name="$2"
  local source_file="$3"
  local module="${target}/tools/bootstrap/aqua-trust.sh"
  local temporary="${module}.new"
  local digest
  [[ "${digest_name}" =~ ^AQUA_(BIN|PROXY_BIN)_SHA256$ ]] || return 2
  digest="$(run_host_command sha256sum -- "${source_file}")"
  digest="${digest%% *}"
  run_host_command sed -E \
    "s/^(builtin readonly ${digest_name}=\")[0-9a-f]{64}(\")$/\\1${digest}\\2/" \
    "${module}" >"${temporary}"
  run_host_command grep -Fqx \
    "builtin readonly ${digest_name}=\"${digest}\"" "${temporary}"
  run_host_command mv -fT -- "${temporary}" "${module}"
}

pin_fixture_aqua() {
  local target="$1"
  pin_fixture_digest "${target}" AQUA_BIN_SHA256 \
    "${target}/.platform/bootstrap/aqua"
}

pin_fixture_proxy() {
  local target="$1"
  pin_fixture_digest "${target}" AQUA_PROXY_BIN_SHA256 \
    "${target}/.platform/aqua/internal/pkgs/fixture/aqua-proxy"
}

prove_untrusted_tool_lock_rejection() {
  local target="$1"
  local marker="${target}/.platform/FAKE_AQUA_EXECUTED"
  local output="${target}/tool-lock.out"
  local status=0
  prepare_fixture "${target}"
  write_marker_aqua "${target}/.platform/bootstrap/aqua"
  run_host_command cp -- "${target}/aqua.yaml" "${target}/aqua.before"
  run_host_command cp -- \
    "${target}/aqua-checksums.json" "${target}/checksums.before"
  run_host_command cp -- \
    "${target}/.platform/bootstrap/aqua" "${target}/aqua-bin.before"
  (
    builtin cd -- "${target}"
    run_host_command env PLATFORM_AQUA_RED_MARKER="${marker}" \
      "$(host_command_path make)" --no-print-directory tool-lock
  ) >"${output}" 2>&1 || status=$?
  if [[ "${status}" == "0" ]]; then
    printf 'FAIL  tool-lock-red forged Aqua unexpectedly passed\n' >&2
    return 1
  fi
  run_host_command grep -Fq 'cached Aqua integrity mismatch' "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  tool-lock-red forged Aqua was executed\n' >&2
    return 1
  fi
  run_host_command cmp -- "${target}/aqua.before" "${target}/aqua.yaml"
  run_host_command cmp -- \
    "${target}/checksums.before" "${target}/aqua-checksums.json"
  run_host_command cmp -- \
    "${target}/aqua-bin.before" "${target}/.platform/bootstrap/aqua"
  [[ -z "$(run_host_command find "${target}/.platform" -maxdepth 1 \
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
  run_host_command cp -- "${target}/aqua.yaml" "${target}/aqua.before"
  run_host_command cp -- \
    "${target}/aqua-checksums.json" "${target}/checksums.before"
  (
    builtin cd -- "${target}"
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2317,SC2329
    verify_existing_aqua() {
      printf 'verify_existing_aqua\n' >>"${PLATFORM_AQUA_RED_MARKER:?}"
      return 0
    }
    export -f verify_existing_aqua
    run_host_command env PLATFORM_AQUA_RED_MARKER="${marker}" \
      "$(host_command_path make)" --no-print-directory tool-lock
  ) >"${output}" 2>&1 || status=$?
  if ((status == 0)); then
    printf 'FAIL  tool-lock-red inherited verifier bypassed canonical trust\n' >&2
    return 1
  fi
  run_host_command grep -Fq 'cached Aqua integrity mismatch' "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  tool-lock-red inherited verifier or forged Aqua executed\n' >&2
    return 1
  fi
  run_host_command cmp -- "${target}/aqua.before" "${target}/aqua.yaml"
  run_host_command cmp -- \
    "${target}/checksums.before" "${target}/aqua-checksums.json"
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
  run_host_command chmod -x -- "${target}/.platform/bootstrap/aqua"
  mode_before="$(run_host_command stat -c '%a' \
    "${target}/.platform/bootstrap/aqua")"
  run_host_command cp -- "${target}/aqua.yaml" "${target}/aqua.before"
  run_host_command cp -- \
    "${target}/aqua-checksums.json" "${target}/checksums.before"
  (
    builtin cd -- "${target}"
    run_host_command env PLATFORM_AQUA_RED_MARKER="${marker}" \
      "$(host_command_path make)" --no-print-directory tool-lock
  ) >"${output}" 2>&1 || status=$?
  if [[ "${status}" == "0" ]]; then
    printf 'FAIL  tool-lock-red non-executable Aqua unexpectedly passed\n' >&2
    return 1
  fi
  run_host_command grep -Fq 'cached Aqua is not executable' "${output}"
  [[ ! -e "${marker}" ]]
  run_host_command cmp -- "${target}/aqua.before" "${target}/aqua.yaml"
  run_host_command cmp -- \
    "${target}/checksums.before" "${target}/aqua-checksums.json"
  [[ "$(run_host_command stat -c '%a' \
    "${target}/.platform/bootstrap/aqua")" == "${mode_before}" ]]
  [[ -z "$(run_host_command find "${target}/.platform" -maxdepth 1 \
    -name 'tool-lock.*' -print -quit)" ]]
  printf 'PASS  tool-lock-red non-executable Aqua rejected before mutation\n'
}

prove_rollback() {
  local target="$1" config_mode checksum_mode
  prepare_fixture "${target}"
  run_host_command chmod 0640 -- "${target}/aqua.yaml"
  run_host_command chmod 0604 -- "${target}/aqua-checksums.json"
  config_mode="$(run_host_command stat -c '%a' "${target}/aqua.yaml")"
  checksum_mode="$(run_host_command stat -c '%a' \
    "${target}/aqua-checksums.json")"
  run_host_command cp -- "${target}/aqua.yaml" "${target}/aqua.before"
  run_host_command cp -- \
    "${target}/aqua-checksums.json" "${target}/checksums.before"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 9
  pin_fixture_aqua "${target}"
  if (
    builtin umask 077
    builtin cd -- "${target}"
    "${target}/tools/bootstrap/lock-tools.sh" >/dev/null 2>&1
  ); then
    printf 'FAIL  tool-lock-red failure fixture unexpectedly passed\n' >&2
    return 1
  fi
  run_host_command cmp -- "${target}/aqua.before" "${target}/aqua.yaml"
  run_host_command cmp -- \
    "${target}/checksums.before" "${target}/aqua-checksums.json"
  [[ "$(run_host_command stat -c '%a' "${target}/aqua.yaml")" == "${config_mode}" ]]
  [[ "$(run_host_command stat -c '%a' \
    "${target}/aqua-checksums.json")" == "${checksum_mode}" ]]
  printf 'PASS  tool-lock-red failed update restored prior bytes and modes\n'
}

prove_initial_backup_failure_cleanup() {
  local target="$1" host_bin output status=0
  host_bin="${target}.host-bin"
  output="${target}.out"
  prepare_fixture "${target}"
  run_host_command mkdir -p -- "${host_bin}"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 0
  pin_fixture_aqua "${target}"
  write_selective_cp_failure "${host_bin}/cp"
  run_host_command cp -- "${target}/aqua.yaml" "${target}/aqua.before"
  run_host_command cp -- \
    "${target}/aqua-checksums.json" "${target}/checksums.before"
  (
    builtin cd -- "${target}"
    run_host_command env PATH="${host_bin}:${PATH}" \
      PLATFORM_FAKE_CP_MODE=backup \
      "${target}/tools/bootstrap/lock-tools.sh"
  ) >"${output}" 2>&1 || status=$?
  if [[ "${status}" -ne 74 ]]; then
    run_host_command cat -- "${output}" >&2
    printf 'FAIL  tool-lock-red initial backup failure status=%s; expected 74\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fqx \
    'FAIL  tool-lock     unable to back up aqua.yaml' "${output}"
  run_host_command cmp -- "${target}/aqua.before" "${target}/aqua.yaml"
  run_host_command cmp -- \
    "${target}/checksums.before" "${target}/aqua-checksums.json"
  [[ -z "$(run_host_command find "${target}/.platform" -maxdepth 1 \
    -name 'tool-lock.*' -print -quit)" ]]
  printf 'PASS  tool-lock-red incomplete backup removed without live mutation\n'
}

prove_restore_failure_retains_backup() {
  local target="$1" host_bin output backup config_mode checksum_mode status=0
  host_bin="${target}.host-bin"
  output="${target}.out"
  prepare_fixture "${target}"
  run_host_command mkdir -p -- "${host_bin}"
  run_host_command sed \
    's/^  require_checksum: true$/  require_checksum: false/' \
    "${target}/aqua.yaml" >"${target}/aqua.initial"
  run_host_command mv -fT -- \
    "${target}/aqua.initial" "${target}/aqua.yaml"
  run_host_command chmod 0640 -- "${target}/aqua.yaml"
  run_host_command chmod 0604 -- "${target}/aqua-checksums.json"
  config_mode="$(run_host_command stat -c '%a' "${target}/aqua.yaml")"
  checksum_mode="$(run_host_command stat -c '%a' \
    "${target}/aqua-checksums.json")"
  run_host_command cp -- "${target}/aqua.yaml" "${target}/aqua.before"
  run_host_command cp -- \
    "${target}/aqua-checksums.json" "${target}/checksums.before"
  run_host_command sed \
    's/^  require_checksum: false$/  require_checksum: true/' \
    "${target}/aqua.before" >"${target}/aqua.mutated"
  write_second_install_failure_aqua \
    "${target}/.platform/bootstrap/aqua"
  pin_fixture_aqua "${target}"
  write_selective_cp_failure "${host_bin}/cp"
  (
    builtin umask 077
    builtin cd -- "${target}"
    run_host_command env PATH="${host_bin}:${PATH}" \
      PLATFORM_FAKE_CP_MODE=restore \
      PLATFORM_AQUA_INSTALL_COUNT="${target}/install-count" \
      "${target}/tools/bootstrap/lock-tools.sh"
  ) >"${output}" 2>&1 || status=$?
  if [[ "${status}" -ne 74 ]]; then
    run_host_command cat -- "${output}" >&2
    printf 'FAIL  tool-lock-red restore failure status=%s; expected 74\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'FAIL  tool-lock     rollback failed; prior files retained at ' \
    "${output}"
  run_host_command cmp -- "${target}/aqua.mutated" "${target}/aqua.yaml"
  backup="$(run_host_command find "${target}/.platform" -maxdepth 1 -type d \
    -name 'tool-lock.*' -print -quit)"
  [[ -n "${backup}" && ! -L "${backup}" ]]
  run_host_command cmp -- "${target}/aqua.before" "${backup}/aqua.yaml"
  run_host_command cmp -- \
    "${target}/checksums.before" "${backup}/aqua-checksums.json"
  [[ "$(run_host_command stat -c '%a' "${backup}/aqua.yaml")" == "${config_mode}" ]]
  [[ "$(run_host_command stat -c '%a' \
    "${backup}/aqua-checksums.json")" == "${checksum_mode}" ]]
  [[ -z "$(run_host_command find "${target}" \
    -name '*.restore.*' -print -quit)" ]]
  printf 'PASS  tool-lock-red failed rollback retained prior bytes and modes\n'
}

prove_success() {
  local target="$1" config_mode
  prepare_fixture "${target}"
  run_host_command chmod 0640 -- "${target}/aqua.yaml"
  config_mode="$(run_host_command stat -c '%a' "${target}/aqua.yaml")"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 0
  pin_fixture_aqua "${target}"
  (
    builtin umask 077
    builtin cd -- "${target}"
    "${target}/tools/bootstrap/lock-tools.sh" >/dev/null
  )
  run_host_command grep -Fqx \
    '  require_checksum: true' "${target}/aqua.yaml"
  [[ -s "${target}/aqua-checksums.json" ]]
  [[ "$(run_host_command stat -c '%a' "${target}/aqua.yaml")" == "${config_mode}" ]]
  printf 'PASS  tool-lock-green checksum lock committed with mode preserved\n'
}

prove_missing_checksum_regenerated() {
  local target="$1" output
  output="${target}.out"
  prepare_fixture "${target}"
  run_host_command rm -f -- "${target}/aqua-checksums.json"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 0
  pin_fixture_aqua "${target}"
  if ! (
    builtin cd -- "${target}"
    "${target}/tools/bootstrap/lock-tools.sh"
  ) >"${output}" 2>&1; then
    run_host_command cat -- "${output}" >&2
    return 1
  fi
  run_host_command grep -Fqx \
    '{"fixture":true}' "${target}/aqua-checksums.json"
  run_host_command grep -Fqx \
    '  require_checksum: true' "${target}/aqua.yaml"
  [[ -z "$(run_host_command find "${target}/.platform" -maxdepth 1 \
    -name 'tool-lock.*' -print -quit)" ]]
  printf 'PASS  tool-lock-green missing checksum lock regenerated\n'
}

prepare_env_boundary_fixture() {
  local target="$1"
  run_host_command mkdir -p -- \
    "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/.platform/bootstrap" \
    "${target}/.platform/aqua/bin"
  run_host_command cp -- "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  run_host_command cp -- "${PLATFORM_ROOT}/aqua-checksums.json" \
    "${target}/aqua-checksums.json"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/common/env.sh" \
    "${PLATFORM_ROOT}/tools/common/host-commands.sh" \
    "${PLATFORM_ROOT}/tools/common/process-state.sh" \
    "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/common/tooling.sh" \
    "${target}/tools/common/tooling.sh"
  run_host_command cp -- "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
}

prove_project_path_not_published() {
  local target="$1"
  prepare_env_boundary_fixture "${target}"
  builtin printf '#!/bin/bash -p\nprintf "unsafe-project-kind\\n"\n' \
    >"${target}/.platform/aqua/bin/kind"
  run_host_command chmod +x -- "${target}/.platform/aqua/bin/kind"
  (
    builtin cd -- "${target}"
    # shellcheck disable=SC2030,SC2031
    export PATH="${target}/.platform/aqua/bin:${PATH}"
    builtin source tools/common/env.sh
    [[ ":${PATH}:" != *":${target}/.platform/aqua/bin:"* ]]
    [[ "$(type -P kind 2>/dev/null || true)" != "${target}/.platform/aqua/bin/kind" ]]
  )
  printf 'PASS  host-path     generated Aqua paths are not published to PATH\n'
}

prove_state_symlink_host_rejected() {
  local target="$1" output status=0 curl_path
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  run_host_command mkdir -p -- "${target}/.platform/host-bin"
  curl_path="$(host_command_path curl)"
  run_host_command ln -s -- \
    "${curl_path}" "${target}/.platform/host-bin/curl"
  (
    builtin cd -- "${target}"
    # shellcheck disable=SC2030,SC2031
    export PATH="${target}/.platform/host-bin:${PATH}"
    builtin source tools/common/env.sh
    host_command_path curl
  ) >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
  run_host_command grep -Fq \
    'lookup location is inside repository or generated command state' \
    "${output}"
  printf 'PASS  host-red      state symlink to host command rejected with 69\n'
}

prove_external_symlink_into_state_rejected() {
  local target="$1" outside marker output status=0
  outside="${target}.outside-bin"
  marker="${target}.marker"
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  run_host_command mkdir -p -- "${target}/.platform/fake" "${outside}"
  write_host_command_marker_fake "${target}/.platform/fake/curl"
  run_host_command ln -s -- \
    "${target}/.platform/fake/curl" "${outside}/curl"
  (
    builtin cd -- "${target}"
    # shellcheck disable=SC2030,SC2031
    export PATH="${outside}:${PATH}"
    # shellcheck disable=SC2030,SC2031
    export PLATFORM_HOST_FAKE_MARKER="${marker}"
    builtin source tools/common/env.sh
    host_command_path curl
  ) >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
  run_host_command grep -Fqx \
    'FAIL  host-command  curl: resolved inside repository or generated command state' \
    "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  host-red      external symlink into state rejected with 69\n'
}

write_host_command_marker_fake() {
  local target="$1"
  run_host_command cat >"${target}" <<'HOST_COMMAND_FAKE'
#!/bin/bash -p
builtin printf 'executed:%s\n' "${0##*/}" >>"${PLATFORM_HOST_FAKE_MARKER:?}"
HOST_COMMAND_FAKE
  run_host_command chmod +x -- "${target}"
}

prove_required_state_host_fakes_rejected() {
  local target="$1" marker output command command_output status
  marker="${target}.marker"
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  for command in curl tar rm mv mktemp sha256sum; do
    write_host_command_marker_fake \
      "${target}/.platform/bootstrap/${command}"
  done
  (
    builtin cd -- "${target}"
    # shellcheck disable=SC2030,SC2031
    export PATH="${target}/.platform/bootstrap:${PATH}"
    # shellcheck disable=SC2030,SC2031
    export PLATFORM_HOST_FAKE_MARKER="${marker}"
    builtin source tools/common/env.sh
    builtin set +e
    for command in curl tar rm mv mktemp sha256sum; do
      command_output="$(run_host_command "${command}" fixture 2>&1)"
      status=$?
      [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]] || exit 1
      [[ "${command_output}" == *"lookup location is inside repository or generated command state"* ]] ||
        exit 1
      builtin printf '%s:status=%s\n' "${command}" "${status}"
    done
  ) >"${output}"
  for command in curl tar rm mv mktemp sha256sum; do
    run_host_command grep -Fqx "${command}:status=69" "${output}"
  done
  [[ ! -e "${marker}" ]]
  printf 'PASS  host-red      required generated-state fakes rejected before use\n'
}

prove_cross_checkout_command_state_rejected() {
  local target="$1" other marker output command command_output status=0
  other="${target}.other"
  marker="${target}.marker"
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  run_host_command mkdir -p -- \
    "${other}/.platform/bootstrap" "${other}/.platform/aqua/bin" \
    "${other}/.platform/other-bin"
  write_host_command_marker_fake "${other}/.platform/bootstrap/tar"
  write_host_command_marker_fake "${other}/.platform/aqua/bin/curl"
  write_host_command_marker_fake "${other}/.platform/other-bin/rm"
  (
    builtin cd -- "${target}"
    # shellcheck disable=SC2030,SC2031
    export PATH="${other}/.platform/bootstrap:${other}/.platform/aqua/bin:${other}/.platform/other-bin:${PATH}"
    # shellcheck disable=SC2030,SC2031
    export PLATFORM_HOST_FAKE_MARKER="${marker}"
    builtin source tools/common/env.sh
    builtin set +e
    for command in tar curl rm; do
      command_output="$(run_host_command "${command}" fixture 2>&1)"
      status=$?
      [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]] || exit 1
      [[ "${command_output}" == *"lookup location is inside repository or generated command state"* ]] ||
        exit 1
    done
  ) >"${output}"
  [[ ! -s "${output}" && ! -e "${marker}" ]]
  printf 'PASS  host-red      cross-checkout generated command paths rejected\n'
}

prove_printf_shadow_cannot_replace_host_path() {
  local target="$1" marker expected actual
  marker="${target}.marker"
  prepare_env_boundary_fixture "${target}"
  expected="$(host_command_path awk)"
  actual="$({
    builtin cd -- "${target}"
    # shellcheck disable=SC2317,SC2329
    printf() {
      builtin printf 'called\n' >"${marker}"
      builtin printf '/forged/awk\n'
    }
    builtin source tools/common/env.sh
    host_command_path awk
  })"
  [[ "${actual}" == "${expected}" && ! -e "${marker}" ]]
  builtin printf \
    'PASS  host-red      caller printf function cannot replace admitted path\n'
}

prove_function_shadow_rejected() {
  local target="$1" marker output status=0
  marker="${target}.marker"
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  (
    builtin cd -- "${target}"
    # shellcheck disable=SC2317,SC2329
    curl() { printf 'executed\n' >"${marker}"; }
    builtin source tools/common/env.sh
    run_host_command curl --version
  ) >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
  run_host_command grep -Fq 'shadowed by shell function' "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  host-red      inherited command function rejected with 69\n'
}

prove_unsupported_host_status() {
  local target="$1" output status=0
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  (
    builtin cd -- "${target}"
    builtin source tools/common/env.sh
    host_command_path perl
  ) >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_USAGE_STATUS}" ]]
  run_host_command grep -Fq 'unsupported prerequisite: perl' "${output}"
  printf 'PASS  host-red      unsupported command rejected with 64\n'
}

prove_child_bash_env_sealed() {
  local target="$1" marker preload
  marker="${target}.marker"
  preload="${target}.bash-env"
  prepare_env_boundary_fixture "${target}"
  run_host_command cat >"${preload}" <<'BASH_ENV_FIXTURE'
printf 'executed\n' >"${PLATFORM_BASH_ENV_MARKER:?}"
BASH_ENV_FIXTURE
  (
    builtin cd -- "${target}"
    export PLATFORM_BASH_ENV_MARKER="${marker}"
    export BASH_ENV="${preload}" ENV="${preload}"
    builtin source tools/common/env.sh
    [[ ! -v BASH_ENV && ! -v ENV ]]
    run_host_command bash -p -c ':'
  )
  [[ ! -e "${marker}" ]]
  printf 'PASS  host-red      child Bash cannot load inherited BASH_ENV\n'
}

write_aqua_environment_probe() {
  local target="$1"
  run_host_command cat >"${target}" <<'AQUA_PROBE'
#!/bin/bash -p
set -euo pipefail
{
  printf 'root=%s\nconfig=%s\nlazy=%s\npath=%s\n' \
    "${AQUA_ROOT_DIR-}" "${AQUA_CONFIG-}" "${AQUA_DISABLE_LAZY_INSTALL-}" \
    "${PATH-}"
  while IFS= read -r aqua_name; do
    printf 'exported=%s\n' "${aqua_name}"
  done < <(compgen -A export AQUA_)
  for aqua_name in AQUA_GLOBAL_CONFIG AQUA_POLICY_CONFIG AQUA_FUTURE_CONTROL \
    AQUA_DISABLE_COSIGN AQUA_ENFORCE_CHECKSUM AQUA_ENFORCE_REQUIRE_CHECKSUM; do
    [[ ! -v "${aqua_name}" ]] || exit 42
  done
} >"${PLATFORM_AQUA_ENV_MARKER:?}"
AQUA_PROBE
  run_host_command chmod +x -- "${target}"
}

write_bounded_duration_target() {
  local target="$1"
  run_host_command cat >"${target}" <<'BOUNDED_TARGET'
#!/bin/bash -p
builtin printf 'executed\n' >"${PLATFORM_BOUNDED_TARGET_MARKER:?}"
BOUNDED_TARGET
  run_host_command chmod +x -- "${target}"
}

prove_invalid_bounded_durations_rejected() {
  local target="$1" marker executable bash_path duration output status
  marker="${target}.marker"
  executable="${target}/.platform/aqua/bounded-target"
  prepare_env_boundary_fixture "${target}"
  write_bounded_duration_target "${executable}"
  bash_path="$(host_command_path bash)"
  for duration in 0 0s invalid 1 1m 601s; do
    output="${target}.${duration}.out"
    status=0
    # The single-quoted program intentionally expands only in the child Bash.
    # shellcheck disable=SC2016
    run_host_command env PLATFORM_BOUNDED_TARGET_MARKER="${marker}" \
      "${bash_path}" -p -c '
target=$1
duration=$2
executable=$3
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/bootstrap/aqua-trust.sh
run_project_aqua_bounded "${duration}" "${executable}"
' bounded-duration "${target}" "${duration}" "${executable}" \
      >"${output}" 2>&1 || status=$?
    [[ "${status}" -eq "${HOST_COMMAND_USAGE_STATUS}" ]]
    run_host_command grep -Fqx \
      "FAIL  aqua-trust    invalid bounded duration: ${duration}; expected 1s..600s" \
      "${output}"
  done
  [[ ! -e "${marker}" ]]
  printf 'PASS  aqua-red     zero and invalid bounded durations rejected with 64\n'
}

prove_normal_aqua_environment_sealed() {
  local target="$1" marker probe bash_path
  marker="${target}.env"
  prepare_env_boundary_fixture "${target}"
  probe="${target}/.platform/aqua/environment-probe"
  bash_path="$(host_command_path bash)"
  write_aqua_environment_probe "${probe}"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env \
    AQUA_ROOT_DIR=/hostile/root AQUA_CONFIG=/hostile/config \
    AQUA_GLOBAL_CONFIG=/hostile/global AQUA_POLICY_CONFIG=/hostile/policy \
    AQUA_FUTURE_CONTROL=hostile AQUA_DISABLE_COSIGN=true \
    AQUA_ENFORCE_CHECKSUM=false AQUA_ENFORCE_REQUIRE_CHECKSUM=false \
    PLATFORM_AQUA_ENV_MARKER="${marker}" \
    "${bash_path}" -p -c '
target=$1
probe=$2
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/bootstrap/aqua-trust.sh
run_project_aqua "${probe}"
' aqua-seal "${target}" "${probe}"
  run_host_command grep -Fqx "root=${target}/.platform/aqua" "${marker}"
  run_host_command grep -Fqx "config=${target}/aqua.yaml" "${marker}"
  run_host_command grep -Fqx 'lazy=true' "${marker}"
  run_host_command grep -Fqx "path=${PLATFORM_HOST_PATH}" "${marker}"
  [[ "$(run_host_command grep -c '^exported=' "${marker}")" -eq 3 ]]
  run_host_command grep -Fqx 'exported=AQUA_CONFIG' "${marker}"
  run_host_command grep -Fqx \
    'exported=AQUA_DISABLE_LAZY_INSTALL' "${marker}"
  run_host_command grep -Fqx 'exported=AQUA_ROOT_DIR' "${marker}"
  builtin printf 'PASS  aqua-seal    hostile Aqua environment cleared exactly\n'
}

write_trusted_proxy_fixture() {
  local target="$1"
  run_host_command cat >"${target}" <<'PROXY'
#!/bin/bash -p
builtin printf 'trusted-proxy\n'
PROXY
  run_host_command chmod 0755 -- "${target}"
}

write_missing_package_aqua() {
  local target="$1" curl_fixture="$2"
  run_host_command cat >"${target}" <<FAKE
#!/bin/bash -p
set -euo pipefail
case "\${1:-}" in
  version)
    builtin printf '${AQUA_VERSION}\n'
    ;;
  exec)
    [[ "\${2:-}" == -- && "\${3:-}" == go && "\$#" -eq 3 ]] || \
      builtin exit 2
    if [[ "\${AQUA_DISABLE_LAZY_INSTALL:-}" != true ]]; then
      ${curl_fixture@Q} https://fixture.invalid/package
      builtin printf 'mutated\n' >"\${AQUA_ROOT_DIR:?}/downloaded-package"
      builtin exit 0
    fi
    builtin printf \
      'fixture package missing; lazy install is disabled\n' >&2
    builtin exit 41
    ;;
  *) builtin exit 2 ;;
esac
FAKE
  run_host_command chmod 0755 -- "${target}"
}

write_network_marker_curl() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
builtin printf 'network attempted\n' >"${PLATFORM_NETWORK_MARKER:?}"
FAKE
  run_host_command chmod 0755 -- "${target}"
}

snapshot_fixture_state() {
  local target="$1" sha256_path
  sha256_path="$(host_command_path sha256sum)" || return
  {
    run_host_command find "${target}/.platform" \
      -printf '%P:%y:%s:%l\n'
    run_host_command find "${target}/.platform" -type f \
      -exec "${sha256_path}" -- {} +
  } | run_host_command sort
}

prove_managed_missing_package_stays_offline() {
  local target="$1" host_bin proxy marker output before after bash_path
  local status=0
  host_bin="${target}.host-bin"
  proxy="${target}/.platform/aqua/internal/pkgs/fixture/aqua-proxy"
  marker="${target}.network"
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  run_host_command mkdir -p -- "${host_bin}" "${proxy%/*}"
  write_network_marker_curl "${host_bin}/curl"
  write_missing_package_aqua \
    "${target}/.platform/bootstrap/aqua" "${host_bin}/curl"
  pin_fixture_aqua "${target}"
  write_trusted_proxy_fixture "${proxy}"
  run_host_command ln -s -- internal/pkgs/fixture/aqua-proxy \
    "${target}/.platform/aqua/aqua-proxy"
  run_host_command ln -s -- ../aqua-proxy \
    "${target}/.platform/aqua/bin/go"
  pin_fixture_proxy "${target}"
  before="$(snapshot_fixture_state "${target}")"
  bash_path="$(host_command_path bash)"
  # PATH changes in earlier isolated fixtures do not affect this shell.
  # shellcheck disable=SC2031
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env PATH="${host_bin}:${PATH}" \
    PLATFORM_NETWORK_MARKER="${marker}" "${bash_path}" -p -c '
target=$1
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/common/tooling.sh
run_managed_tool go
' managed-missing "${target}" >"${output}" 2>&1 || status=$?
  after="$(snapshot_fixture_state "${target}")"
  [[ "${status}" -eq 41 ]]
  run_host_command grep -Fqx \
    'fixture package missing; lazy install is disabled' "${output}"
  [[ "${before}" == "${after}" ]]
  [[ ! -e "${marker}" &&
    ! -e "${target}/.platform/aqua/downloaded-package" ]]
  builtin printf \
    'PASS  aqua-red     managed missing package stayed offline and immutable\n'
}

prove_managed_proxy_rechecked_each_call() {
  local target="$1" marker output proxy bash_path status=0
  marker="${target}.marker"
  output="${target}.out"
  proxy="${target}/.platform/aqua/internal/pkgs/fixture/aqua-proxy"
  prepare_env_boundary_fixture "${target}"
  run_host_command mkdir -p -- "${proxy%/*}"
  write_exec_marker_aqua "${target}/.platform/bootstrap/aqua"
  pin_fixture_aqua "${target}"
  write_trusted_proxy_fixture "${proxy}"
  run_host_command ln -s -- internal/pkgs/fixture/aqua-proxy \
    "${target}/.platform/aqua/aqua-proxy"
  run_host_command ln -s -- ../aqua-proxy \
    "${target}/.platform/aqua/bin/go"
  pin_fixture_proxy "${target}"
  bash_path="$(host_command_path bash)"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env PLATFORM_AQUA_PROXY_RED_MARKER="${marker}" \
    "${bash_path}" -p -c '
target=$1
proxy=$2
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/common/tooling.sh
resolve_managed_tool go
builtin printf "%s\n" "#!/bin/bash -p" "builtin exit 91" >"${proxy}"
run_host_command chmod 0755 -- "${proxy}"
run_managed_tool go
' proxy-recheck "${target}" "${proxy}" >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq 1 ]]
  run_host_command grep -Fq \
    'project-managed toolchain unavailable or untrusted: go' "${output}" || {
    run_host_command cat -- "${output}" >&2
    return 1
  }
  [[ ! -e "${marker}" ]]
  builtin printf \
    'PASS  aqua-red     managed proxy replacement rechecked before second call\n'
}

prove_aqua_maintenance_rechecked_each_call() {
  local target="$1" marker output trusted replacement bash_path
  marker="${target}.marker"
  output="${target}.out"
  trusted="${target}/trusted-aqua"
  replacement="${target}/replacement-aqua"
  prepare_env_boundary_fixture "${target}"
  write_fake_aqua "${target}/.platform/bootstrap/aqua" 0
  pin_fixture_aqua "${target}"
  run_host_command cp -- "${target}/.platform/bootstrap/aqua" "${trusted}"
  write_marker_aqua "${replacement}"
  bash_path="$(host_command_path bash)"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env PLATFORM_AQUA_RED_MARKER="${marker}" \
    "${bash_path}" -p -c '
target=$1
trusted=$2
replacement=$3
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/bootstrap/aqua-trust.sh
replace_aqua() {
  run_host_command cp -fT -- "${replacement}" "${AQUA_BIN}"
}
run_project_aqua_install
replace_aqua
if run_project_aqua_update_checksum; then
  builtin printf "FAIL  aqua-red     replaced Aqua reached checksum update\\n" >&2
  builtin exit 1
fi
run_host_command cp -fT -- "${trusted}" "${AQUA_BIN}"
run_project_aqua_update_checksum
replace_aqua
if run_project_aqua_install; then
  builtin printf "FAIL  aqua-red     replaced Aqua reached install\\n" >&2
  builtin exit 1
fi
' maintenance-recheck "${target}" "${trusted}" "${replacement}" \
    >"${output}" 2>&1
  run_host_command grep -Fq \
    'cached Aqua changed before checksum update' "${output}"
  run_host_command grep -Fq \
    'cached Aqua changed before install' "${output}"
  [[ ! -e "${marker}" ]]
  builtin printf \
    'PASS  aqua-red     maintenance Aqua replacement rechecked before mutation\n'
}

prove_verified_aqua_descriptor_survives_path_swap() {
  local target="$1" marker replacement bash_path
  marker="${target}.marker"
  replacement="${target}/replacement-aqua"
  prepare_fixture "${target}"
  write_identity_marker_aqua \
    "${target}/.platform/bootstrap/aqua" trusted
  pin_fixture_aqua "${target}"
  write_identity_marker_aqua "${replacement}" replacement
  bash_path="$(host_command_path bash)"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env PLATFORM_AQUA_IDENTITY_MARKER="${marker}" \
    "${bash_path}" -p -c '
target=$1
replacement=$2
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/bootstrap/aqua-trust.sh
aqua_open_verified_execution "${AQUA_BIN}"
run_host_command mv -fT -- "${replacement}" "${AQUA_BIN}"
"${AQUA_TRUST_EXEC_PATH}" probe
' aqua-path-swap "${target}" "${replacement}"
  run_host_command grep -Fqx trusted "${marker}"
  builtin printf \
    'PASS  aqua-red     descriptor pin defeated deterministic pathname swap\n'
}

prove_verified_aqua_descriptor_stat_failure_rejected() {
  local target="$1" bash_path
  prepare_fixture "${target}"
  write_identity_marker_aqua \
    "${target}/.platform/bootstrap/aqua" trusted
  pin_fixture_aqua "${target}"
  bash_path="$(host_command_path bash)"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env "${bash_path}" -p -c '
target=$1
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/bootstrap/aqua-trust.sh
definition="$(declare -f run_host_command)"
eval "${definition/run_host_command/original_run_host_command}"
run_host_command() {
  local last="${*: -1}"
  if [[ "${1:-}" == stat && "${last}" == /proc/self/fd/* ]]; then
    return 7
  fi
  original_run_host_command "$@"
}
set +e
aqua_open_verified_execution "${AQUA_BIN}"
status=$?
set -e
[[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
[[ -z "${AQUA_TRUST_EXEC_FD:-}" && -z "${AQUA_TRUST_EXEC_PATH:-}" ]]
' aqua-stat-failure "${target}"
  builtin printf \
    'PASS  aqua-red     descriptor stat failure propagated exact rejection\n'
}

prove_managed_invalid_duration_precedes_resolution() {
  local target="$1" marker output bash_path status=0
  marker="${target}.marker"
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  write_marker_aqua "${target}/.platform/bootstrap/aqua"
  bash_path="$(host_command_path bash)"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env PLATFORM_AQUA_RED_MARKER="${marker}" \
    "${bash_path}" -p -c '
target=$1
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/common/tooling.sh
run_managed_tool_bounded 0s go
' managed-duration "${target}" >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_USAGE_STATUS}" ]]
  run_host_command grep -Fq \
    'invalid bounded duration: 0s; expected 1s..600s' "${output}"
  [[ ! -e "${marker}" ]]
  builtin printf \
    'PASS  aqua-red     managed invalid duration rejected before Aqua resolution\n'
}

write_timeout_tree_fixture() {
  local target="$1" sleep_path
  sleep_path="$(host_command_path sleep)" || return
  run_host_command cat >"${target}" <<TREE
#!/bin/bash -p
${sleep_path@Q} 30 &
child=\$!
builtin printf '%s\n' "\${child}" >"\${PLATFORM_TIMEOUT_CHILD_PID:?}"
builtin wait "\${child}"
TREE
  run_host_command chmod 0755 -- "${target}"
}

prove_bounded_aqua_cleans_descendants() {
  local target="$1" executable pid_file output bash_path pid status=0
  local gone=false
  executable="${target}/.platform/aqua/timeout-tree"
  pid_file="${target}.pid"
  output="${target}.out"
  prepare_env_boundary_fixture "${target}"
  write_timeout_tree_fixture "${executable}"
  bash_path="$(host_command_path bash)"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env PLATFORM_TIMEOUT_CHILD_PID="${pid_file}" \
    "${bash_path}" -p -c '
target=$1
executable=$2
builtin cd -- "${target}"
builtin source tools/common/env.sh
builtin source tools/bootstrap/aqua-trust.sh
run_project_aqua_bounded 1s "${executable}"
' bounded-tree "${target}" "${executable}" >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq 124 && -s "${pid_file}" ]]
  pid="$(<"${pid_file}")"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]]
  for _ in {1..20}; do
    if [[ ! -e "/proc/${pid}" ]]; then
      gone=true
      break
    fi
    run_host_command sleep 0.05
  done
  if [[ "${gone}" != true ]]; then
    builtin kill -KILL "${pid}" 2>/dev/null || builtin true
    builtin printf \
      'FAIL  aqua-red     bounded target left child process %s\n' \
      "${pid}" >&2
    return 1
  fi
  builtin printf 'PASS  aqua-red     bounded target removed descendant process\n'
}

cleanup_prove_tool_lock() {
  local status=$?
  trap - EXIT
  if [[ -n "${WORK_DIR}" ]]; then
    case "${WORK_DIR}" in
      /tmp/flare-prove-tool-lock.*)
        run_host_command rm -rf -- "${WORK_DIR}" || status=1
        ;;
      *)
        builtin printf 'FAIL  tool-lock     unsafe proof cleanup path: %s\n' \
          "${WORK_DIR}" >&2
        status=1
        ;;
    esac
  fi
  exit "${status}"
}

main() {
  WORK_DIR="$(run_host_command mktemp -d \
    /tmp/flare-prove-tool-lock.XXXXXXXXXX)"
  trap cleanup_prove_tool_lock EXIT
  prove_unique_checksum_policy "${WORK_DIR}/unique-checksum"
  prove_duplicate_checksum_policy "${WORK_DIR}/duplicate-checksum"
  prove_fake_cached_aqua "${WORK_DIR}/fake-cache"
  prove_symlink_cached_aqua "${WORK_DIR}/symlink-cache"
  prove_nonregular_cached_aqua "${WORK_DIR}/nonregular-cache"
  prove_untrusted_tool_lock_rejection "${WORK_DIR}/untrusted-tool-lock"
  prove_inherited_verifier_cannot_bypass "${WORK_DIR}/inherited-tool-lock"
  prove_nonexecutable_tool_lock_rejection "${WORK_DIR}/nonexec-tool-lock"
  prove_rollback "${WORK_DIR}/rollback"
  prove_initial_backup_failure_cleanup "${WORK_DIR}/backup-failure"
  prove_restore_failure_retains_backup "${WORK_DIR}/restore-failure"
  prove_success "${WORK_DIR}/success"
  prove_missing_checksum_regenerated "${WORK_DIR}/missing-checksum"
  prove_project_path_not_published "${WORK_DIR}/path"
  prove_state_symlink_host_rejected "${WORK_DIR}/state-symlink"
  prove_external_symlink_into_state_rejected \
    "${WORK_DIR}/external-state-symlink"
  prove_required_state_host_fakes_rejected "${WORK_DIR}/state-host-fakes"
  prove_cross_checkout_command_state_rejected "${WORK_DIR}/cross-checkout"
  prove_printf_shadow_cannot_replace_host_path "${WORK_DIR}/printf-shadow"
  prove_function_shadow_rejected "${WORK_DIR}/function-shadow"
  prove_unsupported_host_status "${WORK_DIR}/unsupported"
  prove_child_bash_env_sealed "${WORK_DIR}/bash-env"
  prove_invalid_bounded_durations_rejected "${WORK_DIR}/bounded-duration"
  prove_normal_aqua_environment_sealed "${WORK_DIR}/aqua-seal"
  prove_managed_missing_package_stays_offline \
    "${WORK_DIR}/managed-missing"
  prove_managed_proxy_rechecked_each_call "${WORK_DIR}/proxy-recheck"
  prove_aqua_maintenance_rechecked_each_call \
    "${WORK_DIR}/maintenance-recheck"
  prove_verified_aqua_descriptor_survives_path_swap \
    "${WORK_DIR}/descriptor-path-swap"
  prove_verified_aqua_descriptor_stat_failure_rejected \
    "${WORK_DIR}/descriptor-stat-failure"
  prove_managed_invalid_duration_precedes_resolution \
    "${WORK_DIR}/managed-duration"
  prove_bounded_aqua_cleans_descendants "${WORK_DIR}/bounded-tree"
}

main "$@"
