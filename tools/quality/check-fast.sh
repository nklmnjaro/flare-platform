#!/bin/bash -p
set -euo pipefail

CHECK_FAST_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${CHECK_FAST_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  CHECK_FAST_SOURCE_DIR=.
builtin source "${CHECK_FAST_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
unset CHECK_FAST_SOURCE_DIR

collect_shell_files() {
  run_host_command git ls-files --cached --others --exclude-standard '*.sh' |
    run_host_command grep -v '^tests/fixtures/' || true
}

check_go_tools() {
  local git_path
  local module
  git_path="$(host_command_path git)"
  for module in tools/artifacts/archive tools/evidence/sanitize \
    tools/quality/policycheck tools/recovery/capsule kubernetes/reference/server; do
    (
      cd "${PLATFORM_ROOT}/${module}"
      if [[ "${module}" == tools/recovery/capsule ]]; then
        RECOVERY_TEST_GIT="${git_path}" run_managed_tool go test ./...
      else
        run_managed_tool go test ./...
      fi
    )
  done
}

check_source_policy() {
  (
    cd "${PLATFORM_ROOT}/tools/quality/policycheck"
    run_managed_tool go run . -root "${PLATFORM_ROOT}"
  )
}

check_gofmt() {
  local output
  local -a go_files=()
  mapfile -t go_files < <(
    run_host_command git ls-files --cached --others --exclude-standard '*.go' |
      run_host_command grep -v '^tests/fixtures/' || true
  )
  ((${#go_files[@]})) || return 0
  output="$(run_managed_tool gofmt -d "${go_files[@]}")"
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}" >&2
    return 1
  fi
}

main() {
  local tool
  local -a shell_files=()
  for tool in shellcheck shfmt actionlint zizmor gofmt go; do
    require_tool "${tool}"
  done

  "${PLATFORM_ROOT}/tools/quality/repo-policy.sh"
  check_go_tools
  check_source_policy
  mapfile -t shell_files < <(collect_shell_files)
  if ((${#shell_files[@]})); then
    run_managed_tool shellcheck -x -P SCRIPTDIR "${shell_files[@]}"
    printf 'PASS  shellcheck    tracked shell targets accepted\n'
    run_managed_tool shfmt -d -i 2 -ci "${shell_files[@]}"
    printf 'PASS  shell-format  tracked shell targets accepted\n'
  fi
  check_gofmt
  printf 'PASS  go-checks     tests, source policy, and formatting accepted\n'
  run_managed_tool actionlint .github/workflows/*.yml
  printf 'PASS  actionlint    workflow syntax accepted\n'
  run_managed_tool zizmor --offline .github/workflows
  printf 'PASS  zizmor        offline workflow security checks accepted\n'
  printf 'PASS  check-fast    cheap static checks\n'
}

main "$@"
