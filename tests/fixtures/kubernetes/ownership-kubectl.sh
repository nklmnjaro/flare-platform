#!/bin/bash -p
set -euo pipefail

record_call() {
  [[ -z "${FIXTURE_KUBECTL_LOG:-}" ]] ||
    printf '%s\n' "$*" >>"${FIXTURE_KUBECTL_LOG}"
}

snapshot_count() {
  local count=0
  if [[ -n "${FIXTURE_SNAPSHOT_COUNT_FILE:-}" &&
    -s "${FIXTURE_SNAPSHOT_COUNT_FILE}" ]]; then
    IFS= read -r count <"${FIXTURE_SNAPSHOT_COUNT_FILE}"
  fi
  ((count += 1))
  [[ -z "${FIXTURE_SNAPSHOT_COUNT_FILE:-}" ]] ||
    printf '%s\n' "${count}" >"${FIXTURE_SNAPSHOT_COUNT_FILE}"
  printf '%s\n' "${count}"
}

emit_nul_snapshot() {
  local uid="$1" resource_version="$2" cluster_name="$3" checkout_id="$4"
  printf 'api_version=v1\nkind=ConfigMap\nnamespace=kube-system\n'
  printf 'name=flare-platform-ownership\nuid=%s\nresource_version=%s\n' \
    "${uid}" "${resource_version}"
  printf 'data_count=4\nbinary_data_count=0\ncontract_version=checkout-v1\n'
  printf 'owner=flare\0-platform-infra\ncluster_name=%s\ncheckout_id=%s\n' \
    "${cluster_name}" "${checkout_id}"
}

emit_snapshot() {
  local count uid resource_version data_count=4 binary_data_count=0
  local contract_version owner cluster_name checkout_id
  count="$(snapshot_count)"
  uid="${FIXTURE_OWNERSHIP_UID:-fixture-uid-1}"
  resource_version="${FIXTURE_OWNERSHIP_RESOURCE_VERSION:-1}"
  contract_version="${FIXTURE_OWNERSHIP_CONTRACT:-checkout-v1}"
  owner="${FIXTURE_OWNERSHIP_OWNER:-flare-platform-infra}"
  cluster_name="${FIXTURE_OWNERSHIP_CLUSTER_NAME:-flare-platform-dev}"
  checkout_id="${FIXTURE_CHECKOUT_ID:?}"
  case "${FIXTURE_OWNERSHIP_MODE:-owned}" in
    owned) ;;
    legacy)
      data_count=2
      contract_version=''
      checkout_id=''
      ;;
    extra) data_count=5 ;;
    binary) binary_data_count=1 ;;
    malformed) resource_version='bad value' ;;
    replace)
      if ((count >= 2)); then
        uid='fixture-uid-2'
        resource_version=2
      fi
      ;;
    nul)
      emit_nul_snapshot "${uid}" "${resource_version}" \
        "${cluster_name}" "${checkout_id}"
      return
      ;;
    oversized)
      resource_version=''
      while ((${#resource_version} < 2200)); do
        resource_version+='x'
      done
      ;;
    *) exit 64 ;;
  esac
  printf 'api_version=v1\nkind=ConfigMap\nnamespace=kube-system\n'
  printf 'name=flare-platform-ownership\nuid=%s\nresource_version=%s\n' \
    "${uid}" "${resource_version}"
  printf 'data_count=%s\nbinary_data_count=%s\n' \
    "${data_count}" "${binary_data_count}"
  printf 'contract_version=%s\nowner=%s\ncluster_name=%s\ncheckout_id=%s\n' \
    "${contract_version}" "${owner}" "${cluster_name}" "${checkout_id}"
}

if [[ -n "${FIXTURE_DOCKER_ENV_LOG:-}" ]]; then
  printf 'kubectl|%s|%s|%s|%s|%s|%s\n' \
    "${DOCKER_HOST-<unset>}" "${DOCKER_CONTEXT-<unset>}" \
    "${BUILDX_BUILDER-<unset>}" "${DOCKER_BUILDKIT-<unset>}" \
    "${DOCKER_TARGET_DOCKER_PATH-<unset>}" \
    "${DOCKER_TARGET_FINGERPRINT-<unset>}" >>"${FIXTURE_DOCKER_ENV_LOG}"
fi
record_call "$@"
arguments="$*"
if [[ "${arguments}" == *"config current-context"* ]]; then
  printf 'kind-flare-platform-dev\n'
elif [[ "${arguments}" == *"get configmap flare-platform-ownership"* ]]; then
  emit_snapshot
elif [[ "${arguments}" == *"create configmap flare-platform-ownership"* ]]; then
  [[ -z "${FIXTURE_OWNERSHIP_CREATE_ARGS:-}" ]] ||
    printf '%s\n' "${arguments}" >"${FIXTURE_OWNERSHIP_CREATE_ARGS}"
  printf 'configmap/flare-platform-ownership created\n'
elif [[ "${arguments}" == *" wait "* ]]; then
  exit "${FIXTURE_NODE_WAIT_STATUS:-0}"
elif [[ "${arguments}" == *"delete namespace"* ]]; then
  [[ -z "${FIXTURE_NAMESPACE_DELETE_MARKER:-}" ]] ||
    : >"${FIXTURE_NAMESPACE_DELETE_MARKER}"
  printf 'absent\n' >"${FIXTURE_NAMESPACE_STATE:?}"
elif [[ "${arguments}" == *"get namespace"* ]]; then
  [[ "${FIXTURE_NAMESPACE_QUERY_FAIL:-false}" != true ]] || exit 7
  [[ "$(<"${FIXTURE_NAMESPACE_STATE:?}")" == absent ]] ||
    printf 'namespace/flare-platform-reference\n'
elif [[ -n "${FIXTURE_DIAGNOSTIC_FAIL_MATCH:-}" &&
  "${arguments}" == *"${FIXTURE_DIAGNOSTIC_FAIL_MATCH}"* ]]; then
  exit "${FIXTURE_DIAGNOSTIC_FAIL_STATUS:-7}"
elif [[ "${FIXTURE_NOISY_RESPONSES:-false}" == true ]]; then
  printf '%*s' 200000 '' | while IFS= read -r -N 4096 chunk; do
    printf '%s' "${chunk// /x}"
  done
else
  exit 2
fi
