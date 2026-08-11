#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
# shellcheck source=../common/tooling.sh
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"
# shellcheck source=environment-profile.sh
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/environment-profile.sh"

WORK_DIR=""
WORK_TOKEN=""
WORK_RM_PATH=""

cleanup_proof_workspace() {
  [[ -n "${WORK_DIR}" && -n "${WORK_TOKEN}" && -n "${WORK_RM_PATH}" ]] || return
  environment_profile_remove_owned_workspace \
    "${WORK_DIR}" "${WORK_TOKEN}" "${WORK_RM_PATH}" >/dev/null 2>&1 || true
}

expect_profile_red() {
  local label="$1"
  local reason="$2"
  local output="${WORK_DIR}/${label}.out"
  shift 2
  if "$@" >"${output}" 2>&1; then
    printf 'FAIL  environment-red %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  if ! grep -Fq -- "${reason}" "${output}"; then
    printf 'FAIL  environment-red %s missed reason: %s\n' \
      "${label}" "${reason}" >&2
    sed -n '1,12p' "${output}" >&2
    return 1
  fi
  printf 'PASS  environment-red %s rejected for exact capability\n' "${label}"
}

expect_invalid_evidence() {
  local label="$1"
  local evidence="$2"
  if environment_profile_validate_evidence "${evidence}" >/dev/null 2>&1; then
    printf 'FAIL  evidence-red %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  evidence-red %s rejected\n' "${label}"
}

write_fake_zero() {
  local target="$1"
  cat >"${target}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${0##*/}:$*" >>"${ZERO_FIXTURE_MARKER:?}"
exit 0
FAKE
  chmod 0755 "${target}"
}

prove_fake_zero_rejected() {
  local fake="${WORK_DIR}/fake-zero"
  local marker="${WORK_DIR}/fake-zero.marker"
  write_fake_zero "${fake}"
  export ZERO_FIXTURE_MARKER="${marker}"
  expect_profile_red fake-zero-bash 'GNU Bash identity is malformed' \
    environment_profile_check_bash "${fake}"
  expect_profile_red fake-zero-tar 'GNU tar identity is malformed' \
    environment_profile_check_tar \
    "${fake}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  expect_profile_red fake-zero-timeout 'GNU timeout identity is malformed' \
    environment_profile_check_timeout "${fake}" "${fake}"
  expect_profile_red fake-zero-docker 'Docker identity response is malformed' \
    environment_profile_check_docker "${fake}" "$(type -P timeout)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  expect_profile_red fake-zero-curl 'curl identity is malformed' \
    environment_profile_check_curl "${fake}"
  [[ "$(wc -l <"${marker}")" -eq 5 ]]
  printf 'PASS  environment-red zero-returning command names prove no capability\n'
}

prove_curl_surface_red() {
  local fake="${WORK_DIR}/limited-curl"
  cat >"${fake}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'curl 9.0.0 test\nProtocols: http https\n'
  exit 0
fi
if [[ "${1:-}" == --help && "${2:-}" == all ]]; then
  printf '%s\n' --fail --location --proto --proto-redir --tlsv1.2 \
    --connect-timeout --max-time --max-filesize --retry --output --silent \
    --show-error
  exit 0
fi
exit 64
FAKE
  chmod 0755 "${fake}"
  expect_profile_red curl-options \
    'required bounded HTTP transfer surface is unavailable' \
    environment_profile_check_curl "${fake}"
  printf 'PASS  environment-red curl protocols and consumed flags are exact\n'
}

prove_core_utility_red() {
  local fake="${WORK_DIR}/fake-core-utility"
  local marker="${WORK_DIR}/fake-core-utility.marker"
  local -a actual probe
  actual=(
    "$(builtin type -P sha256sum)" "$(builtin type -P readlink)"
    "$(builtin type -P stat)" "$(builtin type -P mktemp)"
    "$(builtin type -P cmp)" "$(builtin type -P diff)"
    "$(builtin type -P chmod)" "$(builtin type -P ln)"
    "$(builtin type -P mkfifo)" "$(builtin type -P mkdir)"
    "$(builtin type -P od)" "$(builtin type -P rm)"
  )
  write_fake_zero "${fake}"
  export ZERO_FIXTURE_MARKER="${marker}"
  probe=("${actual[@]}")
  probe[0]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-sha \
    'sha256sum grammar is unavailable' environment_profile_check_core_utilities \
    "${probe[@]}"
  probe=("${actual[@]}")
  probe[1]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-readlink \
    'readlink -n/-f semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[2]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-stat \
    'stat creation-mode semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[3]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-mktemp \
    'mktemp directory template is unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[4]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-cmp \
    'cmp inequality semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[5]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-diff \
    'diff inequality semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[6]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-chmod \
    'stat or chmod semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[7]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-ln \
    'readlink -n/-f semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[8]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-mkfifo \
    'mkfifo semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[9]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-mkdir \
    'mkdir ownership semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[10]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-od \
    'od byte semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[11]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-rm \
    'rm cleanup semantics are unavailable' environment_profile_check_core_utilities \
    "${probe[@]}"
  prove_mktemp_cannot_select_cleanup_target "${actual[@]}"
  prove_mkdir_cannot_select_ownership_target "${actual[@]}"
  TMPDIR=/tmp/ environment_profile_check_core_utilities "${actual[@]}"
  printf 'PASS  environment-red core utility behavior is proved, not named\n'
}

prove_host_utility_pipeline_red() {
  local fake="${WORK_DIR}/fake-host-utility"
  local command_name reason
  local -a text_commands=(
    awk basename cat cut dirname grep head sed sort tail tee tr wc
  )
  local -a file_commands=(cp env find git gzip make mv)
  write_fake_zero "${fake}"
  export ZERO_FIXTURE_MARKER="${WORK_DIR}/fake-host-utility.marker"
  for command_name in "${text_commands[@]}"; do
    environment_profile_require_host_commands
    ENVIRONMENT_PROFILE_HOST_PATHS["${command_name}"]="${fake}"
    reason='bounded text utility semantics are unavailable'
    TMPDIR="${WORK_DIR}" expect_profile_red "host-zero-${command_name}" \
      "${reason}" environment_profile_check_host_utilities
  done
  for command_name in "${file_commands[@]}"; do
    environment_profile_require_host_commands
    ENVIRONMENT_PROFILE_HOST_PATHS["${command_name}"]="${fake}"
    reason='bounded file and command semantics are unavailable'
    TMPDIR="${WORK_DIR}" expect_profile_red "host-zero-${command_name}" \
      "${reason}" environment_profile_check_host_utilities
  done
  environment_profile_require_host_commands
  TMPDIR="${WORK_DIR}" environment_profile_check_host_utilities
  expect_profile_red host-zero-uname 'requires Linux x86_64' \
    environment_profile_check_platform "${fake}"
  expect_profile_red host-zero-sleep \
    'spawned job process-group visibility is unavailable' \
    environment_profile_prove_process_group "${fake}"
  printf 'PASS  environment-red every declared host utility is behavioral\n'
}

prove_mktemp_cannot_select_cleanup_target() {
  local -a actual=("$@") probe
  local fake="${WORK_DIR}/untrusted-mktemp"
  local victim="${WORK_DIR}/unrelated-victim"
  mkdir -p "${victim}"
  printf 'preserve\n' >"${victim}/sentinel"
  cat >"${fake}" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${UNTRUSTED_MKTEMP_RESULT:?}"
FAKE
  chmod 0755 "${fake}"
  probe=("${actual[@]}")
  probe[3]="${fake}"
  UNTRUSTED_MKTEMP_RESULT="${victim}" TMPDIR="${WORK_DIR}" \
    expect_profile_red core-mktemp-target \
    'mktemp directory template is unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  [[ "$(<"${victim}/sentinel")" == preserve ]]
  printf 'PASS  environment-red untrusted mktemp cannot select cleanup target\n'
}

prove_mkdir_cannot_select_ownership_target() {
  local -a actual=("$@") probe
  local fake="${WORK_DIR}/untrusted-mkdir"
  local victim="${WORK_DIR}/ownership-victim"
  printf 'must-survive\n' >"${victim}"
  cat >"${fake}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
"${REAL_MKDIR:?}" "$@"
"${REAL_LN:?}" -s -- "${OWNERSHIP_VICTIM:?}" "${target}/.ownership"
FAKE
  chmod 0755 "${fake}"
  probe=("${actual[@]}")
  probe[9]="${fake}"
  REAL_MKDIR="${actual[9]}" REAL_LN="${actual[7]}" \
    OWNERSHIP_VICTIM="${victim}" TMPDIR="${WORK_DIR}" \
    expect_profile_red core-ownership-target \
    'mkdir ownership semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  [[ "$(<"${victim}")" == must-survive ]]
  printf 'PASS  environment-red ownership marker cannot overwrite a symlink\n'
}

write_limited_tar() {
  local target="$1"
  cat >"${target}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'tar (GNU tar) 1.35\n'
  exit 0
fi
printf '%s\n' "$*" >>"${TAR_FIXTURE_MARKER:?}"
exit 64
FAKE
  chmod 0755 "${target}"
}

write_limited_timeout() {
  local target="$1"
  cat >"${target}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'timeout (GNU coreutils) 9.4\n'
  exit 0
fi
printf '%s\n' "$*" >>"${TIMEOUT_FIXTURE_MARKER:?}"
exit 0
FAKE
  chmod 0755 "${target}"
}

prove_tar_and_timeout_red() {
  local fake_tar="${WORK_DIR}/limited-tar"
  local wrapper="${WORK_DIR}/tar-wrapper"
  local fake_timeout="${WORK_DIR}/limited-timeout"
  local tar_marker="${WORK_DIR}/tar.marker"
  local timeout_marker="${WORK_DIR}/timeout.marker"
  write_limited_tar "${fake_tar}"
  write_limited_timeout "${fake_timeout}"
  TAR_FIXTURE_MARKER="${tar_marker}" expect_profile_red tar-stream \
    'deterministic ustar flags or stream semantics are unavailable' \
    environment_profile_check_tar \
    "${fake_tar}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  write_semantic_tar_wrapper "${wrapper}"
  REAL_TAR="$(builtin type -P tar)" TAR_WRAPPER_MODE=mode-loss \
    expect_profile_red tar-mode \
    'deterministic ustar flags or stream semantics are unavailable' \
    environment_profile_check_tar \
    "${wrapper}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  REAL_TAR="$(builtin type -P tar)" TAR_WRAPPER_MODE=gnu-format \
    expect_profile_red tar-format \
    'deterministic ustar flags or stream semantics are unavailable' \
    environment_profile_check_tar \
    "${wrapper}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  TIMEOUT_FIXTURE_MARKER="${timeout_marker}" expect_profile_red timeout-bound \
    '--foreground and --kill-after behavior returned 0, expected 137' \
    environment_profile_check_timeout "${fake_timeout}" "$(type -P bash)"
  grep -Fq -- '--sort=name --format=ustar --mtime=UTC 1970-01-01' "${tar_marker}"
  grep -Fq -- '--foreground --signal=TERM --kill-after=0.1s 0.1s' \
    "${timeout_marker}"
  printf 'PASS  environment-red tar and timeout behavior is exercised, not named\n'
}

write_semantic_tar_wrapper() {
  local target="$1"
  cat >"${target}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
create=false
args=()
for argument in "$@"; do
  case "${argument}" in
    --create | -*c*) create=true ;;
  esac
  if [[ "${TAR_WRAPPER_MODE:?}" == gnu-format &&
    "${argument}" == --format=ustar ]]; then
    args+=(--format=gnu)
  else
    args+=("${argument}")
  fi
done
if [[ "${TAR_WRAPPER_MODE}" == mode-loss && "${create}" == true ]]; then
  exec "${REAL_TAR:?}" --mode=0644 "${args[@]}"
fi
exec "${REAL_TAR:?}" "${args[@]}"
FAKE
  chmod 0755 "${target}"
}

prove_proc_red() {
  local absent="${WORK_DIR}/proc-absent"
  local malformed="${WORK_DIR}/proc-malformed"
  mkdir -p "${absent}" "${malformed}/self"
  printf '123 (broken) R parent 42\n' >"${malformed}/self/stat"
  expect_profile_red proc-absent '/self/stat is unavailable' \
    environment_profile_read_proc_stat "${absent}"
  expect_profile_red proc-malformed 'Linux /proc stat fields are malformed' \
    environment_profile_read_proc_stat "${malformed}"
  printf 'PASS  environment-red alternate proc roots fail closed\n'
}

write_fake_docker() {
  local target="$1"
  cat >"${target}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DOCKER_FIXTURE_LOG:?}"
case "${DOCKER_FIXTURE_MODE:-valid}:${1:-}" in
  unreachable:version) exit 69 ;;
  malformed:version) printf 'not-a-docker-identity\n' ;;
  extra-line:version)
    printf '29.7.2|29.7.2|1.55|1.55|linux|amd64\nJUNK_SECOND_LINE\n'
    ;;
  *:version)
    printf '29.7.2|29.7.2|1.55|1.55|linux|amd64\n'
    ;;
  zero-help:build | zero-help:image) ;;
  missing-help:build)
    printf '%s\n' 'docker buildx build [OPTIONS] PATH | URL | -' \
      '  --network string' '  --pull' '  --no-cache' '  --progress string auto'
    ;;
  *:build)
    [[ " $* " == *' --help '* ]] || exit 90
    printf '%s\n' 'docker buildx build [OPTIONS] PATH | URL | -' \
      '  --network string' '  --pull' '  --no-cache' \
      '  --progress string' '      ("auto", "plain", "tty", "rawjson")'
    ;;
  inspect-fail:image)
    [[ "${2:-}" != inspect ]] || exit 67
    printf '%s\n' 'docker image rm [OPTIONS] IMAGE'
    ;;
  remove-fail:image)
    [[ "${2:-}" != rm ]] || exit 68
    printf '%s\n' 'docker image inspect [OPTIONS] IMAGE' '  --format string'
    ;;
  *:image)
    [[ " $* " == *' --help '* ]] || exit 91
    case "${2:-}" in
      inspect) printf '%s\n' 'docker image inspect [OPTIONS] IMAGE' '  --format string' ;;
      rm) printf '%s\n' 'docker image rm [OPTIONS] IMAGE' ;;
      *) exit 92 ;;
    esac
    ;;
  *) exit 93 ;;
esac
FAKE
  chmod 0755 "${target}"
}

prove_docker_identity_red() {
  local docker="${WORK_DIR}/docker"
  local log="${WORK_DIR}/docker-red.log"
  local timeout_path
  timeout_path="$(type -P timeout)"
  write_fake_docker "${docker}"
  PLATFORM_TEST_FORCE_MISSING=docker expect_profile_red docker-missing \
    'docker missing' environment_profile_resolve_command docker
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=unreachable \
    expect_profile_red docker-unreachable 'Docker daemon is unreachable within 15s' \
    environment_profile_check_docker "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=malformed \
    expect_profile_red docker-malformed 'Docker identity response is malformed' \
    environment_profile_check_docker "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=extra-line \
    expect_profile_red docker-extra-line 'Docker identity response is malformed' \
    environment_profile_check_docker "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=missing-help \
    expect_profile_red docker-build-response \
    'BuildKit response lacks --progress=plain' \
    environment_profile_check_docker "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=inspect-fail \
    expect_profile_red docker-inspect-query \
    'unable to query local image inspect surface' \
    environment_profile_check_docker "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=remove-fail \
    expect_profile_red docker-remove-query \
    'unable to query local image removal surface' \
    environment_profile_check_docker "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  printf 'PASS  environment-red Docker availability and identity are semantic\n'
}

prove_docker_help_red() {
  local valid missing
  valid=$'docker buildx build [OPTIONS] PATH | URL | -\n--network string\n--pull\n--no-cache\n--progress string plain'
  missing="${valid/docker buildx build/docker legacy build}"
  expect_profile_red docker-buildx 'BuildKit buildx response is absent' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/PATH | URL | -/PATH}"
  expect_profile_red docker-stdin 'stdin tar context is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--network string/--net string}"
  expect_profile_red docker-network '--network=none is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--pull/--download}"
  expect_profile_red docker-pull '--pull=false is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--no-cache/--cache}"
  expect_profile_red docker-no-cache '--no-cache is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--progress string/--output string}"
  expect_profile_red docker-progress 'BuildKit response lacks --progress=plain' \
    environment_profile_check_docker_build_help "${missing}"
  expect_profile_red docker-inspect 'image inspect --format is unavailable' \
    environment_profile_check_docker_local_help \
    'docker image inspect [OPTIONS]' 'docker image rm [OPTIONS] --force'
  expect_profile_red docker-remove 'local image removal is unavailable' \
    environment_profile_check_docker_local_help \
    'docker image inspect [OPTIONS] --format' 'docker image remove [OPTIONS]'
  printf 'PASS  environment-red every consumed Docker help token is required\n'
}

prove_buildkit_parser_helper_red() {
  local directory="${WORK_DIR}/buildkit-helper"
  local log="${directory}/missing.log" marker="${directory}/sed.marker"
  mkdir -p "${directory}/bin"
  cat >"${directory}/bin/sed" <<'FAKE'
#!/usr/bin/env bash
printf 'sha256:%064d\n' 0
printf 'executed\n' >"${FAKE_SED_MARKER:?}"
FAKE
  chmod 0755 "${directory}/bin/sed"
  printf '# no BuildKit result\n' >"${log}"
  # shellcheck source=../kubernetes/buildkit-result.sh
  source "${PLATFORM_ROOT}/tools/kubernetes/buildkit-result.sh"
  if PATH="${directory}/bin:${PATH}" FAKE_SED_MARKER="${marker}" \
    buildkit_result_config_id "${log}" >/dev/null 2>&1; then
    printf 'FAIL  buildkit-red  helper forged a missing result\n' >&2
    return 1
  fi
  [[ ! -e "${marker}" ]]
  printf 'PASS  buildkit-red  exact parser is independent of PATH helpers\n'
}

prove_project_identity_red() {
  expect_profile_red kind-absent \
    'kind identity differs from trusted Aqua identity' \
    environment_profile_check_kind_output '' v2.0.0
  expect_profile_red kind-wrong \
    'kind identity differs from trusted Aqua identity' \
    environment_profile_check_kind_output \
    'kind v1.0.0 go1.25.5 linux/amd64' v2.0.0
  expect_profile_red kubectl-absent \
    'kubectl client identity/platform differs from trusted Aqua identity' \
    environment_profile_check_kubectl_output '{}' v2.0.0
  expect_profile_red kubectl-wrong \
    'kubectl client identity/platform differs from trusted Aqua identity' \
    environment_profile_check_kubectl_output \
    $'  "gitVersion": "v1.0.0",\n  "platform": "linux/amd64"' v2.0.0
  expect_profile_red kubectl-platform \
    'kubectl client identity/platform differs from trusted Aqua identity' \
    environment_profile_check_kubectl_output \
    $'  "gitVersion": "v2.0.0",\n  "platform": "darwin/amd64"' v2.0.0
  printf 'PASS  environment-red managed kind and kubectl identities are exact\n'
}

prove_project_package_checksum_red() {
  local root="${WORK_DIR}/package-lock" lock asset binary expected
  asset='github_release/github.com/example/kind/v1.2.3/kind-linux-amd64'
  binary="${root}/pkgs/${asset}/kind-linux-amd64"
  lock="${root}/aqua-checksums.json"
  mkdir -p "${binary%/*}"
  printf '#!/usr/bin/env bash\nprintf "kind v1.2.3 go1 linux/amd64\\n"\n' \
    >"${binary}"
  chmod 0755 "${binary}"
  expected="$(sha256sum -- "${binary}")"
  expected="${expected%%[[:space:]]*}"
  {
    printf '{\n  "checksums": [\n    {\n'
    printf '      "id": "%s",\n' "${asset}"
    printf '      "checksum": "%s",\n' "${expected^^}"
    printf '      "algorithm": "sha256"\n'
    printf '    }\n  ]\n}\n'
  } >"${lock}"
  environment_profile_verify_installed_tool_checksum \
    "${binary}" "${root}" "${lock}" "$(builtin type -P sha256sum)" kind
  printf '#!/usr/bin/env bash\nprintf "kind v1.2.3 go2 linux/amd64\\n"\n' \
    >"${binary}"
  expect_profile_red project-package-tamper \
    'installed kind bytes differ from checksum lock' \
    environment_profile_verify_installed_tool_checksum \
    "${binary}" "${root}" "${lock}" "$(builtin type -P sha256sum)" kind
  printf 'PASS  project-red   installed package bytes bind to Aqua checksum lock\n'
}

prove_project_proxy_red() {
  local proxy="${WORK_DIR}/failing-aqua-proxy" marker="${WORK_DIR}/proxy.marker"
  cat >"${proxy}" <<'FAKE'
#!/usr/bin/env bash
printf 'executed\n' >"${PROJECT_PROXY_MARKER:?}"
exit 99
FAKE
  chmod 0755 "${proxy}"
  if PROJECT_PROXY_MARKER="${marker}" environment_profile_query_project_tool \
    "$(builtin type -P timeout)" "${proxy}" "${WORK_DIR}" kind \
    >/dev/null 2>&1; then
    printf 'FAIL  project-red   failing managed proxy was bypassed\n' >&2
    return 1
  fi
  [[ "$(<"${marker}")" == executed ]]
  printf 'PASS  project-red   observed tool identity executes admitted proxy\n'
}

prepare_doctor_fixture() {
  local target="$1"
  local path
  mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/kubernetes" "${target}/fake-bin"
  cp "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  for path in aqua-trust.sh doctor.sh environment-profile.sh; do
    cp "${PLATFORM_ROOT}/tools/bootstrap/${path}" "${target}/tools/bootstrap/"
  done
  for path in env.sh process-state.sh state.sh tooling.sh; do
    cp "${PLATFORM_ROOT}/tools/common/${path}" "${target}/tools/common/"
  done
  cp "${PLATFORM_ROOT}/tools/kubernetes/buildkit-result.sh" \
    "${target}/tools/kubernetes/buildkit-result.sh"
  write_fake_docker "${target}/fake-bin/docker"
  cat >"${target}/fake-bin/external-managed" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${0##*/}:$*" >>"${EXTERNAL_MANAGED_MARKER:?}"
exit 0
FAKE
  chmod 0755 "${target}/fake-bin/external-managed"
  ln -s external-managed "${target}/fake-bin/aqua"
  ln -s external-managed "${target}/fake-bin/kind"
  ln -s external-managed "${target}/fake-bin/kubectl"
}

pin_doctor_fixture_digest() {
  local target="$1" variable="$2" source="$3" module temporary digest
  module="${target}/tools/bootstrap/aqua-trust.sh"
  temporary="${module}.new"
  digest="$(sha256sum -- "${source}")"
  digest="${digest%% *}"
  sed -E \
    "s/^(readonly ${variable}=\")[0-9a-f]{64}(\")$/\\1${digest}\\2/" \
    "${module}" >"${temporary}"
  grep -Fqx "readonly ${variable}=\"${digest}\"" "${temporary}"
  mv "${temporary}" "${module}"
}

write_ready_project_fixture_lock() {
  local target="$1" kind_asset="$2" kind_path="$3"
  local kubectl_asset="$4" kubectl_path="$5" kind_hash kubectl_hash
  kind_hash="$(sha256sum -- "${kind_path}")"
  kind_hash="${kind_hash%%[[:space:]]*}"
  kubectl_hash="$(sha256sum -- "${kubectl_path}")"
  kubectl_hash="${kubectl_hash%%[[:space:]]*}"
  {
    printf '{\n  "checksums": [\n    {\n'
    printf '      "id": "%s",\n' "${kind_asset}"
    printf '      "checksum": "%s",\n' "${kind_hash^^}"
    printf '      "algorithm": "sha256"\n    },\n    {\n'
    printf '      "id": "%s",\n' "${kubectl_asset}"
    printf '      "checksum": "%s",\n' "${kubectl_hash^^}"
    printf '      "algorithm": "sha256"\n    }\n  ]\n}\n'
  } >"${target}/aqua-checksums.json"
}

prepare_ready_project_fixture() {
  local target="$1" kind_asset kubectl_asset kind_path kubectl_path proxy
  kind_asset='github_release/github.com/example/kind/v1.2.3/kind-linux-amd64'
  kubectl_asset='http/example.invalid/v4.5.6/linux/amd64/kubectl'
  kind_path="${target}/.platform/aqua/pkgs/${kind_asset}/kind-linux-amd64"
  kubectl_path="${target}/.platform/aqua/pkgs/${kubectl_asset}/kubectl"
  proxy="${target}/.platform/aqua/internal/pkgs/review/aqua-proxy"
  prepare_doctor_fixture "${target}"
  mkdir -p "${target}/.platform/bootstrap" "${target}/.platform/aqua/bin" \
    "${target}/.platform/aqua/registries" "${proxy%/*}" \
    "${kind_path%/*}" "${kubectl_path%/*}"
  cat >"${target}/.platform/bootstrap/aqua" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  ' version ') printf '%s\n' "${FIXTURE_AQUA_VERSION:?}" ;;
  *' list -i '*)
    printf 'kubernetes-sigs/kind\tv1.2.3\tstandard\n'
    printf 'kubernetes/kubectl\tv4.5.6\tstandard\n'
    ;;
  *' which kind '*)
    printf '%s%s\n' \
      "${AQUA_ROOT_DIR:?}/pkgs/github_release/github.com/example/kind/v1.2.3/" \
      'kind-linux-amd64/kind-linux-amd64'
    ;;
  *' which kubectl '*)
    printf '%s%s\n' "${AQUA_ROOT_DIR:?}/pkgs/http/example.invalid/v4.5.6/" \
      'linux/amd64/kubectl/kubectl'
    ;;
  *) exit 2 ;;
esac
FAKE
  cat >"${proxy}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${0##*/}" >>"${PROJECT_FIXTURE_PROXY_MARKER:?}"
case "${0##*/}" in
  kind) printf 'kind v1.2.3 go1.25.5 linux/amd64\n' ;;
  kubectl) printf '{\n  "gitVersion": "v4.5.6",\n  "platform": "linux/amd64"\n}\n' ;;
  *) exit 2 ;;
esac
FAKE
  printf '#!/usr/bin/env bash\nprintf "kind package\\n"\n' >"${kind_path}"
  printf '#!/usr/bin/env bash\nprintf "kubectl package\\n"\n' >"${kubectl_path}"
  chmod 0755 "${target}/.platform/bootstrap/aqua" "${proxy}" \
    "${kind_path}" "${kubectl_path}"
  ln -s internal/pkgs/review/aqua-proxy "${target}/.platform/aqua/aqua-proxy"
  ln -s ../aqua-proxy "${target}/.platform/aqua/bin/kind"
  ln -s ../aqua-proxy "${target}/.platform/aqua/bin/kubectl"
  pin_doctor_fixture_digest "${target}" AQUA_BIN_SHA256 \
    "${target}/.platform/bootstrap/aqua"
  pin_doctor_fixture_digest "${target}" AQUA_PROXY_BIN_SHA256 "${proxy}"
  write_ready_project_fixture_lock \
    "${target}" "${kind_asset}" "${kind_path}" \
    "${kubectl_asset}" "${kubectl_path}"
}

run_ready_project_fixture_doctor() {
  local target="$1" output="$2" proxy_marker="$3"
  env PATH="${target}/fake-bin:${PATH}" \
    FIXTURE_AQUA_VERSION="${AQUA_VERSION}" \
    DOCKER_FIXTURE_LOG="${target}/docker.log" \
    PROJECT_FIXTURE_PROXY_MARKER="${proxy_marker}" \
    EXTERNAL_MANAGED_MARKER="${target}/external.marker" \
    "${target}/tools/bootstrap/doctor.sh" --machine >"${output}" 2>&1
}

prove_ready_project_tamper_red() {
  local valid="${WORK_DIR}/project-valid" package="${WORK_DIR}/project-package"
  local proxy="${WORK_DIR}/project-proxy" output marker target
  prepare_ready_project_fixture "${valid}"
  marker="${valid}/proxy.marker"
  run_ready_project_fixture_doctor "${valid}" "${valid}/doctor.out" "${marker}"
  [[ "$(<"${marker}")" == $'kind\nkubectl' ]]
  prepare_ready_project_fixture "${package}"
  target="${package}/.platform/aqua/pkgs/github_release/github.com/"
  target+='example/kind/v1.2.3/kind-linux-amd64/kind-linux-amd64'
  printf '# tampered\n' >>"${target}"
  marker="${package}/proxy.marker"
  output="${package}/doctor.out"
  if run_ready_project_fixture_doctor "${package}" "${output}" "${marker}"; then
    printf 'FAIL  project-red   tampered package reached READY\n' >&2
    return 1
  fi
  grep -Fq 'installed kind bytes differ from checksum lock' "${output}"
  [[ ! -e "${marker}" ]]
  prepare_ready_project_fixture "${proxy}"
  target="${proxy}/.platform/aqua/internal/pkgs/review/aqua-proxy"
  printf '# tampered\n' >>"${target}"
  marker="${proxy}/proxy.marker"
  output="${proxy}/doctor.out"
  if run_ready_project_fixture_doctor "${proxy}" "${output}" "${marker}"; then
    printf 'FAIL  project-red   tampered proxy reached READY\n' >&2
    return 1
  fi
  grep -Fq 'managed kind proxy is absent or untrusted' "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  project-red   end-to-end package and proxy tampering rejected\n'
}

prove_doctor_non_destructive() {
  local target="${WORK_DIR}/doctor-repo"
  local output="${WORK_DIR}/doctor.out"
  local docker_log="${WORK_DIR}/doctor-docker.log"
  local managed_marker="${WORK_DIR}/external-managed.marker"
  prepare_doctor_fixture "${target}"
  if ! env PATH="${target}/fake-bin:${PATH}" \
    DOCKER_FIXTURE_LOG="${docker_log}" \
    EXTERNAL_MANAGED_MARKER="${managed_marker}" \
    "${target}/tools/bootstrap/doctor.sh" >"${output}" 2>&1; then
    sed -n '1,20p' "${output}" >&2
    return 1
  fi
  grep -Fq 'READY_FOR_BOOTSTRAP' "${output}"
  [[ ! -e "${target}/.platform" && ! -L "${target}/.platform" ]]
  [[ ! -e "${managed_marker}" ]]
  [[ "$(grep -Ec '^version --format ' "${docker_log}")" -eq 1 ]]
  [[ "$(grep -Ec '^build --help$' "${docker_log}")" -eq 1 ]]
  [[ "$(grep -Ec '^image (inspect|rm) --help$' "${docker_log}")" -eq 2 ]]
  if grep -Evq '^(version --format |build --help$|image (inspect|rm) --help$)' \
    "${docker_log}"; then
    printf 'FAIL  doctor-red    doctor attempted a mutating Docker command\n' >&2
    return 1
  fi
  printf 'PASS  doctor        no state, Docker, or cluster mutation attempted\n'
}

prove_inherited_tool_environment_isolated() {
  local directory="${WORK_DIR}/inherited-tool-environment"
  local git_target="${directory}/outside.git"
  local make_marker="${directory}/make.marker"
  local tar_marker="${directory}/tar.marker"
  local bash_marker="${directory}/bash.marker"
  local bash_environment="${directory}/inherited.bash"
  local makefile="${directory}/inherited.mk"
  local output="${directory}/doctor.out"
  mkdir -p "${directory}"
  # The make file-function expands only in the isolated Make process.
  # shellcheck disable=SC2016
  printf '$(file >%s,mutated)\n' "${make_marker}" >"${makefile}"
  printf 'printf "inherited\\n" >>%q\n' "${bash_marker}" >"${bash_environment}"
  env GIT_DIR="${git_target}" MAKEFILES="${makefile}" \
    TAR_OPTIONS="--index-file=${tar_marker}" \
    BASH_ENV="${bash_environment}" ENV="${bash_environment}" \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only \
    >"${output}" 2>&1 || {
    sed -n '1,12p' "${output}" >&2
    return 1
  }
  if [[ -e "${git_target}" || -L "${git_target}" ||
    -e "${make_marker}" || -L "${make_marker}" ||
    -e "${tar_marker}" || -L "${tar_marker}" ||
    -e "${bash_marker}" || -L "${bash_marker}" ]]; then
    printf 'FAIL  doctor-red    inherited tool environment escaped probe root\n' >&2
    return 1
  fi
  printf 'PASS  doctor-red    inherited Bash, Git, Make, and tar state is isolated\n'
}

prove_helper_false_green_red() {
  local target="${WORK_DIR}/doctor-repo"
  local output="${WORK_DIR}/doctor-helper.out"
  local docker_log="${WORK_DIR}/doctor-helper-docker.log"
  cat >"${target}/fake-bin/grep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod 0755 "${target}/fake-bin/grep"
  if env PATH="${target}/fake-bin:${PATH}" \
    DOCKER_FIXTURE_LOG="${docker_log}" DOCKER_FIXTURE_MODE=zero-help \
    "${target}/tools/bootstrap/doctor.sh" >"${output}" 2>&1; then
    printf 'FAIL  doctor-red    fake helper accepted empty Docker evidence\n' >&2
    return 1
  fi
  grep -Fq 'bounded text utility semantics are unavailable' "${output}"
  rm -- "${target}/fake-bin/grep"
  printf 'PASS  doctor-red    fake helper cannot forge Docker capability\n'
}

prove_shadowed_host_command_red() {
  local marker="${WORK_DIR}/shadowed-tar.marker"
  local output="${WORK_DIR}/shadowed-tar.out"
  # The child expands only the two explicitly passed fixture variables.
  # shellcheck disable=SC2016
  if env SHADOWED_COMMAND_MARKER="${marker}" \
    DOCTOR_PATH="${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" \
    bash -c '
tar() { printf "executed\n" >"${SHADOWED_COMMAND_MARKER}"; }
type() { printf "file\n"; }
export -f tar
export -f type
exec "${DOCTOR_PATH}" --base-only
' >"${output}" 2>&1; then
    printf 'FAIL  doctor-red    inherited tar function was accepted\n' >&2
    return 1
  fi
  grep -Fq 'tar is shadowed by shell function' "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  doctor-red    inherited host-command function rejected before use\n'
}

prove_stateful_mktemp_cannot_select_cleanup_target() {
  local target="${WORK_DIR}/doctor-stateful" victim="${WORK_DIR}/later-victim"
  local counter="${WORK_DIR}/mktemp.counter" output="${WORK_DIR}/mktemp.out"
  local fake="${target}/fake-bin/mktemp"
  prepare_doctor_fixture "${target}"
  mkdir -p "${victim}"
  printf 'preserve\n' >"${victim}/sentinel"
  cat >"${fake}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "${STATEFUL_MKTEMP_COUNTER:?}" ]] || count="$(<"${STATEFUL_MKTEMP_COUNTER}")"
((count += 1))
printf '%s\n' "${count}" >"${STATEFUL_MKTEMP_COUNTER}"
if ((count >= 3)); then
  printf '%s\n' "${STATEFUL_MKTEMP_VICTIM:?}"
  exit 0
fi
exec "${REAL_MKTEMP:?}" "$@"
FAKE
  chmod 0755 "${fake}"
  env PATH="${target}/fake-bin:${PATH}" \
    STATEFUL_MKTEMP_COUNTER="${counter}" STATEFUL_MKTEMP_VICTIM="${victim}" \
    REAL_MKTEMP="$(builtin type -P mktemp)" \
    "${target}/tools/bootstrap/doctor.sh" --base-only >"${output}" 2>&1
  [[ "$(<"${counter}")" == 2 && "$(<"${victim}/sentinel")" == preserve ]]
  printf 'PASS  doctor-red    later mktemp output cannot select cleanup target\n'
}

prove_project_state_red() {
  local target="${WORK_DIR}/doctor-repo"
  local output="${WORK_DIR}/doctor-partial.out"
  local docker_log="${WORK_DIR}/doctor-partial-docker.log"
  local managed_marker="${WORK_DIR}/external-managed.marker"
  if env PATH="${target}/fake-bin:${PATH}" \
    DOCKER_FIXTURE_LOG="${docker_log}" \
    EXTERNAL_MANAGED_MARKER="${managed_marker}" \
    "${target}/tools/bootstrap/doctor.sh" --machine >"${output}" 2>&1; then
    printf 'FAIL  project-red   absent toolchain produced machine evidence\n' >&2
    return 1
  fi
  grep -Fq 'machine evidence requires make bootstrap first' "${output}"
  mkdir -p "${target}/.platform/aqua"
  if env PATH="${target}/fake-bin:${PATH}" \
    DOCKER_FIXTURE_LOG="${docker_log}" \
    EXTERNAL_MANAGED_MARKER="${managed_marker}" \
    "${target}/tools/bootstrap/doctor.sh" >"${output}" 2>&1; then
    printf 'FAIL  project-red   partial toolchain unexpectedly passed\n' >&2
    return 1
  fi
  grep -Fq 'Aqua state is partial or untrusted' "${output}"
  [[ ! -e "${managed_marker}" ]]
  printf 'PASS  project-red   absent/partial state rejects external PATH tools\n'
}

project_tool_state_snapshot() {
  local find_path sort_path sha256sum_path
  find_path="$(builtin type -P find)"
  sort_path="$(builtin type -P sort)"
  sha256sum_path="$(builtin type -P sha256sum)"
  (
    cd "${PLATFORM_ROOT}" || exit
    "${find_path}" .platform/aqua .platform/bootstrap/aqua -xdev \
      -printf '%p|%y|%m|%s|%T@|%C@|%l\n'
  ) | "${sort_path}" | "${sha256sum_path}" --
}

prove_ready_toolchain_non_destructive() {
  local directory="${WORK_DIR}/ready-toolchain" marker evidence before after
  local docker_log
  local line first="" last="" count=0 command_name
  marker="${directory}/external.marker"
  evidence="${directory}/machine.env"
  docker_log="${directory}/docker.log"
  mkdir -p "${directory}/bin"
  cat >"${directory}/bin/external" <<'FAKE'
#!/usr/bin/env bash
printf 'executed:%s\n' "${0##*/}" >>"${EXTERNAL_MANAGED_MARKER:?}"
exit 0
FAKE
  chmod 0755 "${directory}/bin/external"
  write_fake_docker "${directory}/bin/docker"
  for command_name in aqua kind kubectl; do
    ln -s external "${directory}/bin/${command_name}"
  done
  before="$(project_tool_state_snapshot)"
  if ! env PATH="${directory}/bin:${PATH}" \
    EXTERNAL_MANAGED_MARKER="${marker}" \
    DOCKER_FIXTURE_LOG="${docker_log}" \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --machine >"${evidence}"; then
    printf 'FAIL  project-red   ready toolchain observation failed\n' >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${first}" ]] || first="${line}"
    last="${line}"
    ((count += 1))
  done <"${evidence}"
  after="$(project_tool_state_snapshot)"
  [[ "${first}" == "SCHEMA=${ENVIRONMENT_PROFILE_SCHEMA}" ]]
  [[ "${last}" =~ ^KUBECTL_IDENTITY=v[0-9]+\.[0-9]+\.[0-9]+$ &&
    "${count}" -eq "${ENVIRONMENT_PROFILE_EVIDENCE_RECORD_COUNT}" ]]
  [[ ! -e "${marker}" && "${before}" == "${after}" ]]
  [[ "$(grep -Ec '^version --format ' "${docker_log}")" -eq 1 ]]
  [[ "$(grep -Ec '^build --help$' "${docker_log}")" -eq 1 ]]
  [[ "$(grep -Ec '^image (inspect|rm) --help$' "${docker_log}")" -eq 2 ]]
  printf 'PASS  project       ready toolchain is explicit-path and non-mutating\n'
}

render_valid_evidence() {
  local target="$1"
  ENVIRONMENT_PROFILE_OS=linux
  ENVIRONMENT_PROFILE_ARCHITECTURE=amd64
  ENVIRONMENT_PROFILE_BASH_VERSION=5.2.21
  ENVIRONMENT_PROFILE_CURL_VERSION=8.5.0
  ENVIRONMENT_PROFILE_TAR_VERSION=1.35
  ENVIRONMENT_PROFILE_TIMEOUT_VERSION=9.4
  ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION=29.7.2
  ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION=29.7.2
  ENVIRONMENT_PROFILE_DOCKER_CLIENT_API=1.55
  ENVIRONMENT_PROFILE_DOCKER_SERVER_API=1.55
  ENVIRONMENT_PROFILE_PROJECT_STATE=ready
  ENVIRONMENT_PROFILE_AQUA_IDENTITY="${AQUA_VERSION}"
  ENVIRONMENT_PROFILE_KIND_IDENTITY=v1.2.3
  ENVIRONMENT_PROFILE_KUBECTL_IDENTITY=v4.5.6
  export ENVIRONMENT_PROFILE_OS ENVIRONMENT_PROFILE_ARCHITECTURE
  export ENVIRONMENT_PROFILE_BASH_VERSION ENVIRONMENT_PROFILE_TAR_VERSION
  export ENVIRONMENT_PROFILE_CURL_VERSION
  export ENVIRONMENT_PROFILE_TIMEOUT_VERSION
  export ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION
  export ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION
  export ENVIRONMENT_PROFILE_DOCKER_CLIENT_API
  export ENVIRONMENT_PROFILE_DOCKER_SERVER_API
  export ENVIRONMENT_PROFILE_PROJECT_STATE ENVIRONMENT_PROFILE_AQUA_IDENTITY
  export ENVIRONMENT_PROFILE_KIND_IDENTITY ENVIRONMENT_PROFILE_KUBECTL_IDENTITY
  environment_profile_render_evidence >"${target}"
  environment_profile_validate_evidence "${target}"
}

prove_evidence_red() {
  local directory="${WORK_DIR}/evidence"
  local valid="${directory}/valid.env"
  local supported_home='/ho''me/review-user'
  mkdir -p "${directory}"
  render_valid_evidence "${valid}"
  head -n -1 "${valid}" >"${directory}/missing.env"
  expect_invalid_evidence missing "${directory}/missing.env"
  {
    cat "${valid}"
    printf 'EXTRA=value\n'
  } >"${directory}/extra.env"
  expect_invalid_evidence extra "${directory}/extra.env"
  awk 'NR == 2 { print } { print }' "${valid}" >"${directory}/duplicate.env"
  expect_invalid_evidence duplicate "${directory}/duplicate.env"
  sed $'s/^AQUA_IDENTITY=.*/AQUA_IDENTITY=bad\tvalue/' "${valid}" \
    >"${directory}/control.env"
  expect_invalid_evidence control "${directory}/control.env"
  cp "${valid}" "${directory}/nul.env"
  printf '\0' >>"${directory}/nul.env"
  expect_invalid_evidence nul "${directory}/nul.env"
  head -c "$((ENVIRONMENT_PROFILE_MAX_EVIDENCE_BYTES + 1))" /dev/zero |
    tr '\0' x >"${directory}/oversize.env"
  expect_invalid_evidence oversize "${directory}/oversize.env"
  sed "s#^AQUA_IDENTITY=.*#AQUA_IDENTITY=${supported_home}#" "${valid}" \
    >"${directory}/path.env"
  expect_invalid_evidence path "${directory}/path.env"
  sed 's/^AQUA_IDENTITY=.*/AQUA_IDENTITY=review-user/' "${valid}" \
    >"${directory}/identity.env"
  expect_invalid_evidence identity "${directory}/identity.env"
  sed 's/^DOCKER_CLIENT_VERSION=.*/DOCKER_CLIENT_VERSION=review-user/' \
    "${valid}" >"${directory}/docker-version.env"
  expect_invalid_evidence docker-version "${directory}/docker-version.env"
  sed 's/^DOCKER_CLIENT_VERSION=.*/DOCKER_CLIENT_VERSION=29.7.2-review-user/' \
    "${valid}" >"${directory}/docker-version-suffix.env"
  expect_invalid_evidence docker-version-suffix \
    "${directory}/docker-version-suffix.env"
  sed 's/^DOCKER_SERVER_API=.*/DOCKER_SERVER_API=credentialToken123/' \
    "${valid}" >"${directory}/docker-api.env"
  expect_invalid_evidence docker-api "${directory}/docker-api.env"
  sed 's/^BASH_CAPABILITY=.*/BASH_CAPABILITY=version_only/' "${valid}" \
    >"${directory}/weakened.env"
  expect_invalid_evidence weakened "${directory}/weakened.env"
  sed 's/^KIND_IDENTITY=.*/KIND_IDENTITY=v9.9.9/' "${valid}" \
    >"${directory}/wrong-kind.env"
  expect_invalid_evidence wrong-kind "${directory}/wrong-kind.env"
  ln -s valid.env "${directory}/symlink.env"
  expect_invalid_evidence symlink "${directory}/symlink.env"
  printf 'PASS  evidence      schema, order, bounds, and path safety proved\n'
}

main() {
  local mkdir_path rm_path
  mkdir_path="$(builtin type -P mkdir)"
  rm_path="$(builtin type -P rm)"
  environment_profile_create_owned_workspace proof "${mkdir_path}"
  WORK_DIR="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  WORK_TOKEN="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  WORK_RM_PATH="${rm_path}"
  trap cleanup_proof_workspace EXIT
  prove_fake_zero_rejected
  prove_curl_surface_red
  prove_core_utility_red
  prove_host_utility_pipeline_red
  prove_tar_and_timeout_red
  prove_proc_red
  prove_docker_identity_red
  prove_docker_help_red
  prove_buildkit_parser_helper_red
  prove_project_identity_red
  prove_project_package_checksum_red
  prove_project_proxy_red
  prove_ready_project_tamper_red
  prove_doctor_non_destructive
  prove_inherited_tool_environment_isolated
  prove_helper_false_green_red
  prove_shadowed_host_command_red
  prove_stateful_mktemp_cannot_select_cleanup_target
  prove_project_state_red
  prove_ready_toolchain_non_destructive
  prove_evidence_red
  printf 'PASS  environment   capability profile adversarial proof complete\n'
  environment_profile_remove_owned_workspace \
    "${WORK_DIR}" "${WORK_TOKEN}" "${WORK_RM_PATH}"
  trap - EXIT
  WORK_DIR=""
  WORK_TOKEN=""
  WORK_RM_PATH=""
}

main "$@"
