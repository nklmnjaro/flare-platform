#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/tooling.sh"

collect_shell_files() {
  git ls-files '*.sh' | grep -v '^tests/fixtures/' || true
}

check_source_policy() {
  (
    cd "${PLATFORM_ROOT}/tools/quality/policycheck"
    go test ./...
    go run . -root "${PLATFORM_ROOT}"
  )
}

check_gofmt() {
  local output
  output="$(gofmt -d kubernetes/reference/server/main.go)"
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
  check_source_policy
  mapfile -t shell_files < <(collect_shell_files)
  if ((${#shell_files[@]})); then
    shellcheck "${shell_files[@]}"
    shfmt -d -i 2 -ci "${shell_files[@]}"
  fi
  check_gofmt
  actionlint .github/workflows/*.yml
  zizmor .github/workflows
  printf 'PASS  check-fast    cheap static checks\n'
}

main "$@"
