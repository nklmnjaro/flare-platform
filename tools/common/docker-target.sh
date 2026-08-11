#!/bin/bash -p

# Source-only admission boundary for the Docker daemon used by local runtime
# verification. Callers must source env.sh first so host_command_path and the
# canonical repository roots are available.

case "$(builtin declare -p PLATFORM_DOCKER_TARGET_MODULE_LOADED \
  2>/dev/null || builtin true)" in
  'declare -r PLATFORM_DOCKER_TARGET_MODULE_LOADED="true"') builtin return 0 ;;
esac

builtin unset DOCKER_TARGET_INHERITED_FINGERPRINT 2>/dev/null || {
  builtin printf \
    'FAIL  docker-target unable to establish invocation boundary\n' >&2
  # The exit is the executed-script fallback.
  # shellcheck disable=SC2317
  builtin return 77 2>/dev/null || builtin exit 77
}
DOCKER_TARGET_INHERITED_FINGERPRINT="${DOCKER_TARGET_EXPECTED_FINGERPRINT-}"
for docker_target_name in PLATFORM_DOCKER_TARGET_MODULE_LOADED \
  DOCKER_TARGET_ADMITTED DOCKER_TARGET_DOCKER_PATH DOCKER_TARGET_ENDPOINT \
  DOCKER_TARGET_SOCKET_PATH DOCKER_TARGET_SOCKET_DEVICE \
  DOCKER_TARGET_SOCKET_INODE DOCKER_TARGET_FINGERPRINT \
  DOCKER_TARGET_DISCOVERY DOCKER_TARGET_EXPECTED_FINGERPRINT; do
  builtin unset "${docker_target_name}" || {
    builtin printf \
      'FAIL  docker-target unable to establish invocation boundary\n' >&2
    # The exit is the executed-script fallback.
    # shellcheck disable=SC2317
    builtin return 77 2>/dev/null || builtin exit 77
  }
done
builtin unset docker_target_name
# The readonly marker is consumed by the exact source guard above.
# shellcheck disable=SC2034
builtin readonly PLATFORM_DOCKER_TARGET_MODULE_LOADED=true

DOCKER_TARGET_BOUNDARY_STATUS=77
DOCKER_TARGET_SCHEMA="flare-platform-local-docker-v1"
DOCKER_TARGET_ADMITTED=false
DOCKER_TARGET_DOCKER_PATH=""
DOCKER_TARGET_ENDPOINT=""
DOCKER_TARGET_SOCKET_PATH=""
DOCKER_TARGET_SOCKET_DEVICE=""
DOCKER_TARGET_SOCKET_INODE=""
DOCKER_TARGET_FINGERPRINT=""
DOCKER_TARGET_DISCOVERY=""
DOCKER_TARGET_EXPECTED_FINGERPRINT="${DOCKER_TARGET_INHERITED_FINGERPRINT}"
builtin unset DOCKER_TARGET_INHERITED_FINGERPRINT
builtin readonly DOCKER_TARGET_SAFE_HOME=/nonexistent
if [[ -n "${DOCKER_TARGET_EXPECTED_FINGERPRINT}" &&
  ! "${DOCKER_TARGET_EXPECTED_FINGERPRINT}" =~ ^[0-9a-f]{64}$ ]]; then
  builtin printf 'FAIL  docker-target inherited frozen fingerprint is malformed\n' >&2
  # The exit is the executed-script fallback.
  # shellcheck disable=SC2317
  builtin return 77 2>/dev/null || builtin exit 77
fi

docker_target_fail() {
  printf 'FAIL  docker-target %s\n' "$*" >&2
  return "${DOCKER_TARGET_BOUNDARY_STATUS}"
}

docker_target_variable_is_set() {
  [[ -v "$1" ]]
}

docker_target_resolve_executable() {
  local lookup admitted
  lookup="$(builtin type -P docker 2>/dev/null)" || {
    docker_target_fail 'Docker executable is unavailable'
    return
  }
  admitted="$(host_command_path docker)" || return
  if [[ "${lookup}" != "${admitted}" ]]; then
    docker_target_fail 'Docker PATH lookup is not a canonical direct executable'
    return
  fi
  printf '%s\n' "${admitted}"
}

docker_target_cleanup_child_state() {
  local root="$1" expected_device="$2" expected_inode="$3" record
  case "${root}" in
    /tmp/flare-platform-docker-child.*) ;;
    *)
      docker_target_fail 'refusing unsafe Docker child-state cleanup'
      return
      ;;
  esac
  if [[ -L "${root}" || ! -d "${root}" ]]; then
    docker_target_fail 'Docker child state changed type before cleanup'
    return
  fi
  record="$(run_host_command stat -Lc '%d|%i' -- "${root}")" || return
  if [[ "${record}" != "${expected_device}|${expected_inode}" ]]; then
    docker_target_fail 'Docker child state changed identity before cleanup'
    return
  fi
  run_host_command rm -rf -- "${root}"
}

docker_target_run_child() (
  local root record device inode owner mode extra
  local command_status=0 cleanup_status=0
  if [[ -e "${DOCKER_TARGET_SAFE_HOME}" || -L "${DOCKER_TARGET_SAFE_HOME}" ]]; then
    docker_target_fail 'safe Docker child home is unexpectedly present'
    return
  fi
  root="$(run_host_command mktemp -d \
    /tmp/flare-platform-docker-child.XXXXXXXX)" || return
  if [[ -L "${root}" || ! -d "${root}" ]]; then
    docker_target_fail 'Docker child state is unsafe'
    return
  fi
  record="$(run_host_command stat -Lc '%d|%i|%u|%a' -- "${root}")" || {
    run_host_command rm -rf -- "${root}" || true
    return
  }
  IFS='|' read -r device inode owner mode extra <<<"${record}" || true
  trap 'docker_target_cleanup_child_state "${root}" "${device}" "${inode}" || true' EXIT
  if [[ ! "${device}" =~ ^[0-9]+$ || ! "${inode}" =~ ^[0-9]+$ ||
    "${owner}" != "${EUID}" || "${mode}" != 700 || -n "${extra}" ]]; then
    docker_target_fail 'Docker child state ownership is unsafe'
    return
  fi
  run_host_command mkdir -- "${root}/docker" "${root}/buildx" || return
  run_host_command chmod 0700 -- "${root}/docker" "${root}/buildx" || return
  unset DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS DOCKER_TLS_VERIFY
  unset DOCKER_CERT_PATH BUILDX_BUILDER BUILDKIT_HOST BUILDX_CONFIG
  unset DOCKER_API_VERSION DOCKER_CUSTOM_HEADERS DOCKER_DEFAULT_PLATFORM
  unset BUILDX_NO_DEFAULT_LOAD EXPERIMENTAL_BUILDKIT_SOURCE_POLICY
  unset KIND_EXPERIMENTAL_PROVIDER KIND_EXPERIMENTAL_DOCKER_NETWORK
  unset KIND_EXPERIMENTAL_PODMAN_NETWORK
  unset KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER
  unset KIND_CLUSTER_NAME KIND_DNS_SEARCH
  export HOME="${DOCKER_TARGET_SAFE_HOME}"
  # These values intentionally exist only for the bounded child invocation.
  # shellcheck disable=SC2030
  export DOCKER_CONFIG="${root}/docker" BUILDX_CONFIG="${root}/buildx"
  # shellcheck disable=SC2030
  export DOCKER_HOST="${DOCKER_TARGET_ENDPOINT}" DOCKER_BUILDKIT=1
  export PATH="${PLATFORM_HOST_PATH}"
  "$@" || command_status=$?
  docker_target_cleanup_child_state \
    "${root}" "${device}" "${inode}" || cleanup_status=$?
  trap - EXIT
  ((cleanup_status == 0)) || return "${cleanup_status}"
  return "${command_status}"
)

docker_target_reject_remote_controls() {
  local variable
  for variable in DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH \
    BUILDX_BUILDER BUILDKIT_HOST BUILDX_CONFIG DOCKER_API_VERSION \
    DOCKER_CUSTOM_HEADERS DOCKER_DEFAULT_PLATFORM BUILDX_NO_DEFAULT_LOAD \
    EXPERIMENTAL_BUILDKIT_SOURCE_POLICY; do
    if docker_target_variable_is_set "${variable}"; then
      docker_target_fail "inherited ${variable} is unsupported for local verification"
      return
    fi
  done
  # The parent value is intentionally independent of child-only exports.
  # shellcheck disable=SC2031
  if docker_target_variable_is_set DOCKER_BUILDKIT &&
    [[ "${DOCKER_BUILDKIT}" != 1 ]]; then
    docker_target_fail 'inherited DOCKER_BUILDKIT must be unset or exactly 1'
    return
  fi
  if docker_target_variable_is_set DOCKER_HOST &&
    docker_target_variable_is_set DOCKER_CONTEXT; then
    docker_target_fail \
      'DOCKER_HOST and DOCKER_CONTEXT cannot both select the local target'
    return
  fi
  return 0
}

docker_target_validate_config_path() {
  # The parent value is intentionally independent of child-only exports.
  # shellcheck disable=SC2031
  local configured="${DOCKER_CONFIG-}" canonical
  docker_target_variable_is_set DOCKER_CONFIG || return 0
  if [[ -z "${configured}" || "${configured}" != /* ||
    "${configured}" == *$'\n'* || "${configured}" == *$'\r'* ||
    "${configured}" == *$'\t'* || -L "${configured}" ||
    ! -d "${configured}" ]]; then
    docker_target_fail 'DOCKER_CONFIG must name an external absolute directory'
    return
  fi
  canonical="$(run_host_command readlink -f -- "${configured}")" || {
    docker_target_fail 'DOCKER_CONFIG cannot be canonicalized'
    return
  }
  case "${canonical}" in
    "${PLATFORM_ROOT}" | "${PLATFORM_ROOT}"/* | \
      "${PLATFORM_STATE_DIR}" | "${PLATFORM_STATE_DIR}"/*)
      docker_target_fail 'DOCKER_CONFIG cannot resolve inside repository state'
      return
      ;;
  esac
  DOCKER_CONFIG="${canonical}"
  export DOCKER_CONFIG
}

docker_target_discovery_command() (
  local duration="$1"
  shift
  local timeout_path
  timeout_path="$(host_command_path timeout)" || return
  unset DOCKER_HOST DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH
  unset BUILDX_BUILDER BUILDKIT_HOST BUILDX_CONFIG
  "${timeout_path}" --foreground --signal=TERM --kill-after=2s \
    "${duration}" "$@"
)

docker_target_validate_context_name() {
  local context="$1"
  [[ "${context}" =~ ^[0-9A-Za-z][0-9A-Za-z_.+-]{0,127}$ ]] || {
    docker_target_fail 'effective Docker context name is unsafe or ambiguous'
    return
  }
}

docker_target_context_endpoint() {
  local docker_path="$1" context="$2" response name endpoint skip_tls
  docker_target_validate_context_name "${context}" || return
  response="$(docker_target_discovery_command 10s "${docker_path}" \
    context inspect --format \
    '{{.Name}}|{{(index .Endpoints "docker").Host}}|{{(index .Endpoints "docker").SkipTLSVerify}}' \
    "${context}" 2>/dev/null)" || {
    docker_target_fail 'effective Docker context cannot be inspected locally'
    return
  }
  if ((${#response} < 1 || ${#response} > 8192)) ||
    [[ "${response}" == *$'\n'* || "${response}" == *$'\r'* ||
      "${response}" == *$'\t'* ]]; then
    docker_target_fail 'effective Docker context response is malformed'
    return
  fi
  if [[ ! "${response}" =~ ^([^|]+)\|([^|]+)\|(true|false)$ ]]; then
    docker_target_fail 'effective Docker context response is malformed'
    return
  fi
  name="${BASH_REMATCH[1]}"
  endpoint="${BASH_REMATCH[2]}"
  skip_tls="${BASH_REMATCH[3]}"
  if [[ "${name}" != "${context}" || "${skip_tls}" != false ]]; then
    docker_target_fail 'effective Docker context response is malformed'
    return
  fi
  printf '%s\n' "${endpoint}"
}

docker_target_effective_endpoint() {
  local docker_path="$1" context endpoint
  # The parent value is intentionally independent of child-only exports.
  # shellcheck disable=SC2031
  if docker_target_variable_is_set DOCKER_HOST; then
    printf '%s\n' "${DOCKER_HOST}"
    return 0
  fi
  if docker_target_variable_is_set DOCKER_CONTEXT; then
    context="${DOCKER_CONTEXT}"
  else
    context="$(docker_target_discovery_command 10s "${docker_path}" \
      context show 2>/dev/null)" || {
      docker_target_fail 'effective Docker context cannot be determined locally'
      return
    }
    if ((${#context} < 1 || ${#context} > 128)) ||
      [[ "${context}" == *$'\n'* || "${context}" == *$'\r'* ||
        "${context}" == *$'\t'* ]]; then
      docker_target_fail 'effective Docker context name is malformed'
      return
    fi
  fi
  endpoint="$(docker_target_context_endpoint "${docker_path}" "${context}")" || return
  printf '%s\n' "${endpoint}"
}

docker_target_path_is_project_owned() {
  local path="$1"
  case "${path}" in
    "${PLATFORM_ROOT}" | "${PLATFORM_ROOT}"/* | \
      "${PLATFORM_STATE_DIR}" | "${PLATFORM_STATE_DIR}"/*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

docker_target_fingerprint() {
  local docker_path="$1" endpoint="$2" device="$3" inode="$4"
  local output digest
  output="$({
    printf '%s\n' "${DOCKER_TARGET_SCHEMA}"
    printf '%s\n' "${docker_path}"
    printf '%s\n' "${endpoint}"
    printf '%s\n' "${device}"
    printf '%s\n' "${inode}"
  } | run_host_command sha256sum --)" || return
  digest="${output%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "${digest}"
}

docker_target_admit_endpoint() {
  local docker_path="$1" endpoint="$2"
  local socket canonical stat_record device inode extra fingerprint
  if [[ -z "${endpoint}" || ${#endpoint} -gt 4096 ||
    "${endpoint}" == *$'\n'* || "${endpoint}" == *$'\r'* ||
    "${endpoint}" == *$'\t'* || "${endpoint}" != unix:///* ]]; then
    docker_target_fail 'remote or non-Unix Docker endpoint is unsupported'
    return
  fi
  socket="${endpoint#unix://}"
  if [[ "${socket}" != /* || "${socket}" == *'?'* ||
    "${socket}" == *'#'* || "${socket}" == *'%'* ]]; then
    docker_target_fail 'local Docker Unix socket path is unsafe or ambiguous'
    return
  fi
  canonical="$(run_host_command readlink -f -- "${socket}" 2>/dev/null)" || {
    docker_target_fail 'local Docker Unix socket cannot be canonicalized'
    return
  }
  if [[ "${canonical}" != /* || -L "${canonical}" || ! -S "${canonical}" ]] ||
    docker_target_path_is_project_owned "${canonical}"; then
    docker_target_fail 'Docker endpoint is not an external local Unix socket'
    return
  fi
  stat_record="$(run_host_command stat -Lc '%d|%i' -- "${canonical}")" || {
    docker_target_fail 'local Docker Unix socket identity is unavailable'
    return
  }
  IFS='|' read -r device inode extra <<<"${stat_record}" || true
  if [[ ! "${device}" =~ ^[0-9]+$ || ! "${inode}" =~ ^[0-9]+$ ||
    -n "${extra}" ]]; then
    docker_target_fail 'local Docker Unix socket identity is malformed'
    return
  fi
  endpoint="unix://${canonical}"
  fingerprint="$(docker_target_fingerprint \
    "${docker_path}" "${endpoint}" "${device}" "${inode}")" || {
    docker_target_fail 'local Docker target fingerprint is unavailable'
    return
  }
  DOCKER_TARGET_DOCKER_PATH="${docker_path}"
  DOCKER_TARGET_ENDPOINT="${endpoint}"
  DOCKER_TARGET_SOCKET_PATH="${canonical}"
  DOCKER_TARGET_SOCKET_DEVICE="${device}"
  DOCKER_TARGET_SOCKET_INODE="${inode}"
  DOCKER_TARGET_FINGERPRINT="${fingerprint}"
  DOCKER_TARGET_ADMITTED=true
}

docker_target_probe_local_daemon() {
  local response timeout_path identity_pattern
  timeout_path="$(host_command_path timeout)" || return
  # PATH is intentionally narrowed inside this command-substitution child.
  # shellcheck disable=SC2030
  response="$(
    docker_target_run_child \
      "${timeout_path}" --foreground --signal=TERM --kill-after=2s 10s \
      "${DOCKER_TARGET_DOCKER_PATH}" version --format \
      '{{.Client.Version}}|{{.Server.Version}}|{{.Server.Os}}|{{.Server.Arch}}'
  )" 2>/dev/null || {
    docker_target_fail 'local Docker daemon identity is unavailable'
    return
  }
  identity_pattern='^([0-9]+\.[0-9]+\.[0-9]+)\|'
  identity_pattern+='([0-9]+\.[0-9]+\.[0-9]+)\|(linux)\|(amd64)$'
  if [[ ! "${response}" =~ ${identity_pattern} ]]; then
    docker_target_fail 'local Docker daemon identity is malformed'
    return
  fi
}

docker_target_publish_frozen_environment() {
  unset DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS DOCKER_TLS_VERIFY
  unset DOCKER_CERT_PATH BUILDX_BUILDER BUILDKIT_HOST BUILDX_CONFIG
  unset DOCKER_API_VERSION DOCKER_CUSTOM_HEADERS DOCKER_DEFAULT_PLATFORM
  unset BUILDX_NO_DEFAULT_LOAD EXPERIMENTAL_BUILDKIT_SOURCE_POLICY
  DOCKER_HOST="${DOCKER_TARGET_ENDPOINT}"
  DOCKER_BUILDKIT=1
  export DOCKER_HOST DOCKER_BUILDKIT
  export DOCKER_TARGET_ADMITTED DOCKER_TARGET_DOCKER_PATH
  export DOCKER_TARGET_ENDPOINT DOCKER_TARGET_SOCKET_PATH
  export DOCKER_TARGET_SOCKET_DEVICE DOCKER_TARGET_SOCKET_INODE
  export DOCKER_TARGET_FINGERPRINT DOCKER_TARGET_DISCOVERY
  export DOCKER_TARGET_EXPECTED_FINGERPRINT
}

docker_target_assert_frozen() {
  local docker_path canonical stat_record device inode extra fingerprint variable
  if [[ "${DOCKER_TARGET_ADMITTED}" != true ||
    ! "${DOCKER_TARGET_FINGERPRINT}" =~ ^[0-9a-f]{64}$ ||
    ! "${DOCKER_TARGET_DISCOVERY}" =~ ^(host_override|explicit_context|selected_context)$ ||
    ! "${DOCKER_TARGET_SOCKET_DEVICE}" =~ ^[0-9]+$ ||
    ! "${DOCKER_TARGET_SOCKET_INODE}" =~ ^[0-9]+$ ||
    "${DOCKER_TARGET_ENDPOINT}" != "unix://${DOCKER_TARGET_SOCKET_PATH}" ||
    "${DOCKER_HOST-}" != "${DOCKER_TARGET_ENDPOINT}" ||
    "${DOCKER_BUILDKIT-}" != 1 ]]; then
    docker_target_fail 'frozen local Docker target is absent or changed'
    return
  fi
  for variable in DOCKER_CONTEXT DOCKER_CONFIG DOCKER_TLS DOCKER_TLS_VERIFY \
    DOCKER_CERT_PATH BUILDX_BUILDER BUILDKIT_HOST BUILDX_CONFIG \
    DOCKER_API_VERSION DOCKER_CUSTOM_HEADERS DOCKER_DEFAULT_PLATFORM \
    BUILDX_NO_DEFAULT_LOAD EXPERIMENTAL_BUILDKIT_SOURCE_POLICY; do
    if docker_target_variable_is_set "${variable}"; then
      docker_target_fail "frozen Docker environment drifted through ${variable}"
      return
    fi
  done
  docker_path="$(docker_target_resolve_executable)" || return
  if [[ "${docker_path}" != "${DOCKER_TARGET_DOCKER_PATH}" ]]; then
    docker_target_fail 'admitted Docker executable changed during the run'
    return
  fi
  canonical="$(run_host_command readlink -f -- \
    "${DOCKER_TARGET_SOCKET_PATH}" 2>/dev/null)" || {
    docker_target_fail 'frozen Docker Unix socket disappeared'
    return
  }
  if [[ "${canonical}" != "${DOCKER_TARGET_SOCKET_PATH}" ||
    ! -S "${canonical}" ]] || docker_target_path_is_project_owned "${canonical}"; then
    docker_target_fail 'frozen Docker Unix socket changed type or target'
    return
  fi
  stat_record="$(run_host_command stat -Lc '%d|%i' -- "${canonical}")" || {
    docker_target_fail 'frozen Docker Unix socket identity is unavailable'
    return
  }
  IFS='|' read -r device inode extra <<<"${stat_record}" || true
  if [[ "${device}" != "${DOCKER_TARGET_SOCKET_DEVICE}" ||
    "${inode}" != "${DOCKER_TARGET_SOCKET_INODE}" || -n "${extra}" ]]; then
    docker_target_fail 'frozen Docker Unix socket identity drifted'
    return
  fi
  fingerprint="$(docker_target_fingerprint "${docker_path}" \
    "${DOCKER_TARGET_ENDPOINT}" "${device}" "${inode}")" || return
  if [[ "${fingerprint}" != "${DOCKER_TARGET_FINGERPRINT}" ]]; then
    docker_target_fail 'frozen Docker target fingerprint drifted'
    return
  fi
  return 0
}

docker_target_ensure() {
  local docker_path endpoint
  if [[ "${DOCKER_TARGET_ADMITTED}" == true ]]; then
    docker_target_assert_frozen || return
    return 0
  fi
  docker_target_reject_remote_controls || return
  docker_target_validate_config_path || return
  DOCKER_TARGET_DOCKER_PATH=""
  DOCKER_TARGET_ENDPOINT=""
  DOCKER_TARGET_SOCKET_PATH=""
  DOCKER_TARGET_SOCKET_DEVICE=""
  DOCKER_TARGET_SOCKET_INODE=""
  DOCKER_TARGET_FINGERPRINT=""
  docker_path="$(docker_target_resolve_executable)" || return
  if docker_target_variable_is_set DOCKER_HOST; then
    DOCKER_TARGET_DISCOVERY=host_override
  elif docker_target_variable_is_set DOCKER_CONTEXT; then
    DOCKER_TARGET_DISCOVERY=explicit_context
  else
    DOCKER_TARGET_DISCOVERY=selected_context
  fi
  endpoint="$(docker_target_effective_endpoint "${docker_path}")" || return
  docker_target_admit_endpoint "${docker_path}" "${endpoint}" || return
  if [[ -n "${DOCKER_TARGET_EXPECTED_FINGERPRINT}" &&
    "${DOCKER_TARGET_EXPECTED_FINGERPRINT}" != "${DOCKER_TARGET_FINGERPRINT}" ]]; then
    docker_target_fail 'local Docker target changed from the parent invocation'
    return
  fi
  docker_target_probe_local_daemon || return
  DOCKER_TARGET_EXPECTED_FINGERPRINT="${DOCKER_TARGET_FINGERPRINT}"
  docker_target_publish_frozen_environment
  docker_target_assert_frozen
}

docker_target_path() {
  docker_target_ensure || return
  printf '%s\n' "${DOCKER_TARGET_DOCKER_PATH}"
}

docker_target_run_bounded() (
  local duration="$1"
  shift
  local timeout_path
  docker_target_ensure || return
  timeout_path="$(host_command_path timeout)" || return
  docker_target_run_child \
    "${timeout_path}" --foreground --signal=TERM --kill-after=5s \
    "${duration}" "$@"
)
