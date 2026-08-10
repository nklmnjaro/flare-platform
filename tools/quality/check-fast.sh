#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

collect_shell_files() {
  git ls-files --cached --others --exclude-standard '*.sh' |
    grep -v '^tests/fixtures/' || true
}

check_go_tools() {
  local module
  for module in tools/artifacts/archive tools/quality/policycheck kubernetes/reference/server; do
    (
      cd "${PLATFORM_ROOT}/${module}"
      go test ./...
    )
  done
}

check_source_policy() {
  (
    cd "${PLATFORM_ROOT}/tools/quality/policycheck"
    go run . -root "${PLATFORM_ROOT}"
  )
}

check_gofmt() {
  local output
  local -a go_files=()
  mapfile -t go_files < <(
    git ls-files --cached --others --exclude-standard '*.go' |
      grep -v '^tests/fixtures/' || true
  )
  ((${#go_files[@]})) || return 0
  output="$(gofmt -d "${go_files[@]}")"
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
    shellcheck -x -P SCRIPTDIR "${shell_files[@]}"
    printf 'PASS  shellcheck    tracked shell targets accepted\n'
    shfmt -d -i 2 -ci "${shell_files[@]}"
    printf 'PASS  shell-format  tracked shell targets accepted\n'
  fi
  check_gofmt
  printf 'PASS  go-checks     tests, source policy, and formatting accepted\n'
  actionlint .github/workflows/*.yml
  printf 'PASS  actionlint    workflow syntax accepted\n'
  zizmor --offline .github/workflows
  printf 'PASS  zizmor        offline workflow security checks accepted\n'
  printf 'PASS  check-fast    cheap static checks\n'
}

main "$@"
