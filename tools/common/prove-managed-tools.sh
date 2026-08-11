#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh"

WORK_DIR=""

prepare_fixture() {
  local target="$1"
  local path
  mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/kubernetes" "${target}/tools/quality" "${target}/fake-bin"
  cp "${PLATFORM_ROOT}/Makefile" "${target}/Makefile"
  for path in aqua-trust.sh install-hooks.sh; do
    cp "${PLATFORM_ROOT}/tools/bootstrap/${path}" "${target}/tools/bootstrap/${path}"
  done
  for path in env.sh state.sh process-state.sh tooling.sh run-managed-tool.sh; do
    cp "${PLATFORM_ROOT}/tools/common/${path}" "${target}/tools/common/${path}"
  done
  for path in runtime.sh verify.sh; do
    cp "${PLATFORM_ROOT}/tools/kubernetes/${path}" "${target}/tools/kubernetes/${path}"
  done
  for path in check-fast.sh check.sh prove-gates.sh; do
    cp "${PLATFORM_ROOT}/tools/quality/${path}" "${target}/tools/quality/${path}"
  done
  for path in aqua go gofmt kind kubectl shellcheck shfmt actionlint zizmor \
    hadolint trivy kubeconform kube-linter prek; do
    cat >"${target}/fake-bin/${path}" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${0##*/}" >>"${FAKE_TOOL_MARKER:?}"
exit 0
FAKE
    chmod 0755 "${target}/fake-bin/${path}"
  done
}

expect_untrusted_rejection() {
  local target="$1" label="$2"
  local marker="${target}/FAKE_TOOLS_EXECUTED"
  local output="${target}/${label}.log"
  local status=0
  shift 2
  rm -f -- "${marker}"
  if env PATH="${target}/fake-bin:${PATH}" FAKE_TOOL_MARKER="${marker}" \
    "$@" >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if ((status == 0)); then
    printf 'FAIL  tooling-red   %s accepted an external managed tool\n' "${label}" >&2
    return 1
  fi
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  tooling-red   %s executed an external managed tool\n' "${label}" >&2
    return 1
  fi
  if ! grep -Fq \
    'project-managed toolchain unavailable or untrusted:' "${output}"; then
    printf 'FAIL  tooling-red   %s missed the exact toolchain reason\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  tooling-red   %s rejected external managed tools\n' "${label}"
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
  local target="$1" capability
  for capability in check-fast check prove-gates verify-runtime hooks; do
    expect_untrusted_rejection "${target}" "make-${capability}" \
      make --no-print-directory -C "${target}" "${capability}"
  done
}

prove_inherited_functions_cannot_bypass() {
  local target="$1"
  local marker="${target}/INHERITED_FUNCTION_EXECUTED"
  local output="${target}/inherited-functions.log"
  local status=0
  rm -f -- "${marker}"
  (
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2329
    run_managed_tool() {
      printf 'run_managed_tool\n' >>"${BYPASS_MARKER:?}"
      return 0
    }
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2329
    require_tool() {
      printf 'require_tool\n' >>"${BYPASS_MARKER:?}"
      return 0
    }
    # Invoked only after export in the child process under test.
    # shellcheck disable=SC2329
    verify_existing_aqua() {
      printf 'verify_existing_aqua\n' >>"${BYPASS_MARKER:?}"
      return 0
    }
    export -f run_managed_tool require_tool verify_existing_aqua
    BYPASS_MARKER="${marker}" PATH="${target}/fake-bin:${PATH}" \
      FAKE_TOOL_MARKER="${marker}" \
      "${target}/tools/common/run-managed-tool.sh" go version
  ) >"${output}" 2>&1 || status=$?
  if ((status == 0)); then
    printf 'FAIL  tooling-red   inherited functions bypassed canonical tooling\n' >&2
    return 1
  fi
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  tooling-red   an inherited function or PATH tool executed\n' >&2
    return 1
  fi
  grep -Fq 'project-managed toolchain unavailable or untrusted:' "${output}"
  printf 'PASS  tooling-red   inherited shell functions cannot bypass tooling\n'
}

prove_project_state_boundary() {
  local target="$1"
  local marker="${target}/FAKE_TOOLS_EXECUTED"
  local output="${target}/project-state.log"
  mkdir -p "${target}/.platform/bootstrap" "${target}/.platform/aqua/bin" \
    "${target}/.platform/aqua/test-fixtures" \
    "${target}/.platform/aqua/internal/test"
  cp "${PLATFORM_STATE_DIR}/bootstrap/aqua" \
    "${target}/.platform/bootstrap/aqua"
  ln -s "${target}/fake-bin/go" "${target}/.platform/aqua/bin/go"
  expect_untrusted_rejection "${target}" escaped-project-proxy \
    "${target}/tools/common/run-managed-tool.sh" go version

  rm -f -- "${target}/.platform/aqua/bin/go"
  cat >"${target}/.platform/aqua/test-fixtures/go" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'project-fixture-go\n'
FAKE
  chmod 0755 "${target}/.platform/aqua/test-fixtures/go"
  ln -s ../test-fixtures/go "${target}/.platform/aqua/bin/go"
  expect_untrusted_rejection "${target}" project-test-fixture-without-adapter \
    "${target}/tools/common/run-managed-tool.sh" go version

  rm -f -- "${target}/.platform/aqua/bin/go"
  cat >"${target}/.platform/aqua/internal/test/aqua-proxy" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'canonical-aqua-proxy\n'
FAKE
  chmod 0755 "${target}/.platform/aqua/internal/test/aqua-proxy"
  ln -s internal/test/aqua-proxy "${target}/.platform/aqua/aqua-proxy"
  ln -s ../aqua-proxy "${target}/.platform/aqua/bin/go"
  rm -f -- "${marker}"
  env PATH="${target}/fake-bin:${PATH}" FAKE_TOOL_MARKER="${marker}" \
    "${target}/tools/common/run-managed-tool.sh" go version >"${output}" 2>&1
  grep -Fqx canonical-aqua-proxy "${output}"
  if [[ -e "${marker}" ]]; then
    printf 'FAIL  tooling-red   external PATH preempted project fixture\n' >&2
    return 1
  fi
  printf 'PASS  tooling       canonical Aqua proxy shape admitted\n'
}

main() {
  local target
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf -- "${WORK_DIR}"' EXIT
  target="${WORK_DIR}/repo"
  prepare_fixture "${target}"
  prove_each_managed_tool "${target}"
  prove_canonical_consumers "${target}"
  prove_inherited_functions_cannot_bypass "${target}"
  prove_project_state_boundary "${target}"
  printf 'PASS  tooling       project-managed tool admission proved\n'
}

main "$@"
