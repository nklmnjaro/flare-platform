#!/bin/bash -p
set -euo pipefail

PROVE_MANAGED_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_MANAGED_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_MANAGED_SOURCE_DIR=.
builtin source "${PROVE_MANAGED_SOURCE_DIR}/env.sh"
unset PROVE_MANAGED_SOURCE_DIR

WORK_DIR=""

prepare_fixture() {
  local target="$1"
  local path
  run_host_command mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/kubernetes" "${target}/tools/quality" "${target}/fake-bin"
  run_host_command cp "${PLATFORM_ROOT}/Makefile" "${target}/Makefile"
  for path in aqua-trust.sh doctor.sh environment-profile.sh install-hooks.sh; do
    run_host_command cp "${PLATFORM_ROOT}/tools/bootstrap/${path}" \
      "${target}/tools/bootstrap/${path}"
  done
  run_host_command cp "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  run_host_command cp "${PLATFORM_ROOT}/aqua-checksums.json" \
    "${target}/aqua-checksums.json"
  for path in docker-target.sh env.sh host-commands.sh process-state.sh state.sh \
    tooling.sh run-managed-tool.sh; do
    run_host_command cp "${PLATFORM_ROOT}/tools/common/${path}" \
      "${target}/tools/common/${path}"
  done
  run_host_command cp "${target}/tools/common/docker-target.sh" \
    "${target}/tools/common/docker-target-production.sh"
  run_host_command cp \
    "${PLATFORM_ROOT}/tools/kubernetes/docker-target-fixture.sh" \
    "${target}/tools/common/docker-target.sh"
  for path in buildkit-result.sh runtime.sh verify.sh; do
    run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/${path}" \
      "${target}/tools/kubernetes/${path}"
  done
  for path in check-commit-message.sh check-fast.sh check.sh prove-gates.sh \
    repo-policy.sh; do
    run_host_command cp "${PLATFORM_ROOT}/tools/quality/${path}" \
      "${target}/tools/quality/${path}"
  done
  for path in aqua go gofmt kind kubectl shellcheck shfmt actionlint zizmor \
    hadolint trivy kubeconform kube-linter prek; do
    run_host_command cat >"${target}/fake-bin/${path}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
printf '%s\n' "${0##*/}" >>"${FAKE_TOOL_MARKER:?}"
exit 0
FAKE
    run_host_command chmod 0755 "${target}/fake-bin/${path}"
  done
  run_host_command cat >"${target}/fake-bin/docker" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
case "${1:-}" in
  version) printf '29.7.2|29.7.2|1.55|1.55|linux|amd64\n' ;;
  build)
    printf '%s\n' 'docker buildx build [OPTIONS] PATH | URL | -' \
      '--builder string' '--network string' '--pull' '--no-cache' \
      '--progress string plain'
    ;;
  image)
    case "${2:-}" in
      inspect) printf '%s\n' 'docker image inspect [OPTIONS]' '--format string' ;;
      rm) printf '%s\n' 'docker image rm [OPTIONS]' ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
FAKE
  run_host_command chmod 0755 "${target}/fake-bin/docker"
  run_host_command mkdir -p "${target}/.platform-test/docker-target"
  printf 'prove-managed-token-001\n' \
    >"${target}/.platform-test/docker-target/.docker-target-owner"
  run_host_command cp "${target}/fake-bin/docker" \
    "${target}/.platform-test/docker-target/docker"
  run_host_command chmod 0755 \
    "${target}/.platform-test/docker-target/docker"
}

expect_untrusted_rejection() {
  local target="$1" label="$2"
  local marker="${target}/FAKE_TOOLS_EXECUTED"
  local output="${target}/${label}.log"
  local status=0
  shift 2
  run_host_command rm -f -- "${marker}"
  if run_host_command env PATH="${target}/fake-bin:${PATH}" \
    FAKE_TOOL_MARKER="${marker}" \
    PLATFORM_DOCKER_TEST_CONTRACT=flare-platform-docker-target-fixture-v1 \
    PLATFORM_DOCKER_TEST_ROOT="${target}/.platform-test/docker-target" \
    PLATFORM_DOCKER_TEST_TOKEN=prove-managed-token-001 \
    "$@" >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if ((status == 0)); then
    printf 'FAIL  tooling-red   %s accepted an external managed tool\n' "${label}" >&2
    return 1
  fi
  if [[ -e "${marker}" || -L "${marker}" ]]; then
    printf 'FAIL  tooling-red   %s executed an external managed tool\n' "${label}" >&2
    return 1
  fi
  if ! run_host_command grep -Fq \
    'project-managed toolchain unavailable or untrusted:' "${output}"; then
    run_host_command sed -n '1,30p' "${output}" >&2
    printf 'FAIL  tooling-red   %s missed the exact toolchain reason\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  tooling-red   %s rejected external managed tools\n' "${label}"
}

pin_fixture_proxy() {
  local target="$1" proxy="$2" module temporary digest
  module="${target}/tools/bootstrap/aqua-trust.sh"
  temporary="${module}.new"
  digest="$(run_host_command sha256sum -- "${proxy}")"
  digest="${digest%% *}"
  run_host_command sed -E \
    "s/^(builtin readonly AQUA_PROXY_BIN_SHA256=\")[0-9a-f]{64}(\")$/\\1${digest}\\2/" \
    "${module}" >"${temporary}"
  run_host_command grep -Fqx \
    "builtin readonly AQUA_PROXY_BIN_SHA256=\"${digest}\"" "${temporary}"
  run_host_command mv -fT -- "${temporary}" "${module}"
}

pin_fixture_aqua() {
  local target="$1" aqua="$2" module temporary digest
  module="${target}/tools/bootstrap/aqua-trust.sh"
  temporary="${module}.new"
  digest="$(run_host_command sha256sum -- "${aqua}")"
  digest="${digest%% *}"
  run_host_command sed -E \
    "s/^(builtin readonly AQUA_BIN_SHA256=\")[0-9a-f]{64}(\")$/\\1${digest}\\2/" \
    "${module}" >"${temporary}"
  run_host_command grep -Fqx \
    "builtin readonly AQUA_BIN_SHA256=\"${digest}\"" "${temporary}"
  run_host_command mv -fT -- "${temporary}" "${module}"
}

write_fixture_aqua() {
  local target="$1"
  run_host_command cat >"${target}" <<'AQUA'
#!/bin/bash -p
set -euo pipefail
case "${1:-}" in
  version) printf '2.62.3\n' ;;
  exec)
    shift
    [[ "${1:-}" == -- ]]
    shift
    command_name="${1:?}"
    shift
    exec "${AQUA_ROOT_DIR:?}/bin/${command_name}" "$@"
    ;;
  *) exit 2 ;;
esac
AQUA
  run_host_command chmod 0755 -- "${target}"
}

prove_each_managed_tool() {
  local target="$1" tool
  for tool in go gofmt kind kubectl shellcheck shfmt actionlint zizmor \
    hadolint trivy kubeconform kube-linter prek; do
    expect_untrusted_rejection "${target}" "tool-${tool}" \
      "${target}/tools/common/run-managed-tool.sh" "${tool}" --version
  done
}

prove_canonical_consumers() {
  local target="$1" capability make_path
  make_path="$(host_command_path make)" || return
  for capability in check-fast check prove-gates verify-runtime hooks; do
    expect_untrusted_rejection "${target}" "make-${capability}" \
      "${make_path}" --no-print-directory -C "${target}" "${capability}"
  done
}

prove_inherited_functions_cannot_bypass() {
  local target="$1"
  local marker="${target}/INHERITED_FUNCTION_EXECUTED"
  local output="${target}/inherited-functions.log"
  local status=0
  run_host_command rm -f -- "${marker}"
  (
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2317,SC2329
    run_managed_tool() {
      printf 'run_managed_tool\n' >>"${BYPASS_MARKER:?}"
      return 0
    }
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2317,SC2329
    require_tool() {
      printf 'require_tool\n' >>"${BYPASS_MARKER:?}"
      return 0
    }
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2317,SC2329
    verify_existing_aqua() {
      printf 'verify_existing_aqua\n' >>"${BYPASS_MARKER:?}"
      return 0
    }
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2317,SC2329
    verify_existing_aqua_proxy() {
      printf 'verify_existing_aqua_proxy\n' >>"${BYPASS_MARKER:?}"
      return 0
    }
    export -f run_managed_tool require_tool verify_existing_aqua
    export -f verify_existing_aqua_proxy
    BYPASS_MARKER="${marker}" PATH="${target}/fake-bin:${PATH}" \
      FAKE_TOOL_MARKER="${marker}" \
      "${target}/tools/common/run-managed-tool.sh" go version
  ) >"${output}" 2>&1 || status=$?
  if ((status == 0)); then
    printf 'FAIL  tooling-red   inherited functions bypassed canonical tooling\n' >&2
    return 1
  fi
  if [[ -e "${marker}" || -L "${marker}" ]]; then
    printf 'FAIL  tooling-red   an inherited function or PATH tool executed\n' >&2
    return 1
  fi
  run_host_command grep -Fq \
    'project-managed toolchain unavailable or untrusted:' "${output}"
  printf 'PASS  tooling-red   inherited shell functions cannot bypass tooling\n'
}

prove_preboundary_environment_is_ignored() {
  local target="$1" state_bin marker startup message output command_name make_path
  state_bin="${target}/.platform/bootstrap"
  marker="${target}/PREBOUNDARY_EXECUTED"
  startup="${target}/hostile-bash-env.sh"
  message="${target}/valid-message.txt"
  output="${target}/preboundary.out"
  run_host_command mkdir -p "${state_bin}"
  run_host_command cat >"${startup}" <<'HOSTILE'
printf 'startup\n' >>"${PREBOUNDARY_MARKER:?}"
HOSTILE
  for command_name in bash dirname; do
    run_host_command cat >"${state_bin}/${command_name}" <<'HOSTILE'
#!/bin/bash -p
printf '%s\n' "${0##*/}" >>"${PREBOUNDARY_MARKER:?}"
exit 0
HOSTILE
    run_host_command chmod 0755 "${state_bin}/${command_name}"
  done
  printf 'fix: accept trusted entrypoint\n' >"${message}"
  run_host_command env PATH="${state_bin}:${PATH}" BASH_ENV="${startup}" \
    ENV="${startup}" PREBOUNDARY_MARKER="${marker}" \
    "${target}/tools/quality/check-commit-message.sh" "${message}"
  make_path="$(host_command_path make)" || return
  run_host_command env PATH="${state_bin}:${PATH}" BASH_ENV="${startup}" \
    ENV="${startup}" PREBOUNDARY_MARKER="${marker}" \
    "${make_path}" --no-print-directory -C "${target}" \
    "SHELL=${state_bin}/bash" '.SHELLFLAGS=-c' help \
    >"${output}"
  run_host_command grep -Fqx 'doctor         inspect host prerequisites' \
    "${output}"
  if [[ -e "${marker}" || -L "${marker}" ]]; then
    printf 'FAIL  tooling-red   pre-boundary Bash or PATH state executed\n' >&2
    return 1
  fi
  printf 'PASS  tooling-red   hostile Bash startup and project PATH ignored\n'
}

write_canonical_fixture_proxy() {
  local target="$1" proxy
  proxy="${target}/.platform/aqua/internal/pkgs/test/aqua-proxy"
  run_host_command cat >"${proxy}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
[[ "${AQUA_ROOT_DIR:?}" == "${FIXTURE_EXPECTED_AQUA_ROOT:?}" ]]
[[ "${AQUA_CONFIG:?}" == "${FIXTURE_EXPECTED_AQUA_CONFIG:?}" ]]
[[ "${AQUA_DISABLE_LAZY_INSTALL:?}" == true ]]
[[ "${PATH:?}" == "${PLATFORM_HOST_PATH:?}" ]]
for kind_control in KIND_EXPERIMENTAL_PROVIDER \
  KIND_EXPERIMENTAL_DOCKER_NETWORK KIND_EXPERIMENTAL_PODMAN_NETWORK \
  KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER KIND_CLUSTER_NAME \
  KIND_DNS_SEARCH; do
  [[ ! -v "${kind_control}" ]]
done
for variable in AQUA_GLOBAL_CONFIG AQUA_POLICY_CONFIG AQUA_DISABLE_POLICY \
  AQUA_DISABLE_COSIGN AQUA_DISABLE_SLSA \
  AQUA_DISABLE_GITHUB_ARTIFACT_ATTESTATION \
  AQUA_X_SYS_EXEC AQUA_EXPERIMENTAL_X_SYS_EXEC; do
  [[ ! -v "${variable}" ]]
done
case "${0##*/}" in
  go) printf 'canonical-aqua-proxy\n' ;;
  prek)
    [[ "${1:-}" == install ]]
    shift
    git_dir=""
    while (($# > 0)); do
      case "$1" in
        --git-dir) git_dir="${2:?}"; shift 2 ;;
        --hook-type) shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [[ -n "${git_dir}" && -d "${git_dir}/hooks" ]]
    for hook_type in pre-commit commit-msg; do
      {
        printf '#!/bin/bash -p\n'
        printf '# File generated by prek: https://github.com/j178/prek\n'
        printf 'exec prek hook-impl --script-version 4 --hook-type=%s -- "$@"\n' \
          "${hook_type}"
      } >"${git_dir}/hooks/${hook_type}"
    done
    ;;
  *) exit 2 ;;
esac
FAKE
  run_host_command chmod 0755 -- "${proxy}"
}

prove_project_state_boundary() {
  local target="$1"
  local marker="${target}/FAKE_TOOLS_EXECUTED"
  local output="${target}/project-state.log"
  run_host_command mkdir -p \
    "${target}/.platform/bootstrap" "${target}/.platform/aqua/bin" \
    "${target}/.platform/aqua/test-fixtures" \
    "${target}/.platform/aqua/internal/pkgs/test"
  write_fixture_aqua "${target}/.platform/bootstrap/aqua"
  pin_fixture_aqua "${target}" "${target}/.platform/bootstrap/aqua"
  run_host_command ln -s "${target}/fake-bin/go" \
    "${target}/.platform/aqua/bin/go"
  expect_untrusted_rejection "${target}" escaped-project-proxy \
    "${target}/tools/common/run-managed-tool.sh" go version

  run_host_command rm -f -- "${target}/.platform/aqua/bin/go"
  run_host_command cat >"${target}/.platform/aqua/test-fixtures/go" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
printf 'project-fixture-go\n'
FAKE
  run_host_command chmod 0755 "${target}/.platform/aqua/test-fixtures/go"
  run_host_command ln -s ../test-fixtures/go "${target}/.platform/aqua/bin/go"
  expect_untrusted_rejection "${target}" project-test-fixture-without-adapter \
    "${target}/tools/common/run-managed-tool.sh" go version

  run_host_command rm -f -- "${target}/.platform/aqua/bin/go"
  write_canonical_fixture_proxy "${target}"
  pin_fixture_proxy \
    "${target}" "${target}/.platform/aqua/internal/pkgs/test/aqua-proxy"
  run_host_command ln -s internal/pkgs/test/aqua-proxy \
    "${target}/.platform/aqua/aqua-proxy"
  run_host_command ln -s ../aqua-proxy "${target}/.platform/aqua/bin/go"
  run_host_command ln -s ../aqua-proxy "${target}/.platform/aqua/bin/prek"
  run_host_command rm -f -- "${marker}"
  run_host_command env PATH="${target}/fake-bin:${PATH}" \
    FAKE_TOOL_MARKER="${marker}" \
    FIXTURE_EXPECTED_AQUA_ROOT="${target}/.platform/aqua" \
    FIXTURE_EXPECTED_AQUA_CONFIG="${target}/aqua.yaml" \
    AQUA_DISABLE_LAZY_INSTALL=false AQUA_GLOBAL_CONFIG=outside-global \
    AQUA_POLICY_CONFIG=outside-policy AQUA_DISABLE_POLICY=true \
    AQUA_DISABLE_COSIGN=true AQUA_DISABLE_SLSA=true \
    AQUA_DISABLE_GITHUB_ARTIFACT_ATTESTATION=true AQUA_X_SYS_EXEC=true \
    AQUA_EXPERIMENTAL_X_SYS_EXEC=true KIND_EXPERIMENTAL_PROVIDER=podman \
    KIND_EXPERIMENTAL_DOCKER_NETWORK=hostile-docker \
    KIND_EXPERIMENTAL_PODMAN_NETWORK=hostile-podman \
    KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER=true \
    KIND_CLUSTER_NAME=hostile-cluster KIND_DNS_SEARCH=hostile.invalid \
    "${target}/tools/common/run-managed-tool.sh" go version >"${output}" 2>&1
  run_host_command grep -Fqx canonical-aqua-proxy "${output}"
  if [[ -e "${marker}" || -L "${marker}" ]]; then
    printf 'FAIL  tooling-red   external PATH preempted project fixture\n' >&2
    return 1
  fi
  printf 'PASS  tooling       canonical Aqua proxy shape admitted\n'
  prove_replaced_proxy_rejected_same_shell "${target}"
  prove_tampered_proxy_rejection "${target}"
}

prove_replaced_proxy_rejected_same_shell() {
  local target="$1" replacement marker output bash_path proxy backup
  replacement="${target}/replacement-proxy"
  marker="${target}/REPLACED_PROXY_EXECUTED"
  output="${target}/replaced-proxy.log"
  proxy="${target}/.platform/aqua/internal/pkgs/test/aqua-proxy"
  backup="${target}/canonical-proxy.before"
  bash_path="$(host_command_path bash)" || return
  run_host_command cp -pT -- "${proxy}" "${backup}"
  run_host_command cat >"${replacement}" <<'REPLACED_PROXY'
#!/bin/bash -p
builtin printf 'executed\n' >"${PLATFORM_REPLACED_PROXY_MARKER:?}"
REPLACED_PROXY
  run_host_command chmod 0755 -- "${replacement}"
  # The single-quoted program intentionally expands only in the child Bash.
  # shellcheck disable=SC2016
  run_host_command env \
    FIXTURE_EXPECTED_AQUA_ROOT="${target}/.platform/aqua" \
    FIXTURE_EXPECTED_AQUA_CONFIG="${target}/aqua.yaml" \
    PLATFORM_REPLACED_PROXY_MARKER="${marker}" \
    "${bash_path}" -p -c '
target=$1
replacement=$2
builtin cd -P -- "${target}"
builtin source tools/common/env.sh
builtin source tools/common/tooling.sh
run_managed_tool go version
run_host_command cp -fT -- "${replacement}" \
  "${target}/.platform/aqua/internal/pkgs/test/aqua-proxy"
second_status=0
run_managed_tool go version || second_status=$?
[[ "${second_status}" -eq 1 ]]
' proxy-revalidation "${target}" "${replacement}" >"${output}" 2>&1
  run_host_command grep -Fqx canonical-aqua-proxy "${output}"
  run_host_command grep -Fq \
    'project-managed toolchain unavailable or untrusted: go' "${output}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  run_host_command cp -pT -- "${backup}" "${proxy}"
  run_host_command rm -f -- "${backup}"
  builtin printf \
    'PASS  tooling-red   Aqua proxy is revalidated before every execution\n'
}

prove_tampered_proxy_rejection() {
  local target="$1" proxy_expected proxy backup
  proxy="${target}/.platform/aqua/internal/pkgs/test/aqua-proxy"
  backup="${target}/canonical-proxy.before"
  proxy_expected="$(run_host_command sed -n \
    's/^builtin readonly AQUA_PROXY_BIN_SHA256="\([0-9a-f]\{64\}\)"$/\1/p' \
    "${target}/tools/bootstrap/aqua-trust.sh")"
  [[ "${proxy_expected}" =~ ^[0-9a-f]{64}$ ]]
  run_host_command cp -pT -- "${proxy}" "${backup}"
  run_host_command cat >"${target}/.platform/bootstrap/sha256sum" <<FAKE
#!/bin/bash -p
printf 'sha256sum\n' >>"\${FAKE_TOOL_MARKER:?}"
printf '${proxy_expected}  %s\n' "\${2:-fixture}"
FAKE
  run_host_command chmod 0755 "${target}/.platform/bootstrap/sha256sum"
  printf '#!/bin/bash -p\nprintf "forged-proxy\\n"\n' \
    >"${target}/.platform/aqua/internal/pkgs/test/aqua-proxy"
  run_host_command chmod 0755 \
    "${target}/.platform/aqua/internal/pkgs/test/aqua-proxy"
  expect_untrusted_rejection "${target}" tampered-project-proxy \
    "${target}/tools/common/run-managed-tool.sh" go version
  run_host_command cp -pT -- "${backup}" "${proxy}"
  run_host_command rm -f -- "${backup}"
  printf 'PASS  tooling-red   tampered proxy rejected by host-rooted digest\n'
}

stage_repository() {
  local target="$1"
  run_host_command mkdir -p -- "${target}"
  (
    builtin cd -P -- "${PLATFORM_ROOT}"
    run_host_command git ls-files -z --cached --others --exclude-standard |
      run_host_command tar --null --verbatim-files-from --files-from=- \
        --create --file=-
  ) | run_host_command tar --extract --file=- --directory="${target}"
  [[ ! -e "${target}/.platform" && ! -L "${target}/.platform" ]]
}

prove_git_attestation_environment_is_sanitized() {
  local fixture="${WORK_DIR}/git-attestation" repo helper marker output git_path
  repo="${fixture}/repo"
  helper="${fixture}/fsmonitor-helper"
  marker="${fixture}/fsmonitor.marker"
  output="${fixture}/policy.out"
  run_host_command mkdir -p -- "${fixture}"
  stage_repository "${repo}"
  run_host_command git -C "${repo}" init --quiet
  run_host_command cat >"${helper}" <<'HELPER'
#!/bin/bash -p
builtin printf 'executed\n' >"${GIT_ATTESTATION_MARKER:?}"
exit 0
HELPER
  run_host_command chmod 0755 -- "${helper}"
  run_host_command env \
    GIT_CONFIG_PARAMETERS="'core.fsmonitor=${helper}'" \
    GIT_ATTESTATION_MARKER="${marker}" \
    "${repo}/tools/quality/repo-policy.sh" >"${output}" 2>&1
  run_host_command grep -Fqx \
    'PASS  policy        repository invariants' "${output}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]

  git_path="$(host_command_path git)" || return
  run_host_command git -C "${repo}" add README.md
  run_host_command git -C "${repo}" config core.fsmonitor "${helper}"
  run_host_command env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 \
    -u GIT_CONFIG_VALUE_0 GIT_ATTESTATION_MARKER="${marker}" \
    "${git_path}" -C "${repo}" status --porcelain >/dev/null 2>&1
  [[ -f "${marker}" && ! -L "${marker}" ]]
  run_host_command rm -f -- "${marker}"
  GIT_ATTESTATION_MARKER="${marker}" \
    run_host_command git -C "${repo}" status --porcelain >/dev/null
  [[ ! -e "${marker}" && ! -L "${marker}" ]]

  printf '\n' >>"${repo}/README.md"
  run_host_command git -C "${repo}" config diff.external "${helper}"
  run_host_command env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 \
    -u GIT_CONFIG_VALUE_0 GIT_ATTESTATION_MARKER="${marker}" \
    "${git_path}" -C "${repo}" diff --ext-diff -- README.md \
    >/dev/null 2>&1
  [[ -f "${marker}" && ! -L "${marker}" ]]
  run_host_command rm -f -- "${marker}"
  GIT_ATTESTATION_MARKER="${marker}" \
    "${repo}/tools/quality/repo-policy.sh" >"${output}" 2>&1
  run_host_command grep -Fqx \
    'PASS  policy        repository invariants' "${output}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  printf 'PASS  git-red       inherited and local Git helpers cannot redirect attestation\n'
}

assert_no_hook_temporaries() {
  local repo="$1" extra_directory="${2:-}" found
  found="$(run_host_command find "${repo}/.git/hooks" -maxdepth 1 \
    \( -name '*.managed.*' -o -name '*.restore.*' \) -print -quit)"
  [[ -z "${found}" ]]
  found="$(run_host_command find "${repo}/.platform" -maxdepth 1 \
    -name '.hooks-install.*' -print -quit)"
  [[ -z "${found}" ]]
  if [[ -n "${extra_directory}" ]]; then
    found="$(run_host_command find "${extra_directory}" -maxdepth 1 \
      \( -name '*.managed.*' -o -name '*.restore.*' \) -print -quit)"
    [[ -z "${found}" ]]
  fi
}

assert_hardened_hook_install() {
  local repo="$1" fixture="$2" hook hook_path expected_root expected_directory
  printf -v expected_root 'readonly PLATFORM_HOOK_ROOT=%q' "${repo}"
  printf -v expected_directory 'readonly PLATFORM_HOOK_DIR=%q' \
    "${repo}/.git/hooks"
  for hook in pre-commit commit-msg; do
    hook_path="${repo}/.git/hooks/${hook}"
    [[ -f "${hook_path}" && ! -L "${hook_path}" && -x "${hook_path}" ]]
    [[ "$(run_host_command head -n 1 "${hook_path}")" == '#!/bin/bash -p' ]]
    run_host_command grep -Fqx "${expected_root}" "${hook_path}"
    run_host_command grep -Fqx "${expected_directory}" "${hook_path}"
    # The hook variables are intentionally matched as literal generated text.
    # shellcheck disable=SC2016
    run_host_command grep -Fqx \
      'builtin source "${PLATFORM_HOOK_ROOT}/tools/common/env.sh"' "${hook_path}"
    # shellcheck disable=SC2016
    run_host_command grep -Fq \
      'run_managed_tool prek hook-impl --hook-dir "${PLATFORM_HOOK_DIR}"' \
      "${hook_path}"
    if run_host_command grep -Eq \
      '(/usr/bin/env bash|PREK="prek"|dirname)' "${hook_path}"; then
      printf 'FAIL  hook-runtime %s retained a pre-boundary fallback\n' \
        "${hook}" >&2
      return 1
    fi
    "$(host_command_path bash)" -p -n "${hook_path}"
    run_host_command cp -pT -- "${hook_path}" "${fixture}/${hook}.before"
    run_host_command stat -c '%a' "${hook_path}" \
      >"${fixture}/${hook}.mode.before"
  done
}

assert_original_hooks_unchanged() {
  local repo="$1" fixture="$2" hook
  for hook in pre-commit commit-msg; do
    run_host_command cmp --silent -- \
      "${fixture}/${hook}.before" "${repo}/.git/hooks/${hook}"
    [[ "$(run_host_command stat -c '%a' "${repo}/.git/hooks/${hook}")" == "$(<"${fixture}/${hook}.mode.before")" ]]
  done
}

prove_hook_transaction_red() {
  local repo="$1" fixture="$2" fake_bin="$3" marker="$4" output status=0
  output="${fixture}/forced-harden.out"
  if run_host_command env PATH="${fake_bin}:${PATH}" FAKE_TOOL_MARKER="${marker}" \
    PLATFORM_TEST_FAIL_HOOK_HARDEN=commit-msg \
    "$(host_command_path make)" --no-print-directory -C "${repo}" hooks \
    >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq 2 ]]
  run_host_command grep -Fqx \
    'FAIL  hooks         forced commit-msg hardening failure' "${output}"
  assert_original_hooks_unchanged "${repo}" "${fixture}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  assert_no_hook_temporaries "${repo}"

  status=0
  output="${fixture}/forced-publish.out"
  if run_host_command env PATH="${fake_bin}:${PATH}" FAKE_TOOL_MARKER="${marker}" \
    PLATFORM_TEST_FAIL_HOOK_PUBLISH=commit-msg \
    "$(host_command_path make)" --no-print-directory -C "${repo}" hooks \
    >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq 2 ]]
  run_host_command grep -Fqx \
    'FAIL  hooks         forced commit-msg publication failure' "${output}"
  assert_original_hooks_unchanged "${repo}" "${fixture}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  assert_no_hook_temporaries "${repo}"
  printf 'PASS  hook-rollback second publish restored both bytes and modes\n'
}

prove_hook_restore_failure_retains_recovery() {
  local repo="$1" fixture="$2" fake_bin="$3" marker="$4"
  local output="${fixture}/forced-restore.out" status=0 retained_backup
  local expected_reason
  local -a retained=()
  if run_host_command env PATH="${fake_bin}:${PATH}" \
    FAKE_TOOL_MARKER="${marker}" \
    PLATFORM_TEST_FAIL_HOOK_PUBLISH=commit-msg \
    PLATFORM_TEST_FAIL_HOOK_RESTORE=pre-commit \
    "${repo}/tools/bootstrap/install-hooks.sh" >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq 74 ]]
  builtin shopt -s nullglob
  retained=("${repo}/.platform"/.hooks-install.*)
  builtin shopt -u nullglob
  [[ "${#retained[@]}" -eq 1 && -d "${retained[0]}" &&
    ! -L "${retained[0]}" ]]
  expected_reason='FAIL  hooks         unable to restore hooks after forced '
  expected_reason+="publication failure; recovery data retained at ${retained[0]}"
  run_host_command grep -Fqx "${expected_reason}" "${output}"
  retained_backup="${retained[0]}/pre-commit.before"
  run_host_command cmp --silent -- \
    "${fixture}/pre-commit.before" "${retained_backup}"
  [[ "$(run_host_command stat -c '%a' "${retained_backup}")" == "$(<"${fixture}/pre-commit.mode.before")" ]]
  run_host_command cmp --silent -- "${fixture}/commit-msg.before" \
    "${repo}/.git/hooks/commit-msg"
  [[ "$(run_host_command stat -c '%a' "${repo}/.git/hooks/commit-msg")" == "$(<"${fixture}/commit-msg.mode.before")" ]]
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  run_host_command rm -rf -- "${retained[0]}"
  assert_no_hook_temporaries "${repo}"
  printf 'PASS  hook-rollback failed restore retained exact recovery bytes\n'
}

write_hook_sentinels() {
  local directory="$1" fixture="$2" suffix="$3" hook
  run_host_command mkdir -p -- "${directory}"
  for hook in pre-commit commit-msg; do
    printf '%s\n' '#!/bin/sh' \
      '# File generated by prek: https://github.com/j178/prek' \
      "printf ${suffix}-hook-must-not-change" >"${directory}/${hook}"
    run_host_command chmod 0755 "${directory}/${hook}"
    run_host_command cp -pT -- \
      "${directory}/${hook}" "${fixture}/${hook}.${suffix}.before"
    run_host_command stat -c '%a' "${directory}/${hook}" \
      >"${fixture}/${hook}.${suffix}.mode.before"
  done
}

assert_hook_sentinels_unchanged() {
  local directory="$1" fixture="$2" suffix="$3" hook
  for hook in pre-commit commit-msg; do
    run_host_command cmp --silent -- \
      "${fixture}/${hook}.${suffix}.before" "${directory}/${hook}"
    [[ "$(run_host_command stat -c '%a' "${directory}/${hook}")" == "$(<"${fixture}/${hook}.${suffix}.mode.before")" ]]
  done
}

prove_external_hook_path_red() {
  local repo="$1" fixture="$2" fake_bin="$3" marker="$4"
  local external="${fixture}/external-hooks" output status=0
  write_hook_sentinels "${external}" "${fixture}" external
  run_host_command git -C "${repo}" config core.hooksPath "${external}"
  output="${fixture}/external.out"
  if run_host_command env PATH="${fake_bin}:${PATH}" FAKE_TOOL_MARKER="${marker}" \
    FIXTURE_EXPECTED_AQUA_ROOT="${repo}/.platform/aqua" \
    FIXTURE_EXPECTED_AQUA_CONFIG="${repo}/aqua.yaml" \
    "$(host_command_path make)" --no-print-directory -C "${repo}" hooks \
    >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq 2 ]]
  run_host_command grep -Fqx \
    'FAIL  hooks         Git hook directory is outside canonical git common directory' \
    "${output}"
  assert_hook_sentinels_unchanged "${external}" "${fixture}" external
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  assert_no_hook_temporaries "${repo}" "${external}"
  run_host_command git -C "${repo}" config --unset core.hooksPath
  printf 'PASS  hook-path     external core.hooksPath preserved sentinels\n'
}

prove_ambient_git_red() {
  local repo="$1" fixture="$2" fake_bin="$3" marker="$4"
  local ambient="${fixture}/ambient-git" output status=0
  run_host_command git init --quiet "${ambient}"
  write_hook_sentinels "${ambient}/.git/hooks" "${fixture}" ambient
  output="${fixture}/ambient.out"
  if run_host_command env PATH="${fake_bin}:${PATH}" FAKE_TOOL_MARKER="${marker}" \
    GIT_DIR="${ambient}/.git" GIT_COMMON_DIR="${ambient}/.git" \
    GIT_WORK_TREE="${ambient}" \
    "$(host_command_path make)" --no-print-directory -C "${repo}" hooks \
    >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq 2 ]]
  run_host_command grep -Fqx \
    'FAIL  hooks         ambient Git repository selectors are not allowed' \
    "${output}"
  assert_hook_sentinels_unchanged \
    "${ambient}/.git/hooks" "${fixture}" ambient
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  assert_no_hook_temporaries "${repo}" "${ambient}/.git/hooks"
  printf 'PASS  hook-env      ambient Git selectors preserved external hooks\n'
}

prove_hook_runtime() {
  local fake_bin="$1" marker="$2" toolchain_fixture="$3"
  local fixture="${WORK_DIR}/hook-runtime"
  local repo="${fixture}/repo" output="${fixture}/hooks.out" status=0
  run_host_command mkdir -p -- "${fixture}"
  stage_repository "${repo}"
  run_host_command git -C "${repo}" init --quiet
  run_host_command mkdir -p -- "${repo}/.platform"
  run_host_command cp -al -- \
    "${toolchain_fixture}/.platform/aqua" "${repo}/.platform/aqua"
  run_host_command cp -al -- \
    "${toolchain_fixture}/.platform/bootstrap" \
    "${repo}/.platform/bootstrap"
  run_host_command cp -pT -- \
    "${toolchain_fixture}/tools/bootstrap/aqua-trust.sh" \
    "${repo}/tools/bootstrap/aqua-trust.sh"
  export FIXTURE_EXPECTED_AQUA_ROOT="${repo}/.platform/aqua"
  export FIXTURE_EXPECTED_AQUA_CONFIG="${repo}/aqua.yaml"
  if run_host_command env PATH="${fake_bin}:${PATH}" FAKE_TOOL_MARKER="${marker}" \
    "$(host_command_path make)" --no-print-directory -C "${repo}" hooks \
    >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if ((status != 0)); then
    run_host_command sed -n '1,30p' "${output}" >&2
    printf 'FAIL  hook-runtime managed hook installation failed: %s\n' \
      "${status}" >&2
    return 1
  fi
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  assert_hardened_hook_install "${repo}" "${fixture}"
  prove_hook_transaction_red "${repo}" "${fixture}" "${fake_bin}" "${marker}"
  prove_hook_restore_failure_retains_recovery \
    "${repo}" "${fixture}" "${fake_bin}" "${marker}"
  prove_external_hook_path_red "${repo}" "${fixture}" "${fake_bin}" "${marker}"
  prove_ambient_git_red "${repo}" "${fixture}" "${fake_bin}" "${marker}"
  unset FIXTURE_EXPECTED_AQUA_ROOT FIXTURE_EXPECTED_AQUA_CONFIG
  printf 'PASS  hook-runtime transactional publication stayed repository-local\n'
}

write_serial_probe() {
  local script="$1" label="$2" mkdir_path rm_path sleep_path
  mkdir_path="$(host_command_path mkdir)" || return
  rm_path="$(host_command_path rm)" || return
  sleep_path="$(host_command_path sleep)" || return
  {
    printf '#!/bin/bash -p\nset -euo pipefail\n'
    printf 'readonly SERIAL_MKDIR=%q\n' "${mkdir_path}"
    printf 'readonly SERIAL_RM=%q\n' "${rm_path}"
    printf 'readonly SERIAL_SLEEP=%q\n' "${sleep_path}"
    # These variables are intentionally emitted for the generated child.
    # shellcheck disable=SC2016
    printf '"${SERIAL_MKDIR}" -- "${SERIAL_LOCK:?}"\n'
    # shellcheck disable=SC2016
    printf 'cleanup_serial_lock() { "${SERIAL_RM}" -rf -- "${SERIAL_LOCK}"; }\n'
    printf 'trap cleanup_serial_lock EXIT\n'
    # shellcheck disable=SC2016
    printf '"${SERIAL_SLEEP}" 0.2\n'
    printf "printf '%%s\\n' %q >>\"\${SERIAL_RECORD:?}\"\n" "${label}"
  } >"${script}"
  run_host_command chmod 0755 "${script}"
}

prove_parallel_verify_is_serial() {
  local target="${WORK_DIR}/serial-repo" output record lock expected status=0
  local fake_make marker
  prepare_fixture "${target}"
  write_serial_probe "${target}/tools/quality/check.sh" check
  write_serial_probe "${target}/tools/quality/prove-gates.sh" prove-gates
  write_serial_probe "${target}/tools/kubernetes/verify.sh" verify-runtime
  output="${target}/parallel-verify.out"
  record="${target}/parallel-verify.record"
  lock="${target}/parallel-verify.lock"
  fake_make="${target}/fake-bin/make"
  marker="${target}/hostile-make.marker"
  run_host_command cat >"${fake_make}" <<'FAKE'
#!/bin/bash -p
builtin printf 'executed\n' >"${HOSTILE_MAKE_MARKER:?}"
exit 99
FAKE
  run_host_command chmod 0755 -- "${fake_make}"
  if run_host_command env SERIAL_RECORD="${record}" SERIAL_LOCK="${lock}" \
    MAKE="${fake_make}" HOSTILE_MAKE_MARKER="${marker}" \
    "$(host_command_path make)" --no-print-directory -j3 -C "${target}" verify \
    >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if ((status != 0)); then
    run_host_command sed -n '1,30p' "${output}" >&2
    printf 'FAIL  make-serial   make -j verify status=%s\n' "${status}" >&2
    return 1
  fi
  expected=$'check\nprove-gates\nverify-runtime'
  [[ "$(run_host_command cat -- "${record}")" == "${expected}" ]]
  [[ ! -e "${lock}" && ! -L "${lock}" &&
    ! -e "${marker}" && ! -L "${marker}" ]]
  printf 'PASS  make-serial   hostile MAKE ignored; verify retained canonical order\n'
}

main() {
  local target
  WORK_DIR="$(run_host_command mktemp -d)"
  trap 'run_host_command rm -rf -- "${WORK_DIR}"' EXIT
  target="${WORK_DIR}/repo"
  prepare_fixture "${target}"
  prove_preboundary_environment_is_ignored "${target}"
  prove_each_managed_tool "${target}"
  prove_canonical_consumers "${target}"
  prove_inherited_functions_cannot_bypass "${target}"
  prove_project_state_boundary "${target}"
  prove_git_attestation_environment_is_sanitized
  prove_hook_runtime "${target}/fake-bin" \
    "${target}/FAKE_TOOLS_EXECUTED" "${target}"
  prove_parallel_verify_is_serial
  printf 'PASS  tooling       project-managed tool admission proved\n'
}

main "$@"
