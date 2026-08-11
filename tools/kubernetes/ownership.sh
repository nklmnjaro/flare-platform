#!/bin/bash -p
set -euo pipefail

OWNERSHIP_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${OWNERSHIP_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  OWNERSHIP_SOURCE_DIR=.
builtin source "${OWNERSHIP_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin source "${PLATFORM_ROOT}/tools/common/checkout-identity.sh"
builtin source "${PLATFORM_ROOT}/tools/kubernetes/runtime.sh"
builtin unset OWNERSHIP_SOURCE_DIR

PLATFORM_OWNERSHIP_CONTRACT='checkout-v1'
PLATFORM_OWNERSHIP_OWNER='flare-platform-infra'
PLATFORM_OWNERSHIP_CONFIGMAP='flare-platform-ownership'
PLATFORM_OWNERSHIP_SNAPSHOT_MAX_BYTES=2048

OWNERSHIP_SNAPSHOT_API_VERSION=''
OWNERSHIP_SNAPSHOT_KIND=''
OWNERSHIP_SNAPSHOT_NAMESPACE=''
OWNERSHIP_SNAPSHOT_NAME=''
OWNERSHIP_SNAPSHOT_UID=''
OWNERSHIP_SNAPSHOT_RESOURCE_VERSION=''
OWNERSHIP_SNAPSHOT_DATA_COUNT=''
OWNERSHIP_SNAPSHOT_BINARY_DATA_COUNT=''
OWNERSHIP_SNAPSHOT_CONTRACT_VERSION=''
OWNERSHIP_SNAPSHOT_OWNER=''
OWNERSHIP_SNAPSHOT_CLUSTER_NAME=''
OWNERSHIP_SNAPSHOT_CHECKOUT_ID=''

ownership_fail() {
  builtin printf 'FAIL  ownership     %s\n' "$*" >&2
  return 1
}

ownership_validate_snapshot() {
  local snapshot="${1:-}"
  local -a lines=()
  local LC_ALL=C
  if [[ $# -ne 1 || -z "${snapshot}" ]] ||
    ((${#snapshot} > PLATFORM_OWNERSHIP_SNAPSHOT_MAX_BYTES)); then
    ownership_fail 'ownership snapshot is unavailable'
    return
  fi
  mapfile -t lines <<<"${snapshot}"
  [[ ${#lines[@]} -eq 12 ]] || {
    ownership_fail 'ownership snapshot is malformed'
    return
  }
  [[ "${lines[0]}" == api_version=* &&
    "${lines[1]}" == kind=* &&
    "${lines[2]}" == namespace=* &&
    "${lines[3]}" == name=* &&
    "${lines[4]}" == uid=* &&
    "${lines[5]}" == resource_version=* &&
    "${lines[6]}" == data_count=* &&
    "${lines[7]}" == binary_data_count=* &&
    "${lines[8]}" == contract_version=* &&
    "${lines[9]}" == owner=* &&
    "${lines[10]}" == cluster_name=* &&
    "${lines[11]}" == checkout_id=* ]] || {
    ownership_fail 'ownership snapshot is malformed'
    return
  }

  OWNERSHIP_SNAPSHOT_API_VERSION="${lines[0]#api_version=}"
  OWNERSHIP_SNAPSHOT_KIND="${lines[1]#kind=}"
  OWNERSHIP_SNAPSHOT_NAMESPACE="${lines[2]#namespace=}"
  OWNERSHIP_SNAPSHOT_NAME="${lines[3]#name=}"
  OWNERSHIP_SNAPSHOT_UID="${lines[4]#uid=}"
  OWNERSHIP_SNAPSHOT_RESOURCE_VERSION="${lines[5]#resource_version=}"
  OWNERSHIP_SNAPSHOT_DATA_COUNT="${lines[6]#data_count=}"
  OWNERSHIP_SNAPSHOT_BINARY_DATA_COUNT="${lines[7]#binary_data_count=}"
  OWNERSHIP_SNAPSHOT_CONTRACT_VERSION="${lines[8]#contract_version=}"
  OWNERSHIP_SNAPSHOT_OWNER="${lines[9]#owner=}"
  OWNERSHIP_SNAPSHOT_CLUSTER_NAME="${lines[10]#cluster_name=}"
  OWNERSHIP_SNAPSHOT_CHECKOUT_ID="${lines[11]#checkout_id=}"

  [[ "${OWNERSHIP_SNAPSHOT_API_VERSION}" == v1 &&
    "${OWNERSHIP_SNAPSHOT_KIND}" == ConfigMap &&
    "${OWNERSHIP_SNAPSHOT_NAMESPACE}" == kube-system &&
    "${OWNERSHIP_SNAPSHOT_NAME}" == "${PLATFORM_OWNERSHIP_CONFIGMAP}" &&
    "${OWNERSHIP_SNAPSHOT_UID}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ &&
    "${OWNERSHIP_SNAPSHOT_RESOURCE_VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,255}$ &&
    "${OWNERSHIP_SNAPSHOT_DATA_COUNT}" == 4 &&
    "${OWNERSHIP_SNAPSHOT_BINARY_DATA_COUNT}" == 0 &&
    "${OWNERSHIP_SNAPSHOT_CONTRACT_VERSION}" =~ ^[a-z0-9][a-z0-9.-]{0,63}$ &&
    "${OWNERSHIP_SNAPSHOT_OWNER}" =~ ^[a-z0-9][a-z0-9.-]{0,63}$ &&
    "${OWNERSHIP_SNAPSHOT_CLUSTER_NAME}" =~ ^[a-z0-9][a-z0-9.-]{0,62}$ &&
    "${OWNERSHIP_SNAPSHOT_CHECKOUT_ID}" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    ownership_fail 'ownership snapshot is malformed'
    return
  }
}

ownership_read_snapshot() (
  local capture raw byte_dump size newline_count=0 byte
  local -a pipeline_status=() bytes=()
  local LC_ALL=C
  local template='go-template=api_version={{.apiVersion}}{{"\n"}}'
  template+='kind={{.kind}}{{"\n"}}'
  template+='namespace={{.metadata.namespace}}{{"\n"}}'
  template+='name={{.metadata.name}}{{"\n"}}'
  template+='uid={{.metadata.uid}}{{"\n"}}'
  template+='resource_version={{.metadata.resourceVersion}}{{"\n"}}'
  template+='data_count={{if .data}}{{len .data}}{{else}}0{{end}}{{"\n"}}'
  template+='binary_data_count={{if .binaryData}}{{len .binaryData}}{{else}}0{{end}}{{"\n"}}'
  template+='contract_version={{index .data "contract_version"}}{{"\n"}}'
  template+='owner={{index .data "owner"}}{{"\n"}}'
  template+='cluster_name={{index .data "cluster_name"}}{{"\n"}}'
  template+='checkout_id={{index .data "checkout_id"}}{{"\n"}}'

  capture="$(run_host_command mktemp \
    '/tmp/flare-platform-ownership.XXXXXXXX')" || {
    ownership_fail 'ownership snapshot capture is unavailable'
    return
  }
  trap 'run_host_command rm -f -- "${capture}" >/dev/null 2>&1 || :' EXIT
  set +e
  kubectl_command 15s -n kube-system get configmap \
    "${PLATFORM_OWNERSHIP_CONFIGMAP}" -o "${template}" |
    run_host_command head -c \
      "$((PLATFORM_OWNERSHIP_SNAPSHOT_MAX_BYTES + 1))" >"${capture}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  size="$(run_host_command wc -c <"${capture}")" || return
  [[ "${size}" =~ ^[0-9]+$ ]] || {
    ownership_fail 'ownership snapshot byte count is malformed'
    return
  }
  if ((10#${size} > PLATFORM_OWNERSHIP_SNAPSHOT_MAX_BYTES)); then
    ownership_fail 'ownership snapshot exceeds its byte boundary'
    return
  fi
  if ((pipeline_status[1] != 0)); then
    ownership_fail 'ownership snapshot capture failed'
    return
  fi
  if ((pipeline_status[0] != 0)); then
    ownership_fail 'ownership marker is unreadable'
    return
  fi
  byte_dump="$(run_host_command od -An -v -t u1 -- "${capture}")" || {
    ownership_fail 'ownership snapshot byte validation failed'
    return
  }
  [[ "${byte_dump}" =~ ^[[:space:][:digit:]]+$ ]] || {
    ownership_fail 'ownership snapshot byte validation failed'
    return
  }
  read -r -a bytes <<<"${byte_dump//$'\n'/ }"
  [[ ${#bytes[@]} -eq $((10#${size})) ]] || {
    ownership_fail 'ownership snapshot byte validation failed'
    return
  }
  for byte in "${bytes[@]}"; do
    [[ "${byte}" =~ ^[0-9]+$ ]] || {
      ownership_fail 'ownership snapshot byte validation failed'
      return
    }
    if ((10#${byte} == 0)); then
      ownership_fail 'ownership snapshot contains a forbidden byte'
      return
    fi
    ((10#${byte} == 10)) && ((newline_count += 1))
  done
  [[ ${#bytes[@]} -gt 0 &&
    $((10#${bytes[-1]})) -eq 10 && ${newline_count} -eq 12 ]] || {
    ownership_fail 'ownership snapshot framing is malformed'
    return
  }
  raw="$(run_host_command cat -- "${capture}")" || return
  ownership_validate_snapshot "${raw}" || return
  builtin printf '%s\n' "${raw}"
)

ownership_assert_current_checkout_snapshot() {
  local snapshot="${1:-}" expected_checkout_id
  ownership_validate_snapshot "${snapshot}" || return
  expected_checkout_id="$(platform_checkout_identity)" || return
  if [[ "${OWNERSHIP_SNAPSHOT_CONTRACT_VERSION}" != "${PLATFORM_OWNERSHIP_CONTRACT}" ||
    "${OWNERSHIP_SNAPSHOT_OWNER}" != "${PLATFORM_OWNERSHIP_OWNER}" ||
    "${OWNERSHIP_SNAPSHOT_CLUSTER_NAME}" != "${PLATFORM_CLUSTER_NAME}" ]]; then
    ownership_fail 'refusing cluster with foreign ownership contract'
    return
  fi
  if [[ "${OWNERSHIP_SNAPSHOT_CHECKOUT_ID}" != "${expected_checkout_id}" ]]; then
    ownership_fail 'refusing cluster owned by another checkout'
    return
  fi
}

ownership_current_checkout_snapshot() {
  local snapshot
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null || return
  snapshot="$(ownership_read_snapshot)" || return
  ownership_assert_current_checkout_snapshot "${snapshot}" || return
  builtin printf '%s\n' "${snapshot}"
}

ownership_recheck_snapshot() {
  local expected="${1:-}" current
  [[ $# -eq 1 && -n "${expected}" ]] || {
    ownership_fail 'expected ownership snapshot is missing'
    return
  }
  ownership_assert_current_checkout_snapshot "${expected}" || return
  current="$(ownership_current_checkout_snapshot)" || return
  if [[ "${current}" != "${expected}" ]]; then
    ownership_fail 'ownership marker changed before mutation'
    return
  fi
}

install_ownership_marker() {
  local checkout_id
  checkout_id="$(platform_checkout_identity)" || return
  "${PLATFORM_ROOT}/tools/kubernetes/guard-context.sh" >/dev/null || return
  kubectl_command 30s -n kube-system create configmap \
    "${PLATFORM_OWNERSHIP_CONFIGMAP}" \
    --from-literal="contract_version=${PLATFORM_OWNERSHIP_CONTRACT}" \
    --from-literal="owner=${PLATFORM_OWNERSHIP_OWNER}" \
    --from-literal="cluster_name=${PLATFORM_CLUSTER_NAME}" \
    --from-literal="checkout_id=${checkout_id}"
}
