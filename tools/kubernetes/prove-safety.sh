#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh"

WORK_DIR=""

copy_runtime_files() {
  local target="$1"
  local script
  mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/kubernetes" "${target}/.platform/bootstrap" \
    "${target}/.platform/aqua/bin" "${target}/.platform/aqua/test-fixtures"
  cp "${PLATFORM_ROOT}/tools/bootstrap/aqua-trust.sh" \
    "${target}/tools/bootstrap/aqua-trust.sh"
  cp "${PLATFORM_ROOT}/tools/common/env.sh" "${target}/tools/common/env.sh"
  cp "${PLATFORM_ROOT}/tools/common/state.sh" "${target}/tools/common/state.sh"
  cp "${PLATFORM_ROOT}/tools/common/tooling.sh" \
    "${target}/tools/common/tooling-production.sh"
  cp "${PLATFORM_ROOT}/tools/kubernetes/managed-tool-fixture.sh" \
    "${target}/tools/common/tooling.sh"
  cp "${PLATFORM_STATE_DIR}/bootstrap/aqua" \
    "${target}/.platform/bootstrap/aqua"
  for script in runtime guard-context guard-ownership kind-up kind-down delete-namespace diagnostics; do
    cp "${PLATFORM_ROOT}/tools/kubernetes/${script}.sh" \
      "${target}/tools/kubernetes/${script}.sh"
  done
}

publish_managed_mock() {
  local target="$1" command_name="$2"
  chmod 0755 "${target}/.platform/aqua/test-fixtures/${command_name}"
}

write_kind_mock() {
  local target="$1"
  cat >"${target}/.platform/aqua/test-fixtures/kind" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cluster_state() {
  if [[ -n "${FIXTURE_CLUSTER_STATE_FILE:-}" ]]; then
    cat "${FIXTURE_CLUSTER_STATE_FILE}"
  else
    printf '%s\n' "${FIXTURE_CLUSTER_STATE:-present}"
  fi
}
case "${1:-} ${2:-}" in
  "get clusters")
    if [[ "$(cluster_state)" == present ]]; then
      printf 'flare-platform-dev\n'
    fi
    ;;
  "export kubeconfig")
    while (($#)); do
      if [[ "$1" == --kubeconfig ]]; then
        shift
        printf 'fixture\n' >"$1"
        exit 0
      fi
      shift
    done
    exit 2
    ;;
  "create cluster")
    while (($#)); do
      if [[ "$1" == --kubeconfig ]]; then
        shift
        printf 'fixture\n' >"$1"
      fi
      shift
    done
    if [[ -n "${FIXTURE_CLUSTER_STATE_FILE:-}" ]]; then
      printf 'present\n' >"${FIXTURE_CLUSTER_STATE_FILE}"
    fi
    exit "${FIXTURE_KIND_CREATE_STATUS:-0}"
    ;;
  "delete cluster")
    : >"${FIXTURE_DELETED_MARKER:?}"
    if [[ -n "${FIXTURE_CLUSTER_STATE_FILE:-}" ]]; then
      printf 'absent\n' >"${FIXTURE_CLUSTER_STATE_FILE}"
    fi
    ;;
  *) exit 2 ;;
esac
MOCK
  publish_managed_mock "${target}" kind
}

write_docker_mock() {
  local target="$1"
  cat >"${target}/.platform/aqua/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == info ]] || exit 2
MOCK
  chmod +x "${target}/.platform/aqua/bin/docker"
}

write_ownership_kubectl_mock() {
  local target="$1"
  cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"jsonpath={.data.owner}"* ]]; then
  printf 'not-flare\n'
elif [[ "${arguments}" == *"jsonpath={.data.cluster-name}"* ]]; then
  printf 'flare-platform-dev\n'
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

write_create_kubectl_mock() {
  local target="$1"
  cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"jsonpath={.data.owner}"* ]]; then
  printf 'flare-platform-infra\n'
elif [[ "${arguments}" == *"jsonpath={.data.cluster-name}"* ]]; then
  printf 'flare-platform-dev\n'
elif [[ "${arguments}" == *" apply "* ]]; then
  exit 0
elif [[ "${arguments}" == *" wait "* ]]; then
  exit "${FIXTURE_NODE_WAIT_STATUS:-0}"
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_post_create_failure_is_cleaned() {
  local target="${WORK_DIR}/post-create-failure"
  local marker="${target}/deleted"
  local state="${target}/cluster-state"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_docker_mock "${target}"
  write_create_kubectl_mock "${target}"
  printf 'absent\n' >"${state}"
  if (cd "${target}" && FIXTURE_CLUSTER_STATE_FILE="${state}" \
    FIXTURE_DELETED_MARKER="${marker}" FIXTURE_NODE_WAIT_STATUS=7 \
    tools/kubernetes/kind-up.sh >/dev/null 2>&1); then
    printf 'FAIL  kube-red       post-create readiness failure passed\n' >&2
    return 1
  fi
  [[ -e "${marker}" ]]
  grep -Fqx absent "${state}"
  [[ ! -e "${target}/.platform/kubeconfig" ]]
  printf 'PASS  kube-red       owned incomplete creation was cleaned\n'
}

prove_create_failure_stops_without_blind_delete() {
  local target="${WORK_DIR}/create-failure"
  local marker="${target}/deleted"
  local state="${target}/cluster-state"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_docker_mock "${target}"
  write_create_kubectl_mock "${target}"
  printf 'absent\n' >"${state}"
  if (cd "${target}" && FIXTURE_CLUSTER_STATE_FILE="${state}" \
    FIXTURE_DELETED_MARKER="${marker}" FIXTURE_KIND_CREATE_STATUS=8 \
    tools/kubernetes/kind-up.sh >/dev/null 2>&1); then
    printf 'FAIL  kube-red       failing create unexpectedly passed\n' >&2
    return 1
  fi
  [[ ! -e "${marker}" ]]
  grep -Fqx present "${state}"
  [[ ! -e "${target}/.platform/kubeconfig" ]]
  printf 'PASS  kube-red       unowned partial creation was not blindly deleted\n'
}

prove_unowned_cluster_is_not_deleted() {
  local target="${WORK_DIR}/unowned"
  local marker="${target}/deleted"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_ownership_kubectl_mock "${target}"
  if (cd "${target}" && FIXTURE_DELETED_MARKER="${marker}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null 2>&1); then
    printf 'FAIL  kube-red       unowned cluster was accepted\n' >&2
    return 1
  fi
  [[ ! -e "${marker}" ]]
  printf 'PASS  kube-red       unowned same-name cluster was not deleted\n'
}

write_owned_kubectl_mock() {
  local target="$1"
  cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"jsonpath={.data.owner}"* ]]; then
  printf 'flare-platform-infra\n'
elif [[ "${arguments}" == *"jsonpath={.data.cluster-name}"* ]]; then
  printf 'flare-platform-dev\n'
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_owned_cluster_is_deleted() {
  local target="${WORK_DIR}/owned"
  local marker="${target}/deleted"
  local state="${target}/cluster-state"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_owned_kubectl_mock "${target}"
  printf 'present\n' >"${state}"
  (cd "${target}" && FIXTURE_CLUSTER_STATE_FILE="${state}" \
    FIXTURE_DELETED_MARKER="${marker}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null)
  [[ -e "${marker}" ]]
  grep -Fqx absent "${state}"
  [[ ! -e "${target}/.platform/kubeconfig" ]]
  printf 'PASS  kube-green     owned cluster deletion reached proven absence\n'
}

prove_absent_destroy_is_idempotent() {
  local target="${WORK_DIR}/absent"
  local marker="${target}/deleted"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  (cd "${target}" && FIXTURE_CLUSTER_STATE=absent FIXTURE_DELETED_MARKER="${marker}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null)
  (cd "${target}" && FIXTURE_CLUSTER_STATE=absent FIXTURE_DELETED_MARKER="${marker}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null)
  [[ ! -e "${marker}" ]]
  printf 'PASS  kube-green     absent cluster destroy is idempotent\n'
}

write_namespace_kubectl_mock() {
  local target="$1"
  cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"delete namespace"* ]]; then
  printf 'absent\n' >"${FIXTURE_NAMESPACE_STATE:?}"
elif [[ "${arguments}" == *"get namespace"* ]]; then
  if [[ "${FIXTURE_NAMESPACE_QUERY_FAIL:-false}" == true ]]; then
    exit 7
  fi
  [[ "$(cat "${FIXTURE_NAMESPACE_STATE:?}")" == absent ]] || \
    printf 'namespace/flare-platform-reference\n'
else
  exit 2
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_namespace_cleanup() {
  local target="${WORK_DIR}/namespace"
  local state="${target}/namespace-state"
  copy_runtime_files "${target}"
  write_namespace_kubectl_mock "${target}"
  printf 'fixture\n' >"${target}/.platform/kubeconfig"
  printf 'present\n' >"${state}"
  (cd "${target}" && FIXTURE_NAMESPACE_STATE="${state}" \
    tools/kubernetes/delete-namespace.sh >/dev/null)
  grep -Fqx absent "${state}"
  printf 'PASS  kube-green     namespace cleanup reached proven absence\n'
}

prove_namespace_query_failure_is_not_absence() {
  local target="${WORK_DIR}/namespace-query-failure"
  local state="${target}/namespace-state"
  copy_runtime_files "${target}"
  write_namespace_kubectl_mock "${target}"
  printf 'fixture\n' >"${target}/.platform/kubeconfig"
  printf 'present\n' >"${state}"
  if (cd "${target}" && FIXTURE_NAMESPACE_STATE="${state}" \
    FIXTURE_NAMESPACE_QUERY_FAIL=true \
    tools/kubernetes/delete-namespace.sh >/dev/null 2>&1); then
    printf 'FAIL  kube-red       API failure was mistaken for namespace absence\n' >&2
    return 1
  fi
  printf 'PASS  kube-red       API failure was not mistaken for cleanup\n'
}

prove_kubeconfig_symlink_is_rejected() {
  local target="${WORK_DIR}/kubeconfig-symlink"
  local marker="${target}/deleted"
  copy_runtime_files "${target}"
  write_kind_mock "${target}"
  write_owned_kubectl_mock "${target}"
  printf 'outside-sentinel\n' >"${target}/outside-kubeconfig"
  ln -s "${target}/outside-kubeconfig" "${target}/.platform/kubeconfig"
  if (cd "${target}" && FIXTURE_DELETED_MARKER="${marker}" \
    tools/kubernetes/kind-down.sh --if-present >/dev/null 2>&1); then
    printf 'FAIL  kube-red       kubeconfig symlink was accepted before export\n' >&2
    return 1
  fi
  grep -Fqx outside-sentinel "${target}/outside-kubeconfig"
  [[ ! -e "${marker}" ]]
  printf 'PASS  kube-red       kubeconfig symlink was rejected before export\n'
}

write_noisy_kubectl_mock() {
  local target="$1"
  cat >"${target}/.platform/aqua/test-fixtures/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
else
  head -c 200000 /dev/zero | tr '\0' x
fi
MOCK
  publish_managed_mock "${target}" kubectl
}

prove_diagnostics_are_bounded() {
  local target="${WORK_DIR}/diagnostics"
  local oversized
  copy_runtime_files "${target}"
  write_noisy_kubectl_mock "${target}"
  printf 'fixture\n' >"${target}/.platform/kubeconfig"
  (cd "${target}" && tools/kubernetes/diagnostics.sh >/dev/null)
  oversized="$(find "${target}/.platform/diagnostics" \
    -type f -size +132000c -print -quit)"
  [[ -z "${oversized}" ]]
  if find "${target}/.platform/diagnostics" -name '.capture.*' -print -quit | grep -q .; then
    printf 'FAIL  kube-red       temporary diagnostic capture leaked\n' >&2
    return 1
  fi
  grep -Fqx 'truncated=true' \
    "${target}/.platform/diagnostics/raw/kubernetes/nodes.txt"
  printf 'PASS  kube-green     failure diagnostics remain stream-bounded\n'
}

main() {
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${WORK_DIR}"' EXIT
  prove_post_create_failure_is_cleaned
  prove_create_failure_stops_without_blind_delete
  prove_unowned_cluster_is_not_deleted
  prove_owned_cluster_is_deleted
  prove_absent_destroy_is_idempotent
  prove_namespace_cleanup
  prove_namespace_query_failure_is_not_absence
  prove_kubeconfig_symlink_is_rejected
  prove_diagnostics_are_bounded
}

main "$@"
