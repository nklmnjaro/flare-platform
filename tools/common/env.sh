#!/usr/bin/env bash
# Source module exports are consumed by callers and child processes.
# shellcheck disable=SC2034
builtin set -euo pipefail

PLATFORM_CALLER_HOST_PATH="${PATH-}"
builtin export -n PLATFORM_CALLER_HOST_PATH
builtin unset BASH_ENV ENV TAR_OPTIONS GZIP POSIXLY_CORRECT
builtin unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
builtin unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
builtin unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
builtin unset GIT_CONFIG_PARAMETERS GIT_EXTERNAL_DIFF GIT_DIFF_OPTS
builtin unset GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
builtin unset MAKEFILES MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
builtin export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
builtin export GIT_CONFIG_COUNT=1
builtin export GIT_CONFIG_KEY_0=core.fsmonitor
builtin export GIT_CONFIG_VALUE_0=false
PLATFORM_ENV_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PLATFORM_ENV_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PLATFORM_ENV_SOURCE_DIR=.
PLATFORM_ROOT="$(builtin cd -P -- "${PLATFORM_ENV_SOURCE_DIR}/../.." &&
  builtin pwd -P)"
builtin export PLATFORM_ROOT
builtin export PLATFORM_STATE_DIR="${PLATFORM_ROOT}/.platform"
AQUA_ROOT_DIR="${PLATFORM_STATE_DIR}/aqua"
AQUA_CONFIG="${PLATFORM_ROOT}/aqua.yaml"
builtin export -n AQUA_ROOT_DIR AQUA_CONFIG
builtin export KUBECONFIG="${PLATFORM_STATE_DIR}/kubeconfig"
builtin export PLATFORM_DIAGNOSTICS_DIR="${PLATFORM_STATE_DIR}/diagnostics/raw"
builtin export TRIVY_CACHE_DIR="${PLATFORM_STATE_DIR}/trivy"
builtin export TRIVY_NO_PROGRESS=true
builtin export PLATFORM_KUBERNETES_SCHEMA_VERSION="1.36.1"

builtin source "${PLATFORM_ROOT}/tools/common/host-commands.sh"
host_command_initialize || {
  platform_env_status=$?
  # The exit is the executed-script fallback.
  # shellcheck disable=SC2317
  builtin return "${platform_env_status}" 2>/dev/null ||
    builtin exit "${platform_env_status}"
}
builtin source "${PLATFORM_ROOT}/tools/common/state.sh"
assert_existing_state_directory "aqua/bin" || {
  # The exit is the executed-script fallback.
  # shellcheck disable=SC2317
  builtin return 1 2>/dev/null || builtin exit 1
}
assert_existing_state_directory "bootstrap" || {
  # The exit is the executed-script fallback.
  # shellcheck disable=SC2317
  builtin return 1 2>/dev/null || builtin exit 1
}

PLATFORM_CLUSTER_NAME="flare-platform-dev"
PLATFORM_CONTEXT="kind-${PLATFORM_CLUSTER_NAME}"
PLATFORM_NAMESPACE="flare-platform-reference"
PLATFORM_IMAGE="flare-platform-reference:dev"
builtin export PLATFORM_CLUSTER_NAME PLATFORM_CONTEXT PLATFORM_NAMESPACE \
  PLATFORM_IMAGE
builtin unset PLATFORM_ENV_SOURCE_DIR
builtin unset platform_env_status
