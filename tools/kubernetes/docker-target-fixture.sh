#!/bin/bash -p

# Explicit dependency adapter for isolated Kubernetes shell fixtures only.
# Production scripts never source this file. prove-safety copies it over the
# fixture repository's docker-target.sh and keeps the production module beside
# it as docker-target-production.sh.

DOCKER_TARGET_FIXTURE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DOCKER_TARGET_FIXTURE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  DOCKER_TARGET_FIXTURE_SOURCE_DIR=.
# shellcheck source=../common/docker-target.sh
builtin source "${DOCKER_TARGET_FIXTURE_SOURCE_DIR}/docker-target-production.sh"
unset DOCKER_TARGET_FIXTURE_SOURCE_DIR

DOCKER_TARGET_TEST_ADAPTER_STATUS=78
DOCKER_TARGET_TEST_CONTRACT_EXPECTED="flare-platform-docker-target-fixture-v1"
DOCKER_TARGET_TEST_ADAPTER_SOURCE="$(run_host_command readlink -f -- \
  "${BASH_SOURCE[0]}")" || return
DOCKER_TARGET_TEST_EXPECTED_PATH=""
DOCKER_TARGET_TEST_EXPECTED_ENDPOINT=""
DOCKER_TARGET_TEST_EXPECTED_FINGERPRINT=""

docker_target_fixture_fail() {
  printf 'FAIL  docker-test   %s\n' "$*" >&2
  return "${DOCKER_TARGET_TEST_ADAPTER_STATUS}"
}

docker_target_fixture_validate() {
  local root="${PLATFORM_DOCKER_TEST_ROOT-}"
  local token="${PLATFORM_DOCKER_TEST_TOKEN-}"
  local canonical candidate expected_production expected_root marker_size
  local -a owner_lines=()
  if [[ "${PLATFORM_DOCKER_TEST_CONTRACT-}" != "${DOCKER_TARGET_TEST_CONTRACT_EXPECTED}" ]]; then
    docker_target_fixture_fail 'exact fixture contract is absent'
    return
  fi
  if [[ "${root}" != /* || -z "${token}" ||
    ! "${token}" =~ ^[0-9A-Za-z._:-]{8,128}$ ||
    -L "${root}" || ! -d "${root}" ]]; then
    docker_target_fixture_fail 'fixture root or ownership token is unsafe'
    return
  fi
  expected_production="${PLATFORM_ROOT}/tools/common/docker-target-production.sh"
  canonical="$(run_host_command readlink -f -- "${expected_production}")" || {
    docker_target_fixture_fail 'production Docker dependency cannot be canonicalized'
    return
  }
  if [[ "${DOCKER_TARGET_TEST_ADAPTER_SOURCE}" != "${PLATFORM_ROOT}/tools/common/docker-target.sh" ||
    "${canonical}" != "${expected_production}" ||
    -L "${expected_production}" || ! -f "${expected_production}" ]]; then
    docker_target_fixture_fail 'fixture adapter source is not the expected repository dependency'
    return
  fi
  expected_root="${PLATFORM_ROOT}/.platform-test/docker-target"
  if [[ "${root}" != "${expected_root}" ]]; then
    docker_target_fixture_fail 'fixture root is not the expected repository subdirectory'
    return
  fi
  canonical="$(run_host_command readlink -f -- "${root}")" || {
    docker_target_fixture_fail 'fixture root cannot be canonicalized'
    return
  }
  if [[ "${canonical}" != "${root}" ||
    -L "${root}/.docker-target-owner" ||
    ! -f "${root}/.docker-target-owner" ]]; then
    docker_target_fixture_fail 'fixture ownership marker is unsafe'
    return
  fi
  mapfile -t owner_lines <"${root}/.docker-target-owner" || {
    docker_target_fixture_fail 'fixture ownership marker is unreadable'
    return
  }
  marker_size="$(run_host_command stat -Lc '%s' -- \
    "${root}/.docker-target-owner")" || {
    docker_target_fixture_fail 'fixture ownership marker size is unavailable'
    return
  }
  if [[ "${#owner_lines[@]}" -ne 1 || "${owner_lines[0]}" != "${token}" ||
    "${marker_size}" != "$((${#token} + 1))" ]]; then
    docker_target_fixture_fail 'fixture ownership token differs'
    return
  fi
  candidate="${root}/docker"
  if [[ -L "${candidate}" || ! -f "${candidate}" ||
    ! -x "${candidate}" ]]; then
    docker_target_fixture_fail 'fixture Docker adapter is unsafe'
    return
  fi
  candidate="$(run_host_command readlink -f -- "${candidate}")" || {
    docker_target_fixture_fail 'fixture Docker adapter cannot be canonicalized'
    return
  }
  case "${candidate}" in
    "${root}"/*) ;;
    *)
      docker_target_fixture_fail 'fixture Docker adapter escaped its root'
      return
      ;;
  esac
  DOCKER_TARGET_TEST_EXPECTED_PATH="${candidate}"
  DOCKER_TARGET_TEST_EXPECTED_ENDPOINT="unix://${root}/docker.sock"
  DOCKER_TARGET_TEST_EXPECTED_FINGERPRINT="$(docker_target_fingerprint \
    "${candidate}" "${DOCKER_TARGET_TEST_EXPECTED_ENDPOINT}" 0 0)" || {
    docker_target_fixture_fail 'fixture Docker fingerprint is unavailable'
    return
  }
  return 0
}

docker_target_assert_frozen() {
  local variable
  docker_target_fixture_validate || return
  if [[ "${DOCKER_TARGET_ADMITTED}" != true ||
    "${DOCKER_TARGET_DOCKER_PATH}" != "${DOCKER_TARGET_TEST_EXPECTED_PATH}" ||
    "${DOCKER_TARGET_ENDPOINT}" != "${DOCKER_TARGET_TEST_EXPECTED_ENDPOINT}" ||
    "${DOCKER_TARGET_SOCKET_PATH}" != "${PLATFORM_DOCKER_TEST_ROOT}/docker.sock" ||
    "${DOCKER_TARGET_SOCKET_DEVICE}" != 0 ||
    "${DOCKER_TARGET_SOCKET_INODE}" != 0 ||
    "${DOCKER_TARGET_DISCOVERY}" != test_adapter ||
    "${DOCKER_TARGET_FINGERPRINT}" != "${DOCKER_TARGET_TEST_EXPECTED_FINGERPRINT}" ||
    "${DOCKER_HOST-}" != "${DOCKER_TARGET_ENDPOINT}" ||
    "${DOCKER_BUILDKIT-}" != 1 ]]; then
    docker_target_fixture_fail 'fixture Docker environment drifted'
    return
  fi
  for variable in DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS DOCKER_TLS_VERIFY \
    DOCKER_CERT_PATH BUILDX_BUILDER BUILDKIT_HOST BUILDX_CONFIG \
    DOCKER_API_VERSION DOCKER_CUSTOM_HEADERS DOCKER_DEFAULT_PLATFORM \
    BUILDX_NO_DEFAULT_LOAD EXPERIMENTAL_BUILDKIT_SOURCE_POLICY; do
    if docker_target_variable_is_set "${variable}"; then
      docker_target_fixture_fail \
        "fixture Docker environment drifted through ${variable}"
      return
    fi
  done
  return 0
}

docker_target_ensure() {
  if [[ "${DOCKER_TARGET_ADMITTED}" == true ]]; then
    docker_target_assert_frozen || return
    return 0
  fi
  docker_target_fixture_validate || return
  DOCKER_TARGET_DOCKER_PATH="${DOCKER_TARGET_TEST_EXPECTED_PATH}"
  DOCKER_TARGET_ENDPOINT="${DOCKER_TARGET_TEST_EXPECTED_ENDPOINT}"
  DOCKER_TARGET_SOCKET_PATH="${PLATFORM_DOCKER_TEST_ROOT}/docker.sock"
  DOCKER_TARGET_SOCKET_DEVICE=0
  DOCKER_TARGET_SOCKET_INODE=0
  DOCKER_TARGET_DISCOVERY=test_adapter
  DOCKER_TARGET_FINGERPRINT="${DOCKER_TARGET_TEST_EXPECTED_FINGERPRINT}"
  DOCKER_TARGET_ADMITTED=true
  docker_target_publish_frozen_environment
  docker_target_assert_frozen
}
